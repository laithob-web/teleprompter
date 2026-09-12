import Foundation

/// Loads a script straight from Google Docs.
///
/// Uses Google's public export endpoint rather than the Drive API, so there is
/// no OAuth, no API key, and nothing to configure — at the cost of requiring the
/// document to be link-shared.
///
/// Exports **HTML rather than plain text** on purpose: the txt export flattens
/// headings into ordinary lines, which would destroy the `## question` structure
/// the matcher depends on. The HTML export keeps `<h1>`–`<h6>`, so real Google
/// Docs headings survive as real script sections.
enum GoogleDocsLoader {

    enum LoadError: LocalizedError {
        case notADocsURL
        case notShared
        case network(String)
        case emptyDocument

        var errorDescription: String? {
            switch self {
            case .notADocsURL:
                return "That does not look like a Google Docs link. It should look like "
                     + "https://docs.google.com/document/d/…"
            case .notShared:
                // Google answers 404 both for "exists but you may not see it" and
                // "no such document", so this message must cover both rather than
                // send you to fix sharing on a document that was never there.
                return """
                    Google would not return that document. Either it is not shared, \
                    or the link points at nothing.

                    Check both:
                    • The link is a real document you can open in your browser
                    • Share → General access → "Anyone with the link" → Viewer
                    """
            case .network(let detail):
                return "Could not reach Google Docs: \(detail)"
            case .emptyDocument:
                return "That document came back empty."
            }
        }
    }

    // MARK: - URL handling

    /// Pulls the document id out of the several URL shapes Google hands out.
    ///
    /// Handles /document/d/<id>/edit, /document/u/0/d/<id>/…, trailing query
    /// strings and fragments, and a bare id pasted on its own.
    static func documentID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let pattern = #"/document/(?:u/\d+/)?d/([a-zA-Z0-9_-]{10,})"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(
               in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)
           ),
           let range = Range(match.range(at: 1), in: trimmed) {
            return String(trimmed[range])
        }

        // A bare document id, which is what a .gdoc file stores.
        if trimmed.range(of: #"^[a-zA-Z0-9_-]{20,}$"#, options: .regularExpression) != nil {
            return trimmed
        }
        return nil
    }

    /// Reads the id out of a `.gdoc` stub, the JSON placeholder that Google
    /// Drive for Desktop leaves in your Drive folder.
    static func documentID(fromGDocFileAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }

        if let id = dictionary["doc_id"] as? String, !id.isEmpty { return id }
        if let link = dictionary["url"] as? String { return documentID(from: link) }
        return nil
    }

    // MARK: - Fetch

    /// Downloads a document and returns it as markdown this app's parser accepts.
    static func fetchMarkdown(documentID id: String) async throws -> String {
        guard let url = URL(
            string: "https://docs.google.com/document/d/\(id)/export?format=html"
        ) else { throw LoadError.notADocsURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LoadError.network(error.localizedDescription)
        }

        // A private document redirects to the sign-in page rather than failing,
        // so a 200 here does not by itself mean success.
        if let host = response.url?.host, host.contains("accounts.google.com") {
            throw LoadError.notShared
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw http.statusCode == 404 ? LoadError.notShared
                                         : LoadError.network("HTTP \(http.statusCode)")
        }

        let html = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        if html.contains("accounts.google.com/ServiceLogin")
            || html.contains("Sign in - Google Accounts") {
            throw LoadError.notShared
        }

        let markdown = convertToMarkdown(html)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LoadError.emptyDocument
        }
        return markdown
    }

    // MARK: - HTML to markdown

    /// Deliberately minimal: headings, paragraphs, list items, line breaks.
    /// Everything else is dropped, because a teleprompter only ever renders
    /// plain text and section structure.
    static func convertToMarkdown(_ html: String) -> String {
        var text = html

        text = replace(text, #"(?s)<(script|style|head)\b[^>]*>.*?</\1>"#, with: "")
        text = replace(text, #"(?i)<br\s*/?>"#, with: "\n")
        text = replace(text, #"(?is)<h[1-6][^>]*>(.*?)</h[1-6]>"#,
                       with: "\n\n" + headingMarker + "$1\n\n")
        text = writeListMarkers(text)
        text = replace(text, #"(?is)</p\s*>"#, with: "\n\n")
        text = replace(text, #"(?is)</t[dh]\s*>"#, with: "\n")
        text = replace(text, #"(?is)</tr\s*>"#, with: "\n")
        text = replace(text, #"(?s)<[^>]+>"#, with: "")

        text = decodeEntities(text)

        // Google wraps headings in spans, so a heading can arrive padded or split;
        // normalise whitespace inside each line, and resolve the heading marker
        // here with plain string operations.
        //
        // Deliberately not a regex: the marker is U+0001, and inside a Swift raw
        // string `\u{1}` is passed through as four literal characters rather than
        // the control character, so the pattern silently never matches and every
        // heading in the document is quietly demoted to body text.
        let lines = text.components(separatedBy: .newlines).map { line -> String in
            var cleaned = line
                .replacingOccurrences(
                    of: #"[ \t\u{00A0}]+"#, with: " ", options: .regularExpression
                )
                .trimmingCharacters(in: .whitespaces)

            guard cleaned.hasPrefix(headingMarker) else { return cleaned }
            cleaned = String(cleaned.dropFirst(headingMarker.count))
            // Strip any "#" the author typed inside the heading itself, so a
            // heading reading "## 4 · Openers" cannot become "## ## 4 · Openers".
            while cleaned.hasPrefix("#") { cleaned = String(cleaned.dropFirst()) }
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? "" : "## " + cleaned
        }
        text = lines.joined(separator: "\n")
        text = replace(text, #"\n{3,}"#, with: "\n\n")
        text = text.replacingOccurrences(of: headingMarker, with: "")

        return promoteQuestionLines(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Lists

    /// Writes list numbers and bullets into the text.
    ///
    /// Google Docs draws list markers with CSS counters, so the exported HTML
    /// carries no "1." at all — each item is bare text inside `<li>`, and
    /// converting the tags naively silently drops every number. A real document
    /// had 29 numbered lists and 111 items, all rendered unnumbered.
    ///
    /// Two details of the export matter. Lists are written flat: nesting lives
    /// only in the class suffix (`lst-kix_…-2`), never in nested tags. And a
    /// list interrupted by a paragraph resumes as a new `<ol start="4">`, so
    /// restarting each list at 1 would show the wrong numbers.
    static func writeListMarkers(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?is)<(ol|ul)\b([^>]*)>|</(?:ol|ul)\s*>|<li\b[^>]*>"#
        ) else { return html }

        let source = html as NSString
        var output = ""
        var cursor = 0
        var open: [(ordered: Bool, level: Int, next: Int)] = []

        for match in regex.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor)
            )
            cursor = NSMaxRange(match.range)

            if match.range(at: 1).location != NSNotFound {
                let kind = source.substring(with: match.range(at: 1)).lowercased()
                let attributes = source.substring(with: match.range(at: 2))
                open.append((kind == "ol", listLevel(attributes), listStart(attributes)))
            } else if source.substring(with: match.range).hasPrefix("</") {
                if !open.isEmpty { open.removeLast() }
            } else if var list = open.popLast() {
                let marker = list.ordered ? listMarker(list.next, level: list.level) + ". " : "• "
                list.next += 1
                open.append(list)
                output += "\n" + marker
            } else {
                output += "\n"
            }
        }
        output += source.substring(from: cursor)
        return output
    }

    /// Nesting depth from Google's class suffix: `lst-kix_abc123-2` is level 2.
    private static func listLevel(_ attributes: String) -> Int {
        guard let range = attributes.range(
            of: #"lst-kix_[A-Za-z0-9]+-\d+"#, options: .regularExpression
        ) else { return 0 }
        return Int(attributes[range].split(separator: "-").last ?? "0") ?? 0
    }

    private static func listStart(_ attributes: String) -> Int {
        guard let range = attributes.range(
            of: #"start="\d+""#, options: .regularExpression
        ) else { return 1 }
        return Int(attributes[range].filter(\.isNumber)) ?? 1
    }

    /// Google cycles decimal, lower-latin, lower-roman as lists nest, and repeats.
    private static func listMarker(_ number: Int, level: Int) -> String {
        switch level % 3 {
        case 1: return latin(number)
        case 2: return roman(number)
        default: return String(number)
        }
    }

    private static func latin(_ number: Int) -> String {
        var n = max(1, number)
        var letters = ""
        while n > 0 {
            n -= 1
            letters = String(UnicodeScalar(UInt8(97 + n % 26))) + letters
            n /= 26
        }
        return letters
    }

    private static func roman(_ number: Int) -> String {
        let table: [(Int, String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
            (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ]
        var n = max(1, number)
        var result = ""
        for (value, symbol) in table {
            while n >= value { result += symbol; n -= value }
        }
        return result
    }

    /// Sentinel marking a converted heading. U+0001 cannot occur in a document,
    /// so it survives tag stripping without colliding with real content.
    private static let headingMarker = "\u{1}"

    /// Words that open an interview prompt. Used only for documents with no
    /// heading styles at all.
    private static let promptOpeners: Set<String> = [
        "tell", "describe", "walk", "explain", "discuss", "share", "talk",
        "give", "why", "what", "whats", "how", "when", "where", "who", "which",
        "can", "could", "would", "do", "did", "have", "are", "is", "any",
    ]

    /// If the document uses no Google Docs heading styles, infer section breaks
    /// from short standalone prompt lines.
    ///
    /// This is what makes an ordinary prep doc — questions typed as plain
    /// paragraphs — work without reformatting it first. A question mark alone is
    /// not enough of a signal: "Tell me about yourself" is among the most common
    /// prompts there is and has no question mark, while a long body sentence can
    /// end in one. So length and the opening word both matter.
    private static func promoteQuestionLines(_ text: String) -> String {
        guard !text.contains("## ") else { return text }

        let lines = text.components(separatedBy: "\n")
        var output: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            output.append(isPromptLine(trimmed) ? "## \(trimmed)" : line)
        }
        return output.joined(separator: "\n")
    }

    private static func isPromptLine(_ line: String) -> Bool {
        let words = line.split(separator: " ")
        guard words.count >= 2 else { return false }

        let opener = TextNormalizer.normalize(String(words[0]))
        let startsLikePrompt = promptOpeners.contains(opener)

        // A trailing question mark tolerates a longer line; without one, the
        // line has to be short and start like a prompt to qualify.
        if line.hasSuffix("?") {
            return words.count <= 15 && (startsLikePrompt || words.count <= 10)
        }
        // A full stop means it is a sentence of the answer, not a prompt.
        guard !line.hasSuffix(".") else { return false }
        return startsLikePrompt && words.count <= 12
    }

    private static func replace(
        _ text: String, _ pattern: String, with template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    private static func decodeEntities(_ text: String) -> String {
        var out = text
        // Google Docs leans on typographic entities heavily — a real document
        // produced 66 `&middot;` and 56 `&rarr;` that a minimal table missed and
        // rendered literally in the prompter.
        let named = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'",
            "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}",
            "&rdquo;": "\u{201D}", "&ldquo;": "\u{201C}",
            "&sbquo;": "\u{201A}", "&bdquo;": "\u{201E}",
            "&mdash;": "\u{2014}", "&ndash;": "\u{2013}", "&hellip;": "\u{2026}",
            "&middot;": "\u{00B7}", "&bull;": "\u{2022}", "&sdot;": "\u{22C5}",
            "&rarr;": "\u{2192}", "&larr;": "\u{2190}", "&harr;": "\u{2194}",
            "&uarr;": "\u{2191}", "&darr;": "\u{2193}",
            "&rArr;": "\u{21D2}", "&lArr;": "\u{21D0}", "&hArr;": "\u{21D4}",
            "&times;": "\u{00D7}", "&divide;": "\u{00F7}", "&minus;": "\u{2212}",
            "&plusmn;": "\u{00B1}", "&deg;": "\u{00B0}", "&permil;": "\u{2030}",
            "&frac12;": "\u{00BD}", "&frac14;": "\u{00BC}", "&frac34;": "\u{00BE}",
            "&le;": "\u{2264}", "&ge;": "\u{2265}", "&ne;": "\u{2260}",
            "&asymp;": "\u{2248}", "&infin;": "\u{221E}",
            "&copy;": "\u{00A9}", "&reg;": "\u{00AE}", "&trade;": "\u{2122}",
            "&sect;": "\u{00A7}", "&para;": "\u{00B6}",
            "&dagger;": "\u{2020}", "&Dagger;": "\u{2021}",
            "&laquo;": "\u{00AB}", "&raquo;": "\u{00BB}",
            "&lsaquo;": "\u{2039}", "&rsaquo;": "\u{203A}",
            "&euro;": "\u{20AC}", "&pound;": "\u{00A3}", "&yen;": "\u{00A5}",
            "&cent;": "\u{00A2}", "&curren;": "\u{00A4}",
            "&alpha;": "\u{03B1}", "&beta;": "\u{03B2}", "&delta;": "\u{03B4}",
            "&Delta;": "\u{0394}", "&pi;": "\u{03C0}", "&mu;": "\u{03BC}",
            "&ensp;": " ", "&emsp;": " ", "&thinsp;": " ", "&shy;": "",
            "&zwj;": "", "&zwnj;": "",
        ]
        // Everything except &amp; first: resolving &amp; early would turn
        // "&amp;rarr;" into "&rarr;" and then into an arrow that was never there.
        for (entity, replacement) in named where entity != "&amp;" {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }

        // Numeric entities, which Google uses for smart quotes.
        guard let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9A-Fa-f]+);"#) else {
            return out
        }
        let matches = regex.matches(in: out, range: NSRange(out.startIndex..., in: out))
        for match in matches.reversed() {
            guard let full = Range(match.range, in: out),
                  let flagRange = Range(match.range(at: 1), in: out),
                  let digitsRange = Range(match.range(at: 2), in: out) else { continue }
            let isHex = !out[flagRange].isEmpty
            guard let value = UInt32(out[digitsRange], radix: isHex ? 16 : 10),
                  let scalar = Unicode.Scalar(value) else { continue }
            out.replaceSubrange(full, with: String(Character(scalar)))
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}

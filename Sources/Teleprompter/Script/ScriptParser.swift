import Foundation

/// One `## heading` block from the script: the heading is the trigger question,
/// the body is what you actually say.
struct ScriptSection {
    let title: String
    /// Alternate phrasings from a `<!-- triggers: a, b, c -->` comment.
    let triggers: [String]
    let body: String

    /// Character ranges into `ParsedScript.displayText`.
    var titleRange = NSRange(location: 0, length: 0)
    var bodyRange = NSRange(location: 0, length: 0)

    /// Index range into `ParsedScript.words`. Body words only — headings are
    /// signposts you don't read aloud, so they must not participate in alignment.
    var firstWordIndex = 0
    var lastWordIndex = 0

    var wordCount: Int { max(0, lastWordIndex - firstWordIndex + 1) }
}

/// A single spoken word of body text, tying normalized form to its on-screen range.
/// This is the shared coordinate system between the scroll engine and the tracker.
struct WordRef {
    let normalized: String
    let range: NSRange
    let sectionIndex: Int
}

struct ParsedScript {
    /// Exactly the string that gets rendered. All ranges index into this.
    let displayText: String
    let sections: [ScriptSection]
    let words: [WordRef]

    static let empty = ParsedScript(displayText: "", sections: [], words: [])

    func section(containingWord index: Int) -> Int? {
        guard index >= 0, index < words.count else { return nil }
        return words[index].sectionIndex
    }
}

enum ScriptParser {

    private static let triggerPattern = try! NSRegularExpression(
        pattern: #"^<!--\s*triggers:\s*(.+?)\s*-->$"#,
        options: [.caseInsensitive]
    )

    /// A plain "Triggers: a, b, c" line.
    ///
    /// HTML comments cannot be typed in Google Docs, so a document written there
    /// has no way to declare alternate phrasings. This gives it one that survives
    /// the HTML export as ordinary text.
    private static let plainTriggerPattern = try! NSRegularExpression(
        pattern: #"^(?:triggers|asked as|also asked|aka)\s*[::]\s*(.+)$"#,
        options: [.caseInsensitive]
    )

    /// Parses Q&A markdown into sections plus a flat word index.
    ///
    /// Any preamble before the first `##` heading becomes an untitled section so
    /// that a plain prose document still renders and still scrolls.
    static func parse(_ markdown: String) -> ParsedScript {
        var sections: [ScriptSection] = []

        var currentTitle: String? = nil
        var currentTriggers: [String] = []
        var currentBody: [String] = []

        func flush() {
            let body = currentBody
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Drop entirely empty leading preamble, but keep empty titled sections
            // so a heading you haven't written under still shows up.
            guard currentTitle != nil || !body.isEmpty else {
                currentTriggers = []
                currentBody = []
                return
            }
            sections.append(ScriptSection(
                title: currentTitle ?? "",
                triggers: currentTriggers,
                body: body
            ))
            currentTitle = nil
            currentTriggers = []
            currentBody = []
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if let heading = headingText(from: line) {
                flush()
                currentTitle = heading
                continue
            }

            if let triggers = triggerList(from: line) {
                currentTriggers.append(contentsOf: triggers)
                continue
            }

            // Skip other HTML comments rather than reading them aloud.
            if line.hasPrefix("<!--") { continue }

            currentBody.append(rawLine)
        }
        flush()

        return buildIndex(sections: attachCrossReferencedTriggers(sections))
    }

    // MARK: - Cross-referenced triggers

    /// Harvests trigger phrases from a lookup table elsewhere in the document.
    ///
    /// Prep documents routinely carry a "story → questions it answers" matrix:
    /// a line naming a section, followed by a semicolon-separated list of the
    /// question archetypes it covers. That table is exactly the trigger data the
    /// matcher needs, already written by hand — it is just in the wrong place.
    ///
    /// Without this, a document whose headings are story names ("Path-to-Feed
    /// (the failure)") rather than questions matches almost nothing, because no
    /// interviewer says the name of your story.
    private static func attachCrossReferencedTriggers(
        _ sections: [ScriptSection]
    ) -> [ScriptSection] {
        guard sections.count > 2 else { return sections }

        let titleTokens: [(index: Int, tokens: Set<String>)] = sections.enumerated()
            .compactMap { index, section in
                let tokens = Set(TextNormalizer.tokenize(section.title))
                return tokens.count >= 2 ? (index, tokens) : nil
            }
        guard !titleTokens.isEmpty else { return sections }

        var harvested: [Int: [String]] = [:]

        for section in sections {
            let lines = section.body
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }

            for (i, line) in lines.enumerated() {
                // Table cells are short; body prose is not.
                guard !line.isEmpty, line.count <= 90,
                      let target = matchingSection(for: line, in: titleTokens)
                else { continue }

                guard let next = lines[(i + 1)...].first(where: { !$0.isEmpty }),
                      next.contains(";"), !looksLikeScore(next)
                else { continue }

                let phrases = next
                    .split(separator: ";")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.count >= 3 && $0.split(separator: " ").count <= 8 }

                if !phrases.isEmpty {
                    harvested[target, default: []].append(contentsOf: phrases)
                }
            }
        }

        guard !harvested.isEmpty else { return sections }
        return sections.enumerated().map { index, section in
            guard let extra = harvested[index] else { return section }
            var merged = section.triggers
            for phrase in extra where !merged.contains(phrase) { merged.append(phrase) }
            return ScriptSection(
                title: section.title, triggers: merged, body: section.body
            )
        }
    }

    /// Fuzzy title lookup, because a table rarely repeats a heading verbatim —
    /// "Path-to-Feed (failure)" in the table, "Path-to-Feed (the failure)" as the
    /// heading, and a year that disagrees between the two.
    private static func matchingSection(
        for line: String, in titleTokens: [(index: Int, tokens: Set<String>)]
    ) -> Int? {
        let lineTokens = Set(TextNormalizer.tokenize(line))
        guard lineTokens.count >= 2 else { return nil }

        var best: Int?
        var bestScore = 0.0
        for (index, tokens) in titleTokens {
            let shared = lineTokens.intersection(tokens).count
            // Two shared tokens minimum: one common word is coincidence.
            guard shared >= 2 else { continue }
            let score = Double(shared) / Double(min(lineTokens.count, tokens.count))
            if score >= 0.6, score > bestScore {
                bestScore = score
                best = index
            }
        }
        return best
    }

    /// Skips the "4.7/5 — Strong: …" column that follows the question list.
    private static func looksLikeScore(_ line: String) -> Bool {
        line.range(of: #"^\d+(\.\d+)?\s*/\s*\d"#, options: .regularExpression) != nil
    }

    // MARK: - Line classification

    /// Accepts `#` through `######`; treats them all as section breaks.
    private static func headingText(from line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }
        guard hashes.count <= 6 else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " || rest.isEmpty else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    private static func triggerList(from line: String) -> [String]? {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        let match = triggerPattern.firstMatch(in: line, range: range)
            ?? plainTriggerPattern.firstMatch(in: line, range: range)
        guard let match, match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Display text + word index

    /// Concatenates sections into the rendered string, recording ranges as it goes.
    private static func buildIndex(sections input: [ScriptSection]) -> ParsedScript {
        var display = ""
        var sections: [ScriptSection] = []
        var words: [WordRef] = []

        for (i, section) in input.enumerated() {
            var s = section

            if i > 0 { display += "\n\n" }

            if !s.title.isEmpty {
                let start = (display as NSString).length
                display += s.title
                s.titleRange = NSRange(location: start, length: (s.title as NSString).length)
                // One newline, not two. A blank line here became an empty
                // paragraph that collected the body's paragraph spacing on top of
                // the heading's, opening a gap far larger than either value.
                // Spacing between heading and body is set in ScriptRenderer.
                display += "\n"
            }

            let bodyStart = (display as NSString).length
            display += s.body
            s.bodyRange = NSRange(
                location: bodyStart,
                length: (display as NSString).length - bodyStart
            )

            s.firstWordIndex = words.count
            words.append(contentsOf: bodyWords(
                from: s.body, offsetBy: bodyStart, section: i
            ))
            // For an empty body this goes below firstWordIndex, making wordCount 0.
            s.lastWordIndex = words.count - 1

            sections.append(s)
        }

        return ParsedScript(displayText: display, sections: sections, words: words)
    }

    private static func bodyWords(
        from body: String,
        offsetBy offset: Int,
        section: Int
    ) -> [WordRef] {
        var words: [WordRef] = []
        let ns = body as NSString
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byWords, .localized]
        ) { substring, range, _, _ in
            guard let substring else { return }
            let normalized = TextNormalizer.normalize(substring)
            guard !normalized.isEmpty else { return }
            words.append(WordRef(
                normalized: normalized,
                range: NSRange(location: range.location + offset, length: range.length),
                sectionIndex: section
            ))
        }
        return words
    }
}

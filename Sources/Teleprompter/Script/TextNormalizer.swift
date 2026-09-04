import Foundation

/// Shared normalization so the script index and the speech transcript agree on
/// what "the same word" means. Both sides must call this — divergence here shows
/// up later as mysterious alignment failures.
enum TextNormalizer {

    private static let allowed = CharacterSet.alphanumerics

    /// Lowercase, strip diacritics and punctuation, spell out digits.
    ///
    /// Digits matter: the script says "8 years" but the transcriber emits
    /// "eight years", so a literal comparison would silently never match.
    static func normalize(_ word: String) -> String {
        let folded = word.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: .current
        )
        let stripped = String(folded.unicodeScalars.filter { allowed.contains($0) })
        guard !stripped.isEmpty else { return "" }

        if stripped.allSatisfy(\.isNumber), let n = Int(stripped) {
            return spellOut(n) ?? stripped
        }
        return stripped
    }

    /// Normalizes a whole utterance into its word sequence.
    static func tokenize(_ text: String) -> [String] {
        var out: [String] = []
        let ns = text as NSString
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byWords, .localized]
        ) { substring, _, _, _ in
            guard let substring else { return }
            let n = normalize(substring)
            if !n.isEmpty { out.append(n) }
        }
        return out
    }

    private static let spellFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .spellOut
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    /// "8" -> "eight", "2024" -> "twothousandtwentyfour" (joined, since the
    /// transcript side is compared word-by-word after the same stripping).
    private static func spellOut(_ n: Int) -> String? {
        guard let words = spellFormatter.string(from: NSNumber(value: n)) else { return nil }
        return String(
            words.lowercased().unicodeScalars.filter { allowed.contains($0) }
        )
    }
}

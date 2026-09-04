import Foundation
import NaturalLanguage

/// Maps a spoken question to the script section that answers it — Feature 2.
///
/// Two tiers, because each covers the other's blind spot:
///
///   1. **Lexical (BM25 + coverage).** Always available, instant, offline
///      forever. Strong when the question reuses your wording.
///   2. **Semantic (`NLContextualEmbedding`).** Catches paraphrases that share
///      no words — "so what brought you here?" → *Why do you want this role?*
///      Degrades silently to tier 1 if the model assets are unavailable.
///
/// The firing rule is deliberately strict: the winner must clear an absolute
/// threshold *and* beat the runner-up by a margin. Ambiguity produces no jump.
/// Jumping to the wrong answer mid-conversation is far more disruptive than
/// leaving you where you are, so the matcher's default is to do nothing.
final class QuestionMatcher {

    struct Match {
        let sectionIndex: Int
        let title: String
        let score: Double
        let runnerUpScore: Double
    }

    /// Per-section score breakdown, for tuning and diagnostics.
    struct Breakdown {
        let sectionIndex: Int
        let title: String
        let lexical: Double
        let semantic: Double?
        let blended: Double
    }

    /// Minimum blended score to jump at all.
    ///
    /// Calibrated against two labelled sets: a small purpose-built Q&A script
    /// and a real 30-section prep document. On the latter, genuine questions
    /// scored 0.61-0.89 and meeting chit-chat 0.42-0.63, so the threshold sits
    /// just above the noise ceiling.
    var acceptThreshold = 0.65

    /// Minimum lead over the second-best section.
    ///
    /// Kept small: on a document with several related stories the right answer
    /// legitimately wins by a hair, and the absolute threshold is what actually
    /// rejects noise.
    private let requiredMargin = 0.03

    /// Independent floor on the lexical tier.
    ///
    /// Measurement showed the semantic tier scores 0.81-0.95 on *everything*,
    /// including "sorry my camera is being weird today" — mean-pooled contextual
    /// embeddings recognise "English sentence about a person", not topic. It
    /// ranks the right section to the top reliably, but it cannot say whether
    /// any section applies at all. Lexical overlap can: genuine chit-chat scores
    /// 0.00 against every section. So semantic decides *which*, lexical decides
    /// *whether*, and a jump needs both.
    private let lexicalFloor = 0.30

    /// Blend weight for the lexical tier; the remainder goes to semantic.
    /// 0.45 measured as the best separation between true and false positives.
    private let lexicalWeight = 0.45

    private struct Document {
        let sectionIndex: Int
        let title: String
        /// Tokens from heading + triggers + opening sentences.
        let tokens: [String]
        let termFrequency: [String: Int]
        var vector: [Double]?
    }

    private var documents: [Document] = []
    private var documentFrequency: [String: Int] = [:]
    private var averageLength: Double = 1
    private var embedding: NLContextualEmbedding?

    private(set) var semanticEnabled = false

    /// Words too common to signal topic. Kept small on purpose — over-filtering
    /// hurts more than it helps once BM25's idf is doing the same job.
    private static let stopWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "am",
        "do", "does", "did", "can", "could", "would", "should", "will",
        "of", "to", "in", "on", "for", "with", "at", "by", "from", "as",
        "and", "or", "but", "if", "so", "that", "this", "these", "those",
        "you", "your", "yours", "me", "my", "i", "we", "our", "us", "it",
        "just", "like", "um", "uh", "okay", "ok", "yeah", "well", "sure",
        // Interview scaffolding. "Tell me about a time you…" prefixes most
        // behavioural questions, so these words identify nothing — yet left in,
        // they let any section sharing the boilerplate outrank the section that
        // actually holds the answer.
        "tell", "about", "time", "times", "describe", "example", "situation",
        "give", "walk", "share", "talk", "story", "thing", "something",
        "someone", "please", "maybe", "kind", "sort", "bit", "lot",
    ]

    /// Collapses inflected forms so the lexical tier can match them.
    ///
    /// Without this, "tell me about a time you **failed**" scores zero against a
    /// section whose trigger reads "**Failure**; wrong decision; …" — the query
    /// reduces to a single content word and that word never matches. Same for
    /// "prioritize" against "prioritization". A four-character prefix is crude
    /// next to real lemmatization, but it collapses exactly the endings that
    /// matter here and cannot fail on unknown vocabulary.
    private static func stem(_ token: String) -> String {
        token.count >= 5 ? String(token.prefix(4)) : token
    }

    /// Normalize, drop stopwords, then stem.
    private static func tokens(_ text: String) -> [String] {
        TextNormalizer.tokenize(text)
            .filter { !stopWords.contains($0) }
            .map(stem)
    }

    // MARK: - Index

    func index(_ script: ParsedScript) {
        documents = []
        documentFrequency = [:]

        for (i, section) in script.sections.enumerated() {
            // Structural headings with no body ("3 · The stories") are useful
            // signposts but there is nothing to read there, so jumping to one
            // would strand you on an empty screen.
            guard section.wordCount > 0 else { continue }

            // When a section declares triggers, those *are* the question
            // phrasings and nothing else should dilute them. Mixing in body prose
            // measurably pulled unrelated stories above the right one, because a
            // 700-word answer shares far more incidental vocabulary with a
            // question than a five-word trigger list does.
            var parts = [section.title]
            if section.triggers.isEmpty {
                parts.append(Self.openingSentences(of: section.body, count: 2))
            } else {
                parts.append(contentsOf: section.triggers)
            }

            let tokens = Self.tokens(parts.joined(separator: " "))
            guard !tokens.isEmpty else { continue }

            var termFrequency: [String: Int] = [:]
            for token in tokens { termFrequency[token, default: 0] += 1 }
            for term in Set(tokens) { documentFrequency[term, default: 0] += 1 }

            documents.append(Document(
                sectionIndex: i,
                title: section.title,
                tokens: tokens,
                termFrequency: termFrequency,
                vector: nil
            ))
        }

        averageLength = documents.isEmpty
            ? 1
            : Double(documents.reduce(0) { $0 + $1.tokens.count }) / Double(documents.count)

        buildVectors(from: script)
    }

    private static func openingSentences(of body: String, count: Int) -> String {
        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = body
        tokenizer.enumerateTokens(in: body.startIndex..<body.endIndex) { range, _ in
            sentences.append(String(body[range]))
            return sentences.count < count
        }
        return sentences.joined(separator: " ")
    }

    // MARK: - Semantic tier

    /// Loads the embedding model. Failure is not fatal — lexical matching alone
    /// still works, so this reports rather than throws.
    func prepareSemanticTier() async -> Bool {
        guard let model = NLContextualEmbedding(language: .english) else {
            return false
        }
        if !model.hasAvailableAssets {
            // Downloaded over the air on first use.
            guard let result = try? await model.requestAssets(), result == .available else {
                return false
            }
        }
        do {
            try model.load()
        } catch {
            return false
        }
        embedding = model
        semanticEnabled = true
        return true
    }

    private func buildVectors(from script: ParsedScript) {
        guard semanticEnabled else { return }
        for i in documents.indices {
            let section = script.sections[documents[i].sectionIndex]
            let text = ([section.title] + section.triggers).joined(separator: ". ")
            documents[i].vector = vector(for: text)
        }
    }

    /// Mean-pooled token vectors. Crude next to a purpose-built sentence encoder,
    /// but the texts here are single questions, where pooling holds up well.
    private func vector(for text: String) -> [Double]? {
        guard let embedding, !text.isEmpty,
              let result = try? embedding.embeddingResult(for: text, language: .english)
        else { return nil }

        var sum: [Double] = []
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { tokenVector, _ in
            if sum.isEmpty {
                sum = tokenVector
            } else {
                for i in 0..<min(sum.count, tokenVector.count) { sum[i] += tokenVector[i] }
            }
            count += 1
            return true
        }
        guard count > 0, !sum.isEmpty else { return nil }

        var norm = 0.0
        for i in sum.indices {
            sum[i] /= Double(count)
            norm += sum[i] * sum[i]
        }
        norm = sqrt(norm)
        guard norm > 0 else { return nil }
        for i in sum.indices { sum[i] /= norm }
        return sum
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0
        for i in a.indices { dot += a[i] * b[i] }
        // Vectors are pre-normalized, so the dot product is already the cosine.
        return max(0, min(1, dot))
    }

    // MARK: - Matching

    /// Scores an utterance against every section. Returns nil when nothing wins
    /// clearly enough to be worth moving the script.
    func match(_ utterance: String) -> Match? {
        guard !documents.isEmpty else { return nil }

        // Gate on the raw utterance. Filtering stopwords first would reject
        // "what drew you to us" — five words, one content token — even though it
        // is a listed trigger.
        let rawTokens = TextNormalizer.tokenize(utterance)
        guard rawTokens.count >= 3 else { return nil }
        let queryTokens = Self.tokens(utterance)

        let queryVector = semanticEnabled ? vector(for: utterance) : nil

        var scored = breakdowns(queryTokens: queryTokens, queryVector: queryVector)
        scored.sort { $0.blended > $1.blended }
        guard let best = scored.first else { return nil }
        let runnerUp = scored.count > 1 ? scored[1].blended : 0

        guard best.blended >= acceptThreshold,
              best.lexical >= lexicalFloor,
              best.blended - runnerUp >= requiredMargin
        else { return nil }

        return Match(
            sectionIndex: best.sectionIndex,
            title: best.title,
            score: best.blended,
            runnerUpScore: runnerUp
        )
    }

    private func breakdowns(queryTokens: [String], queryVector: [Double]?) -> [Breakdown] {
        documents.map { document in
            let lexical = lexicalScore(query: queryTokens, document: document)
            let semantic: Double? = {
                guard let queryVector, let documentVector = document.vector else { return nil }
                return Self.cosine(queryVector, documentVector)
            }()
            let blended = semantic.map {
                lexicalWeight * lexical + (1 - lexicalWeight) * $0
            } ?? lexical
            return Breakdown(
                sectionIndex: document.sectionIndex, title: document.title,
                lexical: lexical, semantic: semantic, blended: blended
            )
        }
    }

    /// Diagnostic entry point: full ranking with components, no thresholds applied.
    func debugScores(_ utterance: String) -> [Breakdown] {
        let queryTokens = Self.tokens(utterance)
        let queryVector = semanticEnabled ? vector(for: utterance) : nil
        return breakdowns(queryTokens: queryTokens, queryVector: queryVector)
            .sorted { $0.blended > $1.blended }
    }

    /// BM25 blended with idf-weighted term coverage.
    ///
    /// Coverage must be weighted by how discriminating each word is. Counting
    /// query words equally means "tell me about a time you failed" scores 3/4
    /// against any section containing "tell", "about" and "time" — while missing
    /// **failed**, the only word that identifies which story to jump to. Measured
    /// on a real 30-section document, that ranked the correct section out of the
    /// top three and put unrelated stories above it.
    ///
    /// Weighting by idf makes the rare word carry the decision and the
    /// interview boilerplate carry almost nothing.
    private func lexicalScore(query: [String], document: Document) -> Double {
        let k1 = 1.2
        let b = 0.75
        let documentCount = Double(documents.count)
        let length = Double(document.tokens.count)

        var bm25 = 0.0
        var matchedWeight = 0.0
        var totalWeight = 0.0

        for term in Set(query) {
            let df = Double(documentFrequency[term] ?? 0)
            // A term in no document still counts toward the denominator: an
            // utterance full of words absent from the script should score low.
            let idf = log(1 + (documentCount - df + 0.5) / (df + 0.5))
            totalWeight += idf

            guard let frequency = document.termFrequency[term] else { continue }
            matchedWeight += idf
            let tf = Double(frequency)
            bm25 += idf * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * length / averageLength))
        }

        let coverage = totalWeight > 0 ? matchedWeight / totalWeight : 0
        // Squash BM25 into 0-1 so the two halves are commensurable.
        let squashed = bm25 / (bm25 + 4.0)
        return 0.5 * coverage + 0.5 * squashed
    }
}

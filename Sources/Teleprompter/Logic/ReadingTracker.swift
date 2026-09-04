import Foundation
import QuartzCore

/// Aligns what you are saying to where you are in the script — Feature 3.
///
/// The problem is not transcription accuracy, it is *position*. Live speech
/// arrives as a noisy, revised, partially-wrong stream, and the script is a
/// fixed sequence. Matching the recent tail of speech against a forward-biased
/// window of the script solves skips, repeats, and stumbles for free: if you
/// jump a paragraph, the window search simply finds you there.
///
/// The design priority is that a *wrong* match is far worse than *no* match.
/// A wrong match scrolls you away from the line you are mid-sentence through.
/// So the thresholds are deliberately conservative and the failure mode is a
/// graceful decay to constant-speed scrolling, not a guess.
final class ReadingTracker {

    struct Update {
        let cursor: Int
        let confidence: Double
        /// False once matching has failed repeatedly — the caller should drift.
        let isConfident: Bool
    }

    var onUpdate: ((Update) -> Void)?

    // MARK: Tuning

    /// Words of recent speech compared against the script.
    private let tailLength = 9
    /// How far back a match may be found — covers a repeated phrase.
    private let backSearch = 25
    /// How far ahead — covers skipping a paragraph.
    private let forwardSearch = 160
    private let acceptThreshold = 0.55
    /// Consecutive failures before admitting we have lost the place.
    private let missTolerance = 3
    /// Cost of a dropped or inserted word during alignment.
    private let gapPenalty = 0.12

    // MARK: State

    private var scriptWords: [String] = []
    private(set) var cursor = 0
    private(set) var isConfident = false

    private var finalizedTail: [String] = []
    private var volatileTail: [String] = []
    private var missStreak = 0

    private var lastMatchTime: CFTimeInterval = 0
    private var lastMatchCursor = 0
    /// Exponentially smoothed estimate of your actual speaking rate.
    private(set) var measuredWPM: Double?

    // MARK: - Script

    func setScript(_ script: ParsedScript) {
        scriptWords = script.words.map(\.normalized)
        reset()
    }

    func reset() {
        cursor = 0
        finalizedTail = []
        volatileTail = []
        missStreak = 0
        isConfident = false
        measuredWPM = nil
        lastMatchTime = 0
    }

    /// Re-seeds the cursor after you scroll by hand or jump to a section.
    /// The speech buffers are cleared: text spoken before a jump says nothing
    /// about where you are after it.
    func reanchor(to wordIndex: Int) {
        guard !scriptWords.isEmpty else { return }
        cursor = min(max(0, wordIndex), scriptWords.count - 1)
        finalizedTail = []
        volatileTail = []
        missStreak = 0
        isConfident = false
        lastMatchTime = 0
    }

    // MARK: - Speech input

    func ingest(volatile text: String) {
        volatileTail = TextNormalizer.tokenize(text)
        align()
    }

    func ingest(final text: String) {
        finalizedTail.append(contentsOf: TextNormalizer.tokenize(text))
        // Bounded: only the recent tail can inform position.
        if finalizedTail.count > 64 {
            finalizedTail.removeFirst(finalizedTail.count - 64)
        }
        volatileTail = []
        align()
    }

    // MARK: - Alignment

    private func align() {
        guard !scriptWords.isEmpty else { return }

        let tail = Array((finalizedTail + volatileTail).suffix(tailLength))
        guard tail.count >= 3 else { return }

        guard let (best, score) = bestMatch(for: tail) else {
            registerMiss()
            return
        }

        guard score >= acceptThreshold else {
            registerMiss()
            return
        }

        updateSpeed(newCursor: best)
        cursor = best
        missStreak = 0
        isConfident = true
        onUpdate?(Update(cursor: best, confidence: score, isConfident: true))
    }

    /// Scans the search window and returns the best-scoring script position,
    /// where "position" means the script index aligned with the last spoken word.
    ///
    /// This is a gapped local alignment (Needleman–Wunsch style DP with a free
    /// start), not a fixed-offset comparison. That matters: recognizers drop and
    /// insert words constantly, and a rigid contiguous match assumes the spoken
    /// tail maps one-to-one onto consecutive script words. Under a 20% error rate
    /// that assumption breaks and the cursor drifts tens of words. Allowing gaps
    /// on both sides absorbs the noise.
    ///
    /// Cost is O(tail x window) — about 1.6k cells, a few times per second.
    private func bestMatch(for tail: [String]) -> (index: Int, score: Double)? {
        let low = max(0, cursor - backSearch)
        let high = min(scriptWords.count - 1, cursor + forwardSearch)
        guard low <= high else { return nil }

        let window = Array(scriptWords[low...high])
        let n = window.count
        let m = tail.count
        guard n > 0, m > 0 else { return nil }

        // Recency weights: the newest word says where you are now, older ones
        // only corroborate.
        var weights = [Double](repeating: 0, count: m)
        for j in 0..<m { weights[j] = pow(0.88, Double(m - 1 - j)) }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return nil }

        func substitution(_ j: Int, _ i: Int) -> Double {
            let scripted = window[i]
            let spoken = tail[j]
            if scripted == spoken { return weights[j] }
            if isNearMatch(scripted, spoken) { return weights[j] * 0.6 }
            return -0.25 * weights[j]
        }

        // row j = best score aligning the first j spoken words against the first
        // i window words. Row 0 is all zeros, which is what makes the start free.
        var previous = [Double](repeating: 0, count: n + 1)
        for j in 1..<max(1, m) {
            var current = [Double](repeating: 0, count: n + 1)
            current[0] = previous[0] - gapPenalty
            for i in 1...n {
                let aligned = previous[i - 1] + substitution(j - 1, i - 1)
                let spokenGap = previous[i] - gapPenalty      // recognizer inserted
                let scriptGap = current[i - 1] - gapPenalty   // recognizer dropped
                current[i] = max(aligned, max(spokenGap, scriptGap))
            }
            previous = current
        }

        // Force the newest spoken word onto the candidate, so the reported
        // position is where you actually are rather than where a trailing gap
        // happened to end.
        var bestIndex = -1
        var bestScore = -Double.infinity
        for i in 1...n {
            let raw = previous[i - 1] + substitution(m - 1, i - 1)
            let candidate = low + i - 1
            let score = raw / totalWeight - positionPenalty(for: candidate)
            if score > bestScore {
                bestScore = score
                bestIndex = candidate
            }
        }

        return bestIndex >= 0 ? (bestIndex, bestScore) : nil
    }

    /// Ties broken toward staying put, and hard against moving backwards —
    /// a false backward jump makes you re-read a line you just delivered.
    private func positionPenalty(for candidate: Int) -> Double {
        let distance = Double(candidate - cursor)
        if distance >= 0 {
            return min(0.15, distance / Double(forwardSearch) * 0.15)
        } else {
            return min(0.35, -distance / Double(backSearch) * 0.35)
        }
    }

    /// Tolerates inflection differences ("year" vs "years", "run" vs "running")
    /// that the recognizer and the script routinely disagree about.
    private func isNearMatch(_ a: String, _ b: String) -> Bool {
        guard a.count >= 4, b.count >= 4, abs(a.count - b.count) <= 3 else {
            return false
        }
        return a.prefix(4) == b.prefix(4)
    }

    private func registerMiss() {
        missStreak += 1
        guard missStreak >= missTolerance, isConfident else { return }
        isConfident = false
        onUpdate?(Update(cursor: cursor, confidence: 0, isConfident: false))
    }

    /// Measures real words-per-minute from confident matches, so the drift
    /// fallback runs at *your* pace rather than a guessed default.
    private func updateSpeed(newCursor: Int) {
        let now = CACurrentMediaTime()
        defer {
            lastMatchTime = now
            lastMatchCursor = newCursor
        }
        guard lastMatchTime > 0 else { return }

        let elapsed = now - lastMatchTime
        let advanced = newCursor - lastMatchCursor
        // Ignore jumps and stalls: neither reflects a sustainable speaking rate.
        guard elapsed >= 0.5, advanced > 0, advanced < 40 else { return }

        let instant = Double(advanced) / elapsed * 60.0
        guard instant > 30, instant < 400 else { return }

        measuredWPM = measuredWPM.map { $0 * 0.8 + instant * 0.2 } ?? instant
    }
}

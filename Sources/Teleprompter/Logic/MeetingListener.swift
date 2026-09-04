import AVFoundation
import Foundation
import Speech

/// Listens to the meeting audio, transcribes it on-device, and reports which
/// script section answers the question that was just asked — Feature 2.
///
/// Structurally a mirror of `FlowController`: same transcriber pipeline, a
/// different source (system audio rather than mic) and a different consumer
/// (a question matcher rather than a position tracker). That symmetry is the
/// payoff of capturing the two voices separately — no diarization anywhere.
@MainActor
final class MeetingListener {

    private let source = SystemAudioSource()
    private let pipeline = TranscriberPipeline()
    private let matcher = QuestionMatcher()

    private(set) var isActive = false
    private(set) var semanticTierReady = false

    /// Fires only when a question clears both matcher gates.
    var onQuestion: ((QuestionMatcher.Match) -> Void)?
    var onStatus: ((String?) -> Void)?
    /// Latest transcript of the other person, for the debug overlay.
    var onTranscript: ((String) -> Void)?

    /// Consulted before firing — the caller vetoes jumps while you are talking.
    var shouldAcceptJump: (() -> Bool)?

    init() {
        // Deliberately only final results. Volatile text revises itself mid-flight
        // and would fire a jump on a half-heard question, then a second jump when
        // the recognizer changed its mind.
        pipeline.onFinal = { [weak self] text in
            self?.handleUtterance(text)
        }
        pipeline.onVolatile = { [weak self] text in
            self?.onTranscript?(text)
        }
        pipeline.onStatusChange = { [weak self] status in
            switch status {
            case .installingAssets(let fraction):
                self?.onStatus?("Downloading speech model… \(Int(fraction * 100))%")
            case .failed(let message):
                self?.onStatus?("Meeting audio unavailable — \(message)")
            case .running, .idle:
                self?.onStatus?(nil)
            }
        }
    }

    func setScript(_ script: ParsedScript) {
        matcher.acceptThreshold = Settings.shared.matchThreshold
        matcher.index(script)
    }

    private func handleUtterance(_ text: String) {
        onTranscript?(text)
        matcher.acceptThreshold = Settings.shared.matchThreshold
        guard let match = matcher.match(text) else { return }
        guard shouldAcceptJump?() ?? true else { return }
        onQuestion?(match)
    }

    /// Returns an error message on failure; nil on success.
    func start(script: ParsedScript) async -> String? {
        guard !isActive else { return nil }

        if let unavailable = await TranscriberPipeline.availability(for: .current) {
            return unavailable
        }

        onStatus?("Preparing question matching…")
        // Semantic tier is optional: it improves which section wins, and the
        // lexical tier still decides whether to fire at all.
        semanticTierReady = await matcher.prepareSemanticTier()
        setScript(script)

        let transcriber = pipeline.makeTranscriber()
        do {
            try await pipeline.prepareAssets(for: transcriber)
        } catch {
            return "Could not install the speech model: \(error.localizedDescription)"
        }

        guard let format = await TranscriberPipeline.preferredFormat(for: transcriber) else {
            return "No compatible audio format for on-device speech recognition."
        }

        do {
            let stream = try source.start(outputFormat: format)
            try await pipeline.start(transcriber: transcriber, inputSequence: stream)
        } catch {
            source.stop()
            return error.localizedDescription
        }

        isActive = true
        onStatus?(nil)
        return nil
    }

    func stop() {
        guard isActive else { return }
        pipeline.stop()
        source.stop()
        isActive = false
        onStatus?(nil)
    }
}

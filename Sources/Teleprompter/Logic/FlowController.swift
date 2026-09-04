import AVFoundation
import Foundation
import QuartzCore
import Speech

/// Ties the microphone, the transcriber, and the reading tracker together, and
/// hands the result to the scroll engine as a word cursor.
///
/// Kept separate from `AppDelegate` because Phase 3 adds a second, structurally
/// identical chain over meeting audio; only the source and the consumer differ.
@MainActor
final class FlowController {

    private let mic = MicSource()
    private let pipeline = TranscriberPipeline()
    let tracker = ReadingTracker()

    private(set) var isActive = false

    /// When your voice was last heard. Used to veto answer jumps while you are
    /// mid-sentence — nothing is more disruptive than the script moving because
    /// the other person made a noise while you were still answering.
    private var lastHeardSelf: CFTimeInterval = 0
    var secondsSinceUserSpoke: Double {
        lastHeardSelf > 0 ? CACurrentMediaTime() - lastHeardSelf : .greatestFiniteMagnitude
    }

    /// Cursor position plus whether alignment currently trusts itself.
    var onCursor: ((Int, Bool) -> Void)?
    /// Human-readable state for the panel header; nil clears it.
    var onStatus: ((String?) -> Void)?
    /// Live transcript of your own voice, for diagnostics.
    var onTranscript: ((String) -> Void)?

    init() {
        tracker.onUpdate = { [weak self] update in
            self?.onCursor?(update.cursor, update.isConfident)
        }
        pipeline.onVolatile = { [weak self] text in
            self?.lastHeardSelf = CACurrentMediaTime()
            self?.onTranscript?(text)
            self?.tracker.ingest(volatile: text)
        }
        pipeline.onFinal = { [weak self] text in
            self?.lastHeardSelf = CACurrentMediaTime()
            self?.tracker.ingest(final: text)
        }
        pipeline.onStatusChange = { [weak self] status in
            switch status {
            case .installingAssets(let fraction):
                self?.onStatus?("Downloading speech model… \(Int(fraction * 100))%")
            case .running:
                self?.onStatus?(nil)
            case .failed(let message):
                self?.onStatus?("Speech unavailable — \(message)")
            case .idle:
                self?.onStatus?(nil)
            }
        }
    }

    func setScript(_ script: ParsedScript) {
        tracker.setScript(script)
    }

    /// Estimated speaking rate, once enough confident matches have accumulated.
    var measuredWPM: Double? { tracker.measuredWPM }

    func reanchor(to wordIndex: Int) {
        tracker.reanchor(to: wordIndex)
    }

    /// Starts listening. Returns an error message on failure rather than
    /// throwing, because every failure here is recoverable — the caller simply
    /// falls back to constant-speed scrolling.
    func start() async -> String? {
        guard !isActive else { return nil }

        if let unavailable = await TranscriberPipeline.availability(for: .current) {
            return unavailable
        }
        guard await MicSource.requestPermission() else {
            return MicSource.SourceError.permissionDenied.localizedDescription
        }

        let transcriber = pipeline.makeTranscriber()

        do {
            onStatus?("Preparing speech model…")
            try await pipeline.prepareAssets(for: transcriber)
        } catch {
            return "Could not install the speech model: \(error.localizedDescription)"
        }

        guard let format = await TranscriberPipeline.preferredFormat(for: transcriber) else {
            return "No compatible audio format for on-device speech recognition."
        }

        do {
            let stream = try mic.start(outputFormat: format)
            try await pipeline.start(transcriber: transcriber, inputSequence: stream)
        } catch {
            mic.stop()
            return error.localizedDescription
        }

        isActive = true
        onStatus?(nil)
        return nil
    }

    func stop() {
        guard isActive else { return }
        pipeline.stop()
        mic.stop()
        isActive = false
        onStatus?(nil)
    }
}

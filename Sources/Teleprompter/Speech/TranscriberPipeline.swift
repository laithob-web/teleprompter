import AVFoundation
import Foundation
import Speech

/// Wraps one `SpeechAnalyzer` + `SpeechTranscriber` pair over a single audio
/// source. Two independent instances run in the finished app — one on your mic,
/// one on the meeting audio — which is why this is a class rather than a
/// singleton, and why speaker separation needs no diarization.
///
/// Everything here runs on-device. No audio is written to disk and none leaves
/// the machine.
@MainActor
final class TranscriberPipeline {

    enum Status: Equatable {
        case idle
        case installingAssets(Double)
        case running
        case failed(String)
    }

    /// Refined partial text, arriving every few hundred milliseconds.
    var onVolatile: ((String) -> Void)?
    /// Text the recognizer has committed to and will not revise.
    var onFinal: ((String) -> Void)?
    var onStatusChange: ((Status) -> Void)?

    private(set) var status: Status = .idle {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var resultsTask: Task<Void, Never>?
    private let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    /// The format the audio source must deliver. Ask before starting the source.
    static func preferredFormat(for transcriber: SpeechTranscriber) async -> AVAudioFormat? {
        await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    }

    /// Builds a transcriber tuned for live prompting.
    ///
    /// `.volatileResults` is the point of the whole exercise — waiting for
    /// finalized text would put the scroll position a full phrase behind you.
    /// `.audioTimeRange` supplies per-word timings used to measure your real
    /// speaking rate for the fallback drift speed.
    func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// Downloads language assets if needed. First run only, but it is a sizable
    /// download, so progress is surfaced rather than left to look like a hang.
    func prepareAssets(for transcriber: SpeechTranscriber) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) else {
            return  // Already installed.
        }

        let progress = request.progress
        let observer = Task { @MainActor [weak self] in
            while !Task.isCancelled, !progress.isFinished {
                self?.status = .installingAssets(progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { observer.cancel() }

        try await request.downloadAndInstall()
    }

    /// Starts analysis over `inputSequence`, which the caller obtains from an
    /// audio source configured with `preferredFormat`.
    func start<S: AsyncSequence & Sendable>(
        transcriber: SpeechTranscriber,
        inputSequence: S
    ) async throws where S.Element == AnalyzerInput {
        stop()

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        self.transcriber = transcriber

        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }
                    if result.isFinal {
                        self.onFinal?(text)
                    } else {
                        self.onVolatile?(text)
                    }
                }
            } catch {
                self?.status = .failed(error.localizedDescription)
            }
        }

        try await analyzer.start(inputSequence: inputSequence)
        status = .running
    }

    func stop() {
        resultsTask?.cancel()
        resultsTask = nil

        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        transcriber = nil
        if status == .running { status = .idle }
    }

    /// Whether on-device transcription is usable for this locale at all.
    static func availability(for locale: Locale) async -> String? {
        guard SpeechTranscriber.isAvailable else {
            return "On-device speech recognition is not available on this Mac."
        }
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        guard supported != nil else {
            return "No on-device speech model for \(locale.identifier). "
                 + "Auto-scroll will fall back to a constant speed."
        }
        return nil
    }
}

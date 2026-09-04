import AVFoundation
import Speech

/// Microphone capture, converted to whatever format `SpeechAnalyzer` asks for
/// and delivered as an async stream of analyzer inputs.
///
/// The engine's input format is decided by the hardware (commonly 48 kHz), while
/// the analyzer wants its own preferred format, so an `AVAudioConverter` sits in
/// between. Skipping that conversion is the usual cause of a transcriber that
/// runs but silently produces nothing.
final class MicSource {

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    private(set) var isRunning = false

    enum SourceError: Error, LocalizedError {
        case permissionDenied
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access was denied. Grant it in System Settings › Privacy & Security › Microphone."
            case .unsupportedFormat:
                return "Could not bridge the microphone format to the speech recognizer."
            }
        }
    }

    /// Prompts for microphone access if it has not been decided yet.
    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Starts capture and returns the stream to hand to `SpeechAnalyzer`.
    func start(outputFormat: AVAudioFormat) throws -> AsyncStream<AnalyzerInput> {
        stop()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw SourceError.unsupportedFormat }

        self.outputFormat = outputFormat
        if inputFormat != outputFormat {
            guard let c = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw SourceError.unsupportedFormat
            }
            converter = c
        } else {
            converter = nil
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation

        // 0.1s of audio per callback: short enough that volatile results feel
        // responsive, long enough to avoid thrashing the converter.
        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.1)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self, let converted = self.convert(buffer) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        return stream
    }

    func stop() {
        guard isRunning || engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        converter = nil
        isRunning = false
    }

    /// Resamples one buffer into the analyzer's format.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let outputFormat else { return buffer }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat, frameCapacity: capacity
        ) else { return nil }

        // The input block is invoked until the converter is satisfied; hand over
        // the buffer once, then report starvation so it returns what it has.
        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    deinit { stop() }
}

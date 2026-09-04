import AVFoundation
import CoreAudio
import Foundation
import Speech

/// Captures the audio coming *out* of your Mac — the other person's voice — via
/// a CoreAudio process tap.
///
/// Chosen over ScreenCaptureKit deliberately. `SCStream` can capture system audio
/// but demands Screen Recording permission and a dummy video stream; asking for
/// screen-recording rights in an app whose whole purpose is hiding from screen
/// recording is both wasteful and a bad look. A process tap needs only the
/// lighter audio-capture consent and carries no video path.
///
/// The tap is global-minus-ourselves rather than targeted at a specific app, so
/// it works with Zoom, Teams, and Meet-in-Chrome without knowing which is running.
final class SystemAudioSource {

    enum SourceError: Error, LocalizedError {
        case tapCreationFailed(OSStatus)
        case aggregateDeviceFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case formatUnavailable

        var errorDescription: String? {
            switch self {
            case .tapCreationFailed(let status):
                return "Could not tap system audio (status \(status)). "
                     + "Grant access under System Settings › Privacy & Security › Audio Recording, then restart the app."
            case .aggregateDeviceFailed(let status):
                return "Could not create the audio capture device (status \(status))."
            case .ioProcFailed(let status):
                return "Could not start the audio capture callback (status \(status))."
            case .formatUnavailable:
                return "The system audio format could not be bridged to the speech recognizer."
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var tapFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    private(set) var isRunning = false

    // MARK: - Start / stop

    func start(outputFormat: AVAudioFormat) throws -> AsyncStream<AnalyzerInput> {
        stop()
        self.outputFormat = outputFormat

        try createTap()
        let tapFormat = try readTapFormat()
        self.tapFormat = tapFormat

        if tapFormat != outputFormat {
            guard let c = AVAudioConverter(from: tapFormat, to: outputFormat) else {
                throw SourceError.formatUnavailable
            }
            converter = c
        }

        let uid = try readTapUID()
        try createAggregateDevice(tapUID: uid)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation

        try startIOProc()
        isRunning = true
        return stream
    }

    func stop() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        continuation?.finish()
        continuation = nil
        converter = nil
        isRunning = false
    }

    deinit { stop() }

    // MARK: - CoreAudio plumbing

    private static func address(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// CoreAudio identifies processes by its own object IDs, not by pid.
    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var input = pid
        var output = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            UInt32(MemoryLayout<pid_t>.size), &input, &size, &output
        )
        return status == noErr && output != kAudioObjectUnknown ? output : nil
    }

    private func createTap() throws {
        // Excluding ourselves matters: without it the prompter would transcribe
        // any sound it makes and could feed its own output back in.
        let selfObject = Self.processObject(for: getpid())
        let description = CATapDescription(
            monoGlobalTapButExcludeProcesses: selfObject.map { [$0] } ?? []
        )
        description.name = "Teleprompter Meeting Audio"
        description.isPrivate = true

        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw SourceError.tapCreationFailed(status)
        }
    }

    private func readTapFormat() throws -> AVAudioFormat {
        var addr = Self.address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw SourceError.formatUnavailable
        }
        return format
    }

    private func readTapUID() throws -> CFString {
        var addr = Self.address(kAudioTapPropertyUID)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { throw SourceError.tapCreationFailed(status) }
        return uid
    }

    /// A private aggregate device is the only way to read a tap's samples.
    private func createAggregateDevice(tapUID: CFString) throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Teleprompter Meeting Audio",
            kAudioAggregateDeviceUIDKey as String:
                "com.laith.teleprompter.tap.\(UUID().uuidString)",
            // Private: never appears in Sound settings or other apps' device lists.
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]

        let status = AudioHardwareCreateAggregateDevice(
            description as CFDictionary, &aggregateID
        )
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            throw SourceError.aggregateDeviceFailed(status)
        }
    }

    private func startIOProc() throws {
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            [weak self] _, inputData, _, _, _ in
            self?.handle(inputData)
        }
        guard status == noErr, let ioProcID else {
            throw SourceError.ioProcFailed(status)
        }

        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard startStatus == noErr else {
            throw SourceError.ioProcFailed(startStatus)
        }
    }

    /// Called on the audio thread. Keep it allocation-light and never block.
    private func handle(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let tapFormat, let continuation else { return }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard let first = bufferList.first, first.mData != nil else { return }

        let frameCount = AVAudioFrameCount(
            first.mDataByteSize / tapFormat.streamDescription.pointee.mBytesPerFrame
        )
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: tapFormat, frameCapacity: frameCount
              )
        else { return }

        buffer.frameLength = frameCount
        if let destination = buffer.floatChannelData?[0],
           let source = first.mData?.bindMemory(
               to: Float.self, capacity: Int(frameCount)
           ) {
            destination.update(from: source, count: Int(frameCount))
        }

        guard let converted = convert(buffer) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let outputFormat else { return buffer }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat, frameCapacity: capacity
        ) else { return nil }

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
}

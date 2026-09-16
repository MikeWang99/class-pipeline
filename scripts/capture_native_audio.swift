// Capture macOS system audio and the active microphone without a virtual
// sound card. The watcher merges the independent streams after stopping.
//
// Usage: capture_native_audio OUTPUT_SYSTEM.caf OUTPUT_MICROPHONE.caf STATUS_FILE

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

struct AudioWriterStats {
    let receivedFrames: Int
    let sampleBuffers: Int
    let sampleRate: Double
    let firstPTS: Double?
    let lastPTS: Double?
    let lastWriteError: String?

    var estimatedDuration: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(receivedFrames) / sampleRate
    }
}

final class AudioWriter: NSObject, SCStreamOutput {
    private let outputURL: URL
    private var file: AVAudioFile?
    private let lock = NSLock()

    private var receivedFrames = 0
    private var sampleBuffers = 0
    private var sampleRate = 0.0
    private var firstPTS: Double?
    private var lastPTS: Double?
    private var lastWriteError: String?

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd),
              let buffer = pcmBuffer(from: sampleBuffer, format: format) else {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

        lock.lock()
        defer { lock.unlock() }
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: outputURL, settings: format.settings)
            }
            try file?.write(from: buffer)
            receivedFrames += Int(buffer.frameLength)
            sampleBuffers += 1
            sampleRate = format.sampleRate
            if firstPTS == nil, pts.isFinite {
                firstPTS = pts
            }
            if pts.isFinite {
                lastPTS = pts
            }
        } catch {
            lastWriteError = String(describing: error)
            fputs("audio write failed: \(error)\n", stderr)
        }
    }

    func stats() -> AudioWriterStats {
        lock.lock()
        defer { lock.unlock() }
        return AudioWriterStats(
            receivedFrames: receivedFrames,
            sampleBuffers: sampleBuffers,
            sampleRate: sampleRate,
            firstPTS: firstPTS,
            lastPTS: lastPTS,
            lastWriteError: lastWriteError
        )
    }

    func ensureSilence(durationSeconds: Double, sampleRate fallbackSampleRate: Double) {
        lock.lock()
        let shouldCreate = receivedFrames == 0
        lock.unlock()
        guard shouldCreate, durationSeconds > 0 else { return }

        let targetRate = fallbackSampleRate > 0 ? fallbackSampleRate : 48_000
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: targetRate,
            channels: 1
        ) else {
            return
        }

        do {
            let silenceFile = try AVAudioFile(
                forWriting: outputURL,
                settings: format.settings
            )
            let chunkFrames = AVAudioFrameCount(targetRate)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: chunkFrames
            ), let channel = buffer.floatChannelData?[0] else {
                return
            }

            var framesRemaining = Int(durationSeconds * targetRate)
            while framesRemaining > 0 {
                let frames = min(framesRemaining, Int(chunkFrames))
                buffer.frameLength = AVAudioFrameCount(frames)
                channel.initialize(repeating: 0, count: frames)
                try silenceFile.write(from: buffer)
                framesRemaining -= frames
            }
        } catch {
            lock.lock()
            lastWriteError = "silence materialization failed: \(error)"
            lock.unlock()
            fputs("silence materialization failed: \(error)\n", stderr)
        }
    }

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer,
                           format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let output = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            return nil
        }
        output.frameLength = frameCount

        var listSize = 0
        var retainedBlock: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &retainedBlock
        ) == noErr, listSize > 0 else {
            return nil
        }

        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawList.deallocate() }
        let list = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: listSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &retainedBlock
        ) == noErr else {
            return nil
        }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(list)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            output.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else {
            return nil
        }
        for index in sourceBuffers.indices {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData else {
                return nil
            }
            let byteCount = min(
                Int(sourceBuffers[index].mDataByteSize),
                Int(destinationBuffers[index].mDataByteSize)
            )
            destinationData.copyMemory(from: sourceData, byteCount: byteCount)
        }
        return output
    }
}

final class NativeCapture {
    private let systemURL: URL
    private let microphoneURL: URL
    private let statusURL: URL
    private var stream: SCStream?
    private var systemWriter: AudioWriter?
    private var microphoneWriter: AudioWriter?

    private let systemQueue = DispatchQueue(
        label: "physics-class-system-audio"
    )
    private let microphoneQueue = DispatchQueue(
        label: "physics-class-microphone"
    )

    init(systemURL: URL, microphoneURL: URL, statusURL: URL) {
        self.systemURL = systemURL
        self.microphoneURL = microphoneURL
        self.statusURL = statusURL
    }

    private func writeStatus(_ value: String) {
        try? (value + "\n").write(
            to: statusURL,
            atomically: true,
            encoding: .utf8
        )
    }

    private func microphoneAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw NSError(
                domain: "PhysicsClassNativeAudio",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "screen/system-audio capture permission not granted"
                ]
            )
        }

        guard await microphoneAuthorized() else {
            throw NSError(
                domain: "PhysicsClassNativeAudio",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "microphone permission not granted"
                ]
            )
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw NSError(
                domain: "PhysicsClassNativeAudio",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "no display available"]
            )
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.excludesCurrentProcessAudio = true

        // Ask ScreenCaptureKit for a predictable audio layout.  The actual
        // sample-buffer format is still honored by AudioWriter.
        configuration.sampleRate = 48_000
        configuration.channelCount = 1

        // We do not consume screen video. Keep the stream tiny so audio capture
        // remains cheap while preserving ScreenCaptureKit's system-audio path.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3

        let systemWriter = AudioWriter(outputURL: systemURL)
        let microphoneWriter = AudioWriter(outputURL: microphoneURL)
        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: nil
        )
        try stream.addStreamOutput(
            systemWriter,
            type: .audio,
            sampleHandlerQueue: systemQueue
        )
        try stream.addStreamOutput(
            microphoneWriter,
            type: .microphone,
            sampleHandlerQueue: microphoneQueue
        )
        try await stream.startCapture()

        self.systemWriter = systemWriter
        self.microphoneWriter = microphoneWriter
        self.stream = stream
        writeStatus("ready")
        print("native audio capture started")
    }

    func stop() async {
        try? await stream?.stopCapture()

        // stopCapture stops delivery, but callbacks already queued on our
        // serial queues may still be writing. Drain both queues before the
        // process exits so the watcher never races a half-flushed CAF file.
        systemQueue.sync {}
        microphoneQueue.sync {}

        let initialSystem = systemWriter?.stats() ?? AudioWriterStats(
            receivedFrames: 0,
            sampleBuffers: 0,
            sampleRate: 0,
            firstPTS: nil,
            lastPTS: nil,
            lastWriteError: nil
        )
        let initialMicrophone = microphoneWriter?.stats() ?? AudioWriterStats(
            receivedFrames: 0,
            sampleBuffers: 0,
            sampleRate: 0,
            firstPTS: nil,
            lastPTS: nil,
            lastWriteError: nil
        )

        // The watcher merges both source files. If ScreenCaptureKit delivered
        // zero buffers for one side but the other side is valid, materialize a
        // matching silent CAF so a recoverable single-source lesson does not
        // fail before health classification/transcription.
        if initialSystem.receivedFrames == 0,
           initialMicrophone.estimatedDuration > 0 {
            systemWriter?.ensureSilence(
                durationSeconds: initialMicrophone.estimatedDuration,
                sampleRate: initialMicrophone.sampleRate
            )
        }
        if initialMicrophone.receivedFrames == 0,
           initialSystem.estimatedDuration > 0 {
            microphoneWriter?.ensureSilence(
                durationSeconds: initialSystem.estimatedDuration,
                sampleRate: initialSystem.sampleRate
            )
        }

        let system = systemWriter?.stats() ?? initialSystem
        let microphone = microphoneWriter?.stats() ?? initialMicrophone

        let status = [
            "stopped",
            "system_frames=\(system.receivedFrames)",
            "system_buffers=\(system.sampleBuffers)",
            "system_sample_rate=\(system.sampleRate)",
            "system_estimated_duration=\(system.estimatedDuration)",
            "system_first_pts=\(system.firstPTS.map { String($0) } ?? "none")",
            "system_last_pts=\(system.lastPTS.map { String($0) } ?? "none")",
            "system_write_error=\(system.lastWriteError ?? "none")",
            "microphone_frames=\(microphone.receivedFrames)",
            "microphone_buffers=\(microphone.sampleBuffers)",
            "microphone_sample_rate=\(microphone.sampleRate)",
            "microphone_estimated_duration=\(microphone.estimatedDuration)",
            "microphone_first_pts=\(microphone.firstPTS.map { String($0) } ?? "none")",
            "microphone_last_pts=\(microphone.lastPTS.map { String($0) } ?? "none")",
            "microphone_write_error=\(microphone.lastWriteError ?? "none")",
        ].joined(separator: "\n")
        writeStatus(status)

        print(
            "native audio capture stopped "
            + "system_frames=\(system.receivedFrames) "
            + "microphone_frames=\(microphone.receivedFrames)"
        )
    }
}

guard CommandLine.arguments.count == 4 else {
    fputs(
        "usage: capture_native_audio SYSTEM.caf MICROPHONE.caf STATUS_FILE\n",
        stderr
    )
    exit(2)
}

let capture = NativeCapture(
    systemURL: URL(fileURLWithPath: CommandLine.arguments[1]),
    microphoneURL: URL(fileURLWithPath: CommandLine.arguments[2]),
    statusURL: URL(fileURLWithPath: CommandLine.arguments[3])
)
let semaphore = DispatchSemaphore(value: 0)
let stopLock = NSLock()
var stopping = false
let signalSources = [SIGINT, SIGTERM].map { signalNumber in
    let source = DispatchSource.makeSignalSource(
        signal: signalNumber,
        queue: DispatchQueue.global(qos: .userInitiated)
    )
    signal(signalNumber, SIG_IGN)
    source.setEventHandler {
        stopLock.lock()
        let shouldStop = !stopping
        if shouldStop {
            stopping = true
        }
        stopLock.unlock()
        guard shouldStop else { return }

        Task {
            await capture.stop()
            semaphore.signal()
        }
    }
    source.resume()
    return source
}

Task {
    do {
        try await capture.start()
    } catch {
        try? ("error: \(error)\n").write(
            to: URL(fileURLWithPath: CommandLine.arguments[3]),
            atomically: true,
            encoding: .utf8
        )
        fputs("native audio capture failed: \(error)\n", stderr)
        semaphore.signal()
    }
}
semaphore.wait()

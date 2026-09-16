// Capture the macOS system audio and the active microphone without a virtual
// sound card. The watcher merges the two independent streams after stopping.
//
// Usage: capture_native_audio OUTPUT_SYSTEM.caf OUTPUT_MICROPHONE.caf STATUS_FILE

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

final class AudioWriter: NSObject, SCStreamOutput {
    private let outputURL: URL
    private var file: AVAudioFile?
    private let lock = NSLock()
    private(set) var receivedFrames = 0

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

        lock.lock()
        defer { lock.unlock() }
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: outputURL, settings: format.settings)
            }
            try file?.write(from: buffer)
            receivedFrames += Int(buffer.frameLength)
        } catch {
            fputs("audio write failed: \(error)\n", stderr)
        }
    }

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer,
                           format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
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
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
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

    init(systemURL: URL, microphoneURL: URL, statusURL: URL) {
        self.systemURL = systemURL
        self.microphoneURL = microphoneURL
        self.statusURL = statusURL
    }

    private func writeStatus(_ value: String) {
        try? (value + "\n").write(to: statusURL, atomically: true, encoding: .utf8)
    }

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw NSError(domain: "PhysicsClassNativeAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "screen capture permission not granted"])
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw NSError(domain: "PhysicsClassNativeAudio", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no display available"])
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let systemWriter = AudioWriter(outputURL: systemURL)
        let microphoneWriter = AudioWriter(outputURL: microphoneURL)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(
            systemWriter,
            type: .audio,
            sampleHandlerQueue: DispatchQueue(label: "physics-class-system-audio")
        )
        try stream.addStreamOutput(
            microphoneWriter,
            type: .microphone,
            sampleHandlerQueue: DispatchQueue(label: "physics-class-microphone")
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
        writeStatus("stopped")
        print("native audio capture stopped system_frames=\(systemWriter?.receivedFrames ?? 0) microphone_frames=\(microphoneWriter?.receivedFrames ?? 0)")
    }
}

guard CommandLine.arguments.count == 4 else {
    fputs("usage: capture_native_audio SYSTEM.caf MICROPHONE.caf STATUS_FILE\n", stderr)
    exit(2)
}

let capture = NativeCapture(
    systemURL: URL(fileURLWithPath: CommandLine.arguments[1]),
    microphoneURL: URL(fileURLWithPath: CommandLine.arguments[2]),
    statusURL: URL(fileURLWithPath: CommandLine.arguments[3])
)
let semaphore = DispatchSemaphore(value: 0)
var stopping = false
let signalSources = [SIGINT, SIGTERM].map { signalNumber in
    let source = DispatchSource.makeSignalSource(
        signal: signalNumber,
        queue: DispatchQueue.global(qos: .userInitiated)
    )
    signal(signalNumber, SIG_IGN)
    source.setEventHandler {
        guard !stopping else { return }
        stopping = true
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

// Spike A: prove ScreenCaptureKit can capture system audio output to a WAV file.
// Usage: CaptureSpike <seconds> <output.wav>

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 5 : 5
let outPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/capture-spike.wav"

final class AudioWriter: NSObject, SCStreamOutput {
    private var file: AVAudioFile?
    private let url: URL
    private(set) var buffersWritten = 0
    private var loggedError = false

    init(url: URL) { self.url = url }

    func finish() {
        // exit() skips deinit, so close explicitly to finalize the WAV header.
        if #available(macOS 15.0, *) { file?.close() }
        file = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let described = sampleBuffer.formatDescription,
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(described) else { return }
        var asbd = asbdPtr.pointee

        guard let format = AVAudioFormat(streamDescription: &asbd) else { return }

        do {
            if file == nil {
                // File format must be interleaved; processing format matches the
                // stream's (typically non-interleaved Float32) so writes convert.
                let fileSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: asbd.mSampleRate,
                    AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame),
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                ]
                file = try AVAudioFile(forWriting: url, settings: fileSettings,
                                       commonFormat: format.commonFormat,
                                       interleaved: format.isInterleaved)
            }

            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            guard numSamples > 0,
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)) else { return }
            pcm.frameLength = AVAudioFrameCount(numSamples)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(numSamples),
                into: pcm.mutableAudioBufferList)
            guard status == noErr else { return }

            try file?.write(from: pcm)
            buffersWritten += 1
        } catch {
            if !loggedError {
                loggedError = true
                print("WRITE ERROR: \(error)")
            }
        }
    }
}

let semaphore = DispatchSemaphore(value: 0)

Task {
    do {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            print("FAIL: no display found")
            exit(1)
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        // Minimal video config; SCStream requires a video track even for audio-focused capture.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let url = URL(fileURLWithPath: outPath)
        try? FileManager.default.removeItem(at: url)
        let writer = AudioWriter(url: url)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio"))
        try await stream.startCapture()
        print("Capturing system audio for \(seconds)s -> \(outPath)")

        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try await stream.stopCapture()
        writer.finish()

        if writer.buffersWritten > 0 {
            print("OK: wrote \(writer.buffersWritten) audio buffers to \(outPath)")
            exit(0)
        } else {
            print("FAIL: no audio buffers received (permission denied or no audio route)")
            exit(1)
        }
    } catch {
        print("FAIL: \(error)")
        exit(1)
    }
}

semaphore.wait()

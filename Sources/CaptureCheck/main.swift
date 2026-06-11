// Phase 1 verification harness: runs the real capture module and writes its
// 16 kHz mono output to a WAV so it can be inspected / fed to WhisperKit.
// Usage: capture-check [system|mic] [seconds] [output.wav]

import AVFoundation
import BlablacadabraCore
import Foundation

let sourceName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "system"
let seconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 10 : 10
let outPath = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "/tmp/capture-check.wav"

let source: AudioSource
switch sourceName {
case "system": source = SystemAudioCapture()
case "mic": source = MicCapture()
default:
    print("usage: capture-check [system|mic] [seconds] [output.wav]")
    exit(2)
}

if sourceName == "system", CapturePermissions.screenRecordingStatus != .granted {
    print("Screen Recording permission: \(CapturePermissions.screenRecordingStatus). Requesting...")
    if !CapturePermissions.requestScreenRecordingAccess() {
        print("FAIL: Screen Recording denied. Enable it in System Settings, then rerun.")
        exit(1)
    }
}

let semaphore = DispatchSemaphore(value: 0)

Task {
    do {
        let url = URL(fileURLWithPath: outPath)
        try? FileManager.default.removeItem(at: url)

        // Interleaved Float32 file settings (gotcha: don't pass the processing
        // format's settings straight through).
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioPipelineFormat.sampleRate,
            AVNumberOfChannelsKey: Int(AudioPipelineFormat.channels),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        var file: AVAudioFile? = try AVAudioFile(
            forWriting: url, settings: fileSettings,
            commonFormat: .pcmFormatFloat32, interleaved: false)

        let stream = try await source.start()
        print("Capturing \(sourceName) audio for \(seconds)s -> \(outPath)")

        let deadline = Date().addingTimeInterval(seconds)
        var buffers = 0
        var frames: AVAudioFramePosition = 0
        for await buffer in stream {
            try file?.write(from: buffer)
            buffers += 1
            frames += AVAudioFramePosition(buffer.frameLength)
            if Date() >= deadline { break }
        }
        await source.stop()

        // exit() skips deinit; close explicitly or the WAV header stays empty.
        if #available(macOS 15.0, *) { file?.close() }
        file = nil

        let capturedSeconds = Double(frames) / AudioPipelineFormat.sampleRate
        if buffers > 0 {
            print("OK: \(buffers) buffers, \(frames) frames (\(String(format: "%.1f", capturedSeconds))s at 16kHz mono) -> \(outPath)")
            exit(0)
        } else {
            print("FAIL: no buffers received (permission denied or no audio route)")
            exit(1)
        }
    } catch {
        print("FAIL: \(error.localizedDescription)")
        exit(1)
    }
}

semaphore.wait()

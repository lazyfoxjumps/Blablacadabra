// Phase 2 verification harness: runs the full live pipeline
// (capture -> VAD chunking -> WhisperKit) and prints captions as they land.
// Partials render in-place on the current line; finals commit as new lines.
// Usage: transcribe-check [system|mic] [seconds] [model] [--translate]

import BlablacadabraCore
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
let translate = args.contains("--translate")
let bilingual = args.contains("--bilingual")
args.removeAll { $0 == "--translate" || $0 == "--bilingual" }

let sourceName = args.count > 0 ? args[0] : "system"
let seconds = args.count > 1 ? Double(args[1]) ?? 30 : 30
let model = args.count > 2 ? args[2] : WhisperKitEngine.defaultModel

let source: AudioSource
switch sourceName {
case "system": source = SystemAudioCapture()
case "mic": source = MicCapture()
default:
    print("usage: transcribe-check [system|mic] [seconds] [model] [--translate]")
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
        let engine = WhisperKitEngine(model: model)
        let pipeline = TranscriptionPipeline(
            source: source,
            engine: engine,
            task: translate ? .translate : .transcribe,
            showOriginal: bilingual
        )

        // Track incoming audio so a silent run is diagnosable (no audio
        // playing vs. VAD threshold vs. engine trouble). BLABLA_DEBUG_WAV=path
        // additionally dumps everything the pipeline hears to a raw Float32
        // file for offline inspection.
        final class LevelMeter: @unchecked Sendable {
            let lock = NSLock()
            var buffers = 0
            var samples = 0
            var peak: Float = 0
            let dump: FileHandle?
            init() {
                if let path = ProcessInfo.processInfo.environment["BLABLA_DEBUG_WAV"] {
                    FileManager.default.createFile(atPath: path, contents: nil)
                    dump = FileHandle(forWritingAtPath: path)
                } else {
                    dump = nil
                }
            }
            func record(_ chunk: [Float]) {
                lock.lock()
                buffers += 1
                samples += chunk.count
                peak = max(peak, chunk.map { abs($0) }.max() ?? 0)
                dump?.write(chunk.withUnsafeBufferPointer { Data(buffer: $0) })
                lock.unlock()
            }
            var summary: String {
                lock.lock()
                defer { lock.unlock() }
                let secs = Double(samples) / AudioPipelineFormat.sampleRate
                return "\(buffers) buffers, \(String(format: "%.1f", secs))s, peak \(String(format: "%.3f", peak))"
            }
        }
        let meter = LevelMeter()
        await pipeline.setAudioTap { meter.record($0) }

        // Mirror what the app's status line gets: download percent, then load.
        await engine.setPrepareHandler { event in
            switch event {
            case .downloading(let fraction):
                FileHandle.standardOutput.write(Data("\r  downloading \(Int(fraction * 100))%\u{1B}[K".utf8))
            case .loading:
                FileHandle.standardOutput.write(Data("\r  download done, loading model\u{1B}[K\n".utf8))
            }
        }

        print("Loading model '\(model)' (downloads on first run)...")
        let captions = try await pipeline.start()
        let mode = translate ? "translate -> English" : "transcribe"
        print("Listening to \(sourceName) audio for \(seconds)s (\(mode)). Speak or play something.")

        let stopper = Task {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await pipeline.stop()
        }

        var finals = 0
        var partials = 0
        for await event in captions {
            switch event {
            case .partial(let text, _, _):
                partials += 1
                FileHandle.standardOutput.write(Data("\r  ~ \(text)\u{1B}[K".utf8))
            case .final(let text, let original, let language, _):
                finals += 1
                FileHandle.standardOutput.write(Data("\r\u{1B}[K".utf8))
                // When translating, show the detected source language and,
                // in bilingual mode, the original text above the English.
                if translate, let name = SpokenLanguage.displayName(forCode: language) {
                    if let original { print("  > [\(name)] \(original)") }
                    print("  > [\(name) → English] \(text)")
                } else {
                    print("  > \(text)")
                }
            }
        }
        stopper.cancel()

        print("")
        print("audio: \(meter.summary)")
        if finals > 0 {
            print("OK: \(finals) final caption(s), \(partials) partial update(s)")
            exit(0)
        } else {
            print("FAIL: no captions produced (was any speech playing?)")
            exit(1)
        }
    } catch {
        print("FAIL: \(error.localizedDescription)")
        exit(1)
    }
}

semaphore.wait()

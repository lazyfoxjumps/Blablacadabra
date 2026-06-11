// Spike B: prove WhisperKit transcribes a WAV file on-device.
// Usage: TranscribeSpike <audio.wav> [model]

import Foundation
import WhisperKit

guard CommandLine.arguments.count > 1 else {
    print("usage: TranscribeSpike <audio.wav> [model]")
    exit(2)
}
let audioPath = CommandLine.arguments[1]
let model = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "base"

let semaphore = DispatchSemaphore(value: 0)

Task {
    do {
        print("Loading WhisperKit model '\(model)' (downloads on first run)...")
        let pipe = try await WhisperKit(WhisperKitConfig(model: model))
        print("Transcribing \(audioPath)...")
        let results = try await pipe.transcribe(audioPath: audioPath)
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            print("FAIL: empty transcription")
            exit(1)
        }
        print("OK: \(text)")
        exit(0)
    } catch {
        print("FAIL: \(error)")
        exit(1)
    }
}

semaphore.wait()

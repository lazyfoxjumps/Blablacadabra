import Foundation
import WhisperKit

/// On-device speech-to-text via WhisperKit. Default engine: private, free,
/// offline, and handles the translate-to-English task natively.
///
/// An actor so concurrent callers serialize; WhisperKit runs one decode at a
/// time anyway, and the pipeline already coalesces stale partials upstream.
public actor WhisperKitEngine: TranscriptionEngine {
    /// Model sizes worth offering in the UI, fastest first. Any other
    /// WhisperKit model name also works via `init(model:)`.
    public static let availableModels = ["tiny", "base", "small", "medium"]
    public static let defaultModel = "base"

    public let model: String
    private var whisper: WhisperKit?

    public init(model: String = WhisperKitEngine.defaultModel) {
        self.model = model
    }

    public func prepare() async throws {
        guard whisper == nil else { return }
        do {
            whisper = try await WhisperKit(WhisperKitConfig(model: model))
        } catch {
            throw TranscriptionError.modelLoadFailed(String(describing: error))
        }
    }

    public func transcribe(_ samples: [Float], task: TranscriptionTask) async throws -> String {
        guard let whisper else { throw TranscriptionError.engineNotPrepared }
        // Whisper pads to its 30s window internally, but sub-0.1s blips only
        // produce hallucinations; the VAD already drops most of these.
        guard samples.count >= Int(AudioPipelineFormat.sampleRate / 10) else { return "" }

        let options = DecodingOptions(
            task: task == .translate ? .translate : .transcribe,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.isNoise(text) ? "" : text
    }

    /// Whisper labels non-speech with bracketed annotations ("[BLANK_AUDIO]",
    /// "(music)", "♪ ♪"); those are noise, not captions.
    static func isNoise(_ text: String) -> Bool {
        if text.isEmpty { return true }
        let stripped = text.filter { !$0.isWhitespace && $0 != "♪" && $0 != "♫" }
        if stripped.isEmpty { return true }
        if let first = stripped.first, let last = stripped.last,
           (first == "[" && last == "]") || (first == "(" && last == ")") {
            return true
        }
        return false
    }
}

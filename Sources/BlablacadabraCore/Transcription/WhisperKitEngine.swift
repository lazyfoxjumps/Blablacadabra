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

    /// Whether this model is already on disk (WhisperKit caches under
    /// ~/Documents/huggingface). A missing or partial cache means `prepare()`
    /// will download first, which can take minutes on the bigger models; the
    /// UI uses this to say so instead of a vague "warming up".
    public static func isModelCached(_ model: String) -> Bool {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return false }
        let modelDir = documents.appendingPathComponent(
            "huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-\(model)"
        )
        // The decoder weights land last; their compiled model is the
        // "download actually finished" marker.
        let decoder = modelDir.appendingPathComponent("TextDecoder.mlmodelc/coremldata.bin")
        return FileManager.default.fileExists(atPath: decoder.path)
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
        let text = Self.cleaned(
            results.map(\.text).joined(separator: " ")
        )
        return Self.isNoise(text) ? "" : text
    }

    /// Whisper opens chunks that start mid-conversation with a dialog dash
    /// ("- I'm going to pause."); as a live caption line that reads like a
    /// stage direction, so the leading dash goes.
    static func cleaned(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.first, first == "-" || first == "\u{2013}" || first == "\u{2014}" {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return text
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

import Foundation

/// What the engine should do with the audio: write down what was said in its
/// original language, or translate any language into English.
public enum TranscriptionTask: String, Sendable, CaseIterable {
    case transcribe
    case translate
}

/// One utterance's worth of recognized text plus what the engine inferred
/// about it.
public struct TranscriptionOutput: Sendable, Equatable {
    /// The caption text (empty when nothing intelligible was said).
    public let text: String
    /// ISO 639-1 code of the detected source language (e.g. "id"), when the
    /// engine knows it. Whisper reports this even on the translate task, so
    /// the UI can show "Indonesian -> English". nil when unknown.
    public let detectedLanguage: String?

    public init(text: String, detectedLanguage: String? = nil) {
        self.text = text
        self.detectedLanguage = detectedLanguage
    }

    public static let empty = TranscriptionOutput(text: "")
}

/// A speech-to-text engine. WhisperKit is the on-device default; a cloud
/// engine (Deepgram, Gemini Live, ...) can conform later and drop in behind
/// the same pipeline.
public protocol TranscriptionEngine: AnyObject, Sendable {
    /// Loads the model (may download on first run). Must be called before
    /// `transcribe`. Safe to call again; subsequent calls are no-ops.
    func prepare() async throws

    /// Transcribes one utterance of 16 kHz mono Float32 samples.
    /// `language` forces the source language (ISO 639-1); pass nil to let the
    /// engine decide. Forcing matters because some engines (WhisperKit) treat
    /// an unspecified language as English rather than auto-detecting.
    /// Returns the text (empty if nothing was said) plus the language the
    /// engine reports for it.
    func transcribe(_ samples: [Float], task: TranscriptionTask, language: String?) async throws -> TranscriptionOutput

    /// Detects the spoken language (ISO 639-1) without producing text.
    /// Used to label the translation direction, since the translate task
    /// itself reports the target language ("en"), not the source.
    /// Engines that can't do this return nil (the default).
    func detectLanguage(_ samples: [Float]) async throws -> String?

    /// Detects the spoken language AND surfaces the full per-language
    /// probability distribution, so the caller can apply confidence + margin
    /// gating (used by `LanguageStickinessGate` on the auto-detect translate
    /// path to avoid sticking to the first language detected). Engines that
    /// can't expose probabilities return nil; the caller falls back to
    /// `detectLanguage`.
    func detectLanguageDetailed(_ samples: [Float]) async throws -> LanguageDetection?
}

/// Result of a probability-bearing language detection. `language` is the
/// top-1 guess; `probabilities` maps ISO 639-1 codes to their model
/// probability so the caller can read confidence and margin against any
/// alternative language without re-running the model.
public struct LanguageDetection: Sendable, Equatable {
    public let language: String
    public let probabilities: [String: Float]

    public init(language: String, probabilities: [String: Float]) {
        self.language = language
        self.probabilities = probabilities
    }

    /// Probability the model assigned to its top guess.
    public var topProbability: Float { probabilities[language] ?? 0 }

    /// Probability the model assigned to an alternative language (0 when absent).
    public func probability(of code: String) -> Float { probabilities[code] ?? 0 }
}

public extension TranscriptionEngine {
    func detectLanguage(_ samples: [Float]) async throws -> String? { nil }
    func detectLanguageDetailed(_ samples: [Float]) async throws -> LanguageDetection? { nil }

    /// Convenience: transcribe without forcing a language.
    func transcribe(_ samples: [Float], task: TranscriptionTask) async throws -> TranscriptionOutput {
        try await transcribe(samples, task: task, language: nil)
    }
}

public enum TranscriptionError: LocalizedError {
    case engineNotPrepared
    case modelLoadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .engineNotPrepared:
            return "Transcription engine used before prepare() finished."
        case .modelLoadFailed(let detail):
            return "Could not load the speech model: \(detail)"
        }
    }
}

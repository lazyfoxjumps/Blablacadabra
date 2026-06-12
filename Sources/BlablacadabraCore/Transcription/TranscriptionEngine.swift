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
}

public extension TranscriptionEngine {
    func detectLanguage(_ samples: [Float]) async throws -> String? { nil }

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

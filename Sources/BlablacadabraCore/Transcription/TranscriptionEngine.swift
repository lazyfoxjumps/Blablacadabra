import Foundation

/// What the engine should do with the audio: write down what was said in its
/// original language, or translate any language into English.
public enum TranscriptionTask: String, Sendable, CaseIterable {
    case transcribe
    case translate
}

/// A speech-to-text engine. WhisperKit is the on-device default; a cloud
/// engine (Deepgram, Gemini Live, ...) can conform later and drop in behind
/// the same pipeline.
public protocol TranscriptionEngine: AnyObject, Sendable {
    /// Loads the model (may download on first run). Must be called before
    /// `transcribe`. Safe to call again; subsequent calls are no-ops.
    func prepare() async throws

    /// Transcribes one utterance of 16 kHz mono Float32 samples.
    /// Returns plain text, or an empty string if nothing was said.
    func transcribe(_ samples: [Float], task: TranscriptionTask) async throws -> String
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

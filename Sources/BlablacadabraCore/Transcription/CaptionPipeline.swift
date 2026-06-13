import Foundation

/// The surface every caption source exposes to `AppState`, regardless of the
/// engine behind it. `TranscriptionPipeline` (WhisperKit, VAD-chunked) and
/// `AppleSpeechPipeline` (Apple `SpeechAnalyzer`, streaming-native) both
/// conform, so the overlay, `AppState.handle()`, the level meter, and the
/// Both-mode lanes treat them identically: capture in, `CaptionEvent`s out.
///
/// Methods mirror exactly what `AppState` already calls on a live pipeline.
/// Some are no-ops on engines that can't honor them mid-stream (the Apple path
/// is transcribe-only in Round 1, and its locale is fixed at init, so it
/// handles language and task changes via an `AppState` restart instead); the
/// protocol keeps the call sites uniform regardless.
/// Which engine a caption session runs on. Apple's `SpeechAnalyzer` is the
/// preferred fast-path; WhisperKit is the universal fallback.
public enum CaptionEngineKind: Equatable, Sendable {
    case apple
    case whisper

    /// Pure engine choice (no OS calls, so it's unit-testable). Apple is used only
    /// when every condition holds: not translating (Round 1 keeps translate on
    /// WhisperKit), the OS has the Apple API, the locale is Apple-supported, and
    /// Speech Recognition is authorized. Any miss falls back to WhisperKit.
    public static func select(
        translate: Bool,
        localeSupported: Bool,
        authorized: Bool,
        osHasApple: Bool
    ) -> CaptionEngineKind {
        if translate || !osHasApple || !localeSupported || !authorized {
            return .whisper
        }
        return .apple
    }
}

public protocol CaptionPipeline: Actor, Sendable {
    /// Starts capture, prepares the engine, and returns the caption stream.
    /// The stream finishes after `stop()` once any queued output has drained.
    func start() async throws -> AsyncStream<CaptionEvent>

    /// Stops capture and tears down the engine; the caption stream finishes.
    func stop() async

    /// The translate toggle. Settable mid-stream where the engine supports it.
    func setTask(_ newTask: TranscriptionTask)

    /// Locks the spoken language (ISO 639-1; nil/empty = auto). Where an engine
    /// fixes its locale at init, the caller restarts instead of relying on this.
    func setSpokenLanguage(_ code: String?)

    /// Bilingual captions: show the source-language text above the translation.
    func setShowOriginal(_ show: Bool)

    /// Linear input gain (1.0 = unchanged). Applies from the next buffer.
    func setInputGain(_ gain: Float)

    /// Optional tap on incoming pipeline-format samples; feeds the level meter
    /// and debug dumps without touching the caption stream.
    func setAudioTap(_ tap: (@Sendable ([Float]) -> Void)?)
}

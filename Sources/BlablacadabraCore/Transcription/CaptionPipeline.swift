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
/// Which engine a caption session runs on. Apple's on-device frameworks are the
/// preferred fast-path; WhisperKit is the universal transcriber.
///
/// - `appleTranscribe`: `SpeechAnalyzer` streaming transcription, translate off.
/// - `whisperAppleTranslate`: WhisperKit transcribes the (locked) source language,
///   then Apple's `Translation` framework text-translates each line to English.
///   This replaced the old all-Apple translate path: Whisper is the reliable
///   transcriber for non-English audio (Apple's speech assets only install for a
///   narrow set), and decoupling transcription from translation fixes the garbage
///   English that Whisper's own audio `.translate` task produced on dialectal /
///   low-resource languages (Arabic especially). Bilingual is near-free: the
///   source line is already the transcriber's output, no second decode.
/// - `whisper`: WhisperKit, the universal fallback (~99 languages, audio
///   auto-detect, audio translate, older macOS).
public enum CaptionEngineKind: Equatable, Sendable {
    case appleTranscribe
    case whisperAppleTranslate
    case whisper

    /// Source languages (ISO 639-1) whose Apple `Translation` quality we judge
    /// worse than WhisperKit's, so we keep them on Whisper's audio-translate even
    /// when Apple's pack is installed. `id` (Indonesian): Apple's on-device model
    /// leans Malay; Whisper's id->en reads truer. Transcribe-only (`appleTranscribe`)
    /// is unaffected — this only steers the translate path.
    public static let appleTranslateDenylist: Set<String> = ["id"]

    /// Pure engine choice (no OS calls, so it's unit-testable).
    ///
    /// - translate OFF: the Apple `SpeechAnalyzer` transcribe fast-path when the OS
    ///   has the API, the locale is Apple-supported, and Speech is authorized;
    ///   otherwise WhisperKit.
    /// - translate ON: `whisperAppleTranslate` when the OS has the macOS 26
    ///   `Translation` framework, the source language is LOCKED (Apple text-translate
    ///   needs a known source, and a locked language is also Whisper's reliable
    ///   transcribe mode), the source->English pack is already INSTALLED (we never
    ///   trigger a download here, to honor the no-nag rule), and the source is not on
    ///   `appleTranslateDenylist`. This path deliberately does NOT require Apple
    ///   speech support or the Speech permission: WhisperKit does the transcription,
    ///   so neither is relevant. Any miss falls back to WhisperKit's universal
    ///   audio-translate.
    public static func select(
        translate: Bool,
        localeSupported: Bool,
        authorized: Bool,
        osHasApple: Bool,
        languageLocked: Bool = false,
        translationInstalled: Bool = false,
        sourceISOCode: String? = nil
    ) -> CaptionEngineKind {
        guard osHasApple else { return .whisper }
        if translate {
            guard languageLocked, translationInstalled else { return .whisper }
            if let iso = sourceISOCode, appleTranslateDenylist.contains(iso) { return .whisper }
            return .whisperAppleTranslate
        }
        guard authorized, localeSupported else { return .whisper }
        return .appleTranscribe
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

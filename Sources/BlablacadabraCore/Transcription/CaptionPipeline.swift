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
    /// when Apple's pack is installed. The translate path then runs Whisper's audio
    /// `.translate` task, which only the translate-capable models can do.
    ///
    /// Currently EMPTY. `id` (Indonesian) used to live here (Apple's model leans
    /// Malay, Whisper's id->en read truer) but the large-v3-turbo model CANNOT
    /// audio-translate at all, so steering id to Whisper produced BLANK English on
    /// Turbo. Removing it routes id to the decoupled `whisperAppleTranslate` path
    /// (Whisper transcribes, Apple text-translates), which works on every model.
    /// The mechanism stays for future use: anything added here falls back to
    /// Whisper audio-translate, which silently produces nothing on Turbo. KNOWN
    /// GAP (not yet guarded): Turbo + translate for any language that still routes
    /// to `.whisper` (a future denylist entry, an Apple-unservable language, or
    /// macOS < 26) yields blank English. The planned fix is to swap such sessions
    /// to a translate-capable model (Medium). Transcribe-only is unaffected.
    public static let appleTranslateDenylist: Set<String> = []

    /// Pure engine choice (no OS calls, so it's unit-testable).
    ///
    /// - translate OFF: the Apple `SpeechAnalyzer` transcribe fast-path when the OS
    ///   has the API, the locale is Apple-supported, and Speech is authorized;
    ///   otherwise WhisperKit.
    /// - translate ON, with the macOS 26 `Translation` framework: `whisperAppleTranslate`,
    ///   WhisperKit transcribes and a text translator handles English. Two sub-cases:
    ///   - LOCKED source: chosen only when the source->English pack is already
    ///     INSTALLED (no download = no nag) and the source isn't on
    ///     `appleTranslateDenylist`; a single `AppleTranslationService` does the work.
    ///   - AUTO (unlocked) source: always chosen on macOS 26. WhisperKit detects the
    ///     language per line and a `TranslationRouter` routes each line (Apple where a
    ///     pack is installed and policy allows, else the carried Whisper audio-translate
    ///     fallback), so install/denylist are decided per language AT RUNTIME, not here.
    ///   This path deliberately does NOT require Apple speech support or the Speech
    ///   permission: WhisperKit does the transcription, so neither is relevant. Without
    ///   the macOS 26 framework it falls back to WhisperKit's universal audio-translate.
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
            // Auto-detect: the router decides Apple-vs-fallback per detected language.
            guard languageLocked else { return .whisperAppleTranslate }
            // Locked: needs an installed, non-denylisted pair, else Whisper handles it.
            guard translationInstalled else { return .whisper }
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

    /// Linear input gain (1.0 = unchanged). Applies from the next buffer. When
    /// auto-gain is on (`setAutoGain(true)`) this manual value is ignored.
    func setInputGain(_ gain: Float)

    /// Hands-off auto-gain (AGC). When on, the pipeline measures the incoming
    /// level and drives the gain itself, ignoring the manual `setInputGain`
    /// value until it's turned back off. Applies from the next buffer.
    func setAutoGain(_ enabled: Bool)

    /// Optional tap on incoming pipeline-format samples; feeds the level meter
    /// and debug dumps without touching the caption stream.
    func setAudioTap(_ tap: (@Sendable ([Float]) -> Void)?)
}

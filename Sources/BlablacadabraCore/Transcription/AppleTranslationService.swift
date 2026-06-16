import Foundation
import Translation

/// A line-by-line text translator backend for `TranslatingPipeline`. Kept minimal
/// and engine-agnostic so the translation pump can be unit-tested with a fake, and
/// so a future backend (e.g. an on-device LLM) can slot in without touching the
/// pipeline. `AppleTranslationService` is the only conformer today.
public protocol TextTranslating: Actor {
    /// Warm/prepare the backend. Throws when the backend can't be used, so the
    /// pipeline falls back BEFORE any audio is captured.
    func start() async throws
    /// Translate one line to the target language. `sourceISO` is the ISO 639-1 code
    /// of the line's source language (nil when unknown); a single-language backend
    /// ignores it, while a multi-language `TranslationRouter` uses it to pick the
    /// right per-language session. Returns nil on empty input, an unknown/unservable
    /// source, or a per-line failure (the caller skips that line or uses a fallback;
    /// the next line keeps flowing).
    func translate(_ text: String, from sourceISO: String?) async -> String?
    /// Tear down the backend.
    func stop()
}

/// On-device text translation via Apple's `Translation` framework (macOS 26),
/// used by the Round 2 Apple translate fast-path. Translates a source language
/// to English line by line.
///
/// Why this exists as its own actor: `TranslationSession` and
/// `LanguageAvailability` are NON-Sendable with `nonisolated` async members, so
/// they must be confined to a single isolation domain. This actor owns the
/// session and never lets it cross a task boundary.
///
/// macOS 26 added the direct `TranslationSession(installedSource:target:)`
/// initializer, so NO hidden SwiftUI `.translationTask` host is needed (that was
/// the only way on macOS 15). Everything here is pure Core code linking the
/// system `Translation` framework.
///
/// Policy: we use Apple translation only for pairs the OS reports as already
/// INSTALLED. We never trigger a model download from here (that shows system UI
/// and would nag, against the ND no-nag rule); an un-installed pair simply falls
/// back to WhisperKit, which translates ~99 languages on its own.
@available(macOS 26, *)
public actor AppleTranslationService: TextTranslating {
    private let source: Locale.Language
    private let target: Locale.Language
    private var session: TranslationSession?

    public init(sourceISOCode: String, targetISOCode: String = "en") {
        self.source = Locale.Language(identifier: sourceISOCode)
        self.target = Locale.Language(identifier: targetISOCode)
    }

    /// Whether Apple can translate `sourceISOCode -> targetISOCode` with an
    /// already-installed pack (status `.installed`, not merely `.supported`).
    /// Used by `AppState`'s engine selection BEFORE the session starts, so an
    /// un-installed pair routes to WhisperKit without any download prompt.
    public static func isInstalled(sourceISOCode: String, targetISOCode: String = "en") async -> Bool {
        let availability = LanguageAvailability()
        let status = await availability.status(
            from: Locale.Language(identifier: sourceISOCode),
            to: Locale.Language(identifier: targetISOCode)
        )
        return status == .installed
    }

    /// Builds and warms the translation session. `prepareTranslation()` can throw
    /// `.notInstalled` on the first call after boot while the OS lazily readies an
    /// "installed" asset (a cold-start race seen in the spike), so this retries a
    /// few times with short backoff. Persistent failure throws
    /// `AppleSpeechUnavailable.translationUnavailable` so the caller falls back to
    /// WhisperKit BEFORE any audio is captured.
    public func start() async throws {
        let session = TranslationSession(installedSource: source, target: target)
        for attempt in 0..<4 {
            do {
                try await session.prepareTranslation()
                self.session = session
                return
            } catch {
                // Cold-start readiness race: wait briefly and retry. Any other
                // failure is treated the same (we just fall back to Whisper).
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
        throw AppleSpeechUnavailable.translationUnavailable
    }

    /// Translates one line to the target language. Returns nil on empty input or
    /// a per-line failure: one bad translation shouldn't kill a live session, the
    /// caller just skips that line (the next one keeps flowing). `sourceISO` is
    /// ignored here: this actor is fixed to a single source/target pair at init
    /// (the multi-language `TranslationRouter` is what dispatches by source).
    public func translate(_ text: String, from sourceISO: String? = nil) async -> String? {
        guard let session, !text.isEmpty else { return nil }
        do {
            let response = try await session.translate(text)
            let out = response.targetText
            return out.isEmpty ? nil : out
        } catch {
            return nil
        }
    }

    public func stop() {
        session?.cancel()
        session = nil
    }
}

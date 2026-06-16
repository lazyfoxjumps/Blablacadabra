import Foundation

/// Per-language policy for the auto-detect translate path. Graduates the old flat
/// `CaptionEngineKind.appleTranslateDenylist` into a table so each language can be
/// steered independently as we learn more about Apple's per-language quality.
public enum TranslationPolicy: Sendable, Equatable {
    /// Use Apple's `Translation` framework when its source->English pack is already
    /// installed; otherwise the caller's Whisper fallback handles the line.
    case auto
    /// Always defer to the Whisper fallback (Apple's on-device quality is judged
    /// worse for this language, e.g. `id` leans Malay). Apple is never tried.
    case whisper
}

/// A multi-language `TextTranslating` backend for the AUTO-detect translate path.
///
/// On the LOCKED path the source language is known up front, so `AppState` builds a
/// single `AppleTranslationService` directly. When the user does NOT lock a
/// language, WhisperKit detects it per session and tags each line; this router uses
/// that tag to dispatch to the right per-language Apple session, creating and
/// caching one lazily the first time a language appears.
///
/// It NEVER triggers a model download (no-nag rule): a language whose pack isn't
/// already `.installed`, or one whose policy is `.whisper`, returns nil so the
/// decorator uses the Whisper audio-translate fallback that `TranscriptionPipeline`
/// carries on each final. So a language Apple can't serve degrades to today's
/// behavior instead of going blank.
@available(macOS 26, *)
public actor TranslationRouter: TextTranslating {
    private let target: String

    /// Per-language overrides; languages absent from the table use `.auto`.
    private let policy: [String: TranslationPolicy]

    /// Lazily-built per-source sessions, keyed by ISO 639-1 source code. A nil value
    /// records a language we've already decided is unservable (policy `.whisper`,
    /// pack not installed, or a failed warm-up), so we don't re-probe it every line.
    private var services: [String: AppleTranslationService?] = [:]

    private var started = false

    public init(targetISOCode: String = "en", policy: [String: TranslationPolicy] = TranslationRouter.defaultPolicy) {
        self.target = targetISOCode
        self.policy = policy
    }

    /// The default policy table. Derived from `CaptionEngineKind.appleTranslateDenylist`
    /// so the denylist stays the single source of truth while reading as a table here.
    public static var defaultPolicy: [String: TranslationPolicy] {
        Dictionary(uniqueKeysWithValues: CaptionEngineKind.appleTranslateDenylist.map { ($0, .whisper) })
    }

    /// Nothing to warm globally: sessions are created per language on first use, and
    /// a language that can't be served just falls back. Always succeeds so the auto
    /// path never refuses to start (the per-line fallback keeps captions flowing).
    public func start() async throws { started = true }

    public func translate(_ text: String, from sourceISO: String?) async -> String? {
        guard !text.isEmpty, let iso = sourceISO, !iso.isEmpty else { return nil }
        // Never translate INTO the same language (e.g. English source, English target).
        guard iso != target else { return nil }

        if let cached = services[iso] {
            return await cached?.translate(text, from: iso)
        }

        // First time we've seen this language: decide and cache.
        guard policyFor(iso) != .whisper else {
            services[iso] = .some(nil)
            return nil
        }
        guard await AppleTranslationService.isInstalled(sourceISOCode: iso, targetISOCode: target) else {
            services[iso] = .some(nil)
            return nil
        }
        let service = AppleTranslationService(sourceISOCode: iso, targetISOCode: target)
        do {
            try await service.start()
        } catch {
            services[iso] = .some(nil) // warm-up failed; treat as unservable from now on
            return nil
        }
        services[iso] = .some(service)
        return await service.translate(text, from: iso)
    }

    public func stop() {
        // Each session lives on its own actor; spin them down off-actor (teardown,
        // so ordering doesn't matter) to satisfy the synchronous protocol method.
        for case let service? in services.values {
            Task { await service.stop() }
        }
        services = [:]
        started = false
    }

    private func policyFor(_ iso: String) -> TranslationPolicy {
        policy[iso] ?? .auto
    }
}

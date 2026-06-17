import Foundation

/// Decides whether a new language detection should REPLACE the currently
/// resolved source language on the auto-detect translate path (Plan B).
///
/// The original behavior cached the very first detection and never re-ran
/// (TranscriptionPipeline.lastLanguage). That fixed one failure mode (ambiguous
/// audio - "dah dah dah", humming - misfiring and poisoning every later line)
/// but introduced a worse one: the moment a real second language enters the
/// call (English -> Japanese -> Spanish), the router stays pinned to the
/// first foreign language detected and translates every later utterance FROM
/// the wrong source.
///
/// This gate keeps both protections by layering them. Re-detection runs on
/// every final, but a switch only commits when the proposed new language
///   (a) clears a confidence floor (rejects "dah dah" - flat distributions
///       never have a sharp top), AND
///   (b) wins by a margin over the currently cached language (handles
///       overlap-region ties), AND
///   (c) survives K consecutive agreeing finals (one-off misfire alone is
///       never enough; a real sustained switch builds the streak).
///
/// All thresholds are linear probabilities in `[0, 1]`. Absent languages in
/// the input dict are treated as 0, which is the correct linear sentinel.
public struct LanguageStickinessGate: Sendable, Equatable {
    /// Top-1 probability the proposed language must clear before it can
    /// challenge the cached one. Default ~50%.
    public let minTopProbability: Float
    /// Required margin of the proposed language's probability OVER the
    /// currently cached language's probability (linear). Default 0.15.
    public let switchMargin: Float
    /// How many CONSECUTIVE finals must agree on the same NEW language before
    /// the cache flips. Default 2 (one misfire alone is never enough).
    public let consecutiveAgreementsToSwitch: Int

    /// The currently resolved language (ISO 639-1), or nil when nothing has
    /// been confidently detected yet.
    public private(set) var current: String?
    private var pendingCandidate: String?
    private var pendingStreak: Int = 0

    public init(
        minTopProbability: Float = 0.5,
        switchMargin: Float = 0.15,
        consecutiveAgreementsToSwitch: Int = 2,
        current: String? = nil
    ) {
        self.minTopProbability = minTopProbability
        self.switchMargin = switchMargin
        self.consecutiveAgreementsToSwitch = max(1, consecutiveAgreementsToSwitch)
        self.current = current
    }

    /// Feed a fresh detection from the engine. Returns the resolved language
    /// AFTER applying the gate to this observation (may be unchanged).
    @discardableResult
    public mutating func observe(_ detection: LanguageDetection) -> String? {
        let proposed = detection.language
        let proposedProb = detection.topProbability

        // First-ever detection: adopt only when confident. A low-confidence
        // first reading shouldn't get to define the session.
        guard let cached = current else {
            if proposedProb >= minTopProbability {
                current = proposed
                resetPending()
            }
            return current
        }

        // Same language as cached: confirms the cache, drop any pending streak.
        if proposed == cached {
            resetPending()
            return current
        }

        // Different language proposed. Apply confidence + margin gates.
        let cachedProb = detection.probability(of: cached)
        let confident = proposedProb >= minTopProbability
        let beatsCache = (proposedProb - cachedProb) >= switchMargin
        guard confident, beatsCache else {
            // Ambiguous reading: drop the streak so a misfire doesn't carry
            // over and combine with the next reading.
            resetPending()
            return current
        }

        // Build the K-of-N streak for THIS candidate. Different proposed
        // language than last attempt? Restart the streak from 1.
        if pendingCandidate == proposed {
            pendingStreak += 1
        } else {
            pendingCandidate = proposed
            pendingStreak = 1
        }

        if pendingStreak >= consecutiveAgreementsToSwitch {
            current = proposed
            resetPending()
        }
        return current
    }

    /// Adopt a language without quorum, used for engines that expose only a
    /// top-1 ISO code (no probabilities). Mirrors the legacy single-shot cache:
    /// first detection wins, later calls are ignored.
    @discardableResult
    public mutating func adoptIfEmpty(_ language: String) -> String? {
        if current == nil { current = language }
        return current
    }

    /// Clear the cache + any in-flight streak (e.g. when the locked language
    /// or task changes, so detection starts fresh).
    public mutating func reset() {
        current = nil
        resetPending()
    }

    private mutating func resetPending() {
        pendingCandidate = nil
        pendingStreak = 0
    }
}

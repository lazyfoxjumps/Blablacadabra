import Testing
@testable import BlablacadabraCore

/// Unit tests for the language stickiness gate that drives the Plan B
/// auto-detect translate path. Pure value type, no async, no engine.
struct LanguageStickinessGateTests {
    /// Build a detection where the top language has `topProb`, the cached
    /// language (if named) has `cachedProb`, and any other listed language
    /// has its given prob. Mirrors the WhisperKit-derived shape after the
    /// engine wrapper converts log-probs to linear.
    private func detection(
        _ top: String,
        prob topProb: Float,
        also others: [String: Float] = [:]
    ) -> LanguageDetection {
        var probs = others
        probs[top] = topProb
        return LanguageDetection(language: top, probabilities: probs)
    }

    // MARK: - first-detection adoption

    @Test func firstHighConfidenceDetectionAdopted() {
        var gate = LanguageStickinessGate()
        let resolved = gate.observe(detection("ja", prob: 0.9))
        #expect(resolved == "ja")
        #expect(gate.current == "ja")
    }

    @Test func firstLowConfidenceDetectionRejected() {
        var gate = LanguageStickinessGate(minTopProbability: 0.5)
        let resolved = gate.observe(detection("cy", prob: 0.2)) // looks like a misfire
        #expect(resolved == nil)
        #expect(gate.current == nil)
    }

    @Test func adoptionFollowsTheFirstConfidentReading() {
        var gate = LanguageStickinessGate(minTopProbability: 0.5)
        _ = gate.observe(detection("cy", prob: 0.2))   // rejected (low conf)
        _ = gate.observe(detection("ja", prob: 0.8))   // adopted
        #expect(gate.current == "ja")
    }

    // MARK: - same-language confirmation

    @Test func sameLanguageConfirmsCacheAndDropsPendingStreak() {
        var gate = LanguageStickinessGate(consecutiveAgreementsToSwitch: 2)
        _ = gate.observe(detection("ja", prob: 0.9))
        // Mid-flight pending streak toward es starts:
        _ = gate.observe(detection("es", prob: 0.8, also: ["ja": 0.05]))
        // ...then a ja final lands: that should DROP the pending streak.
        _ = gate.observe(detection("ja", prob: 0.95))
        // Another es should now have to start its streak from 1 again.
        let resolved = gate.observe(detection("es", prob: 0.8, also: ["ja": 0.05]))
        #expect(resolved == "ja") // not enough streak to flip yet
        #expect(gate.current == "ja")
    }

    // MARK: - real switch (K-of-N + margin + confidence)

    @Test func sustainedNewLanguageSwitchesAfterKAgreements() {
        var gate = LanguageStickinessGate(consecutiveAgreementsToSwitch: 2)
        _ = gate.observe(detection("ja", prob: 0.9))
        let first = gate.observe(detection("es", prob: 0.8, also: ["ja": 0.05]))
        #expect(first == "ja") // streak=1, not switched yet
        let second = gate.observe(detection("es", prob: 0.85, also: ["ja": 0.04]))
        #expect(second == "es") // streak=2, switch commits
        #expect(gate.current == "es")
    }

    @Test func singleHighConfidenceMisfireDoesNotSwitchWhenStreakBreaks() {
        var gate = LanguageStickinessGate(consecutiveAgreementsToSwitch: 2)
        _ = gate.observe(detection("ja", prob: 0.9))
        // High-confidence misfire (e.g., a sneeze sampled as Welsh):
        let one = gate.observe(detection("cy", prob: 0.85, also: ["ja": 0.05]))
        #expect(one == "ja")
        // Next final is back to ja: streak resets.
        _ = gate.observe(detection("ja", prob: 0.92))
        // Another stray cy: streak must start from 1 again.
        let two = gate.observe(detection("cy", prob: 0.85, also: ["ja": 0.05]))
        #expect(two == "ja")
        #expect(gate.current == "ja")
    }

    @Test func lowConfidenceProposalDoesNotBuildStreak() {
        var gate = LanguageStickinessGate(minTopProbability: 0.5, consecutiveAgreementsToSwitch: 2)
        _ = gate.observe(detection("ja", prob: 0.9))
        _ = gate.observe(detection("es", prob: 0.3, also: ["ja": 0.05]))   // confidence too low
        _ = gate.observe(detection("es", prob: 0.35, also: ["ja": 0.05]))  // still too low
        // No streak built; first confident "es" only gets to 1, must wait for two.
        let confident1 = gate.observe(detection("es", prob: 0.8, also: ["ja": 0.05]))
        #expect(confident1 == "ja")
        let confident2 = gate.observe(detection("es", prob: 0.8, also: ["ja": 0.05]))
        #expect(confident2 == "es")
    }

    @Test func insufficientMarginOverCachedDoesNotSwitch() {
        // Cached "ja" still has a meaningful probability in the new dict; the
        // margin to "es" is below the threshold => ambiguous => no switch.
        var gate = LanguageStickinessGate(switchMargin: 0.15, consecutiveAgreementsToSwitch: 2)
        _ = gate.observe(detection("ja", prob: 0.9))
        let r1 = gate.observe(detection("es", prob: 0.55, also: ["ja": 0.5]))
        let r2 = gate.observe(detection("es", prob: 0.55, also: ["ja": 0.5]))
        #expect(r1 == "ja")
        #expect(r2 == "ja")
        #expect(gate.current == "ja")
    }

    @Test func cachedLanguageAbsentFromDictTreatedAsZero() {
        // WhisperKit's dict often contains ONLY the sampled top language. The
        // gate must still be able to switch off a sustained foreign signal.
        var gate = LanguageStickinessGate(consecutiveAgreementsToSwitch: 2)
        _ = gate.observe(detection("ja", prob: 0.9))
        _ = gate.observe(detection("es", prob: 0.7)) // no "ja" key at all
        let switched = gate.observe(detection("es", prob: 0.7))
        #expect(switched == "es")
    }

    // MARK: - the bug this exists to fix (Plan B regression scenario)

    @Test func englishThenJapaneseThenSpanishUnsticksWhereLegacyCachedForever() {
        // Legacy behavior: gate stayed on "ja" forever once the first foreign
        // utterance landed. The fix: a sustained Spanish stream switches.
        var gate = LanguageStickinessGate(consecutiveAgreementsToSwitch: 2)
        _ = gate.observe(detection("en", prob: 0.95))
        // User starts speaking Japanese; gate switches en -> ja in K=2 finals.
        _ = gate.observe(detection("ja", prob: 0.85))
        _ = gate.observe(detection("ja", prob: 0.9))
        #expect(gate.current == "ja")
        // User then switches to Spanish; gate must unstick ja -> es in K=2.
        _ = gate.observe(detection("es", prob: 0.85))
        let final = gate.observe(detection("es", prob: 0.9))
        #expect(final == "es")
        #expect(gate.current == "es")
    }

    // MARK: - reset + adoptIfEmpty

    @Test func resetClearsCacheAndPendingStreak() {
        var gate = LanguageStickinessGate(consecutiveAgreementsToSwitch: 2)
        _ = gate.observe(detection("ja", prob: 0.9))
        _ = gate.observe(detection("es", prob: 0.8)) // streak=1
        gate.reset()
        #expect(gate.current == nil)
        // After reset, a single confident new detection adopts as the FIRST one
        // (no streak required for the very first adoption).
        _ = gate.observe(detection("de", prob: 0.7))
        #expect(gate.current == "de")
    }

    @Test func adoptIfEmptyOnlyAdoptsWhenEmpty() {
        var gate = LanguageStickinessGate(current: "ja")
        let unchanged = gate.adoptIfEmpty("es")
        #expect(unchanged == "ja")
        gate.reset()
        let adopted = gate.adoptIfEmpty("es")
        #expect(adopted == "es")
    }
}

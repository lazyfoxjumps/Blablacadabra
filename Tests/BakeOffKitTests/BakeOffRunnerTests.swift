import Foundation
import Testing
@testable import BakeOffKit

/// Phase 7B (B.4) — runner loop contract. Offline: a fake factory/translator stands in
/// for the real Gemma backend, so these prove coverage (all clips × all models) and the
/// partial-failure rule without weights, network, or hardware.
@Suite struct BakeOffRunnerTests {

    // MARK: - Fakes

    /// A translator that returns a fixed token count per line and never throws.
    struct FakeTranslator: BakeOffTranslator {
        let tokensPerLine: Int
        func warmUp() async throws {}
        func translate(_ line: String, sourceISO: String) async throws -> (text: String, outputTokens: Int) {
            ("translated: \(line)", tokensPerLine)
        }
        func tearDown() async {}
    }

    /// A factory whose behavior is keyed by model, so a single test can make one model
    /// succeed and another fail to build.
    struct FakeFactory: TranslatorFactory {
        /// Models in this set throw `unsupportedModel` from `make` (build failure).
        let failingModels: Set<BakeOffModel>
        let tokensPerLine: Int

        init(failingModels: Set<BakeOffModel> = [], tokensPerLine: Int = 7) {
            self.failingModels = failingModels
            self.tokensPerLine = tokensPerLine
        }

        func make(_ model: BakeOffModel) async throws -> any BakeOffTranslator {
            if failingModels.contains(model) {
                throw BakeOffError.unsupportedModel(model.rawValue)
            }
            return FakeTranslator(tokensPerLine: tokensPerLine)
        }
    }

    private static func clips() -> [BakeOffClip] {
        [
            BakeOffClip(clipId: "es-1", sourceISO: "es", sourceText: ["hola", "adiós"]),
            BakeOffClip(clipId: "id-1", sourceISO: "id", sourceText: ["halo"]),
        ]
    }

    // MARK: - Coverage

    @Test func runsAllClipsAllModels() async {
        let runner = BakeOffRunner(factory: FakeFactory())
        let config = BakeOffConfig(
            models: [.gemma3_4B, .gemma3_1B],
            runs: 1,
            macID: "test-mac"
        )
        let rows = await runner.run(config: config, clips: Self.clips())

        // 2 models × 2 clips = 4 rows, all succeeded.
        #expect(rows.count == 4)
        #expect(rows.allSatisfy { $0.error == nil })

        let combos = Set(rows.map { "\($0.model)/\($0.clipId)" })
        #expect(combos == [
            "gemma-3-4b/es-1", "gemma-3-4b/id-1",
            "gemma-3-1b/es-1", "gemma-3-1b/id-1",
        ])
        // Locked columns are populated on success.
        #expect(rows.allSatisfy { $0.tokensPerSec != nil && $0.ramPeakMB != nil && $0.thermalState != nil })
        #expect(rows.allSatisfy { $0.qualityBleu == nil && $0.qualityHuman == nil }) // human-scored later
    }

    @Test func clipFilterSelectsBySourceISO() async {
        let runner = BakeOffRunner(factory: FakeFactory())
        let config = BakeOffConfig(models: [.gemma3_4B], clipISOFilter: ["es"], runs: 1, macID: "test-mac")
        let rows = await runner.run(config: config, clips: Self.clips())
        #expect(rows.count == 1)
        #expect(rows.first?.clipId == "es-1")
    }

    // MARK: - Partial failure

    @Test func partialFailureDoesNotKillTheRun() async {
        // gemma-3-1b fails to build; gemma-3-4b succeeds. Both still produce rows.
        let runner = BakeOffRunner(factory: FakeFactory(failingModels: [.gemma3_1B]))
        let config = BakeOffConfig(models: [.gemma3_4B, .gemma3_1B], runs: 1, macID: "test-mac")
        let rows = await runner.run(config: config, clips: Self.clips())

        #expect(rows.count == 4)

        let ok = rows.filter { $0.model == "gemma-3-4b" }
        #expect(ok.count == 2)
        #expect(ok.allSatisfy { $0.error == nil })

        let failed = rows.filter { $0.model == "gemma-3-1b" }
        #expect(failed.count == 2)
        #expect(failed.allSatisfy { $0.error != nil })
        // Failed rows still carry identity + the whisper/mac context, just null metrics.
        #expect(failed.allSatisfy { $0.tokensPerSec == nil && $0.macID == "test-mac" })
    }

    @Test func madladReportsUnsupportedViaRealFactory() async {
        // The production factory has no MADLAD backend yet → error row, run survives.
        let runner = BakeOffRunner(factory: GemmaTranslatorFactory())
        let config = BakeOffConfig(models: [.madlad400_3B], runs: 1, macID: "test-mac")
        let rows = await runner.run(
            config: config,
            clips: [BakeOffClip(clipId: "es-1", sourceISO: "es", sourceText: ["hola"])]
        )
        #expect(rows.count == 1)
        #expect(rows.first?.error != nil)
    }

    // MARK: - Row encoding (locked column names)

    @Test func rowEncodesLockedSnakeCaseColumns() throws {
        let row = BakeOffRow(
            model: "gemma-3-4b", clipId: "es-1", sourceISO: "es",
            tokensPerSec: 42.0, perLineLatencyMs: 120.0, ramPeakMB: 2300.0,
            thermalState: "fair", whisperConcurrent: true, macID: "Mac15,3",
            qualityBleu: nil, qualityHuman: nil, error: nil
        )
        let json = String(data: try JSONEncoder().encode(row), encoding: .utf8) ?? ""
        for key in ["clip_id", "source_iso", "tokens_per_sec", "per_line_latency_ms",
                    "ram_peak_mb", "thermal_state", "whisper_concurrent", "mac_id",
                    "quality_bleu", "quality_human"] {
            #expect(json.contains(key), "missing locked column \(key)")
        }
    }
}

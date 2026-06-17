import Foundation
import BlablacadabraCore

// MARK: - Phase 7B (B.4) — bake-off runner (per-clip × per-model loop)
//
// The load-bearing piece: drives each model over each clip and emits one row per
// (model, clip) with the locked metric columns. It produces the numbers that feed the
// Phase C GO/NO-GO call. Quality is the half the harness CANNOT score — `quality_bleu`
// and `quality_human` ship null and get filled by hand / a native speaker (see scaffold
// § B.4). The runner is model-/network-free at the seam: it talks to a `TranslatorFactory`,
// so the loop is unit-testable offline with a fake.

/// A translation model under test. Maps to a Gemma variant where a backend exists;
/// MADLAD is in the plan but its backend isn't built yet, so the factory reports it
/// unsupported and the runner records an error row (the run keeps going — the
/// partial-failure rule).
public enum BakeOffModel: String, CaseIterable, Sendable {
    case gemma3_4B = "gemma-3-4b"
    case gemma3_1B = "gemma-3-1b"
    case madlad400_3B = "madlad-400-3b"

    /// Parse a CLI token (case-insensitive); nil when unknown.
    public init?(cliName: String) {
        self.init(rawValue: cliName.lowercased())
    }
}

/// One clip from the manifest: source-language lines to translate, plus the ground-truth
/// English used later for human/BLEU scoring (not scored here). `audio` is optional and
/// only used by the `--concurrent-with-whisper` contention path.
public struct BakeOffClip: Codable, Sendable {
    public let clipId: String
    public let sourceISO: String
    public let audio: String?
    public let sourceText: [String]
    public let expectedEnglish: [String]?

    enum CodingKeys: String, CodingKey {
        case clipId = "clip_id"
        case sourceISO = "source_iso"
        case audio
        case sourceText = "source_text"
        case expectedEnglish = "expected_english"
    }

    public init(
        clipId: String,
        sourceISO: String,
        audio: String? = nil,
        sourceText: [String],
        expectedEnglish: [String]? = nil
    ) {
        self.clipId = clipId
        self.sourceISO = sourceISO
        self.audio = audio
        self.sourceText = sourceText
        self.expectedEnglish = expectedEnglish
    }
}

/// Top-level manifest: `clips/manifest.json`.
public struct BakeOffManifest: Codable, Sendable {
    public let clips: [BakeOffClip]
    public init(clips: [BakeOffClip]) { self.clips = clips }

    /// Load + decode a manifest from disk.
    public static func load(from url: URL) throws -> BakeOffManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BakeOffManifest.self, from: data)
    }
}

/// One result row. Columns are LOCKED by the scaffold so Tier-2 results stay comparable.
/// Explicit `CodingKeys` emit the exact snake_case keys. `error` is non-nil only when a
/// (model, clip) failed; the row still ships so the JSON is complete and the failure is visible.
public struct BakeOffRow: Codable, Sendable {
    public let model: String
    public let clipId: String
    public let sourceISO: String
    public let tokensPerSec: Double?
    public let perLineLatencyMs: Double?
    public let ramPeakMB: Double?
    public let thermalState: String?
    public let whisperConcurrent: Bool
    public let macID: String
    public let qualityBleu: Double?
    public let qualityHuman: String?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case model
        case clipId = "clip_id"
        case sourceISO = "source_iso"
        case tokensPerSec = "tokens_per_sec"
        case perLineLatencyMs = "per_line_latency_ms"
        case ramPeakMB = "ram_peak_mb"
        case thermalState = "thermal_state"
        case whisperConcurrent = "whisper_concurrent"
        case macID = "mac_id"
        case qualityBleu = "quality_bleu"
        case qualityHuman = "quality_human"
        case error
    }

    public init(
        model: String, clipId: String, sourceISO: String,
        tokensPerSec: Double?, perLineLatencyMs: Double?, ramPeakMB: Double?,
        thermalState: String?, whisperConcurrent: Bool, macID: String,
        qualityBleu: Double?, qualityHuman: String?, error: String?
    ) {
        self.model = model
        self.clipId = clipId
        self.sourceISO = sourceISO
        self.tokensPerSec = tokensPerSec
        self.perLineLatencyMs = perLineLatencyMs
        self.ramPeakMB = ramPeakMB
        self.thermalState = thermalState
        self.whisperConcurrent = whisperConcurrent
        self.macID = macID
        self.qualityBleu = qualityBleu
        self.qualityHuman = qualityHuman
        self.error = error
    }

    // Explicit encode so the LOCKED columns ALWAYS appear — emitting JSON `null` for an
    // absent metric instead of dropping the key (synthesized `encodeIfPresent` would omit
    // nils, which would make a half-filled row look like it has fewer columns).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(clipId, forKey: .clipId)
        try c.encode(sourceISO, forKey: .sourceISO)
        try encodeOptional(tokensPerSec, .tokensPerSec, into: &c)
        try encodeOptional(perLineLatencyMs, .perLineLatencyMs, into: &c)
        try encodeOptional(ramPeakMB, .ramPeakMB, into: &c)
        try encodeOptional(thermalState, .thermalState, into: &c)
        try c.encode(whisperConcurrent, forKey: .whisperConcurrent)
        try c.encode(macID, forKey: .macID)
        try encodeOptional(qualityBleu, .qualityBleu, into: &c)
        try encodeOptional(qualityHuman, .qualityHuman, into: &c)
        try encodeOptional(error, .error, into: &c)
    }

    private func encodeOptional<T: Encodable>(
        _ value: T?, _ key: CodingKeys, into c: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if let value { try c.encode(value, forKey: key) } else { try c.encodeNil(forKey: key) }
    }
}

// MARK: - Translator seam

/// One translated line plus the count of tokens the decoder produced, so the runner can
/// compute tokens/sec from the real decode count. The bake-off owns this protocol (rather
/// than reusing `TextTranslating`, which intentionally returns only text) so throughput is
/// measured honestly.
public protocol BakeOffTranslator: Sendable {
    /// Load weights and warm the model. Throws → the run records error rows for this model.
    func warmUp() async throws
    /// Translate one line; returns the text and the number of output tokens generated.
    func translate(_ line: String, sourceISO: String) async throws -> (text: String, outputTokens: Int)
    func tearDown() async
}

/// Builds a translator per model. Injectable so the runner loop is testable offline with
/// a fake that needs no weights or network.
public protocol TranslatorFactory: Sendable {
    func make(_ model: BakeOffModel) async throws -> any BakeOffTranslator
}

public enum BakeOffError: LocalizedError {
    case unsupportedModel(String)
    case noClipsSelected

    public var errorDescription: String? {
        switch self {
        case .unsupportedModel(let m): return "Model backend not implemented yet: \(m)"
        case .noClipsSelected: return "No clips matched the requested languages."
        }
    }
}

// MARK: - Config + runner

public struct BakeOffConfig: Sendable {
    public var models: [BakeOffModel]
    /// Source-ISO filter (e.g. `["ar","id","es","ja"]`); nil/empty = all clips.
    public var clipISOFilter: Set<String>?
    /// Repetitions per (model, clip); results are averaged for stability.
    public var runs: Int
    public var whisperConcurrent: Bool
    public var macID: String

    public init(
        models: [BakeOffModel],
        clipISOFilter: Set<String>? = nil,
        runs: Int = 3,
        whisperConcurrent: Bool = false,
        macID: String = detectMacID()
    ) {
        self.models = models
        self.clipISOFilter = clipISOFilter
        self.runs = runs
        self.whisperConcurrent = whisperConcurrent
        self.macID = macID
    }
}

public struct BakeOffRunner {
    private let factory: TranslatorFactory

    public init(factory: TranslatorFactory) {
        self.factory = factory
    }

    /// Run every model over every selected clip. Never throws: a model that fails to
    /// build/warm, or a clip that fails to translate, produces an error row and the run
    /// continues (partial-failure rule). Returns one row per (model, selected-clip).
    public func run(
        config: BakeOffConfig,
        clips: [BakeOffClip],
        log: @Sendable (String) -> Void = { _ in }
    ) async -> [BakeOffRow] {
        let filter = config.clipISOFilter
        let selected = clips.filter { filter?.isEmpty ?? true ? true : (filter?.contains($0.sourceISO) ?? true) }

        var rows: [BakeOffRow] = []
        for model in config.models {
            // Build + warm once per model. Any failure → an error row for every selected
            // clip of this model, then on to the next model (one crash never kills the run).
            let translator: any BakeOffTranslator
            do {
                translator = try await factory.make(model)
                try await translator.warmUp()
            } catch {
                log("model \(model.rawValue) unavailable: \(error.localizedDescription)")
                for clip in selected {
                    rows.append(Self.errorRow(model: model, clip: clip, config: config, error: error))
                }
                continue
            }

            for clip in selected {
                let row = await measure(model: model, clip: clip, translator: translator, config: config)
                rows.append(row)
                if let err = row.error { log("  \(model.rawValue)/\(clip.clipId): FAILED — \(err)") }
            }
            await translator.tearDown()
        }
        return rows
    }

    /// Translate one clip's lines `runs` times, averaging latency and accumulating
    /// throughput; track peak RAM and worst thermal across all of it. A per-line throw
    /// drops the whole (model, clip) to an error row.
    private func measure(
        model: BakeOffModel,
        clip: BakeOffClip,
        translator: any BakeOffTranslator,
        config: BakeOffConfig
    ) async -> BakeOffRow {
        var ram = RAMPeakTracker()
        let thermal = ThermalSampler()
        var throughput = TokenThroughput()
        var latenciesMs: [Double] = []

        do {
            for _ in 0..<max(1, config.runs) {
                for line in clip.sourceText {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    let (_, tokens) = try await translator.translate(line, sourceISO: clip.sourceISO)
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000_000
                    latenciesMs.append(elapsed * 1000)
                    throughput.record(tokens: tokens, seconds: elapsed)
                    ram.record(currentResidentBytes())
                    thermal.sampleNow()
                }
            }
        } catch {
            return Self.errorRow(model: model, clip: clip, config: config, error: error)
        }

        let avgLatency = latenciesMs.isEmpty ? nil : latenciesMs.reduce(0, +) / Double(latenciesMs.count)
        return BakeOffRow(
            model: model.rawValue,
            clipId: clip.clipId,
            sourceISO: clip.sourceISO,
            tokensPerSec: throughput.tokensPerSec,
            perLineLatencyMs: avgLatency,
            ramPeakMB: ram.peakMB,
            thermalState: ThermalSampler.label(thermal.worst),
            whisperConcurrent: config.whisperConcurrent,
            macID: config.macID,
            qualityBleu: nil,
            qualityHuman: nil,
            error: nil
        )
    }

    private static func errorRow(
        model: BakeOffModel,
        clip: BakeOffClip,
        config: BakeOffConfig,
        error: Error
    ) -> BakeOffRow {
        BakeOffRow(
            model: model.rawValue,
            clipId: clip.clipId,
            sourceISO: clip.sourceISO,
            tokensPerSec: nil,
            perLineLatencyMs: nil,
            ramPeakMB: nil,
            thermalState: nil,
            whisperConcurrent: config.whisperConcurrent,
            macID: config.macID,
            qualityBleu: nil,
            qualityHuman: nil,
            error: error.localizedDescription
        )
    }
}

/// `hw.model` + the CPU brand string, e.g. `Mac15,3 (Apple M4)`. Used for the `mac_id`
/// column so rows from different Macs stay comparable. Best-effort; never traps.
public func detectMacID() -> String {
    func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
    let model = sysctlString("hw.model") ?? "unknown-mac"
    if let chip = sysctlString("machdep.cpu.brand_string") {
        return "\(model) (\(chip))"
    }
    return model
}

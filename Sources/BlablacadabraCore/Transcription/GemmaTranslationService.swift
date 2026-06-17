import Foundation
import MLX
import MLXNN
import Tokenizers

// MARK: - Phase 7B (B.2) — Gemma on-device translation backend
//
// `GemmaTranslationService` is a `TextTranslating` conformer that runs a Gemma 3
// decoder (see GemmaModel.swift) on core mlx-swift to translate one finalized line
// to the target language. It slots into the SAME seam Apple's service uses, so the
// `TranslatingPipeline` can't tell them apart — that interchangeability is the whole
// point of Phase A and the thing B.2's tests prove.
//
// ⚠️ OFF THE LIVE PATH. Nothing in the app constructs this yet. It exists so the
// B.4 bake-off harness can drive it on real clips and produce the GO/NO-GO numbers.
// Weight DOWNLOAD is B.3's job (`LLMWeightStore`); until then only `.localPath`
// weights start, and `.autoDownload` throws a clear "not yet" so the pipeline falls
// back cleanly (same contract as a missing Apple pack).
//
// ⚠️ The model's translation QUALITY is unproven here (see the validation note atop
// GemmaModel.swift). These offline tests prove the actor's CONTRACT, not its output.

/// On-device LLM text translation via a Gemma 3 decoder on mlx-swift. One source
/// line in, one target-language line out. Single source/target pair per instance,
/// matching `AppleTranslationService` (the `TranslationRouter` is what dispatches by
/// language when several are in play).
public actor GemmaTranslationService: TextTranslating {

    /// Which Gemma checkpoint to run. `repoId` is the Hugging Face repo the B.3
    /// weights store will fetch from; `folderName` is the on-disk cache subdir.
    public enum ModelVariant: String, Sendable, CaseIterable {
        /// Tier-1 latency candidate (decoder-only, first-class mlx-swift support).
        case gemma3_4B
        /// Small-machine fallback (Phase C step 13). Same architecture, fewer layers.
        case gemma3_1B

        public var repoId: String {
            switch self {
            case .gemma3_4B: return "mlx-community/gemma-3-4b-it-4bit"
            case .gemma3_1B: return "mlx-community/gemma-3-1b-it-4bit"
            }
        }

        public var folderName: String {
            switch self {
            case .gemma3_4B: return "gemma-3-4b-it-4bit"
            case .gemma3_1B: return "gemma-3-1b-it-4bit"
            }
        }
    }

    /// Where the weights come from. `.autoDownload` is wired to the B.3 store (not
    /// built yet → `start()` throws). `.localPath` points at a folder that already
    /// holds `config.json`, the tokenizer files, and the `*.safetensors` shards.
    public enum ModelWeightsSource: Sendable {
        case autoDownload
        case localPath(URL)
    }

    private let targetLanguage: String
    private let variant: ModelVariant
    private let weights: ModelWeightsSource

    /// Caps generated tokens per line: translations are short, and an unbounded
    /// loop on a hallucinating model is the accessibility-critical failure mode
    /// (Phase C guardrail, enforced here too). A line that blows the cap returns nil.
    private let maxNewTokens = 256

    // Loaded on `start()`, torn down on `stop()`. Nil before start / after stop, so
    // `translate` returns nil (the line is skipped) rather than crashing.
    private var model: GemmaModel?
    private var tokenizer: Tokenizer?
    private var endOfTurnTokenId: Int?

    public init(
        targetLanguage: String = "en",
        modelVariant: ModelVariant = .gemma3_4B,
        weights: ModelWeightsSource
    ) {
        self.targetLanguage = targetLanguage
        self.variant = modelVariant
        self.weights = weights
    }

    // MARK: - TextTranslating

    /// Resolve the weights folder, then load config + tokenizer + safetensors and
    /// build the decoder. Throws BEFORE any audio is captured so the pipeline falls
    /// back to Apple/Whisper on any failure (missing weights, bad config, B.3-not-
    /// ready for `.autoDownload`, or unsupported hardware).
    public func start() async throws {
        let folder = try resolveWeightsFolder()

        // config.json — architecture constants travel with the weights.
        let configURL = folder.appending(path: "config.json")
        guard let configData = try? Data(contentsOf: configURL) else {
            throw GemmaTranslationError.weightsUnavailable
        }
        let config = try GemmaConfiguration.decode(from: configData)

        // Tokenizer (tokenizer.json + tokenizer_config.json in the same folder).
        let tokenizer = try await AutoTokenizer.from(modelFolder: folder)

        // Weights: merge every safetensors shard in the folder.
        let shardURLs = try FileManager.default
            .contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
        guard !shardURLs.isEmpty else { throw GemmaTranslationError.weightsUnavailable }

        var weightTensors: [String: MLXArray] = [:]
        for url in shardURLs {
            for (key, value) in try loadArrays(url: url) {
                weightTensors[key] = value
            }
        }

        let model = GemmaModel(config)
        // Pre-quantized checkpoints (INT4/INT8) carry a `quantization` block; swap in
        // QuantizedLinear/QuantizedEmbedding BEFORE loading so the param shapes line
        // up with the stored scales/biases. fp16 weights skip this (and the plan bans
        // running MADLAD in fp16 specifically, not Gemma — Gemma bf16 is fine).
        if let q = config.quantization {
            quantize(model: model, groupSize: q.groupSize, bits: q.bits)
        }
        model.update(parameters: ModuleParameters.unflattened(weightTensors))
        eval(model)

        self.model = model
        self.tokenizer = tokenizer
        self.endOfTurnTokenId = tokenizer.convertTokenToId("<end_of_turn>")
    }

    /// Translate one line. Returns nil on empty input, an unservable source language,
    /// before `start()` / after `stop()`, or any per-line failure — the caller skips
    /// the line or uses its carried fallback. Never throws into the live loop.
    public func translate(_ text: String, from sourceISO: String? = nil) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Unservable source -> nil, mirroring AppleTranslationService. A non-nil code
        // we don't recognize never reaches the model (deterministic, model-free).
        if let sourceISO, SpokenLanguage.displayName(forCode: sourceISO) == nil {
            return nil
        }

        guard let model, let tokenizer else { return nil }

        let promptTokens = encodePrompt(trimmed, sourceISO: sourceISO, tokenizer: tokenizer)
        guard !promptTokens.isEmpty else { return nil }

        let output = generate(promptTokens: promptTokens, model: model, tokenizer: tokenizer)
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Guardrail: empty or runaway output is worse than skipping the line.
        guard !cleaned.isEmpty, cleaned.count <= max(64, trimmed.count * 12) else { return nil }
        return cleaned
    }

    public func stop() {
        model = nil
        tokenizer = nil
        endOfTurnTokenId = nil
    }

    // MARK: - Weights

    private func resolveWeightsFolder() throws -> URL {
        switch weights {
        case .localPath(let url):
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                throw GemmaTranslationError.weightsUnavailable
            }
            return url
        case .autoDownload:
            // B.3 (LLMWeightStore) owns the download. Until it lands, auto-download
            // is unavailable and we fall back rather than block on a missing model.
            throw GemmaTranslationError.autoDownloadNotImplemented
        }
    }

    // MARK: - Prompting

    /// Build the Gemma instruction prompt as token ids. We assemble the turn markers
    /// by hand (rather than the Jinja chat template) so the prompt is explicit and
    /// stable for the bake-off; `<start_of_turn>` / `<end_of_turn>` are added tokens
    /// the tokenizer maps to their ids when they appear in the encoded text.
    private func encodePrompt(_ text: String, sourceISO: String?, tokenizer: Tokenizer) -> [Int] {
        let sourceName = sourceISO.flatMap { SpokenLanguage.displayName(forCode: $0) }
        let targetName = SpokenLanguage.displayName(forCode: targetLanguage) ?? targetLanguage
        let from = sourceName.map { "from \($0) " } ?? ""
        let instruction =
            "Translate the following text \(from)to \(targetName). " +
            "Output only the translation, with no preamble, notes, or quotation marks.\n\n" + text
        let prompt = "<start_of_turn>user\n\(instruction)<end_of_turn>\n<start_of_turn>model\n"
        return tokenizer.encode(text: prompt)
    }

    // MARK: - Greedy decode

    /// Deterministic greedy generation: prefill the prompt, then take argmax tokens
    /// one at a time through the KV cache until `<end_of_turn>`/EOS or the token cap.
    /// Greedy (no sampling) keeps the bake-off reproducible.
    private func generate(promptTokens: [Int], model: GemmaModel, tokenizer: Tokenizer) -> String {
        let caches = model.makeCaches()

        // Prefill the whole prompt in one pass.
        var logits = model(MLXArray(promptTokens).reshaped(1, promptTokens.count), caches: caches)
        var next = lastTokenArgmax(logits)

        var generated: [Int] = []
        let stopIds: Set<Int> = Set([endOfTurnTokenId, tokenizer.eosTokenId].compactMap { $0 })

        for _ in 0..<maxNewTokens {
            if stopIds.contains(next) { break }
            generated.append(next)
            logits = model(MLXArray([next]).reshaped(1, 1), caches: caches)
            next = lastTokenArgmax(logits)
        }

        return tokenizer.decode(tokens: generated, skipSpecialTokens: true)
    }

    /// Argmax over the vocabulary of the LAST position's logits -> a token id.
    private func lastTokenArgmax(_ logits: MLXArray) -> Int {
        let last = logits[0, -1]               // [vocab]
        let id = last.argMax(axis: -1)
        eval(id)
        return id.item(Int.self)
    }
}

/// Failures `GemmaTranslationService.start()` can throw. All route to the same
/// place: the pipeline falls back to Apple/Whisper before any audio is captured.
public enum GemmaTranslationError: LocalizedError, Equatable {
    /// Weights folder missing, empty, or lacking config/safetensors.
    case weightsUnavailable
    /// `.autoDownload` requested before the B.3 weights store exists.
    case autoDownloadNotImplemented

    public var errorDescription: String? {
        switch self {
        case .weightsUnavailable:
            return "Gemma translation weights are unavailable; falling back."
        case .autoDownloadNotImplemented:
            return "Gemma auto-download isn't available yet; falling back."
        }
    }
}

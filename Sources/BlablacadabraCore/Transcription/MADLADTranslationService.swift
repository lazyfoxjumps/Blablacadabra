import Foundation
import MLX
import MLXNN
import Tokenizers

// MARK: - Phase 7B (B.5) — MADLAD-400 on-device translation backend
//
// `MADLADTranslationService` is the SECOND `TextTranslating` conformer (alongside Gemma),
// running the MADLAD-400 3B T5 encoder-decoder (see MADLADModel.swift) so the B.4 bake-off
// is the real Gemma-vs-MADLAD shootout the plan locked. It slots into the SAME seam as
// Apple's and Gemma's services, so the pipeline can't tell them apart.
//
// ⚠️ OFF THE LIVE PATH and translation QUALITY UNVALIDATED (see MADLADModel.swift). These
// offline tests prove the actor's CONTRACT, not its output. Weight download is the B.3
// store's job; the bake-off resolves a folder there and hands it in via `.localPath`.

/// On-device LLM text translation via the MADLAD-400 T5 model. One source line in, one
/// target-language line out. MADLAD is natively multilingual MT: the target is selected by
/// the `<2xx>` tag prepended to the encoder input, so a single instance can target any
/// language (we default to English for the captioning use case).
public actor MADLADTranslationService: TextTranslating {

    /// Which MADLAD checkpoint to run. Conforms to `LLMWeightVariant` so the B.3 store can
    /// fetch it just like a Gemma variant.
    public enum ModelVariant: String, Sendable, CaseIterable, LLMWeightVariant {
        /// Tier-1 quality candidate. The base HF checkpoint is fp32; for the bake-off point
        /// this at an INT4/INT8 mlx conversion (the plan bans running MADLAD in fp16).
        case madlad3B

        public var repoId: String {
            switch self {
            case .madlad3B: return "jbochi/madlad400-3b-mt"
            }
        }

        public var folderName: String {
            switch self {
            case .madlad3B: return "madlad400-3b-mt"
            }
        }
    }

    /// Where the weights come from, mirroring `GemmaTranslationService`. `.autoDownload` is
    /// reserved for Phase C live wiring (throws for now); the bake-off uses `.localPath`.
    public enum ModelWeightsSource: Sendable {
        case autoDownload
        case localPath(URL)
    }

    private let targetLanguage: String
    private let variant: ModelVariant
    private let weights: ModelWeightsSource
    private let maxNewTokens = 256

    private var model: MADLADModel?
    private var tokenizer: Tokenizer?
    private var eosTokenId: Int?
    private var decoderStartTokenId: Int?
    private var underscoreTokenId: Int?

    public init(
        targetLanguage: String = "en",
        modelVariant: ModelVariant = .madlad3B,
        weights: ModelWeightsSource
    ) {
        self.targetLanguage = targetLanguage
        self.variant = modelVariant
        self.weights = weights
    }

    // MARK: - TextTranslating

    public func start() async throws {
        let folder = try resolveWeightsFolder()

        let configURL = folder.appending(path: "config.json")
        guard let configData = try? Data(contentsOf: configURL) else {
            throw MADLADTranslationError.weightsUnavailable
        }
        let config = try MADLADConfiguration.decode(from: configData)

        let tokenizer = try await AutoTokenizer.from(modelFolder: folder)

        let shardURLs = try FileManager.default
            .contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
        guard !shardURLs.isEmpty else { throw MADLADTranslationError.weightsUnavailable }

        var weightTensors: [String: MLXArray] = [:]
        for url in shardURLs {
            for (key, value) in try loadArrays(url: url) {
                // `encoder.embed_tokens` / `decoder.embed_tokens` are duplicates of `shared`
                // in the HF checkpoint; our model has only `shared`, so drop the dupes.
                if key.hasPrefix("encoder.embed_tokens") || key.hasPrefix("decoder.embed_tokens") { continue }
                weightTensors[key] = value
            }
        }

        let model = MADLADModel(config)
        if let q = config.quantization {
            // Pre-quantized checkpoint: swap Linear/Embedding for quantized BEFORE loading so
            // param shapes match the stored scales/biases. The relative_attention_bias table
            // (tiny, head-dim < group size) is never quantized in the checkpoint, so skip it.
            quantize(model: model, groupSize: q.groupSize, bits: q.bits) { path, module in
                guard module is Linear || module is Embedding else { return false }
                return !path.contains("relative_attention_bias")
            }
        }
        model.update(parameters: ModuleParameters.unflattened(weightTensors))
        eval(model)

        self.model = model
        self.tokenizer = tokenizer
        self.eosTokenId = config.eosTokenId
        self.decoderStartTokenId = config.decoderStartTokenId
        self.underscoreTokenId = tokenizer.convertTokenToId("\u{2581}")  // ▁
    }

    public func translate(_ text: String, from sourceISO: String? = nil) async -> String? {
        await translateMeasured(text, from: sourceISO)?.text
    }

    /// Bake-off variant reporting the decoder's generated-token count for accurate tokens/sec.
    /// OFF the live path. Same guardrails as `translate`.
    public func translateMeasured(
        _ text: String,
        from sourceISO: String? = nil
    ) async -> (text: String, outputTokens: Int)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Unservable source -> nil, mirroring the other backends. MADLAD's source language is
        // auto-detected by the model, so a recognized (or nil) code is all we gate on.
        if let sourceISO, SpokenLanguage.displayName(forCode: sourceISO) == nil {
            return nil
        }
        guard let model, let tokenizer, let eos = eosTokenId, let start = decoderStartTokenId else {
            return nil
        }

        let promptTokens = encodePrompt(trimmed, tokenizer: tokenizer, eos: eos)
        guard !promptTokens.isEmpty else { return nil }

        let (output, tokenCount) = generate(
            promptTokens: promptTokens, model: model, tokenizer: tokenizer,
            decoderStart: start, eos: eos
        )
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= max(64, trimmed.count * 12) else { return nil }
        return (cleaned, tokenCount)
    }

    public func stop() {
        model = nil
        tokenizer = nil
        eosTokenId = nil
        decoderStartTokenId = nil
        underscoreTokenId = nil
    }

    // MARK: - Weights

    private func resolveWeightsFolder() throws -> URL {
        switch weights {
        case .localPath(let url):
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                throw MADLADTranslationError.weightsUnavailable
            }
            return url
        case .autoDownload:
            // Live auto-download wiring is Phase C; the bake-off resolves the folder via the
            // B.3 store and constructs us with `.localPath`.
            throw MADLADTranslationError.autoDownloadNotImplemented
        }
    }

    // MARK: - Prompting

    /// MADLAD encoder input: `[▁, <2{target}>, ...source tokens..., </s>]`. The target is the
    /// `<2xx>` tag (NOT a chat turn); the leading ▁ is the format MADLAD was trained to expect
    /// (omitting it degrades output). Source-text EOS, if the tokenizer adds one, is stripped
    /// so only the final `</s>` terminates the encoder input.
    private func encodePrompt(_ text: String, tokenizer: Tokenizer, eos: Int) -> [Int] {
        var source = tokenizer.encode(text: text)
        if let tEos = tokenizer.eosTokenId, source.last == tEos { source.removeLast() }

        let langId = tokenizer.convertTokenToId("<2\(targetLanguage)>")
        var ids: [Int] = []
        if let u = underscoreTokenId { ids.append(u) }
        if let l = langId { ids.append(l) }
        ids += source
        ids.append(eos)
        return ids
    }

    // MARK: - Greedy encode-decode

    /// Encode the source once, then greedily decode the target one token at a time through the
    /// decoder's self/cross KV caches until `</s>` or the token cap. Greedy keeps the bake-off
    /// reproducible. Returns the decoded text and the generated-token count.
    private func generate(
        promptTokens: [Int],
        model: MADLADModel,
        tokenizer: Tokenizer,
        decoderStart: Int,
        eos: Int
    ) -> (text: String, tokenCount: Int) {
        let encoderOutput = model.encode(MLXArray(promptTokens).reshaped(1, promptTokens.count))
        eval(encoderOutput)

        var caches = model.makeDecoderCaches()
        var nextInput = decoderStart
        var generated: [Int] = []

        for _ in 0..<maxNewTokens {
            let logits = model.decodeStep(
                MLXArray([nextInput]).reshaped(1, 1), encoderOutput: encoderOutput, caches: &caches
            )
            let tok = lastTokenArgmax(logits)
            if tok == eos { break }
            generated.append(tok)
            nextInput = tok
        }

        return (tokenizer.decode(tokens: generated, skipSpecialTokens: true), generated.count)
    }

    private func lastTokenArgmax(_ logits: MLXArray) -> Int {
        let last = logits[0, -1]
        let id = last.argMax(axis: -1)
        eval(id)
        return id.item(Int.self)
    }
}

/// Failures `MADLADTranslationService.start()` can throw. All route to the same place: the
/// pipeline falls back to another backend before any audio is captured.
public enum MADLADTranslationError: LocalizedError, Equatable {
    case weightsUnavailable
    case autoDownloadNotImplemented

    public var errorDescription: String? {
        switch self {
        case .weightsUnavailable:
            return "MADLAD translation weights are unavailable; falling back."
        case .autoDownloadNotImplemented:
            return "MADLAD auto-download isn't available yet; falling back."
        }
    }
}

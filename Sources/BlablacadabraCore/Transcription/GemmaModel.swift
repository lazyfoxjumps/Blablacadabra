import Foundation
import MLX
import MLXNN

// MARK: - Phase 7B (B.2) — Gemma 3 text decoder on CORE mlx-swift
//
// This is the "build the model layer ourselves" half of B.2 (see
// Design/Item7-PhaseB-Scaffold.md). We deliberately do NOT depend on the
// mlx-swift-examples model zoo: its swift-transformers pin conflicts with
// WhisperKit's (B.1 gotcha). So the Gemma 3 architecture is reconstructed here
// from the published config on top of the core MLX/MLXNN primitives that are in
// the graph (Linear, Embedding, RoPE, RMS norm, scaled dot-product attention).
//
// ⚠️ VALIDATION STATUS: the forward pass is implemented from the documented
// Gemma 3 architecture but is UNVALIDATED end-to-end. It cannot be proven correct
// without the real ~2.5GB weights running on Apple silicon — that is precisely
// what B.3 (weights store) and B.4 (bake-off on the user's hardware) are for. The
// offline unit tests around `GemmaTranslationService` prove the SEAM and the
// CONTRACT (start/translate/stop, nil handling), NOT that this network emits
// faithful translations. Treat every architectural constant below as
// "believed correct, pending bake-off." This whole file is OFF the live caption
// path until Phase 7C.

/// Subset of a Gemma 3 `config.json` we need to build the text decoder. Decoded
/// straight from the HF checkpoint so the architecture constants live with the
/// weights, not hardcoded here (different variants — 1B/4B — differ on these).
struct GemmaConfiguration: Codable {
    let hiddenSize: Int
    let intermediateSize: Int
    let numHiddenLayers: Int
    let numAttentionHeads: Int
    let numKeyValueHeads: Int
    let headDim: Int
    let vocabSize: Int
    let rmsNormEps: Float
    /// Angular base for the GLOBAL (full-attention) layers (Gemma 3: 1e6).
    let ropeTheta: Float
    /// Angular base for the LOCAL (sliding-window) layers (Gemma 3: 1e4).
    let ropeLocalBaseFreq: Float
    /// Every `slidingWindowPattern`-th layer is a global layer; the rest are local.
    let slidingWindowPattern: Int
    /// Denominator under the attention scale (Gemma 3 4B: 256). Falls back to
    /// `headDim` when absent.
    let queryPreAttnScalar: Float?
    /// tanh soft-cap on the final logits; nil/absent on most Gemma 3 configs.
    let finalLogitSoftcapping: Float?
    /// Present only on pre-quantized checkpoints (INT4/INT8). Drives the
    /// QuantizedLinear/QuantizedEmbedding swap before weights are loaded.
    let quantization: Quantization?

    struct Quantization: Codable {
        let groupSize: Int
        let bits: Int
        enum CodingKeys: String, CodingKey {
            case groupSize = "group_size"
            case bits
        }
    }

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size"
        case intermediateSize = "intermediate_size"
        case numHiddenLayers = "num_hidden_layers"
        case numAttentionHeads = "num_attention_heads"
        case numKeyValueHeads = "num_key_value_heads"
        case headDim = "head_dim"
        case vocabSize = "vocab_size"
        case rmsNormEps = "rms_norm_eps"
        case ropeTheta = "rope_theta"
        case ropeLocalBaseFreq = "rope_local_base_freq"
        case slidingWindowPattern = "sliding_window_pattern"
        case queryPreAttnScalar = "query_pre_attn_scalar"
        case finalLogitSoftcapping = "final_logit_softcapping"
        case quantization
    }

    /// `text_config` wrapper: Gemma 3 multimodal checkpoints nest the language
    /// model under `text_config`; text-only checkpoints put it at the root. Try the
    /// nested form first, fall back to the root.
    static func decode(from data: Data) throws -> GemmaConfiguration {
        let decoder = JSONDecoder()
        struct Wrapper: Codable { let textConfig: GemmaConfiguration?
            enum CodingKeys: String, CodingKey { case textConfig = "text_config" } }
        if let nested = try? decoder.decode(Wrapper.self, from: data), let cfg = nested.textConfig {
            return cfg
        }
        return try decoder.decode(GemmaConfiguration.self, from: data)
    }
}

/// Gemma's RMS norm: normalize, then scale by `(1 + weight)` (the "+1" is the
/// Gemma-specific zero-centered weight). We reuse MLX's fused `rmsNorm` kernel and
/// just feed it `1 + weight`, which is numerically identical and keeps the fast path.
final class GemmaRMSNorm: Module, UnaryLayer {
    let eps: Float
    @ParameterInfo(key: "weight") var weight: MLXArray

    init(dimensions: Int, eps: Float) {
        self.eps = eps
        self._weight.wrappedValue = MLXArray.ones([dimensions])
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLX.rmsNorm(x, weight: 1.0 + weight, eps: eps)
    }
}

/// One transformer block's grouped-query attention with Gemma 3's per-head Q/K
/// RMS norm and a per-layer RoPE base (local vs global).
private final class GemmaAttention: Module {
    let numHeads: Int
    let numKVHeads: Int
    let headDim: Int
    let scale: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: GemmaRMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: GemmaRMSNorm

    let rope: RoPE

    init(_ config: GemmaConfiguration, rope: RoPE) {
        self.numHeads = config.numAttentionHeads
        self.numKVHeads = config.numKeyValueHeads
        self.headDim = config.headDim
        let denom = config.queryPreAttnScalar ?? Float(config.headDim)
        self.scale = 1.0 / denom.squareRoot()
        self.rope = rope

        self._qProj.wrappedValue = Linear(config.hiddenSize, numHeads * headDim, bias: false)
        self._kProj.wrappedValue = Linear(config.hiddenSize, numKVHeads * headDim, bias: false)
        self._vProj.wrappedValue = Linear(config.hiddenSize, numKVHeads * headDim, bias: false)
        self._oProj.wrappedValue = Linear(numHeads * headDim, config.hiddenSize, bias: false)
        self._qNorm.wrappedValue = GemmaRMSNorm(dimensions: headDim, eps: config.rmsNormEps)
        self._kNorm.wrappedValue = GemmaRMSNorm(dimensions: headDim, eps: config.rmsNormEps)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray?, cache: KVCache) -> MLXArray {
        let B = x.dim(0)
        let L = x.dim(1)

        // [B, L, H*D] -> [B, H, L, D]
        var q = qProj(x).reshaped(B, L, numHeads, headDim).transposed(0, 2, 1, 3)
        var k = kProj(x).reshaped(B, L, numKVHeads, headDim).transposed(0, 2, 1, 3)
        var v = vProj(x).reshaped(B, L, numKVHeads, headDim).transposed(0, 2, 1, 3)

        // Gemma 3 applies RMS norm to Q and K (over the head dim) BEFORE RoPE.
        q = qNorm(q)
        k = kNorm(k)

        let offset = cache.offset
        q = rope(q, offset: offset)
        k = rope(k, offset: offset)

        // Append to the running KV cache; attend over the whole history.
        (k, v) = cache.update(keys: k, values: v)

        let out = MLX.scaledDotProductAttention(
            queries: q, keys: k, values: v, scale: scale, mask: mask
        )
        .transposed(0, 2, 1, 3)
        .reshaped(B, L, -1)

        return oProj(out)
    }
}

/// Gated GeGLU feed-forward (gate/up/down) with Gemma's `gelu` (tanh approx not
/// required — exact gelu matches the reference).
private final class GemmaMLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear

    init(_ config: GemmaConfiguration) {
        self._gateProj.wrappedValue = Linear(config.hiddenSize, config.intermediateSize, bias: false)
        self._upProj.wrappedValue = Linear(config.hiddenSize, config.intermediateSize, bias: false)
        self._downProj.wrappedValue = Linear(config.intermediateSize, config.hiddenSize, bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(geluApproximate(gateProj(x)) * upProj(x))
    }
}

/// One decoder layer: pre/post norms around attention and around the MLP, the
/// Gemma 2/3 "sandwich" arrangement (norm both before AND after each sub-block).
private final class GemmaDecoderLayer: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: GemmaAttention
    @ModuleInfo(key: "mlp") var mlp: GemmaMLP
    @ModuleInfo(key: "input_layernorm") var inputLayernorm: GemmaRMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayernorm: GemmaRMSNorm
    @ModuleInfo(key: "pre_feedforward_layernorm") var preFeedforwardLayernorm: GemmaRMSNorm
    @ModuleInfo(key: "post_feedforward_layernorm") var postFeedforwardLayernorm: GemmaRMSNorm

    init(_ config: GemmaConfiguration, rope: RoPE) {
        self._selfAttn.wrappedValue = GemmaAttention(config, rope: rope)
        self._mlp.wrappedValue = GemmaMLP(config)
        self._inputLayernorm.wrappedValue = GemmaRMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._postAttentionLayernorm.wrappedValue = GemmaRMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._preFeedforwardLayernorm.wrappedValue = GemmaRMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._postFeedforwardLayernorm.wrappedValue = GemmaRMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray?, cache: KVCache) -> MLXArray {
        let h = x + postAttentionLayernorm(selfAttn(inputLayernorm(x), mask: mask, cache: cache))
        return h + postFeedforwardLayernorm(mlp(preFeedforwardLayernorm(h)))
    }
}

/// The language-model stack (embeddings + layers + final norm), keyed under
/// `model.` to match the HF checkpoint's parameter names.
private final class GemmaLanguageModel: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    fileprivate let layers: [GemmaDecoderLayer]
    @ModuleInfo(key: "norm") var norm: GemmaRMSNorm

    let embedScale: Float
    let globalRope: RoPE
    let localRope: RoPE
    let slidingWindowPattern: Int

    init(_ config: GemmaConfiguration) {
        self._embedTokens.wrappedValue = Embedding(
            embeddingCount: config.vocabSize, dimensions: config.hiddenSize
        )
        // Gemma scales embeddings by sqrt(hidden_size).
        self.embedScale = Float(config.hiddenSize).squareRoot()

        self.globalRope = RoPE(dimensions: config.headDim, traditional: false, base: config.ropeTheta)
        self.localRope = RoPE(dimensions: config.headDim, traditional: false, base: config.ropeLocalBaseFreq)
        self.slidingWindowPattern = config.slidingWindowPattern

        // Global layer cadence: every `pattern`-th layer (1-indexed) is global.
        let globalRope = self.globalRope
        let localRope = self.localRope
        let pattern = config.slidingWindowPattern
        self.layers = (0..<config.numHiddenLayers).map { i in
            let isGlobal = (i + 1) % pattern == 0
            return GemmaDecoderLayer(config, rope: isGlobal ? globalRope : localRope)
        }

        self._norm.wrappedValue = GemmaRMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        super.init()
    }

    func callAsFunction(_ inputs: MLXArray, caches: [KVCache]) -> MLXArray {
        var h = embedTokens(inputs)
        h = h * MLXArray(embedScale).asType(h.dtype)

        let L = inputs.dim(1)
        // Causal mask only when processing more than one token at once (the prefill).
        // Single-token decode steps attend over the full cache with no mask. Sliding
        // window is a no-op for the short lines this backend translates (< window),
        // so one causal mask is correct here; a true sliding mask is a B.4 perf item.
        let mask: MLXArray? = L > 1 ? Self.causalMask(L, dtype: h.dtype) : nil

        for (layer, cache) in zip(layers, caches) {
            h = layer(h, mask: mask, cache: cache)
        }
        return norm(h)
    }

    /// Additive causal mask of shape [L, L]: 0 on/below the diagonal, -1e9 above.
    private static func causalMask(_ L: Int, dtype: DType) -> MLXArray {
        let lower = MLX.tril(MLX.ones([L, L]))         // 1 on/below diagonal, 0 above
        let mask = (lower - 1.0) * Float(1e9)          // 0 on/below, -1e9 above
        return mask.asType(dtype)
    }
}

/// Top-level Gemma 3 model: the `model` stack plus the tied LM head and optional
/// final logit soft-cap. This is the object `GemmaTranslationService` drives.
final class GemmaModel: Module {
    @ModuleInfo(key: "model") fileprivate var model: GemmaLanguageModel
    let config: GemmaConfiguration

    init(_ config: GemmaConfiguration) {
        self.config = config
        self._model.wrappedValue = GemmaLanguageModel(config)
        super.init()
    }

    var numLayers: Int { config.numHiddenLayers }

    /// Fresh per-layer KV caches for one decode session.
    func makeCaches() -> [KVCache] {
        (0..<config.numHiddenLayers).map { _ in KVCache() }
    }

    /// Logits for the given token ids `[B, L]`, advancing the supplied caches.
    func callAsFunction(_ inputs: MLXArray, caches: [KVCache]) -> MLXArray {
        let h = model(inputs, caches: caches)
        // Tied embeddings: project hidden states back through the embedding matrix.
        var logits = model.embedTokens.asLinear(h)
        if let cap = config.finalLogitSoftcapping, cap > 0 {
            logits = MLX.tanh(logits / cap) * cap
        }
        return logits
    }
}

/// A minimal append-only key/value cache for one attention layer. Concatenates on
/// the sequence axis; `offset` is the number of tokens already cached (the RoPE
/// position for the next chunk). No fixed-size ring buffer — translation lines are
/// short, so the simple version is correct and the memory is bounded by the line.
final class KVCache {
    private var keys: MLXArray?
    private var values: MLXArray?
    private(set) var offset = 0

    func update(keys newKeys: MLXArray, values newValues: MLXArray) -> (MLXArray, MLXArray) {
        if let k = keys, let v = values {
            keys = MLX.concatenated([k, newKeys], axis: 2)
            values = MLX.concatenated([v, newValues], axis: 2)
        } else {
            keys = newKeys
            values = newValues
        }
        offset += newKeys.dim(2)
        return (keys!, values!)
    }
}

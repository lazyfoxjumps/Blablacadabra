import Foundation
import MLX
import MLXNN

// MARK: - Phase 7B (B.5) — MADLAD-400 T5 v1.1 encoder-decoder on CORE mlx-swift
//
// MADLAD-400 3B is the SECOND contender in the translation bake-off (the plan locked a
// two-tier Gemma-vs-MADLAD shootout; B.2 only built Gemma, so this is the missing half).
// It is a T5 v1.1 encoder-decoder MT model, architecturally very different from Gemma's
// decoder-only stack: relative-position-bias attention (no RoPE), an encoder read in one
// bidirectional pass, a decoder with self- AND cross-attention, gated-GeLU FFN, T5's
// simplified RMS LayerNorm, and NO 1/sqrt(d) attention scaling.
//
// Reconstructed from the published T5 v1.1 / MADLAD architecture on top of core MLX/MLXNN,
// cross-checked against the soniqo/speech-swift MADLAD port. We deliberately build with
// plain Linear/Embedding and apply `quantize()` conditionally (matching GemmaModel), so the
// same code path loads fp or pre-quantized (INT4/INT8) checkpoints.
//
// ⚠️ VALIDATION STATUS: like GemmaModel, this forward pass is UNVALIDATED end-to-end. It
// cannot be proven correct without the real weights running on Apple silicon — that is what
// the B.4 bake-off is for. The offline tests prove the SEAM/CONTRACT and the relative-bucket
// math, NOT that this network emits faithful translations. OFF the live caption path.

/// Subset of a MADLAD/T5 `config.json` we need to build the model. Field names mirror the
/// HF T5 config so the constants travel with the weights.
struct MADLADConfiguration: Codable {
    let dModel: Int
    let dFf: Int
    let dKv: Int
    let numHeads: Int
    let numLayers: Int
    let numDecoderLayers: Int
    let vocabSize: Int
    let relativeAttentionNumBuckets: Int
    let relativeAttentionMaxDistance: Int
    let layerNormEpsilon: Float
    let decoderStartTokenId: Int
    let eosTokenId: Int
    let padTokenId: Int
    /// Present only on pre-quantized checkpoints; drives the Linear/Embedding → quantized swap.
    let quantization: GemmaConfiguration.Quantization?

    enum CodingKeys: String, CodingKey {
        case dModel = "d_model"
        case dFf = "d_ff"
        case dKv = "d_kv"
        case numHeads = "num_heads"
        case numLayers = "num_layers"
        case numDecoderLayers = "num_decoder_layers"
        case vocabSize = "vocab_size"
        case relativeAttentionNumBuckets = "relative_attention_num_buckets"
        case relativeAttentionMaxDistance = "relative_attention_max_distance"
        case layerNormEpsilon = "layer_norm_epsilon"
        case decoderStartTokenId = "decoder_start_token_id"
        case eosTokenId = "eos_token_id"
        case padTokenId = "pad_token_id"
        case quantization
    }

    static func decode(from data: Data) throws -> MADLADConfiguration {
        try JSONDecoder().decode(MADLADConfiguration.self, from: data)
    }
}

/// T5's relative-position bucketing — the model's only source of position information.
/// Pure integer math, unit-tested directly (this is the easiest part to get subtly wrong).
/// Maps a relative position `k - q` into `[0, numBuckets)`: half the buckets cover small
/// exact distances, the rest are log-spaced out to `maxDistance`. Bidirectional (encoder)
/// splits the budget across past/future; unidirectional (decoder) only sees the past.
enum T5RelativeBucket {
    static func bucket(relative: Int, bidirectional: Bool, numBuckets: Int, maxDistance: Int) -> Int {
        var result = 0
        var n = numBuckets
        var rel = relative
        if bidirectional {
            n /= 2
            if rel > 0 { result += n }
            rel = abs(rel)
        } else {
            // Only the past contributes: clamp future offsets to 0, then make it a distance.
            rel = -min(rel, 0)
        }
        let maxExact = n / 2
        if rel < maxExact {
            return result + rel
        }
        // Log-spaced bucket for the long tail.
        let scaled = Double(maxExact)
            + (log(Double(rel) / Double(maxExact)) / log(Double(maxDistance) / Double(maxExact)))
            * Double(n - maxExact)
        return result + min(Int(scaled), n - 1)
    }
}

/// T5 v1.1 "gelu_new" approximate GeLU. The gated FFN's activation.
private func t5GeluNew(_ x: MLXArray) -> MLXArray {
    let c = Float(0.7978845608028654)            // sqrt(2/pi)
    let inner = c * (x + 0.044715 * x * x * x)
    return 0.5 * x * (1.0 + MLX.tanh(inner))
}

/// T5 attention: encoder/decoder self-attention and decoder cross-attention.
/// No projection biases, scale = 1.0, position injected via an additive relative bias that
/// only the first layer of each stack owns and then shares down the stack.
private final class T5Attention: Module {
    let numHeads: Int
    let headDim: Int
    let innerDim: Int
    let isDecoder: Bool
    let isCrossAttention: Bool
    let numBuckets: Int
    let maxDistance: Int

    @ModuleInfo(key: "q") var q: Linear
    @ModuleInfo(key: "k") var k: Linear
    @ModuleInfo(key: "v") var v: Linear
    @ModuleInfo(key: "o") var o: Linear
    @ModuleInfo(key: "relative_attention_bias") var relativeAttentionBias: Embedding?

    init(_ config: MADLADConfiguration, isDecoder: Bool, isCrossAttention: Bool, hasRelativeAttentionBias: Bool) {
        self.numHeads = config.numHeads
        self.headDim = config.dKv
        self.innerDim = config.numHeads * config.dKv
        self.isDecoder = isDecoder
        self.isCrossAttention = isCrossAttention
        self.numBuckets = config.relativeAttentionNumBuckets
        self.maxDistance = config.relativeAttentionMaxDistance

        self._q.wrappedValue = Linear(config.dModel, innerDim, bias: false)
        self._k.wrappedValue = Linear(config.dModel, innerDim, bias: false)
        self._v.wrappedValue = Linear(config.dModel, innerDim, bias: false)
        self._o.wrappedValue = Linear(innerDim, config.dModel, bias: false)
        self._relativeAttentionBias.wrappedValue = hasRelativeAttentionBias
            ? Embedding(embeddingCount: config.relativeAttentionNumBuckets, dimensions: config.numHeads)
            : nil
        super.init()
    }

    /// Additive position bias `[1, H, qLen, kLen]` from the learned bucket table. `offset` is
    /// the number of already-cached query positions (so incremental decode lines up).
    func computeBias(qLen: Int, kLen: Int, offset: Int) -> MLXArray {
        guard let table = relativeAttentionBias else {
            return MLXArray.zeros([1, numHeads, qLen, kLen])
        }
        var ids = [Int32]()
        ids.reserveCapacity(qLen * kLen)
        for qi in 0..<qLen {
            for ki in 0..<kLen {
                let b = T5RelativeBucket.bucket(
                    relative: ki - (qi + offset),
                    bidirectional: !isDecoder,
                    numBuckets: numBuckets,
                    maxDistance: maxDistance
                )
                ids.append(Int32(b))
            }
        }
        let bucketIds = MLXArray(ids, [qLen * kLen])
        // [qLen*kLen, H] -> [qLen, kLen, H] -> [1, H, qLen, kLen]
        return table(bucketIds).reshaped(qLen, kLen, numHeads).transposed(2, 0, 1).expandedDimensions(axis: 0)
    }

    /// `selfCache`/`crossCache` are the decoder's per-layer KV caches. Returns the attention
    /// output, the (possibly computed) position bias to share down the stack, and the updated
    /// self/cross caches.
    func callAsFunction(
        _ x: MLXArray,
        keyValueStates: MLXArray? = nil,
        positionBias: MLXArray? = nil,
        selfCache: (MLXArray, MLXArray)? = nil,
        crossCache: (MLXArray, MLXArray)? = nil
    ) -> (out: MLXArray, bias: MLXArray?, selfCache: (MLXArray, MLXArray)?, crossCache: (MLXArray, MLXArray)?) {
        let B = x.dim(0)
        let qLen = x.dim(1)
        let queries = q(x).reshaped(B, qLen, numHeads, headDim).transposed(0, 2, 1, 3)

        var keys: MLXArray
        var values: MLXArray
        var newSelf: (MLXArray, MLXArray)? = nil
        var newCross: (MLXArray, MLXArray)? = nil

        if isCrossAttention {
            // K/V come from the encoder output, computed once and cached for every step.
            if let cached = crossCache {
                keys = cached.0; values = cached.1; newCross = cached
            } else {
                guard let kv = keyValueStates else { return (o(MLXArray.zeros(like: x)), nil, nil, nil) }
                let kLen = kv.dim(1)
                keys = k(kv).reshaped(B, kLen, numHeads, headDim).transposed(0, 2, 1, 3)
                values = v(kv).reshaped(B, kLen, numHeads, headDim).transposed(0, 2, 1, 3)
                newCross = (keys, values)
            }
        } else {
            var newK = k(x).reshaped(B, qLen, numHeads, headDim).transposed(0, 2, 1, 3)
            var newV = v(x).reshaped(B, qLen, numHeads, headDim).transposed(0, 2, 1, 3)
            if let cache = selfCache {
                newK = MLX.concatenated([cache.0, newK], axis: 2)
                newV = MLX.concatenated([cache.1, newV], axis: 2)
            }
            keys = newK; values = newV; newSelf = (keys, values)
        }

        let kLen = keys.dim(2)

        // Position bias: cross-attn has none; self-attn computes it on layer 0 then reuses.
        var bias: MLXArray? = positionBias
        if !isCrossAttention && bias == nil {
            let offset = selfCache != nil ? (kLen - qLen) : 0
            bias = computeBias(qLen: qLen, kLen: kLen, offset: offset).asType(queries.dtype)
        }

        // Decoder self-attention is causal. For single-token decode (qLen == 1) every cached
        // key is in the past, so the mask is a no-op; only multi-token prefill needs it.
        var mask = bias
        if isDecoder && !isCrossAttention && qLen > 1 {
            let pastLen = kLen - qLen
            var m = [Float](); m.reserveCapacity(qLen * kLen)
            for qi in 0..<qLen {
                for ki in 0..<kLen { m.append(ki <= qi + pastLen ? 0 : -1e9) }
            }
            let causal = MLXArray(m, [1, 1, qLen, kLen]).asType(queries.dtype)
            mask = (mask ?? MLXArray.zeros([1, numHeads, qLen, kLen]).asType(queries.dtype)) + causal
        }

        // T5: scale = 1.0 (NO 1/sqrt(d_kv)).
        let attn = MLX.scaledDotProductAttention(queries: queries, keys: keys, values: values, scale: 1.0, mask: mask)
            .transposed(0, 2, 1, 3)
            .reshaped(B, qLen, innerDim)
        return (o(attn), bias, newSelf, newCross)
    }
}

/// T5 v1.1 gated FFN: `wo(gelu(wi_0(x)) * wi_1(x))`.
private final class T5DenseGatedActDense: Module {
    @ModuleInfo(key: "wi_0") var wi0: Linear
    @ModuleInfo(key: "wi_1") var wi1: Linear
    @ModuleInfo(key: "wo") var wo: Linear

    init(_ config: MADLADConfiguration) {
        self._wi0.wrappedValue = Linear(config.dModel, config.dFf, bias: false)
        self._wi1.wrappedValue = Linear(config.dModel, config.dFf, bias: false)
        self._wo.wrappedValue = Linear(config.dFf, config.dModel, bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        wo(t5GeluNew(wi0(x)) * wi1(x))
    }
}

/// Self-attention sublayer: `x + SelfAttn(RMSNorm(x))`. HF stores it at `layer.0`.
private final class T5LayerSelfAttention: Module {
    @ModuleInfo(key: "SelfAttention") var selfAttention: T5Attention
    @ModuleInfo(key: "layer_norm") var layerNorm: RMSNorm

    init(_ config: MADLADConfiguration, isDecoder: Bool, hasRelativeAttentionBias: Bool) {
        self._selfAttention.wrappedValue = T5Attention(
            config, isDecoder: isDecoder, isCrossAttention: false, hasRelativeAttentionBias: hasRelativeAttentionBias)
        self._layerNorm.wrappedValue = RMSNorm(dimensions: config.dModel, eps: config.layerNormEpsilon)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, positionBias: MLXArray?, selfCache: (MLXArray, MLXArray)?)
        -> (MLXArray, MLXArray?, (MLXArray, MLXArray)?) {
        let r = selfAttention(layerNorm(x), positionBias: positionBias, selfCache: selfCache)
        return (x + r.out, r.bias, r.selfCache)
    }
}

/// Cross-attention sublayer (decoder only): `x + CrossAttn(RMSNorm(x), encoderOut)`. At `layer.1`.
private final class T5LayerCrossAttention: Module {
    @ModuleInfo(key: "EncDecAttention") var encDecAttention: T5Attention
    @ModuleInfo(key: "layer_norm") var layerNorm: RMSNorm

    init(_ config: MADLADConfiguration) {
        self._encDecAttention.wrappedValue = T5Attention(
            config, isDecoder: true, isCrossAttention: true, hasRelativeAttentionBias: false)
        self._layerNorm.wrappedValue = RMSNorm(dimensions: config.dModel, eps: config.layerNormEpsilon)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, encoderOutput: MLXArray, crossCache: (MLXArray, MLXArray)?)
        -> (MLXArray, (MLXArray, MLXArray)?) {
        let r = encDecAttention(layerNorm(x), keyValueStates: encoderOutput, crossCache: crossCache)
        return (x + r.out, r.crossCache)
    }
}

/// FFN sublayer: `x + FFN(RMSNorm(x))`. Encoder `layer.1`, decoder `layer.2`.
private final class T5LayerFF: Module {
    @ModuleInfo(key: "DenseReluDense") var denseReluDense: T5DenseGatedActDense
    @ModuleInfo(key: "layer_norm") var layerNorm: RMSNorm

    init(_ config: MADLADConfiguration) {
        self._denseReluDense.wrappedValue = T5DenseGatedActDense(config)
        self._layerNorm.wrappedValue = RMSNorm(dimensions: config.dModel, eps: config.layerNormEpsilon)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray { x + denseReluDense(layerNorm(x)) }
}

/// Encoder block: `[SelfAttention, FF]` under `layer.{0,1}`.
private final class T5EncoderBlock: Module {
    @ModuleInfo(key: "layer") var layer: [Module]

    init(_ config: MADLADConfiguration, hasRelativeAttentionBias: Bool) {
        self._layer.wrappedValue = [
            T5LayerSelfAttention(config, isDecoder: false, hasRelativeAttentionBias: hasRelativeAttentionBias),
            T5LayerFF(config),
        ]
        super.init()
    }

    func callAsFunction(_ x: MLXArray, positionBias: MLXArray?) -> (MLXArray, MLXArray?) {
        let sa = (layer[0] as! T5LayerSelfAttention)(x, positionBias: positionBias, selfCache: nil)
        let ff = (layer[1] as! T5LayerFF)(sa.0)
        return (ff, sa.1)
    }
}

/// Decoder block: `[SelfAttention, EncDecAttention, FF]` under `layer.{0,1,2}`.
private final class T5DecoderBlock: Module {
    @ModuleInfo(key: "layer") var layer: [Module]

    init(_ config: MADLADConfiguration, hasRelativeAttentionBias: Bool) {
        self._layer.wrappedValue = [
            T5LayerSelfAttention(config, isDecoder: true, hasRelativeAttentionBias: hasRelativeAttentionBias),
            T5LayerCrossAttention(config),
            T5LayerFF(config),
        ]
        super.init()
    }

    func callAsFunction(_ x: MLXArray, encoderOutput: MLXArray, positionBias: MLXArray?, cache: inout T5DecoderLayerCache)
        -> (MLXArray, MLXArray?) {
        let sa = (layer[0] as! T5LayerSelfAttention)(x, positionBias: positionBias, selfCache: cache.selfAttn)
        cache.selfAttn = sa.2
        let ca = (layer[1] as! T5LayerCrossAttention)(sa.0, encoderOutput: encoderOutput, crossCache: cache.crossAttn)
        cache.crossAttn = ca.1
        let ff = (layer[2] as! T5LayerFF)(ca.0)
        return (ff, sa.1)
    }
}

/// One decoder layer's KV state: self-attention cache grows per step, cross-attention cache
/// is computed once from the encoder output and reused.
struct T5DecoderLayerCache {
    var selfAttn: (MLXArray, MLXArray)?
    var crossAttn: (MLXArray, MLXArray)?
    init() { selfAttn = nil; crossAttn = nil }
}

/// A stack of T5 blocks plus the final RMSNorm. Encoder runs bidirectionally in one pass;
/// decoder runs incrementally with per-layer caches.
private final class T5Stack: Module {
    @ModuleInfo(key: "block") var block: [Module]
    @ModuleInfo(key: "final_layer_norm") var finalLayerNorm: RMSNorm
    let isDecoder: Bool

    init(_ config: MADLADConfiguration, isDecoder: Bool) {
        self.isDecoder = isDecoder
        let n = isDecoder ? config.numDecoderLayers : config.numLayers
        self._block.wrappedValue = (0..<n).map { i -> Module in
            isDecoder
                ? T5DecoderBlock(config, hasRelativeAttentionBias: i == 0)
                : T5EncoderBlock(config, hasRelativeAttentionBias: i == 0)
        }
        self._finalLayerNorm.wrappedValue = RMSNorm(dimensions: config.dModel, eps: config.layerNormEpsilon)
        super.init()
    }

    func encode(_ embeds: MLXArray) -> MLXArray {
        var h = embeds
        var bias: MLXArray? = nil
        for b in block {
            let (newH, newBias) = (b as! T5EncoderBlock)(h, positionBias: bias)
            h = newH
            if bias == nil { bias = newBias }
        }
        return finalLayerNorm(h)
    }

    func decode(_ embeds: MLXArray, encoderOutput: MLXArray, caches: inout [T5DecoderLayerCache]) -> MLXArray {
        var h = embeds
        var bias: MLXArray? = nil
        for (i, b) in block.enumerated() {
            let (newH, newBias) = (b as! T5DecoderBlock)(h, encoderOutput: encoderOutput, positionBias: bias, cache: &caches[i])
            h = newH
            if bias == nil { bias = newBias }
        }
        return finalLayerNorm(h)
    }
}

/// MADLAD-400 T5 v1.1 model: shared embedding + encoder + decoder + (untied) LM head.
/// Parameter keys match the HF checkpoint 1:1 so safetensors load via `unflattened`.
final class MADLADModel: Module {
    @ModuleInfo(key: "shared") fileprivate var shared: Embedding
    @ModuleInfo(key: "encoder") fileprivate var encoder: T5Stack
    @ModuleInfo(key: "decoder") fileprivate var decoder: T5Stack
    @ModuleInfo(key: "lm_head") fileprivate var lmHead: Linear

    let config: MADLADConfiguration

    init(_ config: MADLADConfiguration) {
        self.config = config
        self._shared.wrappedValue = Embedding(embeddingCount: config.vocabSize, dimensions: config.dModel)
        self._encoder.wrappedValue = T5Stack(config, isDecoder: false)
        self._decoder.wrappedValue = T5Stack(config, isDecoder: true)
        // tie_word_embeddings = false for MADLAD/T5 v1.1 → a separate lm_head, no embed scaling.
        self._lmHead.wrappedValue = Linear(config.dModel, config.vocabSize, bias: false)
        super.init()
    }

    /// Fresh per-layer decoder caches for one translation.
    func makeDecoderCaches() -> [T5DecoderLayerCache] {
        (0..<config.numDecoderLayers).map { _ in T5DecoderLayerCache() }
    }

    /// Encode the source token ids `[1, T_src]` once. T5 does NOT scale embeddings.
    func encode(_ inputIds: MLXArray) -> MLXArray {
        encoder.encode(shared(inputIds))
    }

    /// One decoder step: logits `[1, T_q, vocab]` for the given decoder token(s), advancing caches.
    func decodeStep(_ inputIds: MLXArray, encoderOutput: MLXArray, caches: inout [T5DecoderLayerCache]) -> MLXArray {
        let h = decoder.decode(shared(inputIds), encoderOutput: encoderOutput, caches: &caches)
        return lmHead(h)
    }
}

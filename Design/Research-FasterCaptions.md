# Research: Faster captions/translation without shrinking the model

**Date:** 2026-06-13
**Question:** How do we make Blablacadabra's live captioning and translation faster
WITHOUT dropping the Whisper model down to "tiny"?
**Hardware context:** Apple M4, macOS 26.3, WhisperKit on-device, default model "small".

## TL;DR

The model size is NOT your main latency knob. Three things are:

1. **Redundant forward passes per utterance.** Translate finals run
   `detectLanguage()` then a translate pass then (bilingual) a third transcribe
   pass, all on the biggest model in the chain. That is 2x-3x the compute of a
   plain transcript.
2. **Your partials re-decode a growing audio window every ~1s** instead of using
   confirmed-token streaming, so the cost climbs as the utterance gets longer.
3. **Whisper's translate task is inherently slow**, and the fast model (turbo)
   is bad at translation, so you cannot turbo your way out of the translate path.

Biggest wins, in order: decouple translation from transcription, swap the
transcription engine on the fast path (Apple SpeechAnalyzer or Parakeet), adopt
WhisperKit's own streaming, then tune DecodingOptions and compute units.

---

## Tier 1: the big structural wins

### 1. Decouple translation from transcription (highest leverage)

Today translation rides on Whisper's `translate` task, which is slower than
transcribe AND blocks you from using the fast turbo model (OpenAI explicitly says
turbo "was not trained for translation tasks; use medium or large-v3 instead").

Instead:
- **Transcribe** in the source language with a fast engine (turbo, or
  SpeechAnalyzer, or Parakeet, see below).
- **Translate the text** with **Apple's Translation framework**
  (`TranslationSession`, on-device, macOS 15+, you are on 26.3). It runs on
  on-device ML models, supports `translate(batch:)` for efficiency, and reuses
  loaded models across requests.

Why this is faster overall:
- The transcribe pass can now use turbo (4 decoder layers vs 32, "way faster")
  or a non-Whisper engine, instead of the slow translate task.
- Text translation is tiny and fast compared to a second audio decode.
- You delete the separate transcribe pass that bilingual mode currently needs:
  you already have the source text, so the "original language" line is free, and
  the English line is a cheap text translation of it. Your current 3-pass
  bilingual final collapses toward 1 audio pass + 1 text translate.

Tradeoffs / things to verify:
- Translation framework needs the language pair's model downloaded (it can prompt
  the user, or you pre-stage common pairs). Honor your zero-network privacy proof:
  confirm `TranslationSession` makes no network calls once the pair is downloaded
  (it is documented on-device, but re-run the `nettop` proof like you did for
  WhisperKit).
- It is a UIKit/SwiftUI-attached session in the documented path; check the
  headless/programmatic batch path works from your actor pipeline.
- Quality differs from Whisper's end-to-end translate. Spot-check your real
  language pairs (Indonesian, Japanese, German).

### 2. Swap the transcription engine on the fast path

You assumed in Phase 5 there was "no public API" for Apple's live captions. That
was true for the Live Captions *panel*, but Apple shipped a real, public
transcription API you can call directly:

**Apple SpeechAnalyzer + SpeechTranscriber (iOS 26 / macOS 26 "Tahoe").**
- Purpose-built for long-form and **live/low-latency** transcription, fully
  on-device on the Neural Engine.
- Benchmarks: ~**2x faster than Whisper large-v3-turbo**, and ~55% faster than
  Whisper overall on Apple's own numbers. Argmax's own comparison: SpeechTranscriber
  14.0% WER at 70x realtime vs WhisperKit base 15.2% at 111x. So Apple is a bit
  more accurate than base, slightly slower in raw RTF than tiny/base but with much
  better accuracy, and it is the lowest-effort engine since the model ships with
  the OS (no download, no HuggingFace dependency).
- Ships three modules: `SpeechTranscriber` (long-form), `DictationTranscriber`
  (short utterance), `SpeechDetector` (VAD). You could even retire your energy
  VAD for SpeechDetector on this path.
- No translation: pair it with the Translation framework from #1.
- Caveat: language coverage is whatever Apple ships on-device, narrower than
  Whisper's ~99. Use it where supported, fall back to WhisperKit otherwise.
- Argmax says they "will integrate Apple SpeechAnalyzer" into WhisperKit later,
  so a unified path may come for free, but you do not have to wait.

**Parakeet TDT v3 via FluidAudio** (you already plan FluidAudio for diarization
in Phase 6, so this is one dependency for two features):
- Swift + CoreML/ANE, Apache-2.0. ~**110x-190x realtime on M4**.
- Parakeet TDT 0.6B v3: 25 European languages + Japanese + Chinese (batch).
- Parakeet **EOU 120M**: streaming ASR with built-in end-of-utterance detection,
  English only, true real-time dictation. This is the lowest-latency option for
  English-heavy use.
- No translation (decouple via #1). No translate task at all, so same pattern as
  SpeechAnalyzer.

Recommendation: keep WhisperKit as the accuracy/coverage fallback and the
translate-everything engine, but route the common cases (English transcription,
and the major supported languages) through SpeechAnalyzer or Parakeet for the
latency win. This is a `TranscriptionEngine` protocol swap, which your
architecture already supports ("engines are swappable").

### 3. Use confirmed-token streaming instead of re-decoding the window

Right now you roll a partial every ~1s by re-running the engine on the growing
utterance audio. WhisperKit has a built-in **LocalAgreement / Eager streaming**
policy: it confirms the longest common prefix across consecutive hypotheses,
advances the audio cursor past confirmed tokens, and emits two streams (confirmed
+ hypothesis). Sub-second latency, and it stops re-paying for already-stable text.

- This directly attacks partial-decode cost, which grows with utterance length
  under your current approach.
- Maps cleanly onto your overlay: confirmed stream = committed line, hypothesis =
  the live in-place partial you already render.
- Only applies to the WhisperKit path; SpeechAnalyzer and Parakeet EOU stream
  natively, so this is the WhisperKit-equivalent of that behavior.

---

## Tier 2: tuning inside WhisperKit (cheap, do regardless)

### 4. DecodingOptions for live, not for offline accuracy
- **Kill temperature fallback**: set `temperatureFallbackCount = 0` (and avoid
  `compressionRatioThreshold` / `logProbThreshold` retriggers). A failed decode
  currently re-runs the whole chunk at higher temperature, a silent latency spike
  on exactly the hard chunks. For live captions, take the first pass.
- **Cap `sampleLength`** (max decoded tokens per window) to the realistic length
  of one VAD utterance. Whisper otherwise can run the decoder longer than needed.
- Greedy decode (single temperature 0), `withoutTimestamps = true` (you do this),
  `wordTimestamps = false`.
- These are pure latency wins with negligible quality cost on short live chunks.

### 5. Compute-unit placement and prewarm
- WhisperKit lets you set compute units separately for the audio encoder and the
  text decoder. The usual Apple-Silicon sweet spot is **encoder on ANE, decoder
  on ANE or GPU**; the decoder is the autoregressive bottleneck, so test
  `.cpuAndNeuralEngine` vs `.cpuAndGPU` vs `.all` for the decoder on M4 and pick
  the fastest. This can move latency meaningfully with zero accuracy change.
- You already keep a persistent prepared engine across restarts (good). Make sure
  it is fully warmed (one dummy decode) before the first real utterance so the
  ANE compile cost is not paid live.

### 6. turbo on the transcribe-only path
Once translation is decoupled (#1), **turbo becomes the default fast model**:
same encoder as large-v3, 4 decoder layers, "way faster", quality ~large-v2.
Use it for transcription; never for the translate task. This gives you
large-model accuracy at a fraction of medium's decode time. Note larger
per-language degradation on a few languages (Thai, Cantonese); your common pairs
are fine.

---

## Tier 3: optional / later

### 7. Cloud "boost mode" (already on your roadmap)
Gemini Live Translate is already noted as a future opt-in cloud engine. It would
be the fastest translate path of all, but it breaks the zero-network promise, so
it must be explicit opt-in with a clear UI state, never default. Keep it as a
toggle, not the baseline.

### 8. Both-mode memory note
Decoupling helps "Both" too: two lanes each currently can run a translate task.
If both lanes move to a fast transcribe engine + shared Translation framework, you
drop from ~2x heavy Whisper instances toward 2x light transcribe + 1 shared text
translator, easing the ~2x model-memory cost you flagged (heavy for turbo).

---

## Recommended sequence (impact per unit effort)

1. **DecodingOptions tuning (#4)** and **compute-unit test (#5)**: hours of work,
   no architecture change, immediate latency drop on the existing path. Do first.
2. **Decouple translation via Apple Translation framework (#1)** + make **turbo**
   the transcribe model (#6). This is the structural unlock and re-uses an Apple
   framework, not a new model download.
3. **Add SpeechAnalyzer or Parakeet/FluidAudio as a `TranscriptionEngine`** for the
   fast path (#2). Parakeet pairs with the Phase 6 FluidAudio diarization work, so
   sequence them together if diarization is coming anyway.
4. **WhisperKit streaming/LocalAgreement (#3)** for the remaining WhisperKit path.

Keep WhisperKit as the universal fallback (widest language coverage, full
translate task) so nothing regresses for rare languages.

---

## Sources
- Apple SpeechAnalyzer/SpeechTranscriber, WWDC25:
  https://developer.apple.com/videos/play/wwdc2025/277/
- "Apple's new transcription API beats Whisper in speed tests":
  https://www.macrumors.com/2025/06/18/apple-transcription-api-faster-than-whisper/
  and https://gigazine.net/gsc_news/en/20250619-apple-speech-analyzer/
- MacStories hands-on (modules, latency):
  https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/
- Argmax on Apple SpeechAnalyzer vs WhisperKit (benchmarks, future integration):
  https://www.argmaxinc.com/blog/apple-and-argmax
- Apple Translation framework / TranslationSession (WWDC24, batch, on-device):
  https://developer.apple.com/videos/play/wwdc2024/10117/
  and https://www.polpiella.dev/swift-translation-api/
- Whisper large-v3-turbo: faster, NOT for translation:
  https://github.com/openai/whisper/discussions/2363
  and https://huggingface.co/openai/whisper-large-v3-turbo
- WhisperKit LocalAgreement / Eager streaming (paper + repo):
  https://arxiv.org/pdf/2507.10860
  and https://github.com/argmaxinc/WhisperKit/issues/111
- FluidAudio / Parakeet TDT v3 + EOU streaming (speed, languages):
  https://github.com/FluidInference/FluidAudio
  and https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml

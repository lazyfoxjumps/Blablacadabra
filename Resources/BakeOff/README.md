# Bake-off resources (Phase 7B B.4)

This folder feeds the `BakeOff` CLI (`Sources/BakeOff`, library in `Sources/BakeOffKit`).

## `manifest.json`

One entry per clip:

| field | meaning |
|---|---|
| `clip_id` | unique id, used in the `clip_id` result column |
| `source_iso` | ISO 639-1 source language; `--clips ar,id,...` filters on this |
| `audio` | optional path to a WAV, relative to this manifest; only used by `--concurrent-with-whisper` |
| `source_text` | the lines handed to the translator (one "finalized utterance" each) |
| `expected_english` | ground-truth English, filled into `quality_human` / BLEU **by hand later** |

The committed `manifest.json` is **text-only** (no audio) so the harness runs end-to-end
out of the box and measures latency + tokens/sec. It does **not** measure translation
quality — `quality_bleu` and `quality_human` ship `null` by design and must be filled by
a native speaker before any GO/NO-GO call (scaffold § B.4).

## `clips/` — real audio (gitignored)

Real licensed audio clips + reference transcripts are kept out of git (`clips/` is
ignored). To run with real audio, drop the WAVs in `clips/`, reference them from a local
manifest's `audio` field, and point the CLI at it:

```
swift run BakeOff --models gemma-3-4b,gemma-3-1b --clips ar,id,es,ja \
  --runs 3 --concurrent-with-whisper true \
  --manifest Resources/BakeOff/manifest.local.json \
  --out bakeoff-$(date +%Y-%m-%d).json
```

## Reading the output

Each row is one `(model, clip)` with the locked metric columns. A failed model/clip ships
a row with `error` set (and metrics null) so the JSON stays complete — one model crashing
never voids the rest of the run.

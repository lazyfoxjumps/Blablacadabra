# Phase 6 plan: speaker colors (diarization) + English locale setting

Status: PLAN ONLY, not started. Awaiting user go-ahead per the phase rule.
Written 2026-06-12 from the Phase 5 research notes in Handoff.md.

## Part A — Per-speaker caption colors via FluidAudio

### Goal
When two or more people are talking (the Discord-call use case), each
speaker's caption lines get their own color from the MP072 palette PLUS a
non-color marker, so you can tell at a glance who said what. Color is never
the only signal (ND rule, non-negotiable).

### Step 0: design pass — DECIDED 2026-06-14 (user signed off, all proposals accepted)
1. **Max tracked speakers — DECIDED: 4 + overflow.** 4 distinct speakers get
   colors; speaker 5+ all share one "everyone else" (`.other`) style. The
   vetted >= 7:1 caption pairs give us roughly 4 clearly distinguishable
   foregrounds per mode before colors read as "same-ish", and more than 4 is
   cognitive load, not help.
2. **Labels — DECIDED: colored chip "S1"/"S2".** A small chip before the line
   ("S1", "S2"...) in the speaker's color. Plain words available on
   hover/expanded ("Speaker 1"). Renaming speakers mid-call is a v2 idea, not
   Phase 6.
3. **"You" detection — DECIDED: DEFER TO v2.** Do NOT thread per-lane
   provenance through MixedAudioSource for v1. Ship S1/S2/S3 only; the
   mic-lane-is-"You" win waits until lane tagging can be done cleanly. This
   keeps v1 scope tight and avoids the chunker/lane-tagging rabbit hole.
4. **Overlap behavior — DECIDED: dominant speaker, no overlap UI.** When two
   people talk at once the utterance goes to the dominant speaker; no special
   "overlap" UI in Phase 6. Captions already handled overlapping speech
   acceptably in Phase 4 testing.
5. **Default state — DECIDED: ON for source = Both or System.** Settings
   toggle "Color by speaker", ON by default when source is Both or System,
   with plain-language description. Calm mode wins over speaker colors: calm
   mode stays single max-contrast line, keeps only the chip ("S2:") as the
   speaker signal.
6. **Accessibility interactions — LOCKED (restated):** Increase Contrast pins
   captions to the max-contrast pair, which ALSO disables speaker colors (chip
   stays). Differentiate Without Color is already satisfied by the chip.

> Step 0 is CLOSED. Step 1 (FluidAudio spike) is unblocked. "You" detection
> and speaker renaming are explicitly v2, out of Phase 6 scope.

### Step 1: dependency spike (Spikes/DiarizeSpike)
- Add FluidAudio (github.com/FluidInference/FluidAudio, Apache-2.0,
  macOS 14+) as an SPM dependency of the spike only, not Core yet.
- Verify on this M4: model download + cache location, speaker embedding from
  a 16kHz mono Float32 chunk (our pipeline format, convenient), wall-clock
  per 1-10s utterance, memory, and whether it runs on the ANE as advertised.
- Feed it "Talk with Kevin.mov" audio (known multi-speaker recording,
  gotcha 18: afplay plays .mov audio directly) and check cluster stability:
  does the same voice get the same embedding neighborhood across minutes?
- Exit criteria: embedding for a 5s utterance in well under 0.5s, stable
  same-speaker cosine similarity, sane memory. If FluidAudio fails the
  spike, stop and re-research; do not force it into Core.

#### Step 1 RESULT — 2026-06-14: PASS (FluidAudio is viable, proceed pending go-ahead)
Spike lives at `Spikes/DiarizeSpike/` (standalone SPM pkg, does NOT link Core).
FluidAudio 0.12.4. Real API confirmed: `DiarizerModels.downloadIfNeeded()` ->
`DiarizerManager().initialize(models:)` -> `extractSpeakerEmbedding(from: [Float])
throws -> [Float]` (256-d) -> `SpeakerManager(speakerThreshold: 0.65).assignSpeaker(
_:speechDuration:)` does the online clustering + EMA embedding update for us.
Models cache at `~/Library/Application Support/FluidAudio/Models/speaker-diarization`
(wespeaker_v2 + pyannote_segmentation .mlmodelc, ANE).
Run: "Talk with Kevin.mov" (112-min 2-person convo), first 1200s, 5s windows, 10s stride.
- **Speed: median 26 ms / 5s window** (min 25, p95 29; 2.5s "max" is just first-call
  warmup). Bar was <500ms -> ~19x margin. PASS.
- **Memory: peak 521 MB**, ~510 MB of which is MY 20-min audio buffer, not FluidAudio
  (cached-run peak was 103 MB). PASS.
- **Separability: within-speaker 0.569 vs cross 0.399, gap 0.170.** PASS (good, not huge).
- **Speaker count: clustered 6 from a 2-person convo, BUT the 2 real speakers hold
  105/120 windows (87%), each spanning the full ~16-19 min; the other 4 are 15 junk
  windows.** Root cause = the spike's naive FIXED 5s windows (no VAD) straddle silence/
  music/overlap/mid-utterance speaker changes. Step 2 feeds clean VAD-finalized
  single-speaker utterances -> expect the tail to mostly vanish and within-speaker sim
  to rise. NOT a FluidAudio weakness; a spike-methodology artifact.
- **Zero-network once cached: PASS.** `lsof -a -p <pid> -i` empty across 6 samples;
  cached model load 0.14s. Same privacy bar as Phase 5.
- macOS 14 platform, Swift 5 language mode (mirrors Core), Apache-2.0 license.
Open follow-ups for Step 2 (NOT blockers): tune speakerThreshold (6 clusters formed at
borderline distances 0.66-0.78; ~0.70 may collapse the junk); confirm VAD-utterance
inputs sharpen separability; decide max-speaker cap enforcement (Step 0 said 4 + .other).

### Step 2: Core integration (Sources/BlablacadabraCore/Diarization/)
- **`SpeakerIdentifier.swift`** — actor. API sketch:
  `identify(samples: [Float]) async -> SpeakerID` where SpeakerID is a
  stable small int per session. Inside: FluidAudio embedding + online
  clustering by cosine similarity (threshold tuned in the spike; start
  around 0.65). New cluster = next speaker number, capped at maxSpeakers,
  beyond the cap everything maps to `.other`.
- **Pipeline hook:** in TranscriptionPipeline, at FINALIZE only, run the
  utterance samples through SpeakerIdentifier in parallel with (or after)
  Whisper. Partials keep the previous line's speaker tentatively; the final
  sets it for real. Captions must never wait on diarization: if the
  embedding hasn't landed when the final commits, commit unlabeled and
  backfill the color when it arrives (no text reflow, color/chip only).
- **`CaptionEvent`** gains `speaker: SpeakerID?` (nil = feature off or
  single speaker so far).
- Privacy: confirm FluidAudio loads from a local model folder with zero
  network once cached, same standard as Phase 5's nettop proof. If it
  phones home on every init like WhisperKit did, find its offline init path
  before shipping.
- Session reset: clusters are per-session, cleared on stop. No voice prints
  persisted to disk in Phase 6 (privacy posture stays simple).

### Step 3: UI (Overlay + Settings)
- **Speaker -> style map** in Theme: per mode, an ordered list of vetted
  >= 7:1 caption foregrounds on the caption background. The user's chosen
  preset stays the color of Speaker 1 / single-speaker mode, so turning the
  feature on changes nothing until a second voice shows up.
- **Overlay:** chip ("You", "S2"...) leading each line, line text in the
  speaker color. Dimming-by-recency still applies on top. No motion, no
  flashing when a new speaker appears, the line just renders in its style.
- **Settings > Colors:** "Color by speaker" FlameToggle + a static preview
  row showing the speaker styles. Plain copy, e.g. "Each voice gets its own
  color and label. Color is never the only marker."
- Contrast checker: speaker colors come only from pre-vetted pairs, so the
  live checker doesn't need to handle them.

### Step 4: tests + live verification
- Unit tests: clustering math (same embedding -> same id, far embedding ->
  new id, cap -> .other, reset clears), event plumbing (final carries
  speaker, backfill path).
- Harness: extend transcribe-check with `--speakers` to print "S1:"/"S2:"
  prefixes; run against Talk with Kevin audio.
- Live: a real Discord call, screenshots showing two stable colors + chips
  over several minutes. Same bar as Phase 5.

### Open questions / risks
- MixedAudioSource currently sums lanes BEFORE the pipeline, so per-lane
  "You" attribution needs either lane tags through the chunker or a
  parallel mic-energy heuristic. Spike this; if ugly, "You" waits for v2.
- VAD utterances up to 10s can contain a speaker change mid-utterance.
  Phase 6 accepts one speaker per utterance (the 0.6s-pause finalize means
  turns usually split naturally). Per-word diarization is out of scope.
- FluidAudio model size/download UX: reuse the Phase 5 download-progress
  pattern ("first time only" status) if its model isn't tiny.

## Part B — Caption/subtitle English locale setting

### The honest technical bit
WhisperKit outputs "English", full stop. The model has no en-US vs en-GB
switch; accents in are fine, but spelling out is whatever Whisper picked up
in training (mostly US). So the locale setting does two real things:
1. **Today (WhisperKit):** a display-layer spelling normalizer applied to
   caption text (color/colour, -ize/-ise, center/centre, gray/grey, etc.).
   Cheap dictionary pass on finals; partials can skip it. en-AU/en-SG/en-NZ/
   en-IE inherit UK spelling; en-CA is UK-ish with some US forms.
2. **Future engines:** Apple's SpeechAnalyzer/SFSpeechRecognizer and cloud
   engines ARE locale-aware, so the setting is stored as a real locale id
   (en-US, en-GB...) and handed to any engine that can use it. The
   TranscriptionEngine protocol gains an optional locale hint.

### Settings UI
- Speech engine section, PillPicker or compact picker: "Caption language"
  with **English (US) as the default**, plus:
  - English (UK)
  - English (Australia)
  - English (Singapore)
  - English (Canada)
  - English (India)
  - English (New Zealand)
  - English (Ireland)
- That list covers the locales Apple's speech stack actually distinguishes,
  so it stays meaningful when a locale-aware engine lands. If eight pills
  is too dense for the ND spacing rules, ship US/UK/AU/SG/CA/IN in Phase 6
  and add the rest on request.
- Copy must be honest per the voice doc: "Changes spelling in captions
  (colour vs color). Speech recognition itself understands every accent."
  No implying the model gets better at your accent, because it doesn't.
- Persisted in AppState like every other setting; applies at the next
  final (never reflow already-committed lines mid-read).

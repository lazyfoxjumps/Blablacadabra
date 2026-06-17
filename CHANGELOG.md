# Changelog

Every spell Blablacadabra has learned, in order. Newest at the top.

This project follows a loose [semantic versioning](https://semver.org) rhythm, and the dates are when each version actually landed on my Mac.

---

## 1.1 — "No more fizzled spells." (2026-06-17)

A reliability release. 1.0 did the magic; 1.1 makes sure it doesn't fizzle when the conditions get awkward, a specific mic, a tricky language, a model that secretly can't translate. Two small quality-of-life charms came along for the ride.

### Fixed
- **Picking a specific microphone actually works now.** Choosing anything but "Automatic" in Settings used to capture pure silence, with the level meter sitting flat. It now binds the exact device you picked (built-in, EarPods, USB interface, all of them), and flipping back to Automatic still behaves.
- **Translate no longer goes blank on the fast model.** The fastest transcription model can't translate audio at all, so some translate sessions came out with perfect captions and zero English. Now any session that needs to translate audio quietly borrows a translate-capable model just for that run, keeps your saved preference untouched, and tells you it did it. Works on every supported macOS version.
- **Indonesian translates again.** It was being routed down a path the fast model couldn't serve, so you'd get crisp Indonesian captions and no English. Fixed: Indonesian now transcribes on-device and translates to English cleanly.
- **A rare hiccup starting or stopping system capture.** Some shared audio state could be touched from two threads at once. Tightened so it can't.
- **The last line no longer vanishes when you stop translating.** A translation still in flight when you hit stop now finishes and lands instead of getting dropped.
- **Locked languages stay locked.** Norwegian, Tagalog and Javanese could quietly slip back to auto-detect while translating, so a language you'd locked came out as something else entirely. They now hold the language you picked.
- **No more "let me into your Documents" prompt.** The speech models were being cached inside your Documents folder, which made macOS pop a permission ask for no real reason. They now live in the app's own Application Support folder, no prompt, and any models you'd already downloaded are moved over for you instead of fetched again.
- **The app icon shows up where it should.** In the screen-sharing picker (and other system dialogs) the app tile could come up blank; it now shows the real Blablacadabra mark.

### Improved
- **"1 speaker" is now an option.** Tell Blablacadabra it's just one voice and it pins everything to a single speaker, so a lone talker can never accidentally split into S2 and S3.
- **Bilingual captions feel instant.** In bilingual mode the original spoken line now appears the moment you speak, and the English lands when the sentence finishes, instead of waiting on the translation before showing anything at all.
- **Auto-detect keeps up when you switch languages mid-conversation.** In auto translate it used to latch onto the first language it heard and stay there; now it follows a genuine switch (English, then Japanese, then Spanish) while still shrugging off a one-off mis-hear.
- **Permissions are asked together, up front.** Pressing Start for the first time now requests microphone and speech access in one batch instead of dribbling them out across separate sessions.

### Under the hood
- Removed dead code, hardened the model-selection guard so a future change can't quietly bring the translate-blank bug back, and tightened app lifetime and diagnostics logging. Build clean, 124 tests green.

---

## 1.0 — "Now you hear it, now you read it." (2026-06-14)

The first public release. Everything below this line is the story of how Blablacadabra got here. Everything in this section is what you get when you open the box.

### The whole act, in one breath
- **System-wide live captions.** Any app, any website, any call. If your Mac can play it, I can write it down.
- **Translate to English on demand.** One toggle. About 99 languages in, English out, with the original line kept right above it if you want both.
- **Two engines, one app.** On supported languages it captions through Apple's on-device SpeechAnalyzer (fast). Anything that engine can't do, the app hands to WhisperKit without you noticing a seam. You never pick an engine. Blablacadabra just picks the better wand.
- **Per-speaker colors.** When more than one voice shows up, each person gets their own color and a small label (S1, S2). Color is never the only signal, the label always rides along.
- **All on-device. Always.** No account, no cloud, no audio ever leaving your Mac. Proven with the network unplugged: zero sockets, zero flows, while actively captioning.

### Added this release
- **Per-speaker caption colors via on-device diarization** (FluidAudio, Apache-2.0). Voices are told apart by sound, from a single mic channel, so it works in-person too, several people in a room, one Mac.
- **"How many people?" setting.** Tell me 2, 3, 4, or more and I lock the speaker count so one voice can never accidentally split into a rainbow. Leave it on Auto and I'll guess.
- **The mic is always you (S1).** In Both mode your own voice pins to Speaker 1 and everyone else numbers up from there. No more being mistaken for a stranger at your own meeting.
- **A real face.** Proper brand logo across the app icon, the in-app mark, and the menu bar (hollow star when idle, solid burst while I'm listening). The frazzled-wizard mascot was sent back to wizard school and never spoken of again.
- **A perceptually-tuned speaker palette** (OKLab color distance, WCAG AAA large-text contrast floor) so every speaker color is genuinely distinguishable on light, dark, and warm-paper captions, not just "technically different."

### Why this is 1.0
Because the daily thing works, every day, without me thinking about it: open a call, words appear, the right person is the right color, nothing phones home. That was always the bar.

---

## 0.8.0 — Apple's translation desk (2026-06-13)

- **Apple on-device translation fast-path.** When you lock an Apple-supported language and its English pack is already installed, I now transcribe *and* translate through Apple's frameworks. Bilingual captions come nearly free, the original line is already in hand.
- **Indonesian stays on WhisperKit, on purpose.** Apple's Indonesian leans a little Malay, Whisper reads casual Indonesian truer, so the app keeps `id` on Whisper even when translating. A touch slower, noticeably better.
- Everything that isn't a locked, installed, supported pack still falls back to WhisperKit silently. You never see the handoff.

## 0.7.0 — A faster wand (2026-06-13)

- **Apple SpeechAnalyzer transcription fast-path.** On supported languages Blablacadabra now captions through Apple's on-device engine, measurably faster than Whisper, same privacy posture.
- Unsupported language? Locked to something Apple can't do? It falls back to WhisperKit without a stutter.
- Re-proved zero-network on the live build: still no flows, still nothing leaving the Mac.
- Overlay polish: speaker chips read cleanly, faded lines keep their color.

## 0.6.2 — Daily-driver fixes (2026-06-13)

- **Translate-off no longer guesses your language wrong.** Turning translate off stopped silently auto-detecting (the old "I typed English and got Indonesian" gremlin).
- **Both mode is now two real lanes.** System audio and mic run independently instead of fighting over one channel.
- Width-resizable overlay, a brighter original line, a model slider in the menu panel, slimmer controls, and a redundant drag handle shown the door.

## 0.6.1 — The sound board (2026-06-12)

- **Audio settings section.** Mic device picker, a live input-level meter, an input-boost gain slider, a capture-health warning when a virtual audio device misbehaves, and a heads-up when your input device changes under you.
- **Model picker became a 4-stop slider** (tiny, small, medium, turbo) with an automatic migration off the old base model.

## 0.6.0 — Naming the language (2026-06-12)

- **Spoken-language picker.** Lock a language to kill misdetection and skip a model pass entirely. Faster and more accurate when you already know what's being said.
- Auto-mode detection caching, a restart-freeze fix, a rapid-toggle crash fix, and quicker recovery when a model load stalls.

## 0.5.2 — Both languages at once (2026-06-12)

- **Bilingual captions:** the original line above, the English translation below, with the detected source language reported correctly.

## 0.5.1 — Your spelling, your rules (2026-06-12)

- **English locale setting.** Colour or color, your captions match how you write. Speech is understood the same in every accent either way.
- Detected source language now shows in the status line.

## 0.5.0 — Phase 5: out into the world (2026-06-12)

- **Live call captioning, verified on a real Discord call.**
- Honest download progress when a model is fetching for the first time, plus a stall guard so a slow download can't hang you.
- **The zero-network proof.** Captioned with the network watched: no sockets, no flows, nothing left the Mac. This is the promise, written in receipts.
- Fullscreen overlay support and system accessibility settings (reduce motion, increase contrast) honored.

## 0.4.1 — Phase 4.1: staying on its feet (2026-06-12)

- Mic-switch resilience (unplug a headset mid-sentence, I keep writing), launch-at-login, and a round of performance verification.

## 0.4.0 — Phase 4: making it honest (2026-06-12)

- Live verification pass, a VAD seam fix so words stop getting clipped between chunks, and an honest first-run download status instead of a frozen-looking window.

## 0.3.1 — Dressed for the part (2026-06-12)

- The UI pass to match the mockups: bundled Nunito and Jua fonts, pill pickers, proper card chrome, a welcome wordmark, and a new tagline.

## 0.3.0 — Phase 3: the actual app (2026-06-11)

- **It became an app.** Menu-bar shell, the caption overlay, the settings window, and onboarding. The first version you could actually open and use.

## 0.2.0 — Phase 2: turning sound into words (2026-06-11)

- The transcription pipeline: voice-activity chunking, the WhisperKit engine, and the translate toggle.

## 0.1.0 — Phase 1: catching the sound (2026-06-11)

- The real audio capture module, system and mic, emitting clean 16 kHz mono PCM.

## 0.0.1 — Phase 0: proof it's possible (2026-06-11)

- The opening spell. Captured system audio, fed it to on-device transcription, and watched the app's own name come back as text. End to end, it worked. Everything after this was just getting better at it.

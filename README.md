<div align="center">

# 🪄 Blablacadabra

### Now you hear it, now you read it.

*Live, on-device captions for everything on your Mac, with translate-to-English on tap. A little magic between the bla bla and your brain.*

</div>

---

## 💫 Why I made this

Hi. I'm the person who built Blablacadabra, and I'll be honest with you, because that's the whole reason it exists.

I'm autistic and ADHD, and I have auditory processing disorder. My ears work fine. The problem is the part *between* my ears and my understanding, the little spell that's supposed to turn sound into meaning. It drops. A lot. Every few minutes I mishear something, fill the gap with a guess, and nod along hoping the guess was close. On calls, in meetings, watching a video, I'd hear "bla bla bla" where everyone else heard words. I spent so much energy pretending I caught it that I'd be exhausted before the actual thinking even started.

Captions fix this for me instantly. The second I can *read* what I'm hearing, the panic stops. So I went looking for an app that would caption **everything**, every app, every website, every call, not just the one video player that happened to ship with subtitles. I couldn't find one I trusted. Most wanted my audio to take a little field trip to the cloud first, and "your private conversations, but make them a stranger's server problem" is not the kind of magic I'm into.

So I made my own. Blablacadabra is the spellbook I wished someone had handed me years ago: it listens to whatever your Mac is playing and writes it down, live, entirely on your machine. No account, no cloud, no audio ever leaving your Mac, and the receipts are in the [changelog](CHANGELOG.md), proven with the network unplugged. Now I'm handing the spellbook to you.

## 🎩 What Blablacadabra does

Blablacadabra sits quietly up in your menu bar like a familiar waiting to be useful. When you want captions, you summon them, and it starts writing the moment anyone speaks.

| Spell | What it actually does |
|---|---|
| 🌍 **System-wide live captions** | Captions any app, website, or call on your Mac, FaceTime included. If it makes a sound, it becomes words on screen. |
| 🪄 **Translate to English** | One toggle turns about 99 languages into live English. A universal translation charm for your menu bar. |
| 🗨️ **Bilingual captions** | Keeps the original spoken line right above its English translation, so you read both at once. |
| 🎨 **Speaker colors and labels** | When more than one voice shows up, each speaker gets a distinct color *and* a spelled-out label (S1, S2). No sorting hat required, but same energy. |
| 🔢 **Manual speaker count** | Tell it how many people are talking, from a single voice on up, and it locks that count, so one voice never splinters into a rainbow. |
| ⚡ **Dual-engine routing** | Uses Apple's on-device SpeechAnalyzer where it's fastest and silently falls back to WhisperKit everywhere else. You never pick a wand, you just get the better one. |
| 🔒 **On-device, always** | Every word is transcribed and translated locally. No account, no cloud, no audio ever leaving your Mac. |
| ✍️ **Caption styling** | Dyslexia-friendly bundled fonts, high-contrast and warm-paper presets, a resizable overlay, and your choice of spelling (colour vs color). |

No subscriptions, no sign-up labyrinth. Two quick permissions and a flick of the wand, and the bla bla starts spelling itself out.

## ♿ Built for brains and ears that work differently

I made this for my own wiring, but disability is not one-size, and good captions are a secret passage into a lot of locked rooms. Blablacadabra was built so every choice opens *more* of them, not fewer.

### 🧠 If you have auditory processing disorder (like me)
This is the whole point. The gap between hearing and understanding gets filled with text instead of a panicked guess. You stop rationing your energy on "wait, what did they say?" and spend it on the actual conversation. Mishear something? Just read it. The thread is right there, kept for you.

### 🧏 If you're Deaf or hard of hearing
Most of your Mac doesn't come captioned, and the parts that do make you hunt for the button. Blablacadabra captions the *whole system*: the apps with no subtitle track, the live call, the website that never bothered, the voice note a friend sent. Speakers get distinct colors and labels so a group chat reads like a conversation, not one undifferentiated wall of words. And because every label is spelled out and never color alone, it still works perfectly if colors look the same to you.

### 📖 If you're dyslexic
Reading should help, not hand you a second puzzle. Captions render in dyslexia-friendly bundled fonts at a comfortable size, with high-contrast presets and a calm warm-paper background that cuts the glare. You pick the spelling convention (colour vs color) so the words look the way your eyes expect. Nothing flashes, nothing races, and you can resize the overlay and read at your own pace. Reading is allowed to take exactly the time it takes.

### 💭 If you just process best by reading
Plenty of people think more clearly with words on a screen, ND or not. Hearing a name once and reading it are not the same act of memory. Blablacadabra hands you the reading version of everything, so the meeting actually sticks.

### 🤝 Promises baked in all the way down
- **State is always in words and icons, never color alone.** Every color travels with a label riding shotgun.
- **One idea per sentence, literal over clever.** When the app talks to you, it says exactly what's happening and exactly what to do next. No idioms to decode mid-meeting.
- **Calm is the product.** Nothing flashes, nags, nudges, or sounds an alarm. Even when something breaks, Blablacadabra takes the blame and hands you the fix: never "your settings were misconfigured," always "I lost the audio for a sec, here's how to catch back up."

## 🔮 How it works with Apple's accessibility features

Blablacadabra doesn't reinvent your accessibility setup, it *listens* to the one you already trust. The moment you change a setting in **System Settings, Accessibility, Display**, the app notices and adjusts itself live, no restart, no second control panel to keep in sync.

- **Reduce Motion.** Turn it on and the captions stop animating. Lines appear and update without sliding or fading, so nothing moves on screen that you didn't ask to move.
- **Increase Contrast.** The app drops the per-speaker colors (the spelled-out S1, S2 labels stay, so you never lose track of who's talking) and forces the overlay to full, solid opacity for the sharpest possible read.
- **Reduce Transparency.** The caption overlay goes fully opaque instead of letting the desktop ghost through behind your words.
- **VoiceOver.** Every control is properly labeled, and speakers announce as "Speaker 1," "Speaker 2," and so on rather than as a bare color, so the whole app reads cleanly out loud.

The idea is simple: your accessibility preferences are a spell you already cast once. Blablacadabra just honors it instead of asking you to cast it again.

## 🚀 Getting started

It takes about as long as a decent incantation.

1. Download the latest `Blablacadabra.dmg` from [Releases](../../releases).
2. Open it and drag Blablacadabra into your Applications folder, like sliding a book onto the shelf.
3. First launch: right-click the app and choose **Open** (it's ad-hoc signed, so the Mac's gatekeeper asks once, nods, and waves you through).
4. Follow the two-step onboarding: grant audio access (the app only listens, it never records), optionally grant the mic so it can caption people in the room with you, and you're off.

The model downloads itself the first time it's needed. After that it's cached, and you can yank the network cable and Blablacadabra keeps right on writing.

**Requirements:** macOS 14 or later. Apple Silicon recommended (it's where the fast wand lives).

## 🤫 What Blablacadabra is *not*

It's not a recorder. It never saves your audio, never saves a transcript unless you ask, and never keeps a voiceprint of anyone. The speaker colors are conjured fresh each session by sound alone and forgotten the moment you stop. Blablacadabra tells voices apart, it never remembers *whose* voice it was. Privacy isn't a setting bolted on at the end, it's the foundation the whole tower stands on.

## 🔧 Under the hood (for the curious)

- Native macOS menu-bar app (SwiftUI + AppKit), `LSUIElement`, no Dock clutter.
- System audio capture via ScreenCaptureKit. On-device transcription via Apple SpeechAnalyzer with a WhisperKit fallback. On-device translation via Apple's Translation framework, with WhisperKit as the wide-net backup.
- Per-speaker diarization via FluidAudio (Apache-2.0), voice-embedding clustering, entirely local.
- Built with Swift Package Manager. `Scripts/make-app.sh` builds the release bundle; the `.dmg` is packaged from there.

## 📜 License

Blablacadabra is **proprietary, all rights reserved.** Copyright © 2026 lazyfoxjumps. The app is shared for personal use of the compiled application only, no copying, modifying, redistributing, or reverse engineering without written permission. The bundled open-source pieces (WhisperKit, FluidAudio) keep their own Apache-2.0 licenses. Full terms in [LICENSE](LICENSE).

---

<div align="center">

*For my next trick: every word anyone says, written down before it disappears.*

**Blablacadabra** · made by someone who kept mishearing, for everyone who's tired of guessing.

</div>

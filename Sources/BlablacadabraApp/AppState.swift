import AppKit
import BlablacadabraCore
import Combine
import CoreAudio
import ServiceManagement
import SwiftUI

enum CaptureSourceChoice: String, CaseIterable, Identifiable {
    case system, mic, both
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System audio"
        case .mic: return "Microphone"
        // Always shown beside the other two pills, so "Both" stays literal
        // and fits the panel width without truncating.
        case .both: return "Both"
        }
    }
}

/// Where a caption line came from. In "Both" mode the system-audio lane and the
/// mic lane run as separate pipelines (each detects and translates on its own,
/// so the video's language never bleeds into the room's), and lines carry which
/// lane produced them so the overlay can mark it. `.single` = any single-source
/// session, where there's nothing to disambiguate, so no marker is shown.
enum CaptionOrigin: Equatable {
    case single
    case system
    case mic

    /// SF Symbol shown before the line in Both mode (none for single).
    var symbol: String? {
        switch self {
        case .single: return nil
        case .system: return "speaker.wave.2.fill"
        case .mic: return "mic.fill"
        }
    }

    /// Spoken-word label for VoiceOver and tooltips (never color alone).
    var spokenLabel: String {
        switch self {
        case .single: return ""
        case .system: return "From system audio"
        case .mic: return "From the microphone"
        }
    }
}

/// One committed caption line. `original` holds the source-language text
/// shown above the translation in bilingual mode; nil otherwise. `origin`
/// marks which "Both"-mode lane produced it.
struct CaptionLine: Equatable {
    let text: String
    var original: String?
    var origin: CaptionOrigin = .single
    /// Per-session speaker label (Phase 6 diarization), nil when speaker colors
    /// are off or the voice hasn't been identified yet.
    var speaker: SpeakerID?
}

enum SessionPhase: Equatable {
    case idle
    case starting
    case listening
    case paused
    case permissionNeeded
    case trouble(String)
}

/// One object owns everything: persisted settings, the live caption session,
/// and theme resolution. Views observe it; controllers poke it.
@MainActor
final class AppState: ObservableObject {
    // MARK: Session

    @Published private(set) var phase: SessionPhase = .idle
    /// True while `.starting` involves a first-time model download (so the
    /// status can be honest about why the wait is long).
    @Published private(set) var startingNeedsDownload = false
    /// Download progress (0...1) while the speech model is being fetched,
    /// nil otherwise. Drives the percentage in the status line.
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var lines: [CaptionLine] = []
    @Published private(set) var partial: String?
    /// Which lane the live partial belongs to (Both mode), so a final from one
    /// lane doesn't wipe the other lane's in-progress partial.
    @Published private(set) var partialOrigin: CaptionOrigin = .single
    @Published private(set) var lastEventAt: Date?
    /// ISO 639-1 code of the language being translated FROM, detected live by
    /// the engine. Only surfaced while translating; reset each session.
    @Published private(set) var detectedLanguageCode: String?

    /// Live pipelines. One in single-source modes; two in "Both" (system + mic),
    /// each detecting and translating independently. Settings changes fan out to
    /// all of them. Each is a WhisperKit-backed `TranscriptionPipeline`, an Apple
    /// `SpeechAnalyzer` `AppleSpeechPipeline` (transcribe-only), or a
    /// `TranslatingPipeline` wrapping a Whisper transcriber + Apple text-translation;
    /// all conform to `CaptionPipeline` so AppState treats them identically.
    private var pipelines: [any CaptionPipeline] = []
    /// Which engine the live session runs on, decided once per session in
    /// `launchSession`.
    private var activeSessionEngine: CaptionEngineKind = .whisper
    /// Whether the live session is running on either Apple engine. Apple fixes its
    /// locale at init, so a spoken-language change must restart (vs Whisper's live,
    /// no-restart `setSpokenLanguage`).
    private var activeEngineIsApple: Bool { activeSessionEngine != .whisper }
    private var sessionTask: Task<Void, Never>?
    /// One stream-consume task per live lane; cancelled on teardown.
    private var sessionTasks: [Task<Void, Never>] = []
    private var sessionGeneration = 0
    /// The in-flight teardown of the previous session. A new session awaits it
    /// before creating its capture, so AVAudioEngine/SCStream never overlap
    /// (overlapping start/stop throws ObjC assertions that crash the app).
    private var teardownTask: Task<Void, Never>?
    /// Debounce for rapid setting changes (flipping model/source pills fast):
    /// coalesce into one restart instead of spawning overlapping sessions.
    private var restartTask: Task<Void, Never>?
    /// Prepared engines kept alive across restarts (per lane origin) so a source
    /// change or a pause/resume reuses the already-loaded model (near-instant)
    /// instead of reloading it (slow, and re-exposes the WhisperKit load stall).
    /// In "Both" mode each lane gets its OWN engine: separate WhisperKit
    /// instances run concurrently safely, whereas one shared instance can't
    /// transcribe two lanes at once. Entries are replaced when the model changes.
    private var preparedEngines: [CaptionOrigin: (model: String, engine: WhisperKitEngine)] = [:]

    /// The per-session voice labeler (Phase 6). One shared instance across all
    /// lanes so speaker numbering is global (S1 means one person whether they're
    /// on the system lane or the mic lane). Kept across restarts/pause so numbers
    /// don't churn when the user flips a pill; `reset()` only on a full stop.
    /// Per-lane voice labelers. Single-source mode keeps one entry (`.single`)
    /// clustering from Speaker 1. "Both" mode pins the mic lane to Speaker 1 (the
    /// user, recreated inline since it's stateless) and stores a `.system`
    /// clusterer that numbers the OTHER voices from Speaker 2 up. Kept across
    /// restart/pause so numbering stays stable; cluster state cleared on a full
    /// stop so the next session renumbers from the top.
    private var speakerIdentifiers: [CaptionOrigin: SpeakerIdentifier] = [:]
    /// Which speakers have actually been heard this session. Chips and colors
    /// stay off until a SECOND voice appears (so a one-person session looks
    /// exactly as it did before the feature existed).
    @Published private(set) var speakersSeen: Set<SpeakerID> = []

    // MARK: Audio devices (for the Audio settings section)

    /// Input devices available to the mic picker, refreshed when Settings opens
    /// and whenever the default input changes.
    @Published private(set) var inputDevices: [AudioDevice] = []
    /// Name of the current default output, and whether it's a known
    /// capture-breaking virtual device (foxpro), for the capture-health line.
    @Published private(set) var defaultOutputName: String?
    @Published private(set) var outputIsCaptureBreaking = false
    /// A transient line shown when a device auto-switch happens, so the change
    /// is never silent (ND rule). Cleared after a few seconds.
    @Published private(set) var audioDeviceNotice: String?

    /// Live input level (0...1) for the meter. Separate object so meter updates
    /// don't redraw the overlay/panel.
    let levelMonitor = AudioLevelMonitor()

    private var inputDeviceObserver: DefaultDeviceObserver?
    private var outputDeviceObserver: DefaultDeviceObserver?
    private var noticeClearTask: Task<Void, Never>?

    // MARK: Apple accessibility (system-wide settings, reflected live)

    /// Mirrors System Settings > Accessibility > Display. The app honors
    /// these everywhere: Reduce Motion kills crossfades and fades, Reduce
    /// Transparency and Increase Contrast force a fully opaque overlay, and
    /// Increase Contrast also pins captions to the max-contrast pair.
    @Published private(set) var reduceMotion = false
    @Published private(set) var reduceTransparency = false
    @Published private(set) var increaseContrast = false

    // MARK: Theme (resolved)

    @Published private(set) var isDark = true
    private var pendingIsDark: Bool?
    private var themeTimer: Timer?

    // MARK: Persisted settings

    private let defaults = UserDefaults.standard

    @Published var sourceChoice: CaptureSourceChoice {
        didSet {
            defaults.set(sourceChoice.rawValue, forKey: "sourceChoice")
            restartIfRunning()
        }
    }
    @Published var translate: Bool {
        didSet {
            defaults.set(translate, forKey: "translate")
            let task: TranscriptionTask = translate ? .translate : .transcribe
            eachPipeline { await $0.setTask(task) }
            // Turning translate off clears the "from" language; turning it on
            // waits for the next decode to detect it.
            detectedLanguageCode = nil
            // Translate decides the engine (ON forces WhisperKit; OFF lets the
            // Apple fast-path back in), so a flip while running must re-evaluate
            // and rebuild. The live setTask above covers the brief debounce gap.
            restartIfRunning()
        }
    }
    /// Locked spoken language (ISO 639-1), or nil for auto-detect. When set,
    /// the engine never runs language detection: it forces this language on
    /// every decode. This is the fix for an English speaker getting random
    /// Japanese/Russian captions, and it shaves a model pass for speed. Applies
    /// mid-stream, no restart needed.
    @Published var spokenLanguageCode: String? {
        didSet {
            defaults.set(spokenLanguageCode, forKey: "spokenLanguage")
            eachPipeline { [code = spokenLanguageCode] in await $0.setSpokenLanguage(code) }
            // The chip should reflect the locked choice immediately, not the
            // stale auto-detected one.
            if spokenLanguageCode != nil { detectedLanguageCode = nil }
            // Apple fixes its locale at transcriber init (the live fan-out above
            // is a no-op there), and a new lock may even flip Apple<->Whisper
            // support, so restart to re-resolve the locale and re-pick the engine.
            // Also restart when translating: a fresh lock can promote a Whisper
            // translate session to the Apple translate fast-path (it needs a known
            // source language). Plain Whisper transcribe keeps its live, no-restart
            // behavior.
            if activeEngineIsApple || translate { restartIfRunning() }
        }
    }
    /// Bilingual captions: show the original language above the English while
    /// translating. Applies mid-stream; only does anything when translate is on.
    @Published var showOriginal: Bool {
        didSet {
            defaults.set(showOriginal, forKey: "showOriginal")
            eachPipeline { [show = showOriginal] in await $0.setShowOriginal(show) }
        }
    }
    @Published var model: String {
        didSet {
            defaults.set(model, forKey: "model")
            restartIfRunning()
        }
    }
    /// Chosen microphone device uid, or nil to follow the system default
    /// ("Automatic"). Persisted per-uid so it survives unplug/replug. Only
    /// matters when the source includes the mic; a change restarts capture.
    @Published var micDeviceUID: String? {
        didSet {
            defaults.set(micDeviceUID, forKey: "micDevice")
            restartIfRunning()
        }
    }
    /// Linear input gain for soft voices (1.0 = unchanged). Applies live to the
    /// running pipeline; no restart.
    @Published var inputGain: Double {
        didSet {
            defaults.set(inputGain, forKey: "inputGain")
            eachPipeline { [gain = Float(inputGain)] in await $0.setInputGain(gain) }
        }
    }
    /// Display English variant. Whisper has no regional switch, so this is a
    /// spelling pass on caption text today; the stored locale id is ready for
    /// locale-aware engines later. Already-committed lines are left alone
    /// (never reflow text someone may still be reading).
    @Published var captionLocale: EnglishLocale {
        didSet {
            defaults.set(captionLocale.rawValue, forKey: "captionLocale")
            normalizer = SpellingNormalizer(locale: captionLocale)
        }
    }
    private var normalizer: SpellingNormalizer
    @Published var themeMode: ThemeMode {
        didSet {
            defaults.set(themeMode.rawValue, forKey: "themeMode")
            refreshTheme()
        }
    }
    @Published var fontChoice: FontChoice {
        didSet { defaults.set(fontChoice.rawValue, forKey: "fontChoice") }
    }
    @Published var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: "fontSize") }
    }
    @Published var previousLines: Int {
        didSet { defaults.set(previousLines, forKey: "previousLines") }
    }
    @Published var overlayOpacity: Double {
        didSet { defaults.set(overlayOpacity, forKey: "overlayOpacity") }
    }
    /// User-set width of the caption card. The card is resizable by dragging its
    /// edge; height always hugs the content. Never goes below `overlayMinWidth`
    /// (the original fixed size, the smallest it's allowed to get).
    @Published var overlayWidth: Double {
        didSet { defaults.set(overlayWidth, forKey: "overlayWidth") }
    }
    /// The smallest the caption card may be sized to (its original fixed width).
    static let overlayMinWidth: Double = 600
    @Published var calmMode: Bool {
        didSet { defaults.set(calmMode, forKey: "calmMode") }
    }
    /// "Color by speaker": each voice gets its own caption color + chip. ON by
    /// default for source = System or Both (the multi-voice cases); a mic-only
    /// session is one person, so it defaults off there. Flipping it mid-session
    /// restarts so the diarizer is added or dropped.
    @Published var colorBySpeaker: Bool {
        didSet {
            defaults.set(colorBySpeaker, forKey: "colorBySpeaker")
            restartIfRunning()
        }
    }
    /// How many people the user expects on the call, or 0 for "Auto" (let the
    /// clusterer figure it out, today's behavior). A known count is the real fix
    /// for the over-clustering bug: when it implies exactly one voice on a lane
    /// (e.g. "2 people" in Both = you + one other), that lane stops thresholding
    /// and pins everyone to a single speaker, so one voice can never fragment
    /// into S2/S3/S+ on noisy call audio. Changing it rebuilds the labelers, so
    /// numbering restarts cleanly.
    @Published var expectedSpeakerCount: Int {
        didSet {
            defaults.set(expectedSpeakerCount, forKey: "expectedSpeakerCount")
            speakerIdentifiers.removeAll() // rebuild with the new per-lane caps
            restartIfRunning()
        }
    }
    @Published var hideOnSilence: Bool {
        didSet { defaults.set(hideOnSilence, forKey: "hideOnSilence") }
    }
    @Published var clickThrough: Bool {
        didSet { defaults.set(clickThrough, forKey: "clickThrough") }
    }
    @Published var captionPresetID: String {
        didSet { defaults.set(captionPresetID, forKey: "captionPresetID") }
    }
    @Published var customTextHex: String {
        didSet { defaults.set(customTextHex, forKey: "customTextHex") }
    }
    @Published var customBackgroundHex: String {
        didSet { defaults.set(customBackgroundHex, forKey: "customBackgroundHex") }
    }
    @Published var useLocationForSun: Bool {
        didSet {
            defaults.set(useLocationForSun, forKey: "useLocationForSun")
            if useLocationForSun { LocationProvider.shared.requestFix() }
            refreshTheme()
        }
    }
    @Published var hasOnboarded: Bool {
        didSet { defaults.set(hasOnboarded, forKey: "hasOnboarded") }
    }

    /// Launch-at-login, backed by SMAppService (the system is the source of
    /// truth, not UserDefaults; the user can also flip it in System Settings
    /// > General > Login Items and we just reflect it).
    @Published var launchAtLogin: Bool {
        didSet {
            guard !revertingLaunchAtLogin, launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Registration can fail for an unbundled dev build; reflect
                // reality instead of showing a toggle that lies.
                revertingLaunchAtLogin = true
                launchAtLogin = SMAppService.mainApp.status == .enabled
                revertingLaunchAtLogin = false
            }
        }
    }
    private var revertingLaunchAtLogin = false

    init() {
        sourceChoice = CaptureSourceChoice(rawValue: defaults.string(forKey: "sourceChoice") ?? "") ?? .system
        translate = defaults.bool(forKey: "translate")
        // Absent key = nil = auto-detect (the default).
        spokenLanguageCode = defaults.string(forKey: "spokenLanguage")
        // Migrate the old "base" default (removed in 0.6.1) and any gone
        // variant to a currently-offered model, so the slider is never empty.
        model = WhisperKitEngine.migratedModel(fromStored: defaults.string(forKey: "model"))
        micDeviceUID = defaults.string(forKey: "micDevice")
        inputGain = defaults.object(forKey: "inputGain") as? Double ?? 1.0
        let storedLocale = EnglishLocale(rawValue: defaults.string(forKey: "captionLocale") ?? "") ?? .us
        captionLocale = storedLocale
        normalizer = SpellingNormalizer(locale: storedLocale)
        showOriginal = defaults.bool(forKey: "showOriginal")
        themeMode = ThemeMode(rawValue: defaults.string(forKey: "themeMode") ?? "") ?? .system
        fontChoice = FontChoice(rawValue: defaults.string(forKey: "fontChoice") ?? "") ?? .nunito
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 21
        previousLines = defaults.object(forKey: "previousLines") as? Int ?? 2
        overlayOpacity = defaults.object(forKey: "overlayOpacity") as? Double ?? 0.9
        overlayWidth = max(AppState.overlayMinWidth, defaults.object(forKey: "overlayWidth") as? Double ?? AppState.overlayMinWidth)
        calmMode = defaults.bool(forKey: "calmMode")
        // Default ON for the multi-voice sources (System/Both), off for mic-only
        // (one person). Read the source from defaults again (can't touch
        // `self.sourceChoice` until every stored property is initialized).
        let storedSource = CaptureSourceChoice(rawValue: defaults.string(forKey: "sourceChoice") ?? "") ?? .system
        colorBySpeaker = (defaults.object(forKey: "colorBySpeaker") as? Bool) ?? (storedSource != .mic)
        expectedSpeakerCount = defaults.object(forKey: "expectedSpeakerCount") as? Int ?? 0 // 0 = Auto
        hideOnSilence = defaults.bool(forKey: "hideOnSilence")
        clickThrough = defaults.bool(forKey: "clickThrough")
        captionPresetID = defaults.string(forKey: "captionPresetID") ?? "theme"
        customTextHex = defaults.string(forKey: "customTextHex") ?? "#EEE9DF"
        customBackgroundHex = defaults.string(forKey: "customBackgroundHex") ?? "#1B2632"
        useLocationForSun = defaults.bool(forKey: "useLocationForSun")
        hasOnboarded = defaults.bool(forKey: "hasOnboarded")
        launchAtLogin = SMAppService.mainApp.status == .enabled

        isDark = resolveIsDark()
        refreshAccessibility()

        // Accessibility display options (Reduce Motion/Transparency,
        // Increase Contrast) apply the moment the user flips them.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAccessibility() }
        }

        // System appearance flips arrive here; Sun mode is re-checked on a
        // slow timer (sunrise doesn't sneak up on anyone).
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshTheme() }
        }
        themeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTheme() }
        }
        LocationProvider.shared.onUpdate = { [weak self] in
            Task { @MainActor in self?.refreshTheme() }
        }

        refreshAudioDevices()
        // Surface device auto-switches and refresh the picker / capture-health
        // line whenever the system default input or output changes.
        inputDeviceObserver = DefaultDeviceObserver(selector: kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
            Task { @MainActor in self?.handleDefaultInputChange() }
        }
        outputDeviceObserver = DefaultDeviceObserver(selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            Task { @MainActor in self?.refreshAudioDevices() }
        }
    }

    // MARK: - Session control

    var isRunning: Bool {
        switch phase {
        case .starting, .listening: return true
        default: return false
        }
    }

    func startCaptions() {
        guard !isRunning else { return }
        launchSession()
    }

    /// Resolves which engine this session runs on, running the async availability
    /// / install / authorization probes once. Short-circuits before the Speech
    /// permission prompt whenever Apple couldn't be used anyway (unsupported
    /// locale, or translate without a locked + installed pair), so we never nag
    /// for a session that would fall back to WhisperKit. `forceWhisper` skips
    /// Apple entirely (used when an Apple start already failed this session and
    /// we're retrying on the fallback).
    private func resolveEngine(forceWhisper: Bool) async -> CaptionEngineKind {
        guard !forceWhisper else { return .whisper }
        guard #available(macOS 26, *) else { return .whisper }

        let locale = AppleSpeechLocale.resolved(
            spokenLanguage: spokenLanguageCode,
            englishLocale: captionLocale
        )
        let languageLocked = (spokenLanguageCode?.isEmpty == false)

        if translate {
            // Translate path: WhisperKit transcribes the LOCKED source (reliable for
            // non-English, unlike Apple's narrow speech assets) and Apple text-
            // translates source->English. Needs a locked, non-denylisted source with
            // an already-installed pack (no download = no nag). It does NOT need Apple
            // speech support or the Speech permission (Whisper transcribes), so we
            // never probe `isSupported` or trigger the auth prompt for a session
            // Whisper will run anyway. Any miss -> WhisperKit's universal audio-translate.
            guard languageLocked, let iso = AppleSpeechLocale.isoCode(for: locale) else { return .whisper }
            // Languages where Whisper translates better than Apple stay on Whisper
            // (e.g. id: Apple leans Malay). Skip the install probe entirely for them.
            guard !CaptionEngineKind.appleTranslateDenylist.contains(iso) else { return .whisper }
            let translationInstalled = await AppleTranslationService.isInstalled(sourceISOCode: iso)
            return CaptionEngineKind.select(
                translate: true,
                localeSupported: false, // unused on the translate path (Whisper transcribes)
                authorized: false,      // unused on the translate path
                osHasApple: true,
                languageLocked: languageLocked,
                translationInstalled: translationInstalled,
                sourceISOCode: iso
            )
        }

        // Transcribe path: Apple `SpeechAnalyzer` fast-path when the locale is
        // supported and Speech is authorized; otherwise WhisperKit.
        guard await AppleSpeechPipeline.isSupported(locale) else { return .whisper }
        let authorized = await AppleSpeechPipeline.requestAuthorization()
        return CaptionEngineKind.select(
            translate: false,
            localeSupported: true,
            authorized: authorized,
            osHasApple: true
        )
    }

    /// Starts a session unconditionally (the public `startCaptions` guards
    /// against double-start; restart and resume come straight here). Reuses the
    /// prepared engine(s) when the model is unchanged, and waits for any
    /// in-flight teardown so the old capture is fully gone before the new opens.
    ///
    /// "Both" runs two lanes (system + mic) as separate pipelines so each
    /// detects/translates on its own; the lanes start sequentially so a
    /// first-run model download happens once (the second lane then loads it from
    /// cache) and two model loads never collide.
    private func launchSession(forceWhisper: Bool = false) {
        sessionGeneration += 1
        let generation = sessionGeneration
        startingNeedsDownload = !WhisperKitEngine.isModelCached(model)
        downloadProgress = nil
        phase = .starting
        partial = nil
        partialOrigin = .single
        detectedLanguageCode = nil

        let configs = laneConfigs()
        let pendingTeardown = teardownTask
        pipelines = []
        sessionTasks = []

        sessionTask = Task { [weak self] in
            guard let self else { return }
            // Never overlap captures: let the previous session's stop() finish.
            await pendingTeardown?.value
            guard self.sessionGeneration == generation else { return }

            // Decide the engine once for the whole session (both lanes match).
            let engineKind = await self.resolveEngine(forceWhisper: forceWhisper)
            guard self.sessionGeneration == generation else { return }
            self.activeSessionEngine = engineKind
            if engineKind == .appleTranscribe {
                // Apple's transcribe models are OS-resident: English is instant
                // (zero download); only an on-demand locale reports install progress
                // via the per-lane installProgress closure below. The
                // whisperAppleTranslate path still uses a WhisperKit transcriber, so
                // it keeps the normal download/load progress UX.
                self.startingNeedsDownload = false
                self.downloadProgress = nil
            }

            // Attaches the download/load progress handler to a lane-0 WhisperKit
            // engine (lane 1 reuses the now-cached model and no-ops prepare()).
            // Used by the plain Whisper path and the whisperAppleTranslate inner.
            // Honest waiting: percentage while downloading, then "warming up" when
            // the CoreML compile starts.
            func attachWhisperProgress(_ engine: WhisperKitEngine, laneIndex: Int) async {
                guard laneIndex == 0 else { return }
                await engine.setPrepareHandler { [weak self] event in
                    Task { @MainActor in
                        guard let self, self.sessionGeneration == generation else { return }
                        switch event {
                        case .downloading(let fraction):
                            self.startingNeedsDownload = true
                            self.downloadProgress = fraction
                        case .loading:
                            self.startingNeedsDownload = false
                            self.downloadProgress = nil
                        }
                    }
                }
            }

            var started: [any CaptionPipeline] = []
            do {
                for (laneIndex, config) in configs.enumerated() {
                    let pipeline: any CaptionPipeline
                    switch engineKind {
                    case .appleTranscribe:
                        guard #available(macOS 26, *) else { throw AppleSpeechUnavailable.localeUnsupported }
                        let locale = AppleSpeechLocale.resolved(
                            spokenLanguage: self.spokenLanguageCode,
                            englishLocale: self.captionLocale
                        )
                        // Only lane 0 reports asset-install progress (the one that
                        // would download; lane 1 reuses the now-present asset).
                        var installProgress: (@Sendable (Double) -> Void)?
                        if laneIndex == 0 {
                            installProgress = { [weak self] fraction in
                                Task { @MainActor in
                                    guard let self, self.sessionGeneration == generation else { return }
                                    if fraction >= 1 {
                                        self.startingNeedsDownload = false
                                        self.downloadProgress = nil
                                    } else {
                                        self.startingNeedsDownload = true
                                        self.downloadProgress = fraction
                                    }
                                }
                            }
                        }
                        // Transcribe-only (translate off): Apple SpeechAnalyzer.
                        pipeline = AppleSpeechPipeline(
                            source: config.source,
                            locale: locale,
                            inputGain: Float(self.inputGain),
                            speakerIdentifier: self.activeSpeakerIdentifier(for: config.origin),
                            installProgress: installProgress
                        )

                    case .whisperAppleTranslate:
                        guard #available(macOS 26, *) else { throw AppleSpeechUnavailable.translationUnavailable }
                        let locale = AppleSpeechLocale.resolved(
                            spokenLanguage: self.spokenLanguageCode,
                            englishLocale: self.captionLocale
                        )
                        let iso = AppleSpeechLocale.isoCode(for: locale)
                        let engine = self.engine(for: config.origin)
                        await attachWhisperProgress(engine, laneIndex: laneIndex)
                        // Inner transcribes the LOCKED source language (the reliable
                        // half); the decorator text-translates each final to English,
                        // and owns bilingual (so the inner's `original` stays off).
                        let inner = TranscriptionPipeline(
                            source: config.source,
                            engine: engine,
                            task: .transcribe,
                            spokenLanguage: self.spokenLanguageCode,
                            showOriginal: false,
                            inputGain: Float(self.inputGain),
                            speakerIdentifier: self.activeSpeakerIdentifier(for: config.origin)
                        )
                        pipeline = TranslatingPipeline(
                            inner: inner,
                            translator: AppleTranslationService(sourceISOCode: iso ?? "en"),
                            sourceISO: iso,
                            showOriginal: self.showOriginal
                        )

                    case .whisper:
                        let engine = self.engine(for: config.origin)
                        await attachWhisperProgress(engine, laneIndex: laneIndex)
                        pipeline = TranscriptionPipeline(
                            source: config.source,
                            engine: engine,
                            task: self.translate ? .translate : .transcribe,
                            spokenLanguage: self.spokenLanguageCode,
                            showOriginal: self.showOriginal,
                            inputGain: Float(self.inputGain),
                            speakerIdentifier: self.activeSpeakerIdentifier(for: config.origin)
                        )
                    }
                    // Drive the live input level meter off the (gain-applied)
                    // audio tap. The monitor is its own object so this doesn't
                    // churn the overlay/panel. Both lanes feed it; the meter's
                    // peak-decay naturally shows whichever is louder.
                    let monitor = self.levelMonitor
                    await pipeline.setAudioTap { samples in
                        guard !samples.isEmpty else { return }
                        var sum: Float = 0
                        for sample in samples { sum += sample * sample }
                        let rms = (sum / Float(samples.count)).squareRoot()
                        Task { @MainActor in monitor.report(rms: rms) }
                    }
                    // Sequential start: lane 0 fully prepares (download + load)
                    // before lane 1, so a first-run download happens once.
                    let stream = try await pipeline.start()
                    guard self.sessionGeneration == generation else {
                        await pipeline.stop()
                        for p in started { await p.stop() }
                        return
                    }
                    started.append(pipeline)
                    self.pipelines = started
                    if self.phase != .listening { self.phase = .listening }

                    let origin = config.origin
                    let soleLane = configs.count == 1
                    let consume = Task { [weak self] in
                        for await event in stream {
                            guard let self, self.sessionGeneration == generation else { break }
                            self.handle(event, origin: origin)
                        }
                        // A lane ending on its own (source died) is only a
                        // session-level "lost the audio" when it's the only lane.
                        if let self, self.sessionGeneration == generation,
                           self.phase == .listening, soleLane {
                            self.phase = .trouble("I lost the audio. Press start and I'll pick right back up.")
                        }
                    }
                    self.sessionTasks.append(consume)
                }
            } catch let appleError as AppleSpeechUnavailable {
                // Apple couldn't actually start (asset install / format). Tear down
                // and retry the whole session on WhisperKit, silently, so the user
                // keeps captions. If even the fallback is what failed, surface it.
                guard self.sessionGeneration == generation else { return }
                for p in started { await p.stop() }
                for task in self.sessionTasks { task.cancel() }
                self.sessionTasks = []
                self.pipelines = []
                self.activeSessionEngine = .whisper
                if forceWhisper {
                    self.phase = .trouble(Self.friendlyMessage(for: appleError))
                } else {
                    self.launchSession(forceWhisper: true)
                }
            } catch AudioCaptureError.screenRecordingPermissionDenied {
                guard self.sessionGeneration == generation else { return }
                for p in started { await p.stop() }
                self.phase = .permissionNeeded
            } catch {
                guard self.sessionGeneration == generation else { return }
                for p in started { await p.stop() }
                self.phase = .trouble(Self.friendlyMessage(for: error))
            }
        }
    }

    /// The lanes for the current source: one for single sources (origin
    /// `.single`, no marker), two for "Both" (system + mic, each marked).
    private func laneConfigs() -> [(origin: CaptionOrigin, source: AudioSource)] {
        switch sourceChoice {
        case .system: return [(.single, SystemAudioCapture())]
        case .mic: return [(.single, MicCapture(preferredDeviceUID: micDeviceUID))]
        case .both: return [
            (.system, SystemAudioCapture()),
            (.mic, MicCapture(preferredDeviceUID: micDeviceUID)),
        ]
        }
    }

    /// The voice labeler for a lane, created on first use (so a session that
    /// never turns on speaker colors pays nothing). Returns nil when the feature
    /// is off.
    ///
    /// - `.mic` (only ever the mic lane of a "Both" session) is pinned to
    ///   Speaker 1: it's the user, so there's nothing to cluster. This keeps the
    ///   user's own voice out of the system lane's (noisier) clustering job and
    ///   guarantees "you" one stable color.
    /// - `.system` (Both) clusters the remaining voices starting at Speaker 2,
    ///   so your S1 and the call's first voice never collide.
    /// - `.single` clusters everyone from Speaker 1 (no separate mic lane to be
    ///   sure who "you" is).
    private func activeSpeakerIdentifier(for origin: CaptionOrigin) -> SpeakerIdentifying? {
        guard colorBySpeaker else { return nil }
        if origin == .mic { return PinnedSpeakerIdentifier(.speaker(1)) }
        if let existing = speakerIdentifiers[origin] { return existing }
        let isSystemLane = origin == .system
        let created = SpeakerIdentifier(
            maxSpeakers: laneSpeakerSlots(isSystemLane: isSystemLane),
            firstSpeakerNumber: isSystemLane ? 2 : 1, // leave S1 for the user (the mic)
            diagnostics: diarizationDiagnostics(label: isSystemLane ? "system" : "single")
        )
        speakerIdentifiers[origin] = created
        return created
    }

    /// How many distinct speakers a lane's clusterer may hold, from the user's
    /// expected count. The `.system` lane of "Both" mode excludes the user (they
    /// own the pinned mic S1), so it holds `count - 1`; a single-source lane
    /// holds the whole count. `slots == 1` makes the clusterer collapse to one
    /// no-threshold speaker — the bulletproof path for the common 2-person call.
    /// Auto (count 0) keeps the prior defaults.
    private func laneSpeakerSlots(isSystemLane: Bool) -> Int {
        guard expectedSpeakerCount > 0 else { return isSystemLane ? 3 : 4 } // Auto
        let others = isSystemLane ? expectedSpeakerCount - 1 : expectedSpeakerCount
        return min(6, max(1, others)) // cap at the palette's distinct-color budget
    }

    /// The opt-in diarization diagnostics sink, or nil when the hidden
    /// `diagnosticsDiarizationLog` default is off. Lets a live call record the
    /// real per-utterance similarity spread (to tune the merge threshold off
    /// actual call audio, not the clean spike). Writes to
    /// `~/Library/Logs/Blablacadabra/diarization.log` (numbers only, no text).
    private func diarizationDiagnostics(label: String) -> DiarizationDiagnostics? {
        guard UserDefaults.standard.bool(forKey: "diagnosticsDiarizationLog") else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Blablacadabra/diarization.log")
        return DiarizationDiagnostics(url: url, label: label)
    }

    /// A prepared engine for a lane, reused while the model is unchanged. Each
    /// lane origin keeps its own (Both mode needs two live instances).
    private func engine(for origin: CaptionOrigin) -> WhisperKitEngine {
        if let cached = preparedEngines[origin], cached.model == model {
            return cached.engine
        }
        let engine = WhisperKitEngine(model: model)
        preparedEngines[origin] = (model, engine)
        return engine
    }

    /// Apply a change to every live pipeline (one lane, or both lanes in Both
    /// mode). No-op when nothing is running.
    private func eachPipeline(_ body: @escaping (any CaptionPipeline) async -> Void) {
        let ps = pipelines
        guard !ps.isEmpty else { return }
        Task { for pipeline in ps { await body(pipeline) } }
    }

    /// Stop and clear: captions are off, overlay goes away.
    func stopCaptions() {
        endSession(newPhase: .idle)
        lines = []
        partial = nil
        // A full stop ends the session: clear the voice clusters so the next
        // start renumbers from Speaker 1 (restart/pause keep them, on purpose).
        speakersSeen = []
        for identifier in speakerIdentifiers.values {
            Task { await identifier.reset() }
        }
    }

    /// Pause keeps the last lines on screen, per the design kit.
    func pauseCaptions() {
        guard isRunning else { return }
        endSession(newPhase: .paused)
    }

    func resumeCaptions() {
        guard phase == .paused else { return }
        startCaptions()
    }

    func toggleCaptions() {
        if isRunning {
            pauseCaptions()
        } else {
            startCaptions()
        }
    }

    private func endSession(newPhase: SessionPhase) {
        sessionGeneration += 1
        let ending = pipelines
        pipelines = []
        for task in sessionTasks { task.cancel() }
        sessionTasks = []
        sessionTask = nil
        downloadProgress = nil
        phase = newPhase
        partialOrigin = .single
        levelMonitor.reset()
        // Track the teardown so the next session can await it (no overlap).
        teardownTask = Task { for pipeline in ending { await pipeline.stop() } }
    }

    /// A model or source change while running restarts the session. Debounced
    /// so flipping pills quickly coalesces into one restart, and the teardown
    /// is awaited (via launchSession) before the new capture opens, so audio
    /// engines never overlap. NOTE: this no longer routes through the guarded
    /// `startCaptions()` (which would early-return because `.starting` counts as
    /// running, leaving the app stuck on "Warming up" forever, the old bug).
    private func restartIfRunning() {
        guard isRunning else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled, self.isRunning else { return }
            self.endSession(newPhase: .starting)
            self.launchSession()
        }
    }

    // MARK: - Audio devices (Audio settings section)

    /// Re-read the input device list and the default-output capture-health
    /// state. Called on init, when Settings opens, and on device changes.
    func refreshAudioDevices() {
        inputDevices = AudioDevices.inputDevices()
        let output = AudioDevices.defaultOutputDevice()
        defaultOutputName = output?.name
        outputIsCaptureBreaking = output.map(AudioDevices.isCaptureBreaking) ?? false
    }

    /// Default input device changed under us. Refresh the list, and if we're
    /// following the system default (mic in use, no specific device pinned),
    /// surface a calm "Switched to <name>" notice so it's never silent.
    private func handleDefaultInputChange() {
        refreshAudioDevices()
        guard micDeviceUID == nil, sourceChoice != .system,
              let name = AudioDevices.defaultInputDevice()?.name else { return }
        showAudioDeviceNotice("Switched to \(name)")
    }

    private func showAudioDeviceNotice(_ text: String) {
        audioDeviceNotice = text
        noticeClearTask?.cancel()
        noticeClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.audioDeviceNotice = nil
        }
    }

    private func handle(_ event: CaptionEvent, origin: CaptionOrigin) {
        lastEventAt = Date()
        switch event {
        case .partial(let text, let language, _):
            // Partials get the same spelling pass as finals so a word never
            // visibly flips form ("color" -> "colour") at the commit.
            partial = normalizer.normalize(text)
            partialOrigin = origin
            noteDetectedLanguage(language)
        case .final(let text, let original, let language, let speaker):
            // Only clear the partial if it was this lane's; the other Both-mode
            // lane may still have a live partial we shouldn't wipe.
            if partialOrigin == origin { partial = nil }
            if let speaker { speakersSeen.insert(speaker) }
            // Normalize the English headline; leave the original untouched
            // (it's foreign-language text, not English to re-spell).
            lines.append(CaptionLine(
                text: normalizer.normalize(text), original: original, origin: origin, speaker: speaker))
            noteDetectedLanguage(language)
            if lines.count > 8 { lines.removeFirst(lines.count - 8) }
            applyPendingThemeIfQuiet()
        }
    }

    /// Remembers the detected source language so the status can read
    /// "Indonesian -> English (US)" while translating and the language chip can
    /// show what's being heard even in plain transcription. Only updates on an
    /// actual change (a quiet decode reporting the same language shouldn't
    /// churn), and never overrides a manually locked language.
    private func noteDetectedLanguage(_ code: String?) {
        guard spokenLanguageCode == nil, let code, code != detectedLanguageCode else { return }
        detectedLanguageCode = code
    }

    /// What the language chip shows: the locked language by name, or in auto
    /// mode "Auto" (with the detected language appended once it's known).
    var spokenLanguageDisplay: String {
        if let code = spokenLanguageCode {
            return SpokenLanguage.displayName(forCode: code) ?? "Auto"
        }
        // Not translating, no lock: auto-detect is translate-only, so plain
        // transcription always runs in the chosen English variant. Name that
        // variant outright ("English (Australia)") instead of a vague
        // "Auto · English" so the chip says exactly what's on screen.
        if !translate {
            return captionLocale.label
        }
        if let detected = SpokenLanguage.displayName(forCode: detectedLanguageCode) {
            return "Auto · \(detected)"
        }
        return "Auto"
    }

    private static func friendlyMessage(for error: Error) -> String {
        if case TranscriptionError.modelLoadFailed = error {
            return "I couldn't get the speech model ready (the first run downloads it, which needs internet). Check the connection and press start again."
        }
        return "Something on my side didn't work. Press start and I'll try again."
    }

    // MARK: - Status line (words + icon, never color alone)

    var statusText: String {
        switch phase {
        case .idle:
            return "Captions off"
        case .starting:
            if startingNeedsDownload {
                if let progress = downloadProgress, progress > 0 {
                    return "Downloading the speech model · \(Int(progress * 100))% · first time only"
                }
                return "Downloading the speech model · first time only, this can take a few minutes"
            }
            return "Warming up · getting the model ready"
        case .listening:
            guard translate else { return "Listening · \(sourceChoice.label)" }
            // Show the direction ("Indonesian → English (US)") as soon as we know
            // the source: a locked language is known immediately (and is required
            // for the Apple translate path), otherwise once auto-detect names it.
            // Until then, the honest generic ("Translating to English (US)").
            let fromCode = detectedLanguageCode ?? spokenLanguageCode
            if let from = SpokenLanguage.displayName(forCode: fromCode) {
                return "\(from) → \(captionLocale.label) · \(sourceChoice.label)"
            }
            return "Translating to \(captionLocale.label) · \(sourceChoice.label)"
        case .paused:
            return "Paused · last lines kept"
        case .permissionNeeded:
            return "Captions stopped · permission needed"
        case .trouble:
            return "Captions stopped · small hiccup"
        }
    }

    var statusSymbol: String {
        switch phase {
        case .idle: return "moon.zzz"
        case .starting: return "hourglass"
        case .listening: return translate ? "globe" : "waveform"
        case .paused: return "pause.circle"
        case .permissionNeeded: return "lock.shield"
        case .trouble: return "bandage"
        }
    }

    // MARK: - Theme resolution

    var theme: ResolvedTheme { ResolvedTheme(isDark: isDark) }

    /// Effective caption colors after preset/custom/theme resolution.
    var captionColors: (text: RGB, background: RGB) {
        // System "Increase contrast" outranks any chosen preset: pin to the
        // highest-contrast pair the palette has for the current mode.
        if increaseContrast {
            return isDark
                ? (RGB(hexString: "#EEE9DF")!, RGB(hexString: "#1B2632")!)
                : (RGB(hexString: "#1B2632")!, RGB(hexString: "#F7F4EC")!)
        }
        if captionPresetID == "custom",
           let text = RGB(hexString: customTextHex),
           let background = RGB(hexString: customBackgroundHex) {
            return (text, background)
        }
        if let preset = CaptionPreset.vetted.first(where: { $0.id == captionPresetID }),
           let text = preset.text, let background = preset.background {
            return (text, background)
        }
        return (theme.captionText, theme.captionBackground)
    }

    // MARK: - Speaker colors (Phase 6)

    /// Whether to show the leading speaker chip on caption lines. Stays off
    /// until a SECOND distinct voice has been heard, so a one-person session
    /// looks exactly as it did before the feature existed.
    var showSpeakerLabels: Bool {
        colorBySpeaker && speakersSeen.count > 1
    }

    /// Whether speaker COLOR (not just the chip) is applied. System "Increase
    /// contrast" pins captions to one max-contrast pair, which disables the
    /// colors; the chip stays as the non-color signal.
    var speakerColorsEnabled: Bool {
        showSpeakerLabels && !increaseContrast
    }

    /// The caption text color for a given speaker. Falls back to the base
    /// caption text when colors are off, the speaker is unknown, or the speaker
    /// index runs past the available distinct colors (the chip disambiguates).
    func speakerColor(for speaker: SpeakerID?) -> RGB {
        let base = captionColors.text
        guard speakerColorsEnabled, let speaker else { return base }
        let palette = SpeakerPalette.colors(text: base, background: captionColors.background)
        switch speaker {
        case .speaker(let n):
            // 1-based: Speaker 1 is the base text color (palette index 0).
            return palette[min(max(0, n - 1), palette.count - 1)]
        case .other:
            return palette.last ?? base
        }
    }

    /// The chip color for a speaker. Same as the text color when colors are on;
    /// drops to the base text (a plain monochrome "S1" label) when Increase
    /// Contrast is on, so the chip never reintroduces color the user turned off.
    func speakerChipColor(for speaker: SpeakerID?) -> RGB {
        speakerColorsEnabled ? speakerColor(for: speaker) : captionColors.text
    }

    /// Theme changes never land mid-speech: if an utterance is in flight the
    /// new look waits for the next pause, then crossfades (design kit rule).
    func refreshTheme() {
        let target = resolveIsDark()
        guard target != isDark else {
            pendingIsDark = nil
            return
        }
        if partial != nil {
            pendingIsDark = target
        } else {
            crossfade(to: target)
        }
    }

    private func applyPendingThemeIfQuiet() {
        guard let pending = pendingIsDark, partial == nil else { return }
        pendingIsDark = nil
        crossfade(to: pending)
    }

    private func crossfade(to dark: Bool) {
        if reduceMotion {
            isDark = dark
            return
        }
        withAnimation(.easeInOut(duration: 1.4)) {
            isDark = dark
        }
    }

    // MARK: - Accessibility

    /// Overlay background opacity, with the system transparency/contrast
    /// settings outranking the user's slider.
    var effectiveOverlayOpacity: Double {
        (reduceTransparency || increaseContrast) ? 1.0 : overlayOpacity
    }

    private func refreshAccessibility() {
        let workspace = NSWorkspace.shared
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
    }

    private func resolveIsDark() -> Bool {
        switch themeMode {
        case .dark:
            return true
        case .light:
            return false
        case .system:
            let appearance = NSApp?.effectiveAppearance
                ?? NSAppearance.currentDrawing()
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        case .sun:
            let coordinate = (useLocationForSun ? LocationProvider.shared.savedCoordinate : nil)
                ?? SolarClock.estimatedCoordinate
            return !SolarClock.isDaytime(
                at: Date(),
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }
    }
}

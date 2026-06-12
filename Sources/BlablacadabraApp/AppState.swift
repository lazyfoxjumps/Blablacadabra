import AppKit
import BlablacadabraCore
import Combine
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

/// One committed caption line. `original` holds the source-language text
/// shown above the translation in bilingual mode; nil otherwise.
struct CaptionLine: Equatable {
    let text: String
    var original: String?
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
    @Published private(set) var lastEventAt: Date?
    /// ISO 639-1 code of the language being translated FROM, detected live by
    /// the engine. Only surfaced while translating; reset each session.
    @Published private(set) var detectedLanguageCode: String?

    private var pipeline: TranscriptionPipeline?
    private var sessionTask: Task<Void, Never>?
    private var sessionGeneration = 0
    /// The in-flight teardown of the previous session. A new session awaits it
    /// before creating its capture, so AVAudioEngine/SCStream never overlap
    /// (overlapping start/stop throws ObjC assertions that crash the app).
    private var teardownTask: Task<Void, Never>?
    /// Debounce for rapid setting changes (flipping model/source pills fast):
    /// coalesce into one restart instead of spawning overlapping sessions.
    private var restartTask: Task<Void, Never>?
    /// The prepared engine is kept alive across restarts so a source change or
    /// a pause/resume reuses the already-loaded model (near-instant) instead of
    /// reloading it every time (slow, and re-exposes the WhisperKit load stall).
    /// Replaced only when the model itself changes.
    private var preparedEngine: WhisperKitEngine?
    private var preparedModel: String?

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
            if let pipeline {
                Task { await pipeline.setTask(task) }
            }
            // Turning translate off clears the "from" language; turning it on
            // waits for the next decode to detect it.
            detectedLanguageCode = nil
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
            if let pipeline {
                Task { await pipeline.setSpokenLanguage(spokenLanguageCode) }
            }
            // The chip should reflect the locked choice immediately, not the
            // stale auto-detected one.
            if spokenLanguageCode != nil { detectedLanguageCode = nil }
        }
    }
    /// Bilingual captions: show the original language above the English while
    /// translating. Applies mid-stream; only does anything when translate is on.
    @Published var showOriginal: Bool {
        didSet {
            defaults.set(showOriginal, forKey: "showOriginal")
            if let pipeline {
                Task { await pipeline.setShowOriginal(showOriginal) }
            }
        }
    }
    @Published var model: String {
        didSet {
            defaults.set(model, forKey: "model")
            restartIfRunning()
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
    @Published var calmMode: Bool {
        didSet { defaults.set(calmMode, forKey: "calmMode") }
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
        model = defaults.string(forKey: "model") ?? WhisperKitEngine.defaultModel
        let storedLocale = EnglishLocale(rawValue: defaults.string(forKey: "captionLocale") ?? "") ?? .us
        captionLocale = storedLocale
        normalizer = SpellingNormalizer(locale: storedLocale)
        showOriginal = defaults.bool(forKey: "showOriginal")
        themeMode = ThemeMode(rawValue: defaults.string(forKey: "themeMode") ?? "") ?? .system
        fontChoice = FontChoice(rawValue: defaults.string(forKey: "fontChoice") ?? "") ?? .nunito
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 21
        previousLines = defaults.object(forKey: "previousLines") as? Int ?? 2
        overlayOpacity = defaults.object(forKey: "overlayOpacity") as? Double ?? 0.9
        calmMode = defaults.bool(forKey: "calmMode")
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

    /// Starts a session unconditionally (the public `startCaptions` guards
    /// against double-start; restart and resume come straight here). Reuses the
    /// prepared engine when the model is unchanged, and waits for any in-flight
    /// teardown so the old capture is fully gone before the new one opens.
    private func launchSession() {
        sessionGeneration += 1
        let generation = sessionGeneration
        startingNeedsDownload = !WhisperKitEngine.isModelCached(model)
        downloadProgress = nil
        phase = .starting
        partial = nil
        detectedLanguageCode = nil

        // Build a fresh engine only when the model changed; otherwise keep the
        // loaded one (instant restart, no reload stall).
        if preparedModel != model || preparedEngine == nil {
            preparedEngine = WhisperKitEngine(model: model)
            preparedModel = model
        }
        let engine = preparedEngine!
        let pendingTeardown = teardownTask

        sessionTask = Task { [weak self] in
            guard let self else { return }
            // Never overlap captures: let the previous session's stop() finish.
            await pendingTeardown?.value
            guard self.sessionGeneration == generation else { return }
            do {
                let source = self.makeSource()
                // Honest waiting: percentage while downloading, and the
                // status flips to "warming up" the moment the download ends
                // and the CoreML compile starts. A reused, already-loaded
                // engine no-ops prepare() and never fires this.
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
                let pipeline = TranscriptionPipeline(
                    source: source,
                    engine: engine,
                    task: self.translate ? .translate : .transcribe,
                    spokenLanguage: self.spokenLanguageCode,
                    showOriginal: self.showOriginal
                )
                self.pipeline = pipeline
                let stream = try await pipeline.start()
                guard self.sessionGeneration == generation else { return }
                self.phase = .listening
                for await event in stream {
                    guard self.sessionGeneration == generation else { return }
                    self.handle(event)
                }
                // Stream drained on its own (source ended) without stop().
                if self.sessionGeneration == generation, self.phase == .listening {
                    self.phase = .trouble("I lost the audio. Press start and I'll pick right back up.")
                }
            } catch AudioCaptureError.screenRecordingPermissionDenied {
                guard self.sessionGeneration == generation else { return }
                self.phase = .permissionNeeded
            } catch {
                guard self.sessionGeneration == generation else { return }
                self.phase = .trouble(Self.friendlyMessage(for: error))
            }
        }
    }

    /// Stop and clear: captions are off, overlay goes away.
    func stopCaptions() {
        endSession(newPhase: .idle)
        lines = []
        partial = nil
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
        let pipeline = pipeline
        self.pipeline = nil
        sessionTask = nil
        downloadProgress = nil
        phase = newPhase
        // Track the teardown so the next session can await it (no overlap).
        teardownTask = Task { if let pipeline { await pipeline.stop() } }
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

    private func makeSource() -> AudioSource {
        switch sourceChoice {
        case .system: return SystemAudioCapture()
        case .mic: return MicCapture()
        case .both: return MixedAudioSource(SystemAudioCapture(), MicCapture())
        }
    }

    private func handle(_ event: CaptionEvent) {
        lastEventAt = Date()
        switch event {
        case .partial(let text, let language):
            // Partials get the same spelling pass as finals so a word never
            // visibly flips form ("color" -> "colour") at the commit.
            partial = normalizer.normalize(text)
            noteDetectedLanguage(language)
        case .final(let text, let original, let language):
            partial = nil
            // Normalize the English headline; leave the original untouched
            // (it's foreign-language text, not English to re-spell).
            lines.append(CaptionLine(text: normalizer.normalize(text), original: original))
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
            // Once the engine has heard enough to name the source language,
            // show the direction ("Indonesian → English (US)"); until then,
            // the honest generic ("Translating to English (US)").
            if let from = SpokenLanguage.displayName(forCode: detectedLanguageCode) {
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

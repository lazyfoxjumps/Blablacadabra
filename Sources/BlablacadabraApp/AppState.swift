import AppKit
import BlablacadabraCore
import Combine
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
    @Published private(set) var lines: [String] = []
    @Published private(set) var partial: String?
    @Published private(set) var lastEventAt: Date?

    private var pipeline: TranscriptionPipeline?
    private var sessionTask: Task<Void, Never>?
    private var sessionGeneration = 0

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
        }
    }
    @Published var model: String {
        didSet {
            defaults.set(model, forKey: "model")
            restartIfRunning()
        }
    }
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

    init() {
        sourceChoice = CaptureSourceChoice(rawValue: defaults.string(forKey: "sourceChoice") ?? "") ?? .system
        translate = defaults.bool(forKey: "translate")
        model = defaults.string(forKey: "model") ?? WhisperKitEngine.defaultModel
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

        isDark = resolveIsDark()

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
        sessionGeneration += 1
        let generation = sessionGeneration
        phase = .starting
        partial = nil

        sessionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let source = self.makeSource()
                let engine = WhisperKitEngine(model: self.model)
                let pipeline = TranscriptionPipeline(
                    source: source,
                    engine: engine,
                    task: self.translate ? .translate : .transcribe
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
        phase = newPhase
        if let pipeline {
            Task { await pipeline.stop() }
        }
    }

    private func restartIfRunning() {
        guard isRunning else { return }
        endSession(newPhase: .starting)
        startCaptions()
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
        case .partial(let text):
            partial = text
        case .final(let text):
            partial = nil
            lines.append(text)
            if lines.count > 8 { lines.removeFirst(lines.count - 8) }
            applyPendingThemeIfQuiet()
        }
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
            return "Warming up · getting the model ready"
        case .listening:
            return translate
                ? "Translating to English · \(sourceChoice.label)"
                : "Listening · \(sourceChoice.label)"
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
        withAnimation(.easeInOut(duration: 1.4)) {
            isDark = dark
        }
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

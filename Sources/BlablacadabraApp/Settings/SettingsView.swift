import BlablacadabraCore
import SwiftUI

/// Settings, matching the approved mockups: card header row, live preview at
/// top, generously spaced sections (32 between sections, 16 between rows, one
/// Jua heading per group), pill pickers instead of native controls, circular
/// color swatches. Nunito body, Jua headings.
struct SettingsView: View {
    @ObservedObject var state: AppState
    let resetOverlayPosition: () -> Void
    @State private var customText: Color = .white
    @State private var customBackground: Color = .black
    /// Live model-slider position; commits to `state.model` only on release, so
    /// dragging across stops never kicks off several downloads.
    @State private var modelIndex: Double = 0
    @State private var modelSliderEditing = false

    var body: some View {
        let theme = state.theme

        VStack(spacing: 0) {
            headerBar(theme: theme)

            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    preview(theme: theme)
                    sizeAndLayout(theme: theme)
                    colors(theme: theme)
                    fontAndPosition(theme: theme)
                    behavior(theme: theme)
                    audio(theme: theme)
                    engine(theme: theme)
                }
                .padding(28)
            }
            // Belt and suspenders with makeFirstResponder(nil): always open
            // at the top, never scrolled to whatever got focus.
            .defaultScrollAnchor(.top)
        }
        .frame(width: 520, height: 660)
        .background(theme.deepSurface)
        .preferredColorScheme(theme.colorScheme)
        .onAppear {
            customText = RGB(hexString: state.customTextHex)?.color ?? .white
            customBackground = RGB(hexString: state.customBackgroundHex)?.color ?? .black
            modelIndex = Double(WhisperKitEngine.index(of: state.model))
            state.refreshAudioDevices()
        }
    }

    /// In-card window header (the window's own title bar is transparent).
    private func headerBar(theme: ResolvedTheme) -> some View {
        HStack(spacing: 10) {
            Text("Settings")
                .font(AppFont.windowTitle)
                .foregroundStyle(theme.primaryText)
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 14)
    }

    // MARK: Preview

    private func preview(theme: ResolvedTheme) -> some View {
        let colors = state.captionColors
        return section("Preview", subtitle: "Updates live as you change things.", theme: theme) {
            VStack(alignment: .leading, spacing: 6) {
                if !state.calmMode && state.previousLines > 0 {
                    Text("This is what an earlier line looks like.")
                        .font(state.fontChoice.font(size: max(13, state.fontSize * 0.72)))
                        .foregroundStyle(colors.text.color.opacity(0.55))
                }
                Text("And this is the line being spoken right now.")
                    .font(state.fontChoice.font(size: state.fontSize, weight: .medium))
                    .foregroundStyle(colors.text.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(colors.background.color.opacity(state.overlayOpacity))
            )
        }
    }

    // MARK: Size and layout

    private func sizeAndLayout(theme: ResolvedTheme) -> some View {
        section("Size and layout", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                labeledRow("Caption size", detail: "\(Int(state.fontSize)) pt", theme: theme) {
                    NDSlider(value: $state.fontSize, range: 14...36, step: 1, theme: theme)
                }
                labeledRow(
                    "Earlier lines kept on screen",
                    detail: state.previousLines == 0 ? "None" : "\(state.previousLines)",
                    theme: theme
                ) {
                    NDSlider(
                        value: Binding(
                            get: { Double(state.previousLines) },
                            set: { state.previousLines = Int($0) }
                        ),
                        range: 0...4, step: 1, theme: theme
                    )
                }
                labeledRow("Background strength", detail: "\(Int(state.overlayOpacity * 100))%", theme: theme) {
                    NDSlider(value: $state.overlayOpacity, range: 0.3...1, step: 0.05, theme: theme)
                }
            }
        }
    }

    // MARK: Colors

    private func colors(theme: ResolvedTheme) -> some View {
        section("Colors", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Theme")
                        .font(AppFont.detail)
                        .foregroundStyle(theme.secondaryText)
                    PillPicker(
                        selection: $state.themeMode,
                        options: ThemeMode.allCases.map { ($0, $0.label) },
                        theme: theme
                    )
                    if state.themeMode == .sun {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sun switches to light at sunrise and dark at sunset, computed on this Mac.")
                                .font(AppFont.footnote)
                                .foregroundStyle(theme.secondaryText)
                            Toggle(isOn: $state.useLocationForSun) {
                                Text("Use my location for exact sunrise times. Skip if unsure, my timezone estimate works fine.")
                                    .font(AppFont.footnote)
                                    .foregroundStyle(theme.primaryText)
                            }
                            .toggleStyle(FlameToggleStyle())
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Caption colors")
                        .font(AppFont.detail)
                        .foregroundStyle(theme.secondaryText)
                    swatchRow(theme: theme)
                    if state.captionPresetID == "custom" {
                        HStack(spacing: 16) {
                            ColorPicker("Text", selection: $customText, supportsOpacity: false)
                                .onChange(of: customText) { _, newValue in
                                    state.customTextHex = RGB(newValue).hexString
                                }
                            ColorPicker("Background", selection: $customBackground, supportsOpacity: false)
                                .onChange(of: customBackground) { _, newValue in
                                    state.customBackgroundHex = RGB(newValue).hexString
                                }
                        }
                        .font(AppFont.detail)
                        .foregroundStyle(theme.primaryText)
                    }
                    contrastVerdict(theme: theme)
                }

                colorBySpeaker(theme: theme)
            }
        }
    }

    /// "Color by speaker" toggle + a static preview of the speaker chips/colors,
    /// so the user sees exactly what the feature does before turning it on.
    private func colorBySpeaker(theme: ResolvedTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $state.colorBySpeaker) {
                behaviorLabel(
                    "Color by speaker",
                    detail: "When more than one person is talking, each voice gets its own color and a small label (S1, S2). Color is never the only marker. Works best with System or Both.",
                    theme: theme
                )
            }
            .toggleStyle(FlameToggleStyle())

            if state.colorBySpeaker {
                speakerCountPicker(theme: theme)
                speakerPreviewRow(theme: theme)
            }
        }
    }

    /// Lets the user tell the app how many people are talking. A known count is
    /// what actually stops one voice from fragmenting into S2/S3/S+ on noisy call
    /// audio: "2 people" pins the other person to a single color, no guessing.
    /// "Auto" keeps the adaptive behavior for when the count is unknown.
    private func speakerCountPicker(theme: ResolvedTheme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How many people?")
                .font(AppFont.detail)
                .foregroundStyle(theme.secondaryText)
            PillPicker(
                selection: $state.expectedSpeakerCount,
                options: [(0, "Auto"), (1, "1"), (2, "2"), (3, "3"), (4, "4"), (5, "5+")],
                theme: theme
            )
            Text(speakerCountHint)
                .font(AppFont.footnote)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Helper copy under the speaker-count picker, tailored per choice.
    private var speakerCountHint: String {
        switch state.expectedSpeakerCount {
        case 0:
            return "I'll figure out how many voices there are. Best if you're not sure."
        case 1:
            return "Just you. Every line stays S1, no splitting into S2/S3."
        default:
            return "I'll expect \(state.expectedSpeakerCount) and keep each voice steady. Pick the exact number for the cleanest result."
        }
    }

    /// A non-interactive row showing the first few speaker styles on the current
    /// caption background (the same colors the overlay would use).
    private func speakerPreviewRow(theme: ResolvedTheme) -> some View {
        let colors = state.captionColors
        let palette = SpeakerPalette.colors(text: colors.text, background: colors.background)
        // With a declared count, preview exactly that many speakers (no overflow
        // chip — they capped it). In Auto, show four plus the S+ overflow bucket.
        let count = state.expectedSpeakerCount
        let shown = count > 0 ? min(count, palette.count) : 4
        let numbered: [(SpeakerID, RGB)] = (1...max(1, shown)).map { n in
            (.speaker(n), palette[min(n - 1, palette.count - 1)])
        }
        let samples: [(SpeakerID, RGB)] = count > 0
            ? numbered
            : numbered + [(.other, palette.last ?? colors.text)]
        return HStack(spacing: 8) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                HStack(spacing: 4) {
                    Text(sample.0.chipLabel)
                        .font(AppFont.nunito(10, .bold))
                        .foregroundStyle(sample.1.color)
                        .padding(.vertical, 1)
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(sample.1.color.opacity(0.16)))
                    Text("Aa")
                        .font(AppFont.nunito(12, .medium))
                        .foregroundStyle(sample.1.color)
                }
                .help(sample.0.spokenLabel)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colors.background.color)
        )
        .accessibilityLabel("Preview of speaker colors and labels")
    }

    /// Circular swatches (mockup style): background-colored circles with the
    /// text color as a center dot; custom hides behind a dashed plus.
    private func swatchRow(theme: ResolvedTheme) -> some View {
        HStack(spacing: 10) {
            ForEach(CaptionPreset.vetted) { preset in
                swatch(for: preset, theme: theme)
            }
            Button {
                state.captionPresetID = "custom"
            } label: {
                Circle()
                    .strokeBorder(theme.secondaryText.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                    )
                    .overlay(selectionRing(active: state.captionPresetID == "custom"))
            }
            .buttonStyle(.plain)
            .help("Pick your own colors")
            .accessibilityLabel("Pick your own colors")
        }
    }

    private func swatch(for preset: CaptionPreset, theme: ResolvedTheme) -> some View {
        let text = preset.text ?? theme.captionText
        let background = preset.background ?? theme.captionBackground
        return Button {
            state.captionPresetID = preset.id
        } label: {
            Circle()
                .fill(background.color)
                .frame(width: 34, height: 34)
                .overlay(
                    Circle()
                        .fill(text.color)
                        .frame(width: 12, height: 12)
                )
                .overlay(
                    Circle().strokeBorder(theme.secondaryText.opacity(0.25), lineWidth: 0.5)
                )
                .overlay(selectionRing(active: state.captionPresetID == preset.id))
        }
        .buttonStyle(.plain)
        .help(preset.name)
        .accessibilityLabel("Caption colors: \(preset.name)")
        .accessibilityAddTraits(state.captionPresetID == preset.id ? .isSelected : [])
    }

    private func selectionRing(active: Bool) -> some View {
        Circle()
            .strokeBorder(active ? Palette.burningFlame : .clear, lineWidth: 2.5)
    }

    /// Live contrast check with a plain-language verdict, warns on bad combos.
    private func contrastVerdict(theme: ResolvedTheme) -> some View {
        let colors = state.captionColors
        let ratio = RGB.contrast(colors.text, colors.background)
        let rounded = (ratio * 10).rounded() / 10
        let verdict: String
        let symbol: String
        if ratio >= 7 {
            verdict = "Contrast \(rounded) : 1, comfortable and easy to read."
            symbol = "checkmark.circle"
        } else if ratio >= 4.5 {
            verdict = "Contrast \(rounded) : 1, readable, though a stronger combo would be gentler on the eyes."
            symbol = "circle.bottomhalf.filled"
        } else {
            verdict = "Contrast \(rounded) : 1, hard to read. I'd pick a stronger combo."
            symbol = "exclamationmark.circle"
        }
        return HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(verdict)
        }
        .font(AppFont.detail)
        .foregroundStyle(ratio >= 4.5 ? theme.secondaryText : theme.accentText)
    }

    // MARK: Font and position

    private func fontAndPosition(theme: ResolvedTheme) -> some View {
        section("Font and position", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    PillPicker(
                        selection: $state.fontChoice,
                        options: FontChoice.allCases.map { ($0, $0.shortLabel) },
                        theme: theme,
                        fontFor: { $0.font(size: 12.5, weight: .semibold) }
                    )
                    if !state.fontChoice.isInstalled {
                        Text("\(state.fontChoice.label) isn't installed on this Mac yet, so I'm using the system font for now. Install it and I'll switch over.")
                            .font(AppFont.footnote)
                            .foregroundStyle(theme.accentText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("The caption card moves when you drag it. If it ends up somewhere odd, this brings it home.")
                        .font(AppFont.footnote)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Reset caption position") {
                        resetOverlayPosition()
                    }
                    .buttonStyle(AccentButtonStyle(theme: theme))
                }
            }
        }
    }

    // MARK: Behavior

    private func behavior(theme: ResolvedTheme) -> some View {
        section("Behavior", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: $state.showOriginal) {
                    behaviorLabel(
                        "Show the original language too",
                        detail: "While translating, the original words sit just above the English. Only does anything when translation is on.",
                        theme: theme
                    )
                }
                .toggleStyle(FlameToggleStyle())

                Toggle(isOn: $state.calmMode) {
                    behaviorLabel(
                        "Calm mode",
                        detail: "One line at a time, full contrast, no dimmed history.",
                        theme: theme
                    )
                }
                .toggleStyle(FlameToggleStyle())

                Toggle(isOn: $state.hideOnSilence) {
                    behaviorLabel(
                        "Hide when it's quiet",
                        detail: "After 6 seconds of silence I fade out. I come right back when anyone speaks.",
                        theme: theme
                    )
                }
                .toggleStyle(FlameToggleStyle())

                Toggle(isOn: $state.clickThrough) {
                    behaviorLabel(
                        "Click through the captions",
                        detail: "Clicks pass straight through the card. Use the menu bar or the shortcut to pause.",
                        theme: theme
                    )
                }
                .toggleStyle(FlameToggleStyle())

                Toggle(isOn: $state.launchAtLogin) {
                    behaviorLabel(
                        "Start when I log in",
                        detail: "I'll wait quietly in the menu bar. Captions only start when you ask.",
                        theme: theme
                    )
                }
                .toggleStyle(FlameToggleStyle())

                behaviorLabel(
                    "Keyboard shortcut",
                    detail: "Option-Command-C starts or pauses captions from anywhere.",
                    theme: theme
                )
            }
        }
    }

    private func behaviorLabel(_ title: String, detail: String, theme: ResolvedTheme) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(AppFont.body)
                .foregroundStyle(theme.primaryText)
            Text(detail)
                .font(AppFont.footnote)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Engine

    private func engine(theme: ResolvedTheme) -> some View {
        section("Speech engine", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Spoken language")
                        .font(AppFont.detail)
                        .foregroundStyle(theme.secondaryText)
                    SpokenLanguageMenu(selection: $state.spokenLanguageCode) {
                        HStack(spacing: 6) {
                            Text(state.spokenLanguageDisplay)
                                .font(AppFont.control)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(theme.accentText)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(theme.accentText.opacity(0.5), lineWidth: 1)
                        )
                    }
                    Text("Leave it on Auto to detect the language for you. If captions sometimes show the wrong language, pick the one you actually speak and I'll stick to it.")
                        .font(AppFont.footnote)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                modelSlider(theme: theme)
                VStack(alignment: .leading, spacing: 8) {
                    Text("English")
                        .font(AppFont.detail)
                        .foregroundStyle(theme.secondaryText)
                    // Eight variants in two even rows: a single row truncates.
                    PillPicker(
                        selection: $state.captionLocale,
                        options: localeRow([.us, .uk, .au, .sg]),
                        theme: theme
                    )
                    PillPicker(
                        selection: $state.captionLocale,
                        options: localeRow([.ca, .india, .nz, .ie]),
                        theme: theme
                    )
                    Text("Changes the spelling in captions, like colour vs color. Speech is understood the same in every accent either way.")
                        .font(AppFont.footnote)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Image(systemName: "lock")
                    Text("Everything stays on this Mac. Audio never leaves it.")
                }
                .font(AppFont.detail)
                .foregroundStyle(theme.primaryText)
            }
        }
    }

    private func localeRow(_ locales: [EnglishLocale]) -> [(value: EnglishLocale, label: String)] {
        locales.map { ($0, $0.shortLabel) }
    }

    /// Discrete 4-stop model slider. Commits on release (and on VoiceOver
    /// adjust) so dragging across stops never triggers multiple downloads.
    private func modelSlider(theme: ResolvedTheme) -> some View {
        let count = WhisperKitEngine.availableModels.count
        let currentModel = WhisperKitEngine.model(atIndex: Int(modelIndex))
        let commit = {
            let chosen = WhisperKitEngine.model(atIndex: Int(modelIndex))
            if chosen != state.model { state.model = chosen }
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Speech model")
                    .font(AppFont.detail)
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                Text(WhisperKitEngine.displayName(for: currentModel))
                    .font(AppFont.control)
                    .foregroundStyle(theme.accentText)
            }
            NDSlider(
                value: $modelIndex,
                range: 0...Double(max(1, count - 1)),
                step: 1,
                theme: theme,
                onEditingChanged: { editing in
                    modelSliderEditing = editing
                    if !editing { commit() } // committed on release
                }
            )
            // VoiceOver increment/decrement doesn't drag, so commit those too;
            // guarded by `modelSliderEditing` so a live drag never commits.
            .onChange(of: modelIndex) { _, _ in
                if !modelSliderEditing { commit() }
            }
            Text(modelCaption(for: currentModel))
                .font(AppFont.footnote)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modelCaption(for model: String) -> String {
        WhisperKitEngine.caption(for: model)
    }

    // MARK: Audio

    private func audio(theme: ResolvedTheme) -> some View {
        section("Audio", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                micDevicePicker(theme: theme)
                captureHealth(theme: theme)
                if let notice = state.audioDeviceNotice {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(notice)
                    }
                    .font(AppFont.detail)
                    .foregroundStyle(theme.accentText)
                }
                inputLevelRow(theme: theme)
                if state.inputQuietNudge {
                    lowInputNudgeRow(theme: theme)
                }
                Toggle(isOn: $state.autoGain) {
                    behaviorLabel(
                        "Auto-adjust input",
                        detail: "I match the level for you, so soft voices come through without touching the boost. It only lifts when someone's actually talking, never the quiet.",
                        theme: theme
                    )
                }
                .toggleStyle(FlameToggleStyle())
                VStack(alignment: .leading, spacing: 8) {
                    labeledRow("Input boost", detail: state.autoGain ? "Auto" : gainLabel, theme: theme) {
                        NDSlider(value: $state.inputGain, range: 1...3, step: 0.1, theme: theme)
                            .disabled(state.autoGain)
                            .opacity(state.autoGain ? 0.4 : 1)
                    }
                    Text(state.autoGain
                        ? "Auto-adjust is handling the level. Turn it off to set the boost yourself."
                        : "Turn this up if soft voices are getting missed. Leave it at 1× for normal speech.")
                        .font(AppFont.footnote)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Shown when the mic has been quiet for a while: the usual cause is a low
    /// input volume in System Settings, which the app can't change for you.
    private func lowInputNudgeRow(theme: ResolvedTheme) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.bubble")
            VStack(alignment: .leading, spacing: 4) {
                Text("Your mic sounds quiet. Try the built-in mic, or turn its input volume up in System Settings.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Sound settings") {
                    CapturePermissions.openSoundInputSettings()
                }
                .buttonStyle(.plain)
                .underline()
            }
        }
        .font(AppFont.detail)
        .foregroundStyle(theme.accentText)
    }

    private var gainLabel: String {
        let rounded = (state.inputGain * 10).rounded() / 10
        return rounded == 1 ? "1× (off)" : "\(rounded)×"
    }

    private func micDevicePicker(theme: ResolvedTheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Microphone")
                .font(AppFont.detail)
                .foregroundStyle(theme.secondaryText)
            Menu {
                Button {
                    state.micDeviceUID = nil
                } label: {
                    deviceRow("Automatic (follow system)", checked: state.micDeviceUID == nil)
                }
                if !state.inputDevices.isEmpty { Divider() }
                ForEach(state.inputDevices) { device in
                    Button {
                        state.micDeviceUID = device.uid
                    } label: {
                        deviceRow(device.name, checked: state.micDeviceUID == device.uid)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(micDeviceLabel)
                        .font(AppFont.control)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(theme.accentText)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(theme.accentText.opacity(0.5), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Text("Which mic I listen to. Used when you're captioning the microphone or Both.")
                .font(AppFont.footnote)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var micDeviceLabel: String {
        guard let uid = state.micDeviceUID else { return "Automatic (follow system)" }
        return state.inputDevices.first { $0.uid == uid }?.name ?? "Automatic (follow system)"
    }

    @ViewBuilder
    private func deviceRow(_ title: String, checked: Bool) -> some View {
        if checked {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    /// System audio is tapped from the whole output mix before the output
    /// device, so an output picker wouldn't change what's captured (documented
    /// honestly). Instead, warn when the default output is a known
    /// capture-breaking virtual device; otherwise a calm all-clear line.
    private func captureHealth(theme: ResolvedTheme) -> some View {
        Group {
            if state.outputIsCaptureBreaking {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Your sound is going to \"\(state.defaultOutputName ?? "a virtual device")\", which can stop me from hearing system audio. Switch your output to your speakers or headphones in System Settings > Sound, then start captions again.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(AppFont.detail)
                .foregroundStyle(theme.accentText)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                    Text("System audio looks good\(state.defaultOutputName.map { " (playing through \($0))" } ?? "").")
                }
                .font(AppFont.detail)
                .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private func inputLevelRow(theme: ResolvedTheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Input level")
                .font(AppFont.detail)
                .foregroundStyle(theme.secondaryText)
            InputLevelMeter(monitor: state.levelMonitor, theme: theme)
            Text(state.isRunning
                 ? "The bar moves when I hear sound, so you know I'm listening."
                 : "Start captions to see the level move.")
                .font(AppFont.footnote)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Section scaffolding

    private func section(
        _ title: String,
        subtitle: String? = nil,
        theme: ResolvedTheme,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.sectionHeading)
                    .foregroundStyle(theme.primaryText)
                if let subtitle {
                    Text(subtitle)
                        .font(AppFont.footnote)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.surface)
        )
    }

    private func labeledRow(
        _ title: String,
        detail: String,
        theme: ResolvedTheme,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(AppFont.body)
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Text(detail)
                    .font(AppFont.detail)
                    .foregroundStyle(theme.secondaryText)
            }
            content()
        }
    }
}

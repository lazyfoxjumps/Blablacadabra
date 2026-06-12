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
            }
        }
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
                    PillPicker(
                        selection: $state.model,
                        options: WhisperKitEngine.availableModels.map { ($0, $0.capitalized) },
                        theme: theme
                    )
                    Text("Bigger is more accurate, smaller is faster. Base is a good middle.")
                        .font(AppFont.footnote)
                        .foregroundStyle(theme.secondaryText)
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

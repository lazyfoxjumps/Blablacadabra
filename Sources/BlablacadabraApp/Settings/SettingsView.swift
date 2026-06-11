import BlablacadabraCore
import SwiftUI

/// Settings, exactly as designed: live preview at top, then generously
/// spaced sections (32 between sections, 16 between rows, one heading per
/// group). Space over squeeze, always.
struct SettingsView: View {
    @ObservedObject var state: AppState
    let resetOverlayPosition: () -> Void
    @State private var customText: Color = .white
    @State private var customBackground: Color = .black

    var body: some View {
        let theme = state.theme

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
        .frame(width: 520, height: 640)
        .background(theme.deepSurface)
        .preferredColorScheme(theme.colorScheme)
        .onAppear {
            customText = RGB(hexString: state.customTextHex)?.color ?? .white
            customBackground = RGB(hexString: state.customBackgroundHex)?.color ?? .black
        }
    }

    // MARK: Preview

    private func preview(theme: ResolvedTheme) -> some View {
        let colors = state.captionColors
        return section("Preview", theme: theme) {
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
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                    Picker("", selection: $state.themeMode) {
                        ForEach(ThemeMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if state.themeMode == .sun {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sun switches to light at sunrise and dark at sunset, computed on this Mac.")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.secondaryText)
                            Toggle(isOn: $state.useLocationForSun) {
                                Text("Use my location for exact sunrise times. Skip if unsure, my timezone estimate works fine.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.primaryText)
                            }
                            .toggleStyle(FlameToggleStyle())
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Caption colors")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                    swatchGrid(theme: theme)
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
                        .font(.system(size: 12))
                        .foregroundStyle(theme.primaryText)
                    }
                    contrastVerdict(theme: theme)
                }
            }
        }
    }

    private func swatchGrid(theme: ResolvedTheme) -> some View {
        let columns = [GridItem(.adaptive(minimum: 64), spacing: 10)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(CaptionPreset.vetted) { preset in
                swatch(for: preset, theme: theme)
            }
            // Custom hides behind a plus until wanted (design kit).
            Button {
                state.captionPresetID = "custom"
            } label: {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.secondaryText.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                    .frame(width: 64, height: 40)
                    .overlay(
                        Image(systemName: "plus")
                            .foregroundStyle(theme.secondaryText)
                    )
                    .overlay(selectionRing(active: state.captionPresetID == "custom", theme: theme))
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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(background.color)
                .frame(width: 64, height: 40)
                .overlay(
                    Text("Abc")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(text.color)
                )
                .overlay(selectionRing(active: state.captionPresetID == preset.id, theme: theme))
        }
        .buttonStyle(.plain)
        .help(preset.name)
    }

    private func selectionRing(active: Bool, theme: ResolvedTheme) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
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
        .font(.system(size: 12))
        .foregroundStyle(ratio >= 4.5 ? theme.secondaryText : theme.accentText)
    }

    // MARK: Font and position

    private func fontAndPosition(theme: ResolvedTheme) -> some View {
        section("Font and position", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $state.fontChoice) {
                        ForEach(FontChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    if !state.fontChoice.isInstalled {
                        Text("\(state.fontChoice.label) isn't installed on this Mac yet, so I'm using the system font for now. Install it and I'll switch over.")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.accentText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("The caption card moves when you drag it. If it ends up somewhere odd, this brings it home.")
                        .font(.system(size: 11))
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
                .font(.system(size: 13))
                .foregroundStyle(theme.primaryText)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Engine

    private func engine(theme: ResolvedTheme) -> some View {
        section("Speech engine", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $state.model) {
                        ForEach(WhisperKitEngine.availableModels, id: \.self) { name in
                            Text(name.capitalized).tag(name)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("Bigger is more accurate, smaller is faster. Base is a good middle.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
                HStack(spacing: 6) {
                    Image(systemName: "lock")
                    Text("Everything stays on this Mac. Audio never leaves it.")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.primaryText)
            }
        }
    }

    // MARK: Section scaffolding

    private func section(_ title: String, theme: ResolvedTheme, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.primaryText)
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
                    .font(.system(size: 13))
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
            content()
        }
    }
}

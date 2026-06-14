import BlablacadabraCore
import SwiftUI

/// The menu-bar panel: status at top, one big start/stop, then the three
/// everyday controls (source, translate, model). Settings and quit at the
/// bottom. No nested menus, big targets, state in words plus icon.
struct MenuBarPanelView: View {
    @ObservedObject var state: AppState
    let openSettings: () -> Void
    /// Live model-slider position; commits to `state.model` only on release, so
    /// dragging across stops never kicks off several downloads (same rule as
    /// Settings).
    @State private var modelIndex: Double = 0
    @State private var modelSliderEditing = false

    var body: some View {
        let theme = state.theme

        VStack(alignment: .leading, spacing: 16) {
            // Brand row: logo mark (transparent, theme-aware) + wordmark.
            HStack(spacing: 8) {
                BrandLogo(isDark: theme.isDark, size: 24)
                Text("blablacadabra")
                    .font(AppFont.jua(15))
                    .foregroundStyle(theme.primaryText)
            }

            // Status row.
            HStack(spacing: 8) {
                Image(systemName: state.statusSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accentText)
                Text(state.statusText)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(theme.primaryText)
            }

            // The one big button.
            Button {
                if state.isRunning {
                    state.pauseCaptions()
                } else {
                    state.startCaptions()
                }
            } label: {
                HStack {
                    Spacer()
                    Label(
                        startStopLabel,
                        systemImage: state.isRunning ? "pause.fill" : "play.fill"
                    )
                    .font(AppFont.nunito(14, .bold))
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(AccentButtonStyle(theme: theme))

            if state.phase == .paused || state.phase == .permissionNeeded {
                Button("Turn captions off") {
                    state.stopCaptions()
                }
                .buttonStyle(.plain)
                .font(AppFont.detail)
                .foregroundStyle(theme.secondaryText)
            }

            Divider().overlay(theme.secondaryText.opacity(0.3))

            // Generous spacing so the three everyday controls don't read as a
            // cramped stack (ND rule: space over squeeze).
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What I listen to")
                        // Same size as "Translate to English" below.
                        .font(AppFont.body)
                        .foregroundStyle(theme.secondaryText)
                    PillPicker(
                        selection: $state.sourceChoice,
                        options: CaptureSourceChoice.allCases.map { ($0, $0.label) },
                        theme: theme,
                        // "System audio" needs the smaller size to breathe at
                        // this panel width.
                        fontFor: { _ in AppFont.nunito(11, .semibold) }
                    )
                }

                Toggle(isOn: $state.translate) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Translate to English")
                            .font(AppFont.body)
                            .foregroundStyle(theme.primaryText)
                        Text("Any language in, English captions out.")
                            .font(AppFont.footnote)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .toggleStyle(FlameToggleStyle())

                modelSlider(theme: theme)
            }

            Divider().overlay(theme.secondaryText.opacity(0.3))

            HStack {
                Button("Settings") { openSettings() }
                    .buttonStyle(.plain)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(theme.accentText)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(AppFont.body)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(20)
        .frame(width: 300)
        .background(theme.surface)
        .preferredColorScheme(theme.colorScheme)
        .onAppear { modelIndex = Double(WhisperKitEngine.index(of: state.model)) }
        .onChange(of: state.model) { _, newModel in
            // Keep the slider in step if the model changes elsewhere (Settings),
            // unless the user is mid-drag here.
            if !modelSliderEditing { modelIndex = Double(WhisperKitEngine.index(of: newModel)) }
        }
    }

    /// Discrete 4-stop model slider (tiny/small/medium/turbo), matching the one
    /// in Settings. Commits to `state.model` only on release (and on VoiceOver
    /// adjust) so dragging across stops never starts several downloads.
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
                    // Same size as "Translate to English".
                    .font(AppFont.body)
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
                    if !editing { commit() }
                }
            )
            .onChange(of: modelIndex) { _, _ in
                if !modelSliderEditing { commit() }
            }
            Text(WhisperKitEngine.caption(for: currentModel))
                .font(AppFont.footnote)
                .foregroundStyle(theme.secondaryText)
        }
    }

    private var startStopLabel: String {
        switch state.phase {
        case .paused: return "Resume captions"
        case .listening, .starting: return "Pause captions"
        default: return "Start captions"
        }
    }
}

/// Toggles ON are a Burning Flame pill with an Abyssal knob, in both modes
/// (orange means on, everywhere).
struct FlameToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top) {
            configuration.label
            Spacer(minLength: 12)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Palette.burningFlame : Palette.oatmeal.opacity(0.55))
                    .frame(width: 38, height: 22)
                Circle()
                    .fill(configuration.isOn ? Palette.abyssal : Palette.palladian)
                    .frame(width: 18, height: 18)
                    .padding(2)
                    .shadow(radius: 0.5)
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    configuration.isOn.toggle()
                }
            }
            .accessibilityAddTraits(.isToggle)
        }
    }
}

import BlablacadabraCore
import SwiftUI

/// The menu-bar panel: status at top, one big start/stop, then the three
/// everyday controls (source, translate, model). Settings and quit at the
/// bottom. No nested menus, big targets, state in words plus icon.
struct MenuBarPanelView: View {
    @ObservedObject var state: AppState
    let openSettings: () -> Void

    var body: some View {
        let theme = state.theme

        VStack(alignment: .leading, spacing: 16) {
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

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What I listen to")
                        .font(AppFont.footnote)
                        .foregroundStyle(theme.secondaryText)
                    PillPicker(
                        selection: $state.sourceChoice,
                        options: CaptureSourceChoice.allCases.map { ($0, $0.label) },
                        theme: theme
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

                VStack(alignment: .leading, spacing: 6) {
                    Text("Speech model")
                        .font(AppFont.footnote)
                        .foregroundStyle(theme.secondaryText)
                    PillPicker(
                        selection: $state.model,
                        options: WhisperKitEngine.availableModels.map { ($0, $0.capitalized) },
                        theme: theme
                    )
                    Text("Bigger is more accurate, smaller is faster.")
                        .font(AppFont.footnote)
                        .foregroundStyle(theme.secondaryText)
                }
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

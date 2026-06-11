import BlablacadabraCore
import SwiftUI

/// First-run window: a welcome card and a numbered three-step checklist, all
/// on one screen. No hidden wizard pages, max two permission asks, and the
/// mic step is guilt-free skippable.
struct OnboardingView: View {
    @ObservedObject var state: AppState
    let finish: () -> Void

    @State private var screenStatus = CapturePermissions.screenRecordingStatus
    @State private var micGranted = CapturePermissions.microphoneStatus == .authorized
    @State private var micSkipped = false

    var body: some View {
        let theme = state.theme

        VStack(alignment: .leading, spacing: 24) {
            welcome(theme: theme)

            VStack(alignment: .leading, spacing: 16) {
                step(
                    number: 1, done: screenStatus == .granted,
                    title: "Let me hear what your Mac plays", theme: theme
                ) {
                    screenRecordingStep(theme: theme)
                }
                step(
                    number: 2, done: micGranted || micSkipped,
                    title: "Microphone, only if you want it", theme: theme
                ) {
                    microphoneStep(theme: theme)
                }
                step(
                    number: 3, done: false,
                    title: "Try it", theme: theme
                ) {
                    tryItStep(theme: theme)
                }
            }
        }
        .padding(28)
        .frame(width: 460)
        .background(theme.deepSurface)
        .preferredColorScheme(theme.colorScheme)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            // Auto-detect the Screen Recording grant; no restart, no hunting.
            screenStatus = CapturePermissions.screenRecordingStatus
            micGranted = CapturePermissions.microphoneStatus == .authorized
        }
    }

    // MARK: Welcome card

    private func welcome(theme: ResolvedTheme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Mascot slot, reserved (the design kit keeps this spot warm).
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .frame(width: 72, height: 72)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: 26))
                        .foregroundStyle(Palette.burningFlame)
                )
            Text("Now you hear it, now you read it.")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(theme.primaryText)
            Text("Live captions for everything on your Mac. Two quick steps, then you're done. No account, no setup maze.")
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Steps

    private func screenRecordingStep(theme: ResolvedTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("macOS calls this permission Screen Recording, but I only listen to the audio. Nothing is recorded. Nothing leaves your Mac.")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            switch screenStatus {
            case .granted:
                doneLine("System audio is ready.", theme: theme)
            case .notDetermined:
                VStack(alignment: .leading, spacing: 6) {
                    Button("Allow system audio") {
                        CapturePermissions.requestScreenRecordingAccess()
                        screenStatus = CapturePermissions.screenRecordingStatus
                    }
                    .buttonStyle(AccentButtonStyle(theme: theme))
                    Text("I'll detect it automatically. No restart needed.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
            case .denied:
                VStack(alignment: .leading, spacing: 6) {
                    Button("Open System Settings") {
                        CapturePermissions.openScreenRecordingSettings()
                    }
                    .buttonStyle(AccentButtonStyle(theme: theme))
                    Text("Turn on Blablacadabra under Privacy & Security, then Screen & System Audio Recording. I'll notice the moment you do.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func microphoneStep(theme: ResolvedTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("With the mic I can also caption people in the room with you. Skip if unsure, you can turn it on later in one click.")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if micGranted {
                doneLine("Microphone is ready.", theme: theme)
            } else if micSkipped {
                Text("Skipped. No rush, it'll be right here.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            } else {
                HStack(spacing: 12) {
                    Button("Allow microphone") {
                        Task {
                            micGranted = await CapturePermissions.requestMicrophoneAccess()
                        }
                    }
                    .buttonStyle(AccentButtonStyle(theme: theme))
                    Button("Skip for now") {
                        micSkipped = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }

    private func tryItStep(theme: ResolvedTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Play any video. I'll start writing the moment anyone speaks.")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
            Button("Start captions") {
                finish()
                state.startCaptions()
            }
            .buttonStyle(AccentButtonStyle(theme: theme))
            .disabled(screenStatus != .granted)
            if screenStatus != .granted {
                Text("Step 1 unlocks this one.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    // MARK: Bits

    private func step(
        number: Int, done: Bool, title: String, theme: ResolvedTheme,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(done ? Palette.burningFlame : theme.surface)
                    .frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.abyssal)
                } else {
                    Text("\(number)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                content()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.surface.opacity(done ? 0.55 : 1))
        )
    }

    private func doneLine(_ text: String, theme: ResolvedTheme) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Palette.burningFlame)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.primaryText)
        }
    }
}

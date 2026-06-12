import BlablacadabraCore
import SwiftUI

/// The caption card: header row (status words + icon left, drag handle and
/// pause right), then rolling captions. Current line large; up to four
/// previous lines dimmed by recency (brightness encodes age, nothing moves).
struct OverlayView: View {
    @ObservedObject var state: AppState
    @State private var fadedOut = false

    private static let cardWidth: Double = 600

    var body: some View {
        let colors = state.captionColors
        let theme = state.theme

        VStack(alignment: .leading, spacing: 12) {
            header(theme: theme, textColor: colors.text)

            switch state.phase {
            case .permissionNeeded:
                permissionLost(textColor: colors.text, theme: theme)
            case .trouble(let message):
                troubleState(message: message, textColor: colors.text, theme: theme)
            default:
                captions(textColor: colors.text)
            }
        }
        .padding(16)
        .frame(width: Self.cardWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colors.background.color.opacity(state.effectiveOverlayOpacity))
        )
        .opacity(fadedOut ? 0 : 1)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
            updateSilenceFade(now: now)
        }
        .onChange(of: state.lastEventAt) {
            if fadedOut {
                withAnimation(fadeAnimation(.easeIn(duration: 0.3))) { fadedOut = false }
            }
        }
        .animation(state.reduceMotion ? nil : .easeInOut(duration: 0.2), value: state.partial)
    }

    // MARK: Header

    private func header(theme: ResolvedTheme, textColor: RGB) -> some View {
        HStack(spacing: 8) {
            Image(systemName: state.statusSymbol)
                .font(.system(size: 12, weight: .semibold))
            Text(state.statusText)
                .font(AppFont.nunito(12, .semibold))
                .lineLimit(1)
            languageChip(textColor: textColor)
            Spacer(minLength: 12)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .help("Drag anywhere on the card to move it")
                .accessibilityHidden(true)
            if state.phase == .paused {
                Button {
                    state.resumeCaptions()
                } label: {
                    Image(systemName: "play.fill").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Resume captions")
                .accessibilityLabel("Resume captions")
            } else if state.isRunning {
                Button {
                    state.pauseCaptions()
                } label: {
                    Image(systemName: "pause.fill").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Pause captions. The last lines stay put.")
                .accessibilityLabel("Pause captions")
            }
        }
        .foregroundStyle(textColor.color.opacity(0.75))
    }

    /// Clickable language chip: shows what's being heard (or the locked
    /// language) and opens a dropdown to pick the spoken language right from the
    /// caption card. Locking a language stops misdetection on the spot.
    private func languageChip(textColor: RGB) -> some View {
        SpokenLanguageMenu(selection: $state.spokenLanguageCode) {
            HStack(spacing: 3) {
                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .semibold))
                Text(state.spokenLanguageDisplay)
                    .font(AppFont.nunito(11, .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(Capsule().fill(textColor.color.opacity(0.12)))
            .contentShape(Capsule())
        }
        .foregroundStyle(textColor.color.opacity(0.8))
        .help("Pick the spoken language, or leave it on Auto")
        .accessibilityLabel("Spoken language: \(state.spokenLanguageDisplay)")
    }

    // MARK: Captions

    @ViewBuilder
    private func captions(textColor: RGB) -> some View {
        // The current line is the live partial (English only, no original yet)
        // or, when nothing is being spoken, the last committed line.
        let current: CaptionLine? = state.partial.map { CaptionLine(text: $0, original: nil) }
            ?? state.lines.last
        if state.calmMode {
            // Calm mode: one line, max contrast, no dimming. Original still
            // sits above it when bilingual is on (it's the point of the mode
            // for the user who needs both).
            currentLine(current, textColor: textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let history = previousLines(current: current)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(history.enumerated()), id: \.offset) { index, line in
                    // Oldest is dimmest: brightness encodes age, no motion.
                    // History shows the English line only (calm, uncluttered).
                    let age = history.count - index
                    Text(line.text)
                        .font(state.fontChoice.font(size: max(13, state.fontSize * 0.72)))
                        .foregroundStyle(textColor.color.opacity(dimming(forAge: age)))
                        .fixedSize(horizontal: false, vertical: true)
                }
                currentLine(current, textColor: textColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The current line, with the original-language text above it (smaller,
    /// dimmed) when bilingual mode supplied one.
    @ViewBuilder
    private func currentLine(_ line: CaptionLine?, textColor: RGB) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let original = line?.original, !original.isEmpty {
                Text(original)
                    .font(state.fontChoice.font(size: max(13, state.fontSize * 0.78)))
                    .foregroundStyle(textColor.color.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(line?.text ?? quietLine)
                .font(state.fontChoice.font(size: state.fontSize, weight: .medium))
                .foregroundStyle(textColor.color.opacity(line == nil ? 0.6 : 1))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Idle copy, playful is allowed here (empty states only).
    private var quietLine: String {
        switch state.phase {
        case .starting: return "One moment, getting my pen ready."
        case .paused: return "Paused. Press play whenever you're ready."
        default: return "It's quiet... too quiet. I'll start writing the moment anyone speaks."
        }
    }

    private func previousLines(current: CaptionLine?) -> [CaptionLine] {
        var history = state.lines
        // The newest final doubles as the current line while nothing is
        // being spoken; don't show it twice.
        if current != nil, state.partial == nil, !history.isEmpty {
            history.removeLast()
        }
        return Array(history.suffix(state.previousLines))
    }

    private func dimming(forAge age: Int) -> Double {
        // age 1 (newest history) ~0.62 down to ~0.26 for age 4.
        max(0.26, 0.74 - Double(age) * 0.12)
    }

    // MARK: Edge states

    /// Calm, zero jokes, fix-first (voice doc). What happened, why, one step.
    private func permissionLost(textColor: RGB, theme: ResolvedTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("macOS turned off my audio access (this can happen after an update). One click fixes it.")
                .font(state.fontChoice.font(size: max(14, state.fontSize * 0.8)))
                .foregroundStyle(textColor.color)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                CapturePermissions.openScreenRecordingSettings()
            }
            .buttonStyle(AccentButtonStyle(theme: theme))
        }
    }

    private func troubleState(message: String, textColor: RGB, theme: ResolvedTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(state.fontChoice.font(size: max(14, state.fontSize * 0.8)))
                .foregroundStyle(textColor.color)
                .fixedSize(horizontal: false, vertical: true)
            Button("Start again") {
                state.startCaptions()
            }
            .buttonStyle(AccentButtonStyle(theme: theme))
        }
    }

    // MARK: Hide on silence

    private func updateSilenceFade(now: Date) {
        guard state.hideOnSilence, state.phase == .listening else {
            if fadedOut { withAnimation(fadeAnimation(.easeIn(duration: 0.3))) { fadedOut = false } }
            return
        }
        let quietFor = now.timeIntervalSince(state.lastEventAt ?? now)
        if quietFor >= 6, !fadedOut {
            withAnimation(fadeAnimation(.easeOut(duration: 1.2))) { fadedOut = true }
        }
    }

    /// System Reduce Motion makes every fade instant (hide-on-silence still
    /// hides; it just stops animating on the way out).
    private func fadeAnimation(_ animation: Animation) -> Animation? {
        state.reduceMotion ? nil : animation
    }
}

/// Burning Flame pill with Abyssal label, the one accent, both modes.
struct AccentButtonStyle: ButtonStyle {
    let theme: ResolvedTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.nunito(13, .bold))
            .foregroundStyle(Palette.abyssal)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Palette.burningFlame.opacity(configuration.isPressed ? 0.75 : 1)))
    }
}

import BlablacadabraCore
import SwiftUI

/// The caption card: header row (status words + icon left, pause right; the
/// whole card drags), then rolling captions. Current line large; up to four
/// previous lines dimmed by recency (brightness encodes age, nothing moves).
/// Width is user-resizable by dragging the card's edges (min 600, persisted);
/// height always fits the content.
struct OverlayView: View {
    @ObservedObject var state: AppState
    @State private var fadedOut = false

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
        .frame(width: max(AppState.overlayMinWidth, state.overlayWidth), alignment: .leading)
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
            // Color the label content directly: the borderless-button menu
            // style otherwise overrides it with a default (dark) control color,
            // which read as black instead of the caption color.
            .foregroundStyle(textColor.color.opacity(0.9))
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(Capsule().fill(textColor.color.opacity(0.12)))
            .contentShape(Capsule())
        }
        .tint(textColor.color)
        .help("Pick the spoken language, or leave it on Auto")
        .accessibilityLabel("Spoken language: \(state.spokenLanguageDisplay)")
    }

    // MARK: Captions

    @ViewBuilder
    private func captions(textColor: RGB) -> some View {
        // The current line is the live partial (English only, no original yet)
        // or, when nothing is being spoken, the last committed line. A partial
        // inherits the previous line's speaker (its own label lands on finalize).
        let current: CaptionLine? = state.partial.map {
            CaptionLine(
                text: $0, original: nil, origin: state.partialOrigin,
                speaker: state.lines.last?.speaker)
        } ?? state.lines.last
        if state.calmMode {
            // Calm mode: one line, max contrast, no dimming. Original still
            // sits above it when bilingual is on (it's the point of the mode
            // for the user who needs both). The speaker chip stays; per-speaker
            // color does not (calm mode = one max-contrast color, by design).
            currentLine(current, textColor: textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let history = previousLines(current: current)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(history.enumerated()), id: \.offset) { index, line in
                    // Oldest is dimmest: brightness encodes age, no motion.
                    // History shows the English line only (calm, uncluttered).
                    let age = history.count - index
                    let opacity = dimming(forAge: age)
                    let color = lineColor(line, base: textColor)
                    originLine(line, textColor: textColor, opacity: opacity) {
                        Text(line.text)
                            .font(state.fontChoice.font(size: max(13, state.fontSize * 0.72)))
                            .foregroundStyle(color.color.opacity(opacity))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                currentLine(current, textColor: textColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The current line, with the original-language text above it when
    /// bilingual mode supplied one. The original (the language being translated
    /// FROM) is drawn in the same (speaker) color, only lightly dimmed, so it
    /// stays clearly readable instead of fading into the background.
    @ViewBuilder
    private func currentLine(_ line: CaptionLine?, textColor: RGB) -> some View {
        let color = line.map { lineColor($0, base: textColor) } ?? textColor
        let body = VStack(alignment: .leading, spacing: 3) {
            if let original = line?.original, !original.isEmpty {
                Text(original)
                    .font(state.fontChoice.font(size: max(13, state.fontSize * 0.78)))
                    .foregroundStyle(color.color.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(line?.text ?? quietLine)
                .font(state.fontChoice.font(size: state.fontSize, weight: .medium))
                .foregroundStyle(color.color.opacity(line == nil ? 0.6 : 1))
                .fixedSize(horizontal: false, vertical: true)
        }
        originLine(line, textColor: textColor, opacity: 1) {
            body
        }
    }

    /// The caption color for a line: the speaker's color when speaker colors are
    /// on, otherwise the base caption text. Calm mode always uses the base color
    /// (one max-contrast line is the whole point of the mode).
    private func lineColor(_ line: CaptionLine, base: RGB) -> RGB {
        state.calmMode ? base : state.speakerColor(for: line.speaker)
    }

    /// Prefixes a caption line with its leading markers: the speaker chip
    /// ("S1"...) when speaker colors are on AND more than one voice has been
    /// heard, then the "Both"-mode source icon (speaker / mic). Each marker
    /// carries a VoiceOver label so meaning never rides on color alone.
    @ViewBuilder
    private func originLine(
        _ line: CaptionLine?, textColor: RGB, opacity: Double,
        @ViewBuilder _ content: () -> some View
    ) -> some View {
        let origin = line?.origin ?? .single
        let chipSpeaker: SpeakerID? = state.showSpeakerLabels ? line?.speaker : nil
        if origin.symbol != nil || chipSpeaker != nil {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let speaker = chipSpeaker {
                    speakerChip(speaker, opacity: opacity)
                }
                if let symbol = origin.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: max(10, state.fontSize * 0.5), weight: .semibold))
                        .foregroundStyle(textColor.color.opacity(opacity * 0.7))
                        .accessibilityLabel(origin.spokenLabel)
                }
                content()
            }
        } else {
            content()
        }
    }

    /// Small colored chip ("S1") leading a line, the non-color-dependent speaker
    /// signal (the label reads as words to VoiceOver / on hover).
    private func speakerChip(_ speaker: SpeakerID, opacity: Double) -> some View {
        let chipColor = state.speakerChipColor(for: speaker)
        return Text(speaker.chipLabel)
            .font(AppFont.nunito(max(10, state.fontSize * 0.5), .bold))
            .foregroundStyle(chipColor.color.opacity(opacity))
            .padding(.vertical, 1)
            .padding(.horizontal, 5)
            .background(Capsule().fill(chipColor.color.opacity(opacity * 0.16)))
            .accessibilityLabel(speaker.spokenLabel)
            .help(speaker.spokenLabel)
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
        // Older lines fade by recency, but never below a floor that keeps them
        // clearly in the caption color. A harsher fade washed toward near-black
        // on a dark card and read as "wrong color" rather than "older".
        // age 1 ~0.77 down to a 0.55 floor by age 3+.
        max(0.55, 0.88 - Double(age) * 0.11)
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

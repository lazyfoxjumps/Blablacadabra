import Foundation
import SwiftUI

/// Drives the live input level meter. Kept separate from `AppState` on purpose:
/// the level updates many times a second, and only the meter view should redraw
/// for it, never the overlay or the menu panel that also observe `AppState`.
@MainActor
final class AudioLevelMonitor: ObservableObject {
    /// 0...1, smoothed. The meter reads this.
    @Published private(set) var level: Double = 0

    /// Feed one buffer's RMS (already gain-applied). Rises instantly to a new
    /// peak, falls gently, so the bar reads like a real level meter rather than
    /// flickering. Called from the audio tap via a main-actor hop.
    func report(rms: Float) {
        // Speech RMS sits around 0.05-0.3; scale so a normal voice fills most
        // of the bar without pinning, and clamp.
        let scaled = min(1.0, Double(rms) * 6)
        level = max(scaled, level * 0.82)
    }

    /// Session ended: drop the bar so it doesn't freeze at the last value.
    func reset() {
        level = 0
    }
}

/// A simple horizontal level bar (flame fill on the slider track). Observes the
/// monitor directly so only this view redraws as the level moves.
struct InputLevelMeter: View {
    @ObservedObject var monitor: AudioLevelMonitor
    let theme: ResolvedTheme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.sliderTrack)
                Capsule()
                    .fill(Palette.burningFlame)
                    .frame(width: max(0, geo.size.width * monitor.level))
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue(Text("\(Int(monitor.level * 100)) percent"))
    }
}

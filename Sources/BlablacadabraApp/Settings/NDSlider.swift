import SwiftUI

/// Custom-drawn slider per the design kit: clearly visible track (Oatmeal in
/// light mode), strong fill, a big knob. Never faint, in either mode.
struct NDSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let theme: ResolvedTheme

    private let trackHeight: Double = 8
    private let knobSize: Double = 22

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let knobX = fraction * (width - knobSize)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.sliderTrack)
                    .frame(height: trackHeight)
                Capsule()
                    .fill(theme.sliderFill)
                    .frame(width: max(trackHeight, knobX + knobSize / 2), height: trackHeight)
                Circle()
                    .fill(theme.sliderFill)
                    .overlay(Circle().strokeBorder(theme.deepSurface, lineWidth: 2))
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: knobX)
                    .shadow(radius: 1, y: 0.5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = min(max((drag.location.x - knobSize / 2) / (width - knobSize), 0), 1)
                        let raw = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                        value = (raw / step).rounded() * step
                    }
            )
        }
        .frame(height: knobSize)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int(value))"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}

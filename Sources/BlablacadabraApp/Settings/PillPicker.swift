import SwiftUI

/// The mockup-style segmented control: equal-width pill chips in a row.
/// Selected chip = soft Burning Flame tint with a Flame border (accent text is
/// Flame in dark mode, Truffle in light, per the palette rules). Unselected
/// chips = thin border, secondary text. Big targets, no native styling.
struct PillPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    let theme: ResolvedTheme

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.value) { option in
                pill(option.value, label: option.label)
            }
        }
    }

    private func pill(_ value: Value, label: String) -> some View {
        let selected = selection == value
        return Button {
            selection = value
        } label: {
            Text(label)
                .font(AppFont.control)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(selected ? theme.accentText : theme.secondaryText)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected ? Palette.burningFlame.opacity(theme.isDark ? 0.16 : 0.28) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            selected
                                ? theme.accentText.opacity(0.5)
                                : theme.secondaryText.opacity(0.25),
                            lineWidth: selected ? 1 : 0.5
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

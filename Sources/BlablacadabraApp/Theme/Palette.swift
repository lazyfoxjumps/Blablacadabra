import SwiftUI

/// Brand palette MP072 by Alex Cristache (user-supplied, locked in the
/// design kit). Every color in the app comes from here or from a user-picked
/// caption color.
enum Palette {
    static let palladian = Color(hex: 0xEEE9DF)
    static let oatmeal = Color(hex: 0xC9C1B1)
    static let blueFantastic = Color(hex: 0x2C3B4D)
    static let burningFlame = Color(hex: 0xFFB162)
    static let truffleTrouble = Color(hex: 0xA35139)
    static let abyssal = Color(hex: 0x1B2632)

    /// Light-mode card surface ("warm paper", from the approved mockups).
    static let warmPaper = Color(hex: 0xF7F4EC)
    /// Soft Burning Flame tint used behind Truffle accent text in light mode
    /// (Flame alone on cream is ~1.7:1, unreadable).
    static let flameTint = Color(hex: 0xFFB162).opacity(0.25)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    init?(hexString: String) {
        var cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(hex: value)
    }
}

/// sRGB components for contrast math and persistence; SwiftUI Color round-trips
/// through NSColor.
struct RGB: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        red = Double(ns.redComponent)
        green = Double(ns.greenComponent)
        blue = Double(ns.blueComponent)
    }

    init?(hexString: String) {
        var cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    var hexString: String {
        String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio between two colors (1...21).
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let lighter = max(a.luminance, b.luminance)
        let darker = min(a.luminance, b.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

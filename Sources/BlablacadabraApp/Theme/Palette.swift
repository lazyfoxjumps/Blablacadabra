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

    /// OKLab coordinates (perceptually uniform). Used to judge when two colors
    /// look "the same" to the eye regardless of how light or dark they are.
    /// Plain sRGB distance collapses every dark color near black, so dark navy
    /// and dark teal read as identical to it; OKLab keeps them honestly apart.
    var oklab: (l: Double, a: Double, b: Double) {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linear(red), g = linear(green), bl = linear(blue)
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return (
            0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        )
    }

    /// Perceptual distance (OKLab ΔE) between two colors. ~0.02 is the
    /// just-noticeable threshold; larger means more clearly different.
    static func perceptualDistance(_ a: RGB, _ b: RGB) -> Double {
        let x = a.oklab, y = b.oklab
        let dl = x.l - y.l, da = x.a - y.a, db = x.b - y.b
        return (dl * dl + da * da + db * db).squareRoot()
    }
}

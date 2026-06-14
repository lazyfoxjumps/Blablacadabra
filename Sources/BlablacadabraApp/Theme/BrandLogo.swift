import AppKit
import SwiftUI

/// The Blablacadabra brand mark (transparent-background burst star + wordmark
/// sparkle), shown in-app wherever a logo belongs. Two artworks: a dark-navy
/// star for LIGHT surfaces and an orange star for DARK surfaces, picked from the
/// active theme. Loaded from the bundled SVGs (scalable, transparent); falls
/// back to an SF Symbol when run outside the .app bundle (e.g. `swift run`).
struct BrandLogo: View {
    /// Whether the surface behind the logo is dark (use the orange artwork).
    let isDark: Bool
    /// Rendered edge length in points.
    var size: CGFloat = 24

    var body: some View {
        if let image = Self.image(isDark: isDark) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityLabel("Blablacadabra")
        } else {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: size * 0.5))
                .foregroundStyle(Palette.burningFlame)
                .frame(width: size, height: size)
                .accessibilityLabel("Blablacadabra")
        }
    }

    private static func image(isDark: Bool) -> NSImage? {
        let name = isDark ? "BlablacadabraLogo-Dark" : "BlablacadabraLogo-Light"
        guard let url = Bundle.main.url(
            forResource: name, withExtension: "svg", subdirectory: "Logo"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }
}

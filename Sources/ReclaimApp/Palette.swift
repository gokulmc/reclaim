import SwiftUI
import AppKit

/// Central color palette for the panel v4 redesign (docs/design/panel.html). The four Docker
/// footprint categories use the exact same hex value in both light and dark per the design's
/// `<style>` block (`.s-cache`/`.s-img`/`.s-cont`/`.s-vol`, `.c-cache`/`.c-img`/`.c-cont`/
/// `.c-vol`), so those are plain static colors. A few text colors (health-pill "Healthy"
/// label, tag foregrounds) use a slightly different tone per scheme to keep contrast against
/// their tinted pill background — exactly what panel.html's `.dark` overrides specify —
/// reproduced here as dynamic `NSColor`s, the same approach as MemBar's `dynamicColor` helper
/// (gokulmc/membar Sources/MemBar/MenuViews.swift).
enum Palette {
    // MARK: - Docker footprint categories

    /// `#0a84ff` — Build cache (`.s-cache` / `.c-cache`).
    static let buildCache = Color(redByte: 0x0A, 0x84, 0xFF)
    /// `#5e5ce6` — Images (`.s-img` / `.c-img`).
    static let images = Color(redByte: 0x5E, 0x5C, 0xE6)
    /// `#ff9f0a` — Containers (`.s-cont` / `.c-cont`).
    static let containers = Color(redByte: 0xFF, 0x9F, 0x0A)
    /// `#34c759` — Your data (`.s-vol` / `.c-vol`).
    static let yourData = Color(redByte: 0x34, 0xC7, 0x59)

    // MARK: - Tags (`.tag.clean` / `.tag.safe` / `.tag.none`)

    static let tagCleanableFG = dynamic(light: 0x0A72E0, dark: 0x4DA3FF)
    static let tagCleanableBG = buildCache.opacity(0.16)

    static let tagSafeFG = dynamic(light: 0x248A3D, dark: 0x5BE07A)
    static let tagSafeBG = yourData.opacity(0.18)

    static let tagNoneFG = Color.secondary
    static let tagNoneBG = Color.secondary.opacity(0.18)

    // MARK: - Health pill (`.pill.ok` in the mockup; amber/red extrapolate the same 16-20%
    // tinted-capsule formula from `DiskLevel`'s existing systemOrange/systemRed, since the
    // approved design card only illustrates the green "Healthy" state)

    static let healthGreenFG = dynamic(light: 0x248A3D, dark: 0x30D158)
    static let healthGreenDot = Color(redByte: 0x34, 0xC7, 0x59)

    // MARK: - CTA button (`.cta` / `.cta:active`)

    static let ctaFill = buildCache
    static let ctaPressedFill = Color(redByte: 0x00, 0x60, 0xDF)

    /// A light/dark pair resolved against the current effective appearance.
    static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark)
                : NSColor(hex: light)
        })
    }
}

extension Color {
    init(redByte r: Int, _ g: Int, _ b: Int) {
        self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

private extension NSColor {
    convenience init(hex: Int) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

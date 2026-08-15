import SwiftUI

// MARK: - Hex color helpers

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

/// Resolves to `light` or `dark` at runtime based on the trait environment.
private func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(Color(hex: dark))
            : UIColor(Color(hex: light))
    })
}

// MARK: - Theme namespace

/// Design-token entry point. See docs/DESIGN_TOKENS.md for the reference table.
enum Theme {
    static let color = AppColor()
    static let spacing = Spacing()
    static let radius = Radius()
    static let font = Typography()
    static let elevation = Elevation()
}

// MARK: - Color tokens

struct AppColor {
    // Brand & accent
    let brand         = adaptive(0x0A84FF, 0x0A84FF)
    let brandPressed  = adaptive(0x0060DF, 0x409CFF)
    let accent        = adaptive(0x30D158, 0x30D158)

    // Battery status scale
    let batteryGood     = adaptive(0x30D158, 0x32D74B)
    let batteryMedium   = adaptive(0xFF9F0A, 0xFFB340)
    let batteryLow      = adaptive(0xFF9500, 0xFF9F0A)
    let batteryCritical = adaptive(0xFF453B, 0xFF6961)

    // Feedback
    let success = adaptive(0x248A3D, 0x30D158)
    let warning = adaptive(0xB25000, 0xFF9F0A)
    let danger  = adaptive(0xD70015, 0xFF453B)

    // Surfaces & text
    let background      = adaptive(0xF2F2F7, 0x000000)
    let surface         = adaptive(0xFFFFFF, 0x1C1C1E)
    let surfaceElevated = adaptive(0xFFFFFF, 0x2C2C2E)
    let border          = adaptive(0xE5E5EA, 0x38383A)
    let textPrimary     = adaptive(0x1C1C1E, 0xFFFFFF)
    let textSecondary   = adaptive(0x6C6C70, 0x98989F)
    let textOnBrand     = adaptive(0xFFFFFF, 0xFFFFFF)

    /// Maps a battery percentage (0...1) to its status color.
    func battery(forPercentage pct: Double) -> Color {
        switch pct {
        case ..<0.10: return batteryCritical
        case ..<0.25: return batteryLow
        case ..<0.60: return batteryMedium
        default:      return batteryGood
        }
    }
}

// MARK: - Spacing (4pt grid)

struct Spacing {
    let xxs: CGFloat = 2
    let xs: CGFloat = 4
    let sm: CGFloat = 8
    let md: CGFloat = 12
    let lg: CGFloat = 16
    let xl: CGFloat = 24
    let xxl: CGFloat = 32
    let xxxl: CGFloat = 48
}

// MARK: - Radius

struct Radius {
    let sm: CGFloat = 8
    let md: CGFloat = 12
    let lg: CGFloat = 16
    let xl: CGFloat = 24
    let pill: CGFloat = 999
}

// MARK: - Typography

struct Typography {
    let largeTitle  = Font.system(size: 34, weight: .bold)
    let title       = Font.system(size: 22, weight: .semibold)
    let headline    = Font.system(size: 17, weight: .semibold)
    let body        = Font.system(size: 17, weight: .regular)
    let callout     = Font.system(size: 16, weight: .regular)
    let subheadline = Font.system(size: 15, weight: .regular)
    let footnote    = Font.system(size: 13, weight: .regular)
    let caption     = Font.system(size: 12, weight: .regular)
    let mono        = Font.system(size: 17, weight: .regular, design: .monospaced)
    let monoLarge   = Font.system(size: 40, weight: .semibold, design: .monospaced)
}

// MARK: - Elevation

struct Elevation {
    struct Shadow { let color: Color; let radius: CGFloat; let y: CGFloat }
    let card    = Shadow(color: .black.opacity(0.08), radius: 8,  y: 2)
    let raised  = Shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    let overlay = Shadow(color: .black.opacity(0.18), radius: 32, y: 12)
}

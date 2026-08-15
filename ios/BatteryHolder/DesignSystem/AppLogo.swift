import SwiftUI

/// A lightning-bolt shape matching the app icon, drawn as a vector so it stays
/// crisp at any size (used by the splash and anywhere a brand mark is needed).
struct BoltShape: Shape {
    // Normalized silhouette (0...1) mirroring tools/generate_appicon.py.
    private static let points: [CGPoint] = [
        CGPoint(x: 0.563, y: 0.02),
        CGPoint(x: 0.269, y: 0.558),
        CGPoint(x: 0.466, y: 0.558),
        CGPoint(x: 0.374, y: 0.98),
        CGPoint(x: 0.744, y: 0.414),
        CGPoint(x: 0.525, y: 0.414),
        CGPoint(x: 0.718, y: 0.02),
    ]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let pts = Self.points.map {
            CGPoint(x: rect.minX + $0.x * rect.width,
                    y: rect.minY + $0.y * rect.height)
        }
        p.move(to: pts[0])
        pts.dropFirst().forEach { p.addLine(to: $0) }
        p.closeSubpath()
        return p
    }
}

/// The BatteryHolder brand mark: a glossy glass battery with a green charge
/// level and a glowing lightning bolt. Scales to whatever frame it's given.
struct AppLogo: View {
    var size: CGFloat = 120

    var body: some View {
        ZStack {
            // Terminal nub
            RoundedRectangle(cornerRadius: size * 0.03, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xD0E6FF), Color(hex: 0x24417A)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.26, height: size * 0.10)
                .offset(y: -size * 0.51)

            // Glass body
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xD0E6FF).opacity(0.85),
                                              Color(hex: 0x24417A).opacity(0.75),
                                              Color(hex: 0x121E42).opacity(0.9)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.78, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                        .stroke(Color(hex: 0x96BEFF).opacity(0.85), lineWidth: max(1, size * 0.012))
                )

            // Green energy fill (lower portion)
            RoundedRectangle(cornerRadius: size * 0.11, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x4AE88C), Color(hex: 0x12965A)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.66, height: size * 0.56)
                .offset(y: size * 0.16)

            // Top glass sheen
            Ellipse()
                .fill(Color.white.opacity(0.35))
                .frame(width: size * 0.7, height: size * 0.28)
                .offset(y: -size * 0.3)
                .blur(radius: size * 0.05)
                .mask(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                    .frame(width: size * 0.78, height: size))

            // Lightning bolt with glow
            BoltShape()
                .fill(LinearGradient(colors: [Color.white, Color(hex: 0xFFCA3C)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.5, height: size * 0.82)
                .shadow(color: Color(hex: 0xFFC246).opacity(0.7), radius: size * 0.09)
                .overlay(
                    BoltShape()
                        .stroke(Color.white.opacity(0.85), lineWidth: max(1, size * 0.008))
                        .frame(width: size * 0.5, height: size * 0.82)
                )
        }
        .frame(width: size, height: size * 1.12)
    }
}

#Preview {
    ZStack {
        LinearGradient(colors: [Color(hex: 0x0E2052), Color(hex: 0x03060F)],
                       startPoint: .top, endPoint: .bottom).ignoresSafeArea()
        AppLogo(size: 160)
    }
}

import SwiftUI

// MARK: - Card

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius.lg, style: .continuous))
            .shadow(color: Theme.elevation.card.color,
                    radius: Theme.elevation.card.radius,
                    y: Theme.elevation.card.y)
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font.headline)
            .foregroundStyle(Theme.color.textOnBrand)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.spacing.md)
            .background(configuration.isPressed ? Theme.color.brandPressed : Theme.color.brand)
            .opacity(enabled ? 1 : 0.4)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font.headline)
            .foregroundStyle(Theme.color.brand)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.spacing.md)
            .background(Theme.color.brand.opacity(configuration.isPressed ? 0.2 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.xxs) {
            Text(title).font(Theme.font.headline).foregroundStyle(Theme.color.textPrimary)
            if let subtitle {
                Text(subtitle).font(Theme.font.footnote).foregroundStyle(Theme.color.textSecondary)
            }
        }
    }
}

// MARK: - Stat pill

struct StatPill: View {
    let label: String
    let value: String
    var tint: Color = Theme.color.brand

    var body: some View {
        VStack(spacing: Theme.spacing.xxs) {
            Text(value).font(Theme.font.mono).foregroundStyle(tint)
            Text(label).font(Theme.font.caption).foregroundStyle(Theme.color.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.spacing.md)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius.md, style: .continuous))
    }
}

// MARK: - Pin chip

struct PinChip: View {
    let pin: Pin
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(pin.name).font(Theme.font.caption.weight(.semibold))
            if let ch = pin.adcChannel {
                Text(ch).font(.system(size: 9)).opacity(0.7)
            }
        }
        .padding(.horizontal, Theme.spacing.md)
        .padding(.vertical, Theme.spacing.sm)
        .foregroundStyle(isSelected ? Theme.color.textOnBrand : Theme.color.textPrimary)
        .background(isSelected ? Theme.color.brand : Theme.color.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.sm, style: .continuous)
                .stroke(pin.wifiSafeADC ? Color.clear : Theme.color.warning.opacity(0.6), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius.sm, style: .continuous))
        .opacity(pin.supportsADC ? 1 : 0.35)
    }
}

// MARK: - Battery gauge

struct BatteryGauge: View {
    /// 0...1
    let fraction: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.color.border, lineWidth: 14)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: fraction)
        }
    }
}

// MARK: - Sparkline

struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.color.brand

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            Path { p in
                guard let first = pts.first else { return }
                p.move(to: first)
                pts.dropFirst().forEach { p.addLine(to: $0) }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let minV = values.min() ?? 0
        let maxV = values.max() ?? 1
        let range = max(0.0001, maxV - minV)
        let stepX = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            let x = CGFloat(i) * stepX
            let y = size.height * (1 - CGFloat((v - minV) / range))
            return CGPoint(x: x, y: y)
        }
    }
}

// MARK: - Transport badge

struct TransportBadge: View {
    let transport: FlashTransport
    var body: some View {
        Label(transport.displayName, systemImage: transport.systemImage)
            .font(Theme.font.caption.weight(.semibold))
            .padding(.horizontal, Theme.spacing.sm)
            .padding(.vertical, Theme.spacing.xs)
            .background(Theme.color.brand.opacity(0.12))
            .foregroundStyle(Theme.color.brand)
            .clipShape(Capsule())
    }
}

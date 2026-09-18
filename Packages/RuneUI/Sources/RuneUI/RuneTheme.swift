import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public enum RunePalette {
    public static let accent = adaptive(0x355B49, 0xA9C7AE)
    public static let canvas = adaptive(0xF5F3EE, 0x141815)
    public static let surface = adaptive(0xFFFFFF, 0x202621)
    public static let ink = adaptive(0x202B24, 0xF0F1E9)
    public static let secondary = adaptive(0x686F65, 0xABB2A8)
    public static let line = adaptive(0xDDDCD3, 0x3A423B)
    public static let danger = adaptive(0xA2433A, 0xF29B91)
    public static let amber = adaptive(0x8C5C28, 0xD8B076)
    public static let paper = adaptive(0xEAECE2, 0x29372E)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
        #else
        return Color(red: Double((light >> 16) & 255) / 255,
                     green: Double((light >> 8) & 255) / 255, blue: Double(light & 255) / 255)
        #endif
    }
}

public struct RuneMark: View {
    public init() {}
    public var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            Path { path in
                path.move(to: CGPoint(x: w * 0.28, y: h * 0.9))
                path.addLine(to: CGPoint(x: w * 0.28, y: h * 0.1))
                path.addLine(to: CGPoint(x: w * 0.76, y: h * 0.35))
                path.addLine(to: CGPoint(x: w * 0.28, y: h * 0.59))
                path.addLine(to: CGPoint(x: w * 0.76, y: h * 0.89))
            }.stroke(style: StrokeStyle(lineWidth: max(2, w * 0.065), lineCap: .round, lineJoin: .round))
        }.accessibilityHidden(true)
    }
}

public struct RuneSectionTitle: View {
    let title: String
    let subtitle: String?
    public init(_ title: String, subtitle: String? = nil) { self.title = title; self.subtitle = subtitle }
    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline).foregroundStyle(RunePalette.ink)
            Spacer()
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(RunePalette.secondary) }
        }
    }
}

public struct RuneStatusLabel: View {
    public let phase: StudioPhase
    public init(_ phase: StudioPhase) { self.phase = phase }
    public var body: some View {
        Label(phase.title, systemImage: phase.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(phase == .approval ? RunePalette.amber : RunePalette.accent)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background((phase == .approval ? RunePalette.amber : RunePalette.accent).opacity(0.09), in: Capsule())
    }
}

public struct RuneEmptyState: View {
    let title: String, detail: String, symbol: String
    public init(_ title: String, detail: String, symbol: String) {
        self.title = title; self.detail = detail; self.symbol = symbol
    }
    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(RunePalette.accent)
                .frame(width: 72, height: 72).background(RunePalette.paper, in: RoundedRectangle(cornerRadius: 24))
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(RunePalette.ink)
            Text(detail).font(.subheadline).foregroundStyle(RunePalette.secondary).multilineTextAlignment(.center)
        }.padding(28).frame(maxWidth: .infinity)
    }
}

public struct RunePrimaryStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold)).foregroundStyle(RunePalette.canvas)
            .padding(.horizontal, 20).padding(.vertical, 15).frame(maxWidth: .infinity)
            .background(RunePalette.accent.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18)).opacity(enabled ? 1 : 0.45)
    }
}

private struct RuneGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let radius: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(RunePalette.surface, in: RoundedRectangle(cornerRadius: radius))
        } else if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

public extension View {
    func runeGlass(radius: CGFloat = 24) -> some View { modifier(RuneGlass(radius: radius)) }
    func runeSurface(radius: CGFloat = 22) -> some View {
        background(RunePalette.surface, in: RoundedRectangle(cornerRadius: radius))
    }
}

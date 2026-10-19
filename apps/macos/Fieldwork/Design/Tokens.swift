import AppKit
import SwiftUI

/// Design tokens mirrored from design/tokens.json. Colors resolve per appearance.
enum Tokens {
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    static let window = dynamic(light: 0xF5F6FA, dark: 0x13151B)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x20232D)
    static let textPrimary = dynamic(light: 0x161820, dark: 0xF1F3F8)
    static let textSecondary = dynamic(light: 0x626775, dark: 0xABB3C5)
    static let accent = dynamic(light: 0x2868E8, dark: 0x82A7FF)
    static let warning = dynamic(light: 0xA95F00, dark: 0xFFC46A)
    static let error = dynamic(light: 0xB92D41, dark: 0xFF8E9A)
    /// The field stays the same in both appearances for stable contrast.
    static let field = NSColor(hex: 0x192A36)
    static let grid = NSColor(hex: 0x5E727C)
    static let fieldAccent = NSColor(hex: 0x82A7FF)

    /// The realistic field: mowed grass, or a tarp for indoor floors. Shared by
    /// the field picker's thumbnails and the editor's grass view.
    enum Turf {
        static let grass = NSColor(hex: 0x338545)
        static let stripe = NSColor(hex: 0x3D944F)
        static let endZone = NSColor(hex: 0x266B3B)
        static let tarp = NSColor(hex: 0x525969)
    }

    /// The paper field: cream graph paper with an orange step grid, like a printed drill chart.
    enum Paper {
        static let paper = NSColor(hex: 0xFBF4E4)
        static let gridMinor = NSColor(hex: 0xF3D9B5)
        static let gridMajor = NSColor(hex: 0xE8B27A)
        static let line = NSColor(hex: 0x8E8E8E)
        static let border = NSColor(hex: 0x1E1E1E)
        /// Labels, selection rings and paths drawn on paper.
        static let ink = NSColor(hex: 0x2A2A2A)
    }

    static let sectionPalette: [NSColor] = [0x82A7FF, 0xFFC46A, 0x7FD6B4, 0xF29CC6, 0xB8A6FF, 0xFF9F7A, 0x9FD4FF, 0xE4E07C, 0xC3C8D4, 0x8EE08E].map { NSColor(hex: $0) }

    static func sectionColor(_ index: Int) -> NSColor { sectionPalette[((index % sectionPalette.count) + sectionPalette.count) % sectionPalette.count] }

    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 10, panel: CGFloat = 12, cluster: CGFloat = 20
    }

    enum Layout {
        static let navigator: CGFloat = 190, inspector: CGFloat = 260, timeline: CGFloat = 170, status: CGFloat = 22
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    static let fwWindow = Color(nsColor: Tokens.window)
    static let fwSurface = Color(nsColor: Tokens.surface)
    static let fwSecondary = Color(nsColor: Tokens.textSecondary)
    static let fwAccent = Color(nsColor: Tokens.accent)
    static let fwWarning = Color(nsColor: Tokens.warning)
    static let fwError = Color(nsColor: Tokens.error)
}

/// System Liquid Glass on macOS 26+, system material on older versions, and an
/// opaque surface when Reduce Transparency is on. Used only for floating
/// control clusters, never for the field, waveform or inspector rows.
struct FloatingGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var cornerRadius: CGFloat = Tokens.Radius.cluster

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color.fwSurface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        }
    }
}

extension View {
    func floatingGlass(cornerRadius: CGFloat = Tokens.Radius.cluster) -> some View {
        modifier(FloatingGlass(cornerRadius: cornerRadius))
    }

    /// Groups adjacent glass clusters so they blend correctly on macOS 26.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 12) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

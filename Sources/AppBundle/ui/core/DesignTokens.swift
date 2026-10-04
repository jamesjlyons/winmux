import AppKit
import SwiftUI

// Shared neutral chrome follows macOS appearance. Explicit solid-color themes
// retain their chosen color and use a matching foreground appearance.

enum GlassToken {
    // Surface recipe (originally the sidebar surface, now shared by all chrome)
    static let tint = Color(hue: 0, saturation: 0, brightness: 0.50)
    static let tintOpacity: Double = 0.025
    static let scrimOpacity: Double = 0.12
    static let highlightPeak: Double = 0.025
    static let borderOpacity: Double = 0.09
    static let separatorOpacity: Double = 0.07
    // Width of the refractive Liquid Glass edge band (macOS 26). Wider = more visible
    // refraction; the main knob for how pronounced the glassy border reads.
    static let refractiveBorderWidth: CGFloat = 1

    // Interactive fills layered on glass
    static let fillActive: Double = 0.10
    static let fillHover: Double = 0.055
    static let fillResting: Double = 0.025
    static let fillFaint: Double = 0.015

    // Strokes around interactive elements
    static let strokeActive: Double = 0.12
    static let strokeHover: Double = 0.10
    static let strokeResting: Double = 0.035
    static let cardStroke: Double = 0.05

    // Text emphasis on glass
    static let textPrimary: Double = 0.92
    static let textSecondary: Double = 0.74
    static let textTertiary: Double = 0.58
    static let textQuaternary: Double = 0.48
}

enum RadiusToken {
    static let row: CGFloat = 8 // rows, drag proxies, small chips
    static let card: CGFloat = 10 // status cards, dropdown menus
    static let section: CGFloat = 12 // sidebar sections, tab strip, alert panels
    static let panel: CGFloat = 14 // panel outer edges
}

enum StrokeToken {
    static let hairline: CGFloat = 0.5
    static let control: CGFloat = 0.75
    static let emphasis: CGFloat = 1.0
}

struct ShadowToken {
    let opacity: Double
    let radius: CGFloat
    let y: CGFloat

    static let resting = ShadowToken(opacity: 0.15, radius: 6, y: 2)
    static let raised = ShadowToken(opacity: 0.18, radius: 8, y: 4)
    static let hover = ShadowToken(opacity: 0.35, radius: 12, y: 6)
}

enum MotionToken {
    static let hover = Animation.interactiveSpring(response: 0.34, dampingFraction: 0.86, blendDuration: 0.06)
    static let pill = Animation.spring(response: 0.28, dampingFraction: 0.72, blendDuration: 0.08)
    static let appear = Animation.spring(response: 0.30, dampingFraction: 0.85)
    static let quick = Animation.easeOut(duration: 0.12)
}

extension View {
    func glassShadow(_ token: ShadowToken) -> some View {
        shadow(color: Color.black.opacity(token.opacity), radius: token.radius, x: 0, y: token.y)
    }
}

enum ChromePalette {
    static let background = NSColor(name: "WinMuxChromeBackground") { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(srgbRed: dark ? 0.12 : 0.955, green: dark ? 0.12 : 0.955,
                       blue: dark ? 0.13 : 0.96, alpha: 1)
    }
    static let separator = NSColor.separatorColor

    static func customColor(_ hex: String) -> NSColor {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x191B20
        return NSColor(srgbRed: Double((value >> 16) & 0xff) / 255,
                       green: Double((value >> 8) & 0xff) / 255,
                       blue: Double(value & 0xff) / 255, alpha: 1)
    }

    static func appearance(for color: NSColor) -> NSAppearance.Name {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .darkAqua }
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        return 1.05 / (luminance + 0.05) >= (luminance + 0.05) / 0.05 ? .darkAqua : .aqua
    }
}

extension ChromeSolidColor {
    var nsColor: NSColor {
        if self == .system { return ChromePalette.background }
        let components = rgb
        return NSColor(srgbRed: components.red, green: components.green, blue: components.blue, alpha: 1)
    }
    var color: Color { Color(nsColor: nsColor) }
}

extension WorkspaceSidebarConfig {
    var resolvedSolidChromeNSColor: NSColor {
        solidChromeColor == .custom ? ChromePalette.customColor(solidChromeCustomColor) : solidChromeColor.nsColor
    }
    var resolvedSolidChromeColor: Color { Color(nsColor: resolvedSolidChromeNSColor) }
    var chromeAppearance: NSAppearance.Name? {
        chromeStyle == .solid && solidChromeColor != .system ? ChromePalette.appearance(for: resolvedSolidChromeNSColor) : nil
    }
    var chromeColorScheme: ColorScheme? {
        chromeAppearance.map { $0 == .darkAqua ? .dark : .light }
    }
}

extension WorkspaceSidebarConfiguration {
    var resolvedSolidChromeNSColor: NSColor {
        solidChromeColor == .custom ? ChromePalette.customColor(solidChromeCustomColor) : solidChromeColor.nsColor
    }
    var resolvedSolidChromeColor: Color { Color(nsColor: resolvedSolidChromeNSColor) }
    var chromeAppearance: NSAppearance.Name? {
        chromeStyle == .solid && solidChromeColor != .system ? ChromePalette.appearance(for: resolvedSolidChromeNSColor) : nil
    }
    var chromeColorScheme: ColorScheme? {
        chromeAppearance.map { $0 == .darkAqua ? .dark : .light }
    }
}

extension Color {
    init(chromeHex: String) {
        let hex = chromeHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(hex, radix: 16) ?? 0x191B20
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255,
        )
    }

    var chromeHex: String {
        let components = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int((components.redComponent * 255).rounded()), Int((components.greenComponent * 255).rounded()), Int((components.blueComponent * 255).rounded()))
    }
}

/// Native material supplies depth; a quiet wash and hairline keep shared chrome
/// readable in either appearance without layering another glossy card over it.
struct GlassSurface<S: Shape>: View {
    @Environment(\.colorScheme) private var colorScheme
    let shape: S
    var hasHighlight: Bool = false
    var hasBorder: Bool = true
    var style: ChromeStyle = .liquidGlass
    var solidColor: Color = Color(nsColor: ChromePalette.background)

    var body: some View {
        ZStack {
            base
            if style == .liquidGlass {
                shape.fill((colorScheme == .dark ? Color.black : .white).opacity(GlassToken.scrimOpacity))
                shape.fill(GlassToken.tint.opacity(GlassToken.tintOpacity))
                    .blendMode(.plusLighter)
            }
            if hasHighlight, style == .liquidGlass {
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(GlassToken.highlightPeak), location: 0),
                            .init(color: Color.white.opacity(GlassToken.highlightPeak * 0.25), location: 0.12),
                            .init(color: Color.clear, location: 0.45),
                        ],
                        startPoint: .top,
                        endPoint: .bottom,
                    )
                )
                .blendMode(.screen)
            }
            if hasBorder {
                borderEdge
            }
        }
        .compositingGroup()
        // `glassEffect` is backed by a rectangular AppKit layer. Clip the composed result,
        // not only its SwiftUI fills, so that backing layer cannot show beyond a shaped edge.
        .clipShape(shape)
    }

    @ViewBuilder
    private var base: some View {
        switch style {
        case .solid:
            shape.fill(solidColor)
        case .liquidGlass:
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular.interactive(false), in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
            }
        }
    }

    private var borderEdge: some View {
        shape.stroke(Color.primary.opacity(GlassToken.borderOpacity), lineWidth: StrokeToken.hairline)
    }
}

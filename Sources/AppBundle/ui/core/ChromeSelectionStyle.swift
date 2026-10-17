import AppKit
import SwiftUI

/// Selection survives focus changes; keyboard navigation never masquerades as hover.
struct ChromeItemState: Equatable {
    var isSelected = false
    var isFocused = false
    var isHovered = false
    var isKeyboardTarget = false
    var isGroup = false

    var isRaised: Bool { !isGroup && (isSelected || isFocused) }
}

enum ChromeControlToken {
    static let addressHeight: CGFloat = 26
    static let controlRadius: CGFloat = 13
    static let hoverOpacity = 0.055
    static let groupOpacity = 0.035
    static let focusRingWidth: CGFloat = 1.5
    static let transition = Animation.easeOut(duration: 0.12)

    static func selectionColor(dark: Bool, focused: Bool) -> Color {
        dark ? Color(white: focused ? 0.30 : 0.25)
            : Color.white.opacity(focused ? 0.96 : 0.76)
    }
}

/// Sidebar depth stays close to its near-black foundation. Other chrome keeps
/// its existing contrast, and both palettes share the light appearance.
enum ChromeSelectionPalette {
    case standard
    case sidebar

    func selectionColor(dark: Bool, focused: Bool) -> Color {
        if self == .sidebar && dark { return Color(chromeHex: focused ? "#1E1E1E" : "#1B1B1B") }
        return ChromeControlToken.selectionColor(dark: dark, focused: focused)
    }

    func hoverColor(dark: Bool) -> Color {
        self == .sidebar && dark ? Color(chromeHex: "#191919") : Color.primary.opacity(ChromeControlToken.hoverOpacity)
    }

    func outlineColor(dark: Bool, focused: Bool, increasedContrast: Bool) -> Color {
        if increasedContrast { return Color.primary.opacity(0.55) }
        if self == .sidebar && dark { return Color(chromeHex: focused ? "#303030" : "#282828") }
        return Color.primary.opacity(focused ? 0.14 : 0.08)
    }

    func shadowOpacity(dark: Bool, focused: Bool) -> Double {
        self == .sidebar && dark ? 0 : (focused ? 0.12 : 0.06)
    }
}

/// Cheap fills sit over the shared glass shell. Rows do not create extra blur layers.
struct ChromeSelectionBackground: View {
    let state: ChromeItemState
    var cornerRadius: CGFloat = ChromeControlToken.controlRadius
    var transition: Animation? = ChromeControlToken.transition
    var palette: ChromeSelectionPalette = .standard
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(fill)
            .shadow(color: .black.opacity(state.isRaised
                    ? palette.shadowOpacity(dark: colorScheme == .dark, focused: state.isFocused) : 0),
                    radius: 2, y: 1)
            .overlay {
                if state.isRaised {
                    shape.strokeBorder(palette.outlineColor(dark: colorScheme == .dark, focused: state.isFocused,
                                                           increasedContrast: contrast == .increased),
                                       lineWidth: contrast == .increased ? 1 : 0.5)
                }
                if state.isKeyboardTarget {
                    shape.strokeBorder(Color.accentColor, lineWidth: ChromeControlToken.focusRingWidth)
                }
            }
            .animation(reduceMotion ? nil : transition, value: state)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var fill: Color {
        if state.isRaised { return palette.selectionColor(dark: colorScheme == .dark, focused: state.isFocused) }
        if state.isHovered { return palette.hoverColor(dark: colorScheme == .dark) }
        if state.isGroup && state.isFocused { return Color.primary.opacity(ChromeControlToken.groupOpacity) }
        return .clear
    }
}

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

/// Cheap fills sit over the shared glass shell. Rows do not create extra blur layers.
struct ChromeSelectionBackground: View {
    let state: ChromeItemState
    var cornerRadius: CGFloat = ChromeControlToken.controlRadius
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(fill)
            .shadow(color: .black.opacity(state.isRaised ? (state.isFocused ? 0.12 : 0.06) : 0),
                    radius: 2, y: 1)
            .overlay {
                if state.isRaised {
                    shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.55 : state.isFocused ? 0.14 : 0.08),
                                       lineWidth: contrast == .increased ? 1 : 0.5)
                }
                if state.isKeyboardTarget {
                    shape.strokeBorder(Color.accentColor, lineWidth: ChromeControlToken.focusRingWidth)
                }
            }
            .animation(reduceMotion ? nil : ChromeControlToken.transition, value: state)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var fill: Color {
        if state.isRaised { return ChromeControlToken.selectionColor(dark: colorScheme == .dark, focused: state.isFocused) }
        if state.isHovered { return Color.primary.opacity(ChromeControlToken.hoverOpacity) }
        if state.isGroup && state.isFocused { return Color.primary.opacity(ChromeControlToken.groupOpacity) }
        return .clear
    }
}

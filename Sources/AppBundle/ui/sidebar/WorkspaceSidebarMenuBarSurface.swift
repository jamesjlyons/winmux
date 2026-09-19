import AppKit
import SwiftUI

private struct WorkspaceSidebarMenuBarStyleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var workspaceSidebarMenuBarStyle: Bool {
        get { self[WorkspaceSidebarMenuBarStyleKey.self] }
        set { self[WorkspaceSidebarMenuBarStyleKey.self] = newValue }
    }
}

/// Clear glass keeps the desktop visible, with only a light contrast wash beneath it.
struct WorkspaceSidebarMenuBarSurface<S: Shape>: View {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.clear, in: shape)
                .background {
                    shape.fill((colorScheme == .dark ? Color.black : .white).opacity(0.12))
                }
                .clipShape(shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }
}

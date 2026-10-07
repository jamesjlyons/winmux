import SwiftUI
import WorkspaceCore

/// The close control is a sibling of the row button, so clicking it never also
/// selects/drags the row. Reserve its width to keep titles stable during hover.
struct WorkspaceSidebarHoverClose: ViewModifier {
    let surface: SurfaceID?
    let title: String
    let actions: WorkspaceSidebarActions
    var selection: ChromeItemState? = nil
    @State private var isHovered = false
    @Environment(\.workspaceSidebarMenuBarStyle) private var menuBarStyle
    @Environment(\.workspaceSidebarCompactRows) private var isCompact

    func body(content: Content) -> some View {
        if let surface, !isCompact {
            HStack(spacing: 0) {
                content
                    .environment(\.workspaceSidebarExternalRowSelection, selection != nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { actions.send(.closeSurface(surface)) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close \(title)")
                .accessibilityLabel("Close \(title)")
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }
            .background {
                if let selection {
                    ChromeSelectionBackground(state: hoveredSelection(selection), cornerRadius: menuBarStyle ? 5 : 7)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
        } else { content }
    }

    private func hoveredSelection(_ selection: ChromeItemState) -> ChromeItemState {
        var result = selection
        result.isHovered = result.isHovered || isHovered
        return result
    }
}

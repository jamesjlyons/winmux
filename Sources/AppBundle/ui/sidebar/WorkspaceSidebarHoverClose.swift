import SwiftUI
import WorkspaceCore

/// The close control is a sibling of the row button, so clicking it never also
/// selects/drags the row. Reserve its width to keep titles stable during hover.
struct WorkspaceSidebarHoverClose: ViewModifier {
    let surface: SurfaceID?
    let title: String
    let actions: WorkspaceSidebarActions
    @State private var isHovered = false

    func body(content: Content) -> some View {
        if let surface {
            HStack(spacing: 0) {
                content.frame(maxWidth: .infinity, alignment: .leading)
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
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
        } else { content }
    }
}

import AppKit
import SwiftUI
import WorkspaceCore

struct WorkspaceSidebarOptionalDragModifier: ViewModifier {
    let isEnabled: Bool
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    var surface: SurfaceID? = nil
    @State private var isDragging = false
    @Environment(\.tabSelection) private var tabSelection

    func body(content: Content) -> some View {
        if isEnabled {
            content.highPriorityGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in
                        guard !WorkspaceSidebarTabReorderState.shared.isSettling else { return }
                        guard isDragging || tabSelection.allowsDrag else { return }
                        if !isDragging {
                            isDragging = true
                            beginWorkspaceSidebarItemDrag()
                            if let surface {
                                WorkspaceSidebarTabReorderState.shared.begin(surface,
                                    pointer: currentWorkspaceSidebarDragPointer(), translation: value.translation)
                            }
                        }
                        onChanged(currentWorkspaceSidebarDragPointer())
                    }
                    .onEnded { _ in
                        guard isDragging else { return }
                        onEnded(currentWorkspaceSidebarDragPointer())
                        if isDragging {
                            isDragging = false
                            endWorkspaceSidebarItemDrag()
                        }
                    },
            )
        } else {
            content
        }
    }
}

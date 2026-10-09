import AppKit
import SwiftUI

struct WorkspaceSidebarOptionalDragModifier: ViewModifier {
    let isEnabled: Bool
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    @State private var isDragging = false
    @Environment(\.tabSelection) private var tabSelection

    func body(content: Content) -> some View {
        if isEnabled {
            content.highPriorityGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { _ in
                        guard isDragging || tabSelection.allowsDrag else { return }
                        if !isDragging {
                            isDragging = true
                            beginWorkspaceSidebarItemDrag()
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

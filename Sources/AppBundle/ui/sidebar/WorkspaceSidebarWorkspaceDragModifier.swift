import AppKit
import SwiftUI

struct WorkspaceSidebarWorkspaceDragModifier: ViewModifier {
    let name: String
    let isEnabled: Bool
    let actions: WorkspaceSidebarActions
    @GestureState private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .highPriorityGesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .updating($isDragging) { _, dragging, _ in dragging = true }
                        .onChanged { value in
                            WorkspaceSidebarWorkspaceReorderState.shared.update(
                                sourceName: name,
                                pointer: currentWorkspaceSidebarDragPointer(),
                                translation: value.translation
                            )
                        }
                        .onEnded { value in
                            WorkspaceSidebarWorkspaceReorderState.shared.finish(
                                sourceName: name,
                                pointer: currentWorkspaceSidebarDragPointer(),
                                translation: value.translation,
                                reduceMotion: reduceMotion,
                                actions: actions
                            )
                        }
                )
                .onChange(of: isDragging) { dragging in
                    if !dragging && !WorkspaceSidebarWorkspaceReorderState.shared.isSettling {
                        WorkspaceSidebarWorkspaceReorderState.shared.cancel(sourceName: name)
                    }
                }
                .onDisappear { WorkspaceSidebarWorkspaceReorderState.shared.cancel(sourceName: name) }
        } else {
            content
        }
    }

}

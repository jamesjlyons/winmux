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
                                pointer: currentDragPointer(),
                                translation: value.translation
                            )
                        }
                        .onEnded { value in
                            WorkspaceSidebarWorkspaceReorderState.shared.finish(
                                sourceName: name,
                                pointer: currentDragPointer(),
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

    private func currentDragPointer() -> CGPoint {
        // Use the event's screen position, including when AppKit delivers a queued
        // drag event before the global cursor sample has caught up.
        if let event = NSApp.currentEvent, event.window != nil,
           event.type == .leftMouseDragged || event.type == .leftMouseUp {
            MousePointerTracker.shared.note(event: event)
        } else {
            noteCurrentMousePointerSample()
        }
        return MousePointerTracker.shared.currentSample.point
    }
}

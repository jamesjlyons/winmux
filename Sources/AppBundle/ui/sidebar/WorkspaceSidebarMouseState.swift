import AppKit

@MainActor
func currentWorkspaceSidebarDragPointer(event: NSEvent? = nil) -> CGPoint {
    // A queued drag/up event can precede the global cursor sample. Use the
    // event's location for both window drops and group reordering.
    if let event = event ?? NSApp.currentEvent, event.window != nil,
       event.type == .leftMouseDragged || event.type == .leftMouseUp {
        MousePointerTracker.shared.note(event: event)
    } else {
        noteCurrentMousePointerSample()
    }
    return MousePointerTracker.shared.currentSample.point
}

func isMouseWindowDragInProgress(kind: MouseManipulationKind, draggedWindowId: UInt32?, isLeftMouseButtonDown: Bool) -> Bool {
    kind == .move && draggedWindowId != nil && isLeftMouseButtonDown
}

@MainActor
func isMouseWindowDragInProgress() -> Bool {
    isMouseWindowDragInProgress(
        kind: getCurrentMouseManipulationKind(),
        draggedWindowId: currentlyManipulatedWithMouseWindowId,
        isLeftMouseButtonDown: isLeftMouseButtonDown,
    )
}

@MainActor
func isMousePushedAgainstDisplayEdge() -> Bool {
    let mouseLocation = NSEvent.mouseLocation
    let screenFrame = NSScreen.screens
        .first(where: { $0.frame.contains(mouseLocation) })?
        .frame ?? NSScreen.main?.frame
    guard let screenFrame else { return false }
    return mouseLocation.x <= screenFrame.minX + workspaceSidebarDisplayEdgeCompactionMargin ||
        mouseLocation.x >= screenFrame.maxX - workspaceSidebarDisplayEdgeCompactionMargin ||
        mouseLocation.y <= screenFrame.minY + workspaceSidebarDisplayEdgeCompactionMargin ||
        mouseLocation.y >= screenFrame.maxY - workspaceSidebarDisplayEdgeCompactionMargin
}

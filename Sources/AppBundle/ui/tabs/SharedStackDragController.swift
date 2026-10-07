import AppKit
import WorkspaceCore

struct SharedStackDrop: Equatable {
    let pane: SurfacePane
    let destination: BrowserSurfaceDropDestination
}

@MainActor
func resolveSharedStackDrop(_ pane: SurfacePane, pointer: CGPoint,
                            controller: BrowserWorkspaceController = .shared) -> SharedStackDrop? {
    guard let moving = controller.surfaceTree.node(for: pane),
          moving.surfaces.allSatisfy(controller.canMoveSurface), let representative = moving.surfaces.first,
          let name = controller.surfaceTree.workspace(of: pane), let source = Workspace.existing(byName: name) else { return nil }
    let workspace = pointer.monitorApproximation.activeWorkspace
    guard workspace.isVisible, workspace.projectId == source.projectId, workspace.isPinnedGroup == source.isPinnedGroup else { return nil }
    if let header = sharedStackHeaderTarget(at: pointer, excluding: Set(moving.surfaces), in: workspace, controller: controller) {
        return .init(pane: pane, destination: .init(source: representative, target: header.surface, zone: .tab,
            targetFrame: header.frame, sourceWorkspace: name, targetWorkspace: workspace.name, targetStack: header.id))
    }
    for placement in controller.plannedSurfaces(in: workspace) where placement.visible && !moving.surfaces.contains(placement.surfaceID) {
        guard controller.canMoveSurface(placement.surfaceID),
              let frame = surfaceDropTargetFrame(placement, workspace: workspace, controller: controller),
              let zone = WindowIntentZoneBuilder.zone(at: pointer, in: frame),
              zone != .tab || config.windowTabs.enabled,
              zone != .middle || source === workspace else { continue }
        return .init(pane: pane, destination: .init(source: representative, target: placement.surfaceID,
            zone: zone, targetFrame: frame, sourceWorkspace: name, targetWorkspace: workspace.name))
    }
    return nil
}

@MainActor
@discardableResult
func commitSharedStackDrop(_ drop: SharedStackDrop, pointer: CGPoint,
                           controller: BrowserWorkspaceController = .shared) -> Bool {
    guard resolveSharedStackDrop(drop.pane, pointer: pointer, controller: controller) == drop else { return false }
    let destination = drop.destination
    let edit: (inout SurfaceTree) -> Bool = { tree in
        switch destination.zone {
        case .middle: return tree.swap(drop.pane, .surface(destination.target))
        case .tab:
            // Joining a stack happens after the complete cross-View transfer.
            if tree.workspace(of: drop.pane) != destination.targetWorkspace {
                switch drop.pane {
                case .surface(let id): guard tree.moveToRoot(id, in: destination.targetWorkspace) else { return false }
                case .group(let id): guard tree.moveGroupToRoot(id, in: destination.targetWorkspace) else { return false }
                }
            }
            return tree.insertIntoStack(drop.pane, with: destination.target, inStack: destination.targetStack)
        case .left: return tree.place(drop.pane, beside: .surface(destination.target), toward: .left)
        case .right: return tree.place(drop.pane, beside: .surface(destination.target), toward: .right)
        case .top: return tree.place(drop.pane, beside: .surface(destination.target), toward: .up)
        case .bottom: return tree.place(drop.pane, beside: .surface(destination.target), toward: .down)
        }
    }
    guard controller.editOrganization(in: [destination.sourceWorkspace, destination.targetWorkspace], edit) else { return false }
    return true
}

/// Tab/header drags preview a shared edit without moving one owner's window on
/// behalf of an entire mixed arrangement. Release revalidates the captured tree.
@MainActor
final class SharedStackDragController {
    static let shared = SharedStackDragController()
    private(set) var pane: SurfacePane?
    private var layoutAtStart: SurfaceTree?
    private var selection: SurfaceID?
    private var generation: UInt64?
    private var invalidated = false

    func update(_ pane: SurfacePane, selecting surface: SurfaceID,
                at pointer: CGPoint = normalizeAppKitScreenPoint(NSEvent.mouseLocation)) {
        let controller = BrowserWorkspaceController.shared
        guard !invalidated else { return }
        if self.pane == nil {
            guard controller.surfaceTree.node(for: pane)?.surfaces.contains(surface) == true else { return }
            self.pane = pane; layoutAtStart = controller.surfaceTree; selection = surface
            generation = controller.focusCoordinator.generation
            beginWorkspaceSidebarItemDrag()
        }
        guard self.pane == pane, layoutAtStart == controller.surfaceTree else {
            invalidated = true
            clearFeedback(at: pointer)
            return
        }
        MousePointerTracker.shared.note(point: pointer)
        postWorkspaceSidebarDragPointerNotification(workspaceSidebarDragPointerChangedNotification, pointer: pointer)
        if let preview = workspaceSidebarSurfaceSourcePreview(pane.sidebarDragSubject) {
            WindowDragCursorProxyPanel.shared.show(preview: preview, mouseScreenPoint: denormalizedAppKitScreenPoint(pointer))
        }
        if let target = workspaceSidebarSurfaceDragTarget(pane.sidebarDragSubject, at: pointer) {
            previewWorkspaceSidebarSurfaceDrop(pane.sidebarDragSubject, target: target)
            WindowDropIntentOverlayPanelController.shared.hide()
            return
        }
        clearWorkspaceSidebarDropPreview()
        if WorkspaceSidebarPanel.panel(containing: pointer) == nil,
           let drop = resolveSharedStackDrop(pane, pointer: pointer) {
            WindowDropIntentOverlayPanelController.shared.show(drop.destination.overlay)
        } else { WindowDropIntentOverlayPanelController.shared.hide() }
    }

    func finish(at pointer: CGPoint = normalizeAppKitScreenPoint(NSEvent.mouseLocation)) {
        let controller = BrowserWorkspaceController.shared
        guard let pane else { return }
        defer { cancel() }
        guard !invalidated, TrayMenuModel.shared.isEnabled, layoutAtStart == controller.surfaceTree,
              generation == controller.focusCoordinator.generation else { return }
        if let target = workspaceSidebarSurfaceDragTarget(pane.sidebarDragSubject, at: pointer) {
            commitWorkspaceSidebarSurfaceDrop(pane.sidebarDragSubject, target: target)
            return
        }
        guard WorkspaceSidebarPanel.panel(containing: pointer) == nil else { return }
        let applied: Bool
        if let drop = resolveSharedStackDrop(pane, pointer: pointer) {
            applied = commitSharedStackDrop(drop, pointer: pointer)
        } else {
            applied = separateSharedStackTab(pane)
        }
        if applied, let selection { _ = controller.select(selection) }
        runWorkspaceSidebarSession {}
    }

    func cancel() {
        guard pane != nil else { return }
        pane = nil; layoutAtStart = nil; selection = nil; generation = nil; invalidated = false
        endWorkspaceSidebarItemDrag()
        clearFeedback(at: MousePointerTracker.shared.currentSample.point)
    }

    func notePointerEvent(type: NSEvent.EventType, at pointer: CGPoint) {
        guard let pane, let selection else { return }
        switch type {
        case .leftMouseDragged: update(pane, selecting: selection, at: pointer)
        case .leftMouseUp: finish(at: pointer)
        case .rightMouseDown, .otherMouseDown: cancel()
        default: break
        }
    }

    private func clearFeedback(at pointer: CGPoint) {
        clearWorkspaceSidebarDropPreview()
        WindowDragCursorProxyPanel.shared.hide()
        WindowDropIntentOverlayPanelController.shared.hide()
        postWorkspaceSidebarDragPointerNotification(workspaceSidebarDragPointerEndedNotification, pointer: pointer)
        WorkspaceSidebarPanel.scheduleHoverRecheckForVisiblePanels()
    }
}

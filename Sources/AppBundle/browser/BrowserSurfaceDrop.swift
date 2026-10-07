import AppKit
import WorkspaceCore

/// A drop keeps durable owner identities and the geometry that was previewed.
/// Native numeric window IDs never stand in for a browser or a recycled window.
struct BrowserSurfaceDropDestination: Equatable {
    let source: SurfaceID
    let target: SurfaceID
    let zone: WindowDropZone
    let targetFrame: Rect
    let sourceWorkspace: String
    let targetWorkspace: String
    var targetStack: UUID? = nil

    var overlay: WindowDropIntentOverlayModel {
        .init(targetFrame: targetFrame, activeZone: zone, cornerRadius: nil)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source && lhs.target == rhs.target && lhs.zone == rhs.zone &&
            lhs.targetFrame.isEqual(to: rhs.targetFrame) &&
            lhs.sourceWorkspace == rhs.sourceWorkspace && lhs.targetWorkspace == rhs.targetWorkspace &&
            lhs.targetStack == rhs.targetStack
    }
}

@MainActor
func resolveBrowserSurfaceDrop(source: SurfaceID, pointer: CGPoint,
                               controller: BrowserWorkspaceController = .shared) -> BrowserSurfaceDropDestination? {
    guard controller.usesSurfaceTree, canDropSurface(source, controller: controller),
          let sourceWorkspace = controller.surfaceTree.workspace(of: source),
          controller.workspaceName(for: source) == sourceWorkspace else { return nil }
    let workspace = pointer.monitorApproximation.activeWorkspace
    guard workspace.isVisible else { return nil }
    if let header = sharedStackHeaderTarget(at: pointer, excluding: [source], in: workspace, controller: controller) {
        return .init(source: source, target: header.surface, zone: .tab, targetFrame: header.frame,
            sourceWorkspace: sourceWorkspace, targetWorkspace: workspace.name, targetStack: header.id)
    }
    // Shared placements include native leaves and Chromium pages, but only the
    // selected member of a stack is a destination that the user can see.
    for placement in controller.plannedSurfaces(in: workspace) where placement.visible && placement.surfaceID != source {
        let target = placement.surfaceID
        guard canDropSurface(target, controller: controller),
              controller.workspaceName(for: target) == workspace.name,
              let frame = surfaceDropTargetFrame(placement, workspace: workspace, controller: controller),
              let zone = WindowIntentZoneBuilder.zone(at: pointer, in: frame),
              zone != .tab || config.windowTabs.enabled,
              zone != .middle || sourceWorkspace == workspace.name else { continue }
        return .init(source: source, target: target, zone: zone, targetFrame: frame,
                     sourceWorkspace: sourceWorkspace, targetWorkspace: workspace.name)
    }
    return nil
}

/// Revalidate the preview before mutating either tree. The event owner resolves
/// the release pointer again; this guard also rejects removed, moved, hidden or
/// resized targets between the last preview and this synchronous commit.
@MainActor
@discardableResult
func commitBrowserSurfaceDrop(_ destination: BrowserSurfaceDropDestination,
                              controller: BrowserWorkspaceController = .shared) -> Bool {
    guard controller.usesSurfaceTree, destination.source != destination.target,
          canDropSurface(destination.source, controller: controller),
          canDropSurface(destination.target, controller: controller),
          controller.surfaceTree.workspace(of: destination.source) == destination.sourceWorkspace,
          controller.workspaceName(for: destination.source) == destination.sourceWorkspace,
          controller.surfaceTree.workspace(of: destination.target) == destination.targetWorkspace,
          controller.workspaceName(for: destination.target) == destination.targetWorkspace,
          let workspace = Workspace.existing(byName: destination.targetWorkspace), workspace.isVisible,
          let placement = controller.plannedSurfaces(in: workspace).first(where: { $0.surfaceID == destination.target && $0.visible }),
          let frame = destination.targetStack.flatMap({ stackDropTargetFrame($0, containing: destination.target, in: workspace, controller: controller) })
              ?? (destination.targetStack == nil ? surfaceDropTargetFrame(placement, workspace: workspace, controller: controller) : nil),
          frame.isEqual(to: destination.targetFrame),
          destination.zone != .tab || config.windowTabs.enabled,
          destination.zone != .middle || destination.sourceWorkspace == destination.targetWorkspace else { return false }
    guard let source = Workspace.existing(byName: destination.sourceWorkspace),
          source.projectId == workspace.projectId, source.isPinnedGroup == workspace.isPinnedGroup else { return false }

    let edit: (inout SurfaceTree) -> Bool = { tree in
        switch destination.zone {
        case .tab:
            if let stack = destination.targetStack {
                guard tree.insertIntoStack(.surface(destination.source), with: destination.target, inStack: stack) else { return false }
                tree.select(destination.source)
                return true
            }
            return tree.insertIntoStack(destination.source, with: destination.target)
        case .middle: return tree.swapLeaves(destination.source, destination.target)
        case .left, .right:
            return tree.split(destination.source, beside: destination.target, layout: .horizontal, before: destination.zone == .left)
        case .top, .bottom:
            return tree.split(destination.source, beside: destination.target, layout: .vertical, before: destination.zone == .top)
        }
    }
    let applied: Bool
    if destination.sourceWorkspace == destination.targetWorkspace {
        applied = controller.editOrganization(of: destination.source, edit)
    } else {
        applied = controller.editOrganization(of: destination.source, movingTo: workspace, edit)
    }
    guard applied else { return false }
    // editOrganization retains the old selection while it validates a candidate.
    // Select the dragged leaf after committing so a newly stacked tab is visible.
    _ = controller.select(destination.source)
    return true
}

/// Explicit headers are drop targets too. Owner content begins below them, so
/// leaf-frame hit testing alone would turn a header drop into a detach.
@MainActor
func sharedStackHeaderTarget(at point: CGPoint, excluding: Set<SurfaceID>, in workspace: Workspace,
                             controller: BrowserWorkspaceController) -> (id: UUID, surface: SurfaceID, frame: Rect)? {
    guard config.windowTabs.enabled, controller.hasSharedLayout(in: workspace) else { return nil }
    let plan = controller.plannedLayout(in: workspace)
    let live = Set(plan.surfaces.filter(\.visible).map(\.surfaceID)).subtracting(excluding)
    for stack in plan.stacks where stack.visible {
        let header = stack.headerFrame
        guard CGRect(x: header.x, y: header.y, width: header.width, height: header.height).contains(point),
              let surface = controller.surfaceTree.group(stack.groupID)?.surfaces.first(where: { live.contains($0) && controller.canMoveSurface($0) }) else { continue }
        let frame = stack.frame
        return (stack.groupID, surface, Rect(topLeftX: CGFloat(frame.x), topLeftY: CGFloat(frame.y),
            width: CGFloat(frame.width), height: CGFloat(frame.height)))
    }
    return nil
}

@MainActor
private func stackDropTargetFrame(_ id: UUID, containing surface: SurfaceID, in workspace: Workspace,
                                   controller: BrowserWorkspaceController) -> Rect? {
    guard controller.surfaceTree.group(id)?.surfaces.contains(surface) == true,
          let frame = controller.plannedLayout(in: workspace).stacks.first(where: { $0.groupID == id && $0.visible })?.frame else { return nil }
    return Rect(topLeftX: CGFloat(frame.x), topLeftY: CGFloat(frame.y), width: CGFloat(frame.width), height: CGFloat(frame.height))
}

@MainActor
private func canDropSurface(_ id: SurfaceID, controller: BrowserWorkspaceController) -> Bool {
    guard controller.isAvailable(id) else { return false }
    if case .browserTab = id { return controller.owner(of: id)?.supportsLayout == true }
    return true
}

@MainActor
func surfaceDropTargetFrame(_ placement: SurfacePlacement, workspace: Workspace,
                                    controller: BrowserWorkspaceController) -> Rect? {
    if !controller.hasSharedLayout(in: workspace), case .nativeWindow = placement.surfaceID {
        // A workspace joins shared layout only on commit. Until then its native
        // tree remains authoritative for the destination the user can see.
        return Window.get(bySurfaceID: placement.surfaceID)?.windowDragVisibleRect
    }
    let frame = placement.frame
    return Rect(topLeftX: CGFloat(frame.x), topLeftY: CGFloat(frame.y), width: CGFloat(frame.width), height: CGFloat(frame.height))
}

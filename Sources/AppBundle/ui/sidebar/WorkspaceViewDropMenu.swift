import AppKit
import WorkspaceCore

@MainActor
func workspaceViewDropHint(_ subject: WorkspaceSidebarSurfaceDragSubject,
                          target: WorkspaceSidebarDropTargetKind) -> String? {
    guard config.workspaceInteractionMode == .views else { return nil }
    let controller = BrowserWorkspaceController.shared
    let sourceName: String?
    switch subject {
    case .surface(let id): sourceName = controller.workspaceName(for: id)
    case .group(let id): sourceName = controller.workspaceName(forGroup: id)
    case .pin(let id): sourceName = controller.pinWorkspaceName(id)
    }
    guard let sourceName, let source = Workspace.existing(byName: sourceName) else { return nil }
    let pointer = MousePointerTracker.shared.currentSample.point
    switch target {
    case .workspace(let name):
        guard let destination = Workspace.existing(byName: name) else { return nil }
        if source.isPinnedGroup && !destination.isPinnedGroup { return "Unpin into its own view" }
        if destination.isPinnedGroup { return "Pin in this Space" }
        if source.projectId != destination.projectId { return "Move to this Space" }
        guard controller.preferredSurface(in: destination) != nil else { return "Move to this view" }
        if (controller.surfaceTree.roots[sourceName] ?? []).flatMap(\.surfaces).count == 1,
           let hit = workspaceSidebarDropTarget(at: pointer) {
            let inset = min(8, hit.rect.height * 0.2)
            if pointer.y < hit.rect.topLeftY + inset { return "Move before this view" }
            if pointer.y > hit.rect.topLeftY + hit.rect.height - inset { return "Move after this view" }
        }
        return "Release to choose split or stack"
    case .pin(let id):
        if !source.isPinnedGroup { return "Pin in this Space" }
        if let hit = workspaceSidebarDropTarget(at: pointer),
           pointer.x < hit.rect.topLeftX + min(8, hit.rect.width * 0.2) { return "Move before this pin" }
        let live = controller.pinTiles(in: controller.pinWorkspaceName(id) ?? "").first { $0.id == id }?.surfaceID
        return live == nil ? "Move before this pin" : "Release to choose split or stack"
    default: return nil
    }
}

/// A drop chooses intent before any tree mutation. NSMenu also provides native
/// keyboard selection and Escape cancellation after the pointer is released.
@MainActor
func requestWorkspaceViewCombination(_ subject: WorkspaceSidebarSurfaceDragSubject,
                                     target: WorkspaceSidebarDropTargetKind) -> Bool {
    guard config.workspaceInteractionMode == .views else { return false }
    let controller = BrowserWorkspaceController.shared
    let source: SurfaceID
    switch subject {
    case .surface(let id): source = id
    case .pin(let id):
        guard let name = controller.pinWorkspaceName(id),
              let id = controller.pinTiles(in: name).first(where: { $0.id == id })?.surfaceID else { return false }
        source = id
    case .group(let id):
        guard let first = controller.surfaceTree.group(id)?.surfaces.first else { return true }
        source = first
    }
    let destination: Workspace
    let selected: SurfaceID
    switch target {
    case .workspace(let name):
        guard let workspace = Workspace.existing(byName: name), !workspace.isPinnedGroup,
              let id = controller.preferredSurface(in: workspace) else { return false }
        destination = workspace; selected = id
    case .pin(let id):
        guard let name = controller.pinWorkspaceName(id), let workspace = Workspace.existing(byName: name),
              let id = controller.pinTiles(in: name).first(where: { $0.id == id })?.surfaceID else { return false }
        destination = workspace; selected = id
    default: return false
    }
    guard let name = controller.workspaceName(for: source), let sourceWorkspace = Workspace.existing(byName: name) else { return true }
    if source == selected { return true }
    guard sourceWorkspace.projectId == destination.projectId else { return false }
    if sourceWorkspace.isPinnedGroup != destination.isPinnedGroup {
        if case .pin(let pin) = subject, !destination.isPinnedGroup {
            runWorkspaceSidebarSession {
                _ = controller.unpin(pin, to: controller.newStandaloneWorkspace(in: destination))
            }
            return true
        }
        // Dropping an ordinary window onto Pinned retains the explicit pin action.
        return false
    }
    // The edge of a normal row is an insertion point, not a combine target.
    if case .workspace = target, !sourceWorkspace.isPinnedGroup,
       (controller.surfaceTree.roots[name] ?? []).flatMap(\.surfaces).count == 1,
       let hit = workspaceSidebarDropTarget(at: MousePointerTracker.shared.currentSample.point) {
        let y = MousePointerTracker.shared.currentSample.point.y
        let inset = min(8, hit.rect.height * 0.2)
        if y < hit.rect.topLeftY + inset || y > hit.rect.topLeftY + hit.rect.height - inset {
            let placement: WorkspaceReorderPlacement = y < hit.rect.topLeftY + inset ? .before : .after
            runWorkspaceSidebarSession { _ = reorderWorkspace(name, relativeTo: destination.name, placement: placement) }
            return true
        }
    }
    if case .pin(let sourcePin) = subject, case .pin(let targetPin) = target,
       let hit = workspaceSidebarDropTarget(at: MousePointerTracker.shared.currentSample.point),
       MousePointerTracker.shared.currentSample.point.x < hit.rect.topLeftX + min(8, hit.rect.width * 0.2) {
        runWorkspaceSidebarSession { controller.reorderPin(sourcePin, before: targetPin) }
        return true
    }
    let menu = WorkspaceViewDropMenu()
    for (title, layout, before) in WorkspaceViewDropMenu.choices {
        menu.add(title) {
            runWorkspaceSidebarSession {
                if case .group(let group) = subject {
                    _ = controller.combineGroupViews(group, with: selected, layout: layout, before: before)
                } else if case .pin(let pin) = subject, controller.savedPinnedView(pin) != nil {
                    _ = controller.combineGroupViews(pin, with: selected, layout: layout, before: before)
                } else { _ = controller.combineViews(source, with: selected, layout: layout, before: before) }
            }
        }
    }
    menu.show()
    return true
}

@MainActor
private final class WorkspaceViewDropMenu: NSObject {
    static let choices: [(String, SurfaceContainerLayout, Bool)] = [
        ("Stack", .stack, false), ("Split Left", .horizontal, true), ("Split Right", .horizontal, false),
        ("Split Above", .vertical, true), ("Split Below", .vertical, false),
    ]
    let menu = NSMenu(title: "Combine Windows")
    var handlers: [() -> Void] = []
    func add(_ title: String, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self; item.tag = handlers.count
        handlers.append(action); menu.addItem(item)
    }
    @objc func choose(_ item: NSMenuItem) { handlers[item.tag]() }
    func show() { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
}

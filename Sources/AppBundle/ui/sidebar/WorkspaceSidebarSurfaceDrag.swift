import AppKit
import WorkspaceCore

/// A typed sidebar gesture owns its preview independently of native AX dragging.
/// Cancellation remains latched until mouse-up so SwiftUI cannot restart it.
struct WorkspaceSidebarSurfaceDragState {
    private(set) var subject: WorkspaceSidebarSurfaceDragSubject?
    private(set) var cancelledSubject: WorkspaceSidebarSurfaceDragSubject?

    mutating func begin(_ next: WorkspaceSidebarSurfaceDragSubject) -> Bool {
        guard cancelledSubject != next, subject == nil || subject == next else { return false }
        subject = next
        return true
    }

    mutating func finish(_ expected: WorkspaceSidebarSurfaceDragSubject) -> Bool {
        guard subject == expected else { return false }
        subject = nil
        return true
    }

    mutating func cancel() {
        cancelledSubject = subject
        subject = nil
    }

    mutating func releasePointer() { cancelledSubject = nil }
}

@MainActor
private final class WorkspaceSidebarSurfaceDragDriver {
    static let shared = WorkspaceSidebarSurfaceDragDriver()
    var state = WorkspaceSidebarSurfaceDragState()

    func update(_ subject: WorkspaceSidebarSurfaceDragSubject, pointer: CGPoint) {
        guard state.begin(subject) else { return }
        MousePointerTracker.shared.note(point: pointer)
        postWorkspaceSidebarDragPointerNotification(workspaceSidebarDragPointerChangedNotification, pointer: pointer)
        refreshPreview()
        DisplayRefreshDriver.shared.add(owner: self) { [weak self] _ in self?.refreshPreview() }
    }

    func refreshPreview() {
        guard let subject = state.subject else { return }
        guard let preview = workspaceSidebarSurfaceSourcePreview(subject) else { cancel(); return }
        let pointer = MousePointerTracker.shared.currentSample.point
        WindowDragCursorProxyPanel.shared.show(preview: preview, mouseScreenPoint: denormalizedAppKitScreenPoint(pointer))
        if let target = workspaceSidebarSurfaceDragTarget(subject, at: pointer) {
            previewWorkspaceSidebarSurfaceDrop(subject, target: target)
            WindowDropIntentOverlayPanelController.shared.hide()
        } else {
            clearWorkspaceSidebarDropPreview()
            if WorkspaceSidebarPanel.panel(containing: pointer) == nil,
               case .surface(let id) = subject,
               let drop = resolveBrowserSurfaceDrop(source: id, pointer: pointer) {
                WindowDropIntentOverlayPanelController.shared.show(drop.overlay)
            } else {
                WindowDropIntentOverlayPanelController.shared.hide()
            }
        }
    }

    func finish(_ subject: WorkspaceSidebarSurfaceDragSubject, pointer: CGPoint) {
        guard state.finish(subject) else { return }
        MousePointerTracker.shared.note(point: pointer)
        let target = workspaceSidebarSurfaceDragTarget(subject, at: pointer)
        let contentDrop: BrowserSurfaceDropDestination?
        if target == nil, WorkspaceSidebarPanel.panel(containing: pointer) == nil, case .surface(let id) = subject {
            contentDrop = resolveBrowserSurfaceDrop(source: id, pointer: pointer)
        } else { contentDrop = nil }
        clearFeedback(pointer: pointer)
        state.releasePointer()
        if let target { commitWorkspaceSidebarSurfaceDrop(subject, target: target) }
        else if let contentDrop {
            runWorkspaceSidebarSession {
                guard commitBrowserSurfaceDrop(contentDrop) else { return }
                await updateWorkspaceSidebarModel()
            }
        }
    }

    func cancel() {
        guard state.subject != nil else { return }
        state.cancel()
        clearFeedback(pointer: MousePointerTracker.shared.currentSample.point)
        resetWorkspaceSidebarItemDrag()
    }

    private func clearFeedback(pointer: CGPoint) {
        DisplayRefreshDriver.shared.remove(owner: self)
        clearWorkspaceSidebarDropPreview()
        WindowDragCursorProxyPanel.shared.hide()
        WindowDropIntentOverlayPanelController.shared.hide()
        postWorkspaceSidebarDragPointerNotification(workspaceSidebarDragPointerEndedNotification, pointer: pointer)
        WorkspaceSidebarPanel.scheduleHoverRecheckForVisiblePanels()
    }
}

@MainActor
func currentWorkspaceSidebarSurfaceDragSubject() -> WorkspaceSidebarSurfaceDragSubject? {
    WorkspaceSidebarSurfaceDragDriver.shared.state.subject
}

@MainActor
func updateWorkspaceSidebarSurfaceDrag(_ subject: WorkspaceSidebarSurfaceDragSubject, pointer: CGPoint) {
    WorkspaceSidebarSurfaceDragDriver.shared.update(subject, pointer: pointer)
}

@MainActor
func finishWorkspaceSidebarSurfaceDrag(_ subject: WorkspaceSidebarSurfaceDragSubject, pointer: CGPoint) {
    WorkspaceSidebarSurfaceDragDriver.shared.finish(subject, pointer: pointer)
}

@MainActor
func cancelWorkspaceSidebarSurfaceDrag() { WorkspaceSidebarSurfaceDragDriver.shared.cancel() }

@MainActor
func noteWorkspaceSidebarSurfaceDragPointerEvent(type: NSEvent.EventType, at pointer: CGPoint) {
    let driver = WorkspaceSidebarSurfaceDragDriver.shared
    switch type {
    case .leftMouseDown:
        driver.state.releasePointer()
    case .leftMouseDragged:
        if let subject = driver.state.subject { driver.update(subject, pointer: pointer) }
    case .leftMouseUp:
        if let subject = driver.state.subject {
            driver.finish(subject, pointer: pointer)
            resetWorkspaceSidebarItemDrag()
        }
        driver.state.releasePointer()
    default: break
    }
}

@MainActor
private func workspaceSidebarSurfaceDragTarget(_ subject: WorkspaceSidebarSurfaceDragSubject, at pointer: CGPoint) -> WorkspaceSidebarDropTargetKind? {
    guard let target = workspaceSidebarDropTarget(at: pointer)?.kind,
          isActionableWorkspaceSidebarSurfaceDrop(subject, target: target) else { return nil }
    return target
}

@MainActor
func isActionableWorkspaceSidebarSurfaceDrop(_ subject: WorkspaceSidebarSurfaceDragSubject, target: WorkspaceSidebarDropTargetKind,
                                            controller: BrowserWorkspaceController = .shared) -> Bool {
    let source: String?
    switch subject {
    case .surface(let id):
        guard controller.canMoveSurface(id) else { return false }
        source = controller.workspaceName(for: id)
    case .group(let id):
        guard controller.canMoveGroup(id) else { return false }
        source = controller.workspaceName(forGroup: id)
    case .pin(let id):
        source = controller.pinWorkspaceName(id)
    }
    guard let source, let workspace = Workspace.existing(byName: source), !workspace.isArchived else { return false }
    switch target {
    case .pin(let id):
        if case .pin(let sourcePin) = subject { return sourcePin != id && controller.pinWorkspaceName(id) != nil }
        return controller.pinWorkspaceName(id).map { $0 != source } ?? false
    case .workspace(let name):
        return name != source && Workspace.existing(byName: name)?.isArchived == false
    case .newWorkspace(let projectId, _):
        return winMuxWorkspaceState.projectsById[projectId] != nil
    case .monitor(let scope):
        guard let monitor = workspaceSidebarMonitor(forScopeId: scope) else { return false }
        return monitor.activeWorkspace.name != source && !monitor.activeWorkspace.isArchived
    }
}

@MainActor
private func commitWorkspaceSidebarSurfaceDrop(_ subject: WorkspaceSidebarSurfaceDragSubject, target: WorkspaceSidebarDropTargetKind) {
    guard isActionableWorkspaceSidebarSurfaceDrop(subject, target: target) else { return }
    let controller = BrowserWorkspaceController.shared
    if case .pin(let targetPin) = target, let name = controller.pinWorkspaceName(targetPin) {
        if case .pin(let id) = subject {
            runWorkspaceSidebarSession {
                guard let workspace = Workspace.existing(byName: name) else { return }
                if controller.pinWorkspaceName(id) != name { guard controller.movePin(id, to: workspace.projectId) else { return } }
                controller.reorderPin(id, before: targetPin)
            }
        } else { commitWorkspaceSidebarSurfaceDrop(subject, target: .workspace(name)) }
        return
    }
    if case .workspace(let name) = target, let workspace = Workspace.existing(byName: name), workspace.isPinnedGroup {
        runWorkspaceSidebarSession {
            switch subject {
            case .pin(let id): _ = controller.movePin(id, to: workspace.projectId)
            case .surface(let id): _ = controller.pinSurface(id, in: workspace.projectId)
            case .group(let id):
                guard let group = controller.surfaceTree.group(id), controller.canMoveGroup(id) else { return }
                for surface in group.surfaces { _ = controller.pinSurface(surface, in: workspace.projectId) }
            }
        }
        return
    }
    switch (subject, target) {
    case (.pin(let id), .workspace(let name)):
        runWorkspaceSidebarSession { if let workspace = Workspace.existing(byName: name) { _ = controller.unpin(id, to: workspace) } }
    case (.pin(let id), .newWorkspace(let project, let scope)):
        runWorkspaceSidebarSession {
            guard controller.pinWorkspaceName(id) != nil else { return }
            let monitor = workspaceSidebarTargetMonitor(scopeId: scope, fallbackPoint: mouseLocation)
            _ = controller.unpin(id, to: getOrCreateAdjacentBlankWorkspace(projectId: project, monitor: monitor))
        }
    case (.surface(let id), .workspace(let name)):
        moveSurfaceFromSidebar(id, toWorkspace: name)
    case (.group(let id), .workspace(let name)):
        moveSurfaceGroupFromSidebar(id, toWorkspace: name)
    case (.surface(let id), .newWorkspace(let project, let scope)):
        moveSurfaceToNewWorkspaceFromSidebar(id, projectId: project, monitorScopeId: scope)
    case (.group(let id), .newWorkspace(let project, let scope)):
        moveSurfaceGroupToNewWorkspaceFromSidebar(id, projectId: project, monitorScopeId: scope)
    case (_, .monitor(let scope)):
        guard let workspace = workspaceSidebarMonitor(forScopeId: scope)?.activeWorkspace else { return }
        commitWorkspaceSidebarSurfaceDrop(subject, target: .workspace(workspace.name))
    case (_, .pin): break
    }
}

@MainActor
func previewWorkspaceSidebarSurfaceDrop(_ subject: WorkspaceSidebarSurfaceDragSubject, target: WorkspaceSidebarDropTargetKind) {
    guard isActionableWorkspaceSidebarSurfaceDrop(subject, target: target),
          let preview = workspaceSidebarSurfaceSourcePreview(subject, target: target) else {
        clearWorkspaceSidebarDropPreview()
        return
    }
    setWorkspaceSidebarDropPreviewIfChanged(preview)
}

/// Build from the durable tree and unfiltered shared model, including every
/// member of a stack even while search renders only some children.
@MainActor
func workspaceSidebarSurfaceSourcePreview(_ subject: WorkspaceSidebarSurfaceDragSubject, target: WorkspaceSidebarDropTargetKind? = nil,
                                          controller: BrowserWorkspaceController = .shared,
                                          viewModel: TrayMenuModel = .shared) -> WorkspaceSidebarDropPreviewViewModel? {
    let ids: [SurfaceID]
    switch subject {
    case .pin(let id):
        guard let workspace = controller.pinWorkspaceName(id), let pin = controller.pinTiles(in: workspace).first(where: { $0.id == id }) else { return nil }
        let destination: String?
        var project: WorkspaceProjectId?
        var scope: String?
        switch target {
        case .pin(let targetID): destination = controller.pinWorkspaceName(targetID)
        case .workspace(let name): destination = name
        case .monitor(let id): destination = workspaceSidebarMonitor(forScopeId: id)?.activeWorkspace.name
        case .newWorkspace(let id, let monitor): destination = nil; project = id; scope = monitor
        case nil: destination = nil
        }
        return .init(sourceSubject: subject, label: pin.title, appName: pin.title,
            appBundleIdentifier: pin.bundleIdentifier, appBundlePath: pin.bundlePath,
            targetWorkspaceName: destination, targetsNewWorkspace: project != nil,
            targetProjectId: project, targetMonitorScopeId: scope, isTabGroup: false, windowCount: 1)
    case .surface(let id):
        guard controller.canMoveSurface(id) else { return nil }
        ids = [id]
    case .group(let id):
        guard controller.canMoveGroup(id), let node = workspaceSidebarSurfaceGroupNode(id, in: controller.surfaceTree.roots.values.flatMap { $0 }) else { return nil }
        ids = node.surfaces
    }
    let presentation = Dictionary(viewModel.workspaceSidebarWorkspaces.flatMap { $0.items.flatMap(\.surfaceItems) }.map { ($0.surfaceID, $0) }, uniquingKeysWith: { first, _ in first })
    let tabs = ids.map { id -> WorkspaceSidebarDropPreviewTabItem in
        if let item = presentation[id] {
            return .init(title: item.title, appName: item.appName, appBundleIdentifier: item.appBundleId, appBundlePath: item.appBundlePath)
        }
        if let window = Window.get(bySurfaceID: id) {
            let app = window.app.name ?? window.app.rawAppBundleId ?? "Window"
            return .init(title: cachedWindowTitle(for: window) ?? app, appName: app,
                         appBundleIdentifier: window.app.rawAppBundleId, appBundlePath: window.app.bundlePath)
        }
        let record = controller.owner(of: id)?.inventory.tabs[id]
        return .init(title: record.flatMap { $0.title.isEmpty ? nil : $0.title } ?? record?.url ?? "Web page", appName: "WinMux Browser",
                     appBundleIdentifier: "com.jameslyons.winmux.browser.alpha", appBundlePath: nil)
    }
    guard let first = tabs.first else { return nil }
    let isGroup: Bool
    if case .group = subject { isGroup = true } else { isGroup = false }
    let targetName: String?
    var project: WorkspaceProjectId?
    var scope: String?
    var isNew = false
    switch target {
    case .pin(let id): targetName = controller.pinWorkspaceName(id)
    case .workspace(let name): targetName = name
    case .monitor(let id): targetName = workspaceSidebarMonitor(forScopeId: id)?.activeWorkspace.name
    case .newWorkspace(let id, let monitor): targetName = nil; project = id; scope = monitor; isNew = true
    case nil: targetName = nil
    }
    let label: String
    if case .group(let id) = subject {
        switch controller.sidebarGroupLayout(id) {
        case .stack: label = "Tab Stack"
        case .horizontal: label = "Horizontal Split"
        case .vertical: label = "Vertical Split"
        }
    } else { label = first.title }
    return .init(sourceSubject: subject, label: label, appName: first.appName,
                 appBundleIdentifier: first.appBundleIdentifier, appBundlePath: first.appBundlePath,
                 targetWorkspaceName: targetName, targetsNewWorkspace: isNew,
                 targetProjectId: project, targetMonitorScopeId: scope, isTabGroup: isGroup,
                 windowCount: ids.count, tabItems: isGroup ? tabs : [])
}

private func workspaceSidebarSurfaceGroupNode(_ id: UUID, in nodes: [SurfaceTreeNode]) -> SurfaceTreeNode? {
    for node in nodes {
        guard case .group(let group, let children) = node else { continue }
        if id == group { return node }
        if let nested = workspaceSidebarSurfaceGroupNode(id, in: children) { return nested }
    }
    return nil
}

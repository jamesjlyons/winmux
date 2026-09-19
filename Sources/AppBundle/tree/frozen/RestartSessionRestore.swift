import AppKit
import Common

@MainActor
func restartTargetMonitor(_ saved: FrozenMonitor) -> Monitor {
    if let uuid = saved.displayUUID, let found = monitors.first(where: { $0.persistentDisplayUUID == uuid }) { return found }
    if saved.displayUUID == nil, let found = monitors.first(where: { $0.rect.topLeftCorner == saved.topLeftCorner }) { return found }
    return mainMonitor
}

@MainActor
func restoreRestartMetadata(_ snapshot: RestartSessionSnapshot) {
    for project in snapshot.projects ?? [] {
        winMuxWorkspaceState.registerProject(WorkspaceProject(id: project.id, name: project.name, order: project.order))
    }
    for frozen in snapshot.world.workspaces {
        let workspace = Workspace.get(byName: frozen.name)
        workspace.assignProject(frozen.projectId)
        workspace.restoreNamingStyle(frozen.namingStyle)
        workspace.preferredMonitorPoint = restartTargetMonitor(frozen.monitor).rect.topLeftCorner
    }
    for project in snapshot.projects ?? [] {
        guard var restored = winMuxWorkspaceState.projectsById[project.id] else { continue }
        restored.workspaceOrder = project.workspaceNames.compactMap { Workspace.existing(byName: $0)?.id }
        winMuxWorkspaceState.registerProject(restored)
    }
}

/// Rebuild matching leaves, retaining newly opened windows in their current workspace.
@MainActor
func restoreRestartWorkspace(_ frozen: FrozenWorkspace, matchedIds: Set<UInt32>, records: [RestartWindow]) async throws {
    let workspace = Workspace.get(byName: frozen.name)
    workspace.assignProject(frozen.projectId)
    workspace.restoreNamingStyle(frozen.namingStyle)
    let monitor = restartTargetMonitor(frozen.monitor)
    let matchingWindows = Dictionary(uniqueKeysWithValues: matchedIds.compactMap { id in Window.get(byId: id).map { (id, $0) } })
    workspace.preferredMonitorPoint = monitor.rect.topLeftCorner
    let previousRoot = workspace.rootTilingContainer
    let orphans = previousRoot.allLeafWindowsRecursive.filter { !matchedIds.contains($0.windowId) }
    previousRoot.unbindFromParent()
    restoreRestartTree(frozen.rootTilingNode, parent: workspace, matchedIds: matchedIds, windows: matchingWindows)
    for window in orphans { window.bind(to: workspace.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST) }
    for frozenWindow in frozen.floatingWindows where matchedIds.contains(frozenWindow.id) {
        guard let window = matchingWindows[frozenWindow.id] else { continue }
        applyFrozenWindowState(window, frozenWindow)
        window.bindAsFloatingWindow(to: workspace)
        if let frame = records.first(where: { $0.id == window.windowId })?.floatingFrame,
           frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite {
            let rect = monitor.visibleRect
            let restored = restoredFloatingFrame(frame, savedScreen: frozen.monitor.visibleRect,
                                                 targetScreen: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
            window.lastFloatingSize = restored.size
            if let macWindow = window as? MacWindow { macWindow.unhideFromCorner() }
            if let macWindow = window as? MacWindow {
                try await macWindow.setAxFrameBlocking(restored.origin, restored.size)
            } else { window.setAxFrame(restored.origin, restored.size) }
        }
    }
    for frozenWindow in frozen.macosUnconventionalWindows where matchedIds.contains(frozenWindow.id) {
        if let window = matchingWindows[frozenWindow.id] {
            try await restoreFrozenUnconventionalWindow(window, frozenWindow, on: workspace)
        }
    }
}

@discardableResult
@MainActor
func restoreRestartTree(_ frozen: FrozenContainer, parent: NonLeafTreeNodeObject, matchedIds: Set<UInt32>, windows: [UInt32: Window]) -> TilingContainer {
    let container = TilingContainer(parent: parent, adaptiveWeight: max(frozen.weight, 0.001), frozen.orientation, frozen.layout, index: INDEX_BIND_LAST)
    var restoredChildren: [Int: TreeNode] = [:]
    for (index, child) in frozen.children.enumerated() {
        switch child {
            case .window(let frozenWindow):
                guard matchedIds.contains(frozenWindow.id), let window = windows[frozenWindow.id] else { continue }
                applyFrozenWindowState(window, frozenWindow)
                window.bind(to: container, adaptiveWeight: max(frozenWindow.weight, 0.001), index: INDEX_BIND_LAST)
                restoredChildren[index] = window
            case .container(let nested):
                let child = restoreRestartTree(nested, parent: container, matchedIds: matchedIds, windows: windows)
                if child.children.isEmpty { child.unbindFromParent() } else { restoredChildren[index] = child }
        }
    }
    for index in (frozen.mostRecentChildIndices ?? []).reversed() { restoredChildren[index]?.markAsMostRecentChild() }
    return container
}

@MainActor
func restoreRestartFocus(_ snapshot: RestartSessionSnapshot, matchedIds: Set<UInt32>, excluding: Set<String>) {
    var assignedMonitors: Set<CGPoint> = []
    for saved in snapshot.world.monitors where !excluding.contains(saved.visibleWorkspace) {
        let monitor = restartTargetMonitor(saved)
        guard !assignedMonitors.contains(monitor.rect.topLeftCorner), let workspace = Workspace.existing(byName: saved.visibleWorkspace) else { continue }
        let viewportId = MonitorViewportId(monitor)
        for (projectId, name) in saved.lastActiveWorkspaceByProject ?? [:] where !excluding.contains(name) {
            if let remembered = Workspace.existing(byName: name), remembered.projectId.rawValue == projectId {
                winMuxWorkspaceState.monitorViewportsById[viewportId]?.lastActiveWorkspaceByProject[remembered.projectId] = remembered.id
            }
        }
        _ = monitor.setActiveWorkspace(workspace)
        assignedMonitors.insert(monitor.rect.topLeftCorner)
    }
    guard let name = snapshot.focusedWorkspace, !excluding.contains(name) else { return }
    if let id = snapshot.focusedWindowId, matchedIds.contains(id), let window = Window.get(byId: id), window.focusWindow() {
        window.nativeFocus()
    } else if let workspace = Workspace.existing(byName: name) { _ = workspace.focusWorkspace() }
}

import WorkspaceCore

/// Capture before owner reconciliation can remove the selected row or report a
/// provisional native focus. The order follows the sidebar within this Space.
struct SurfaceClosureFocusSnapshot: Sendable {
    let selected: SurfaceID?
    let opener: SurfaceID?
    let orderedSurfaces: [SurfaceID]
    let workspaceName: String
    let projectId: WorkspaceProjectId
    let monitorId: MonitorViewportId
}

extension BrowserWorkspaceController {
    func captureClosureFocus() -> SurfaceClosureFocusSnapshot {
        let selected = focusCoordinator.target ?? focus.windowOrNil?.surfaceID
        let workspace = selected.flatMap { workspaceName(for: $0) }.flatMap(Workspace.existing(byName:)) ?? focus.workspace
        let ordered = orderedWorkspacesForPresentation().filter {
            $0.projectId == workspace.projectId && MonitorViewportId($0.workspaceMonitor) == MonitorViewportId(workspace.workspaceMonitor)
        }.flatMap { view in
            let shared = (surfaceTree.roots[view.name] ?? []).flatMap(\.surfaces)
            let sharedIDs = Set(shared)
            return shared + view.allLeafWindowsRecursive.map(\.surfaceID).filter { !sharedIDs.contains($0) }
        }
        let opener = selected.flatMap { tabOpeners[$0] ?? owner(of: $0)?.inventory.tabs[$0]?.openerSurfaceID }
        return .init(selected: selected, opener: opener, orderedSurfaces: ordered,
                     workspaceName: workspace.name, projectId: workspace.projectId,
                     monitorId: MonitorViewportId(workspace.workspaceMonitor))
    }

    /// Wait for confirmed removal so a cancelled close never changes selection.
    @discardableResult
    func restoreFocusAfterClosing(_ removed: Set<SurfaceID>, snapshot: SurfaceClosureFocusSnapshot,
                                 workspace: Workspace?) -> Bool {
        recentSelections.removeAll(where: removed.contains)
        selectedByWorkspace = selectedByWorkspace.filter { !removed.contains($0.value) }
        tabOpeners = tabOpeners.filter { !removed.contains($0.key) && !removed.contains($0.value) }
        return restoreFocusAfterRemovingFromView(removed, snapshot: snapshot)
    }

    /// Minimization keeps ownership and opener metadata, but uses the same
    /// replacement order as closure. A later explicit selection always wins.
    @discardableResult
    func restoreFocusAfterRemovingFromView(_ removed: Set<SurfaceID>, snapshot: SurfaceClosureFocusSnapshot) -> Bool {
        guard let selected = snapshot.selected, removed.contains(selected),
              focus.workspace.projectId == snapshot.projectId,
              MonitorViewportId(focus.workspace.workspaceMonitor) == snapshot.monitorId else { return false }

        var candidates: [SurfaceID] = []
        if let opener = snapshot.opener { candidates.append(opener) }
        if let index = snapshot.orderedSurfaces.firstIndex(of: selected) {
            candidates.append(contentsOf: snapshot.orderedSurfaces.dropFirst(index + 1))
            // The bottom row has no tab below it; use the nearest surviving row above.
            candidates.append(contentsOf: snapshot.orderedSurfaces.prefix(index).reversed())
        } else if let workspace = Workspace.existing(byName: snapshot.workspaceName) {
            candidates.append(contentsOf: (surfaceTree.roots[workspace.name] ?? []).flatMap(\.surfaces))
        }
        for id in candidates where !removed.contains(id) && canRestoreFocusAfterClosure(id, snapshot: snapshot) {
            if select(id, deferNativeFocusUntilLayout: true) == .issued { return true }
        }
        nativeSelectionChanged(nil)
        return false
    }

    private func canRestoreFocusAfterClosure(_ id: SurfaceID, snapshot: SurfaceClosureFocusSnapshot) -> Bool {
        guard isAvailable(id), !isProfileMoveCopy(id),
              let name = workspaceName(for: id), let workspace = Workspace.existing(byName: name),
              workspace.projectId == snapshot.projectId,
              MonitorViewportId(workspace.workspaceMonitor) == snapshot.monitorId,
              !workspace.isArchived else { return false }
        switch id {
        case .nativeWindow:
            guard let window = Window.get(bySurfaceID: id), window.participatesInWorkspaceFocus,
                  window.lastKnownNativeMinimized != true else { return false }
            return (window.app as? MacApp)?.nsApp.isTerminated != true
        case .browserTab:
            return owner(of: id)?.inventory.tabs[id]?.hostMinimized != true
        }
    }
}

import WorkspaceCore

/// Capture before owner reconciliation can remove the selected row or report a
/// provisional native focus. The order follows the sidebar within this Space.
struct SurfaceClosureFocusSnapshot: Sendable {
    let selected: SurfaceID?
    let opener: SurfaceID?
    let orderedSurfaces: [SurfaceID]
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
        return .init(selected: selected, opener: opener, orderedSurfaces: ordered)
    }

    /// Wait for confirmed removal so a cancelled close never changes selection.
    @discardableResult
    func restoreFocusAfterClosing(_ removed: Set<SurfaceID>, snapshot: SurfaceClosureFocusSnapshot,
                                 workspace: Workspace?) -> Bool {
        recentSelections.removeAll(where: removed.contains)
        selectedByWorkspace = selectedByWorkspace.filter { !removed.contains($0.value) }
        tabOpeners = tabOpeners.filter { !removed.contains($0.key) && !removed.contains($0.value) }
        guard let selected = snapshot.selected, removed.contains(selected) else { return false }

        var candidates: [SurfaceID] = []
        if let opener = snapshot.opener { candidates.append(opener) }
        if let index = snapshot.orderedSurfaces.firstIndex(of: selected) {
            candidates.append(contentsOf: snapshot.orderedSurfaces.dropFirst(index + 1))
            // The bottom row has no tab below it; use the nearest surviving row above.
            candidates.append(contentsOf: snapshot.orderedSurfaces.prefix(index).reversed())
        } else if let workspace {
            candidates.append(contentsOf: (surfaceTree.roots[workspace.name] ?? []).flatMap(\.surfaces))
        }
        for id in candidates where !removed.contains(id) && canRestoreFocusAfterClosure(id) {
            if select(id, deferNativeFocusUntilLayout: true) == .issued { return true }
        }
        nativeSelectionChanged(nil)
        return false
    }

    private func canRestoreFocusAfterClosure(_ id: SurfaceID) -> Bool {
        guard isAvailable(id), !isProfileMoveCopy(id),
              let name = workspaceName(for: id), let workspace = Workspace.existing(byName: name),
              !workspace.isArchived else { return false }
        switch id {
        case .nativeWindow:
            guard let window = Window.get(bySurfaceID: id), window.participatesInWorkspaceFocus else { return false }
            return (window.app as? MacApp)?.nsApp.isTerminated != true
        case .browserTab:
            return owner(of: id)?.inventory.tabs[id]?.hostMinimized != true
        }
    }
}

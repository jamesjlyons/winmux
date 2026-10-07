import WorkspaceCore

/// Capture before owner reconciliation can report a provisional native focus.
struct SurfaceClosureFocusSnapshot: Sendable {
    let selected: SurfaceID?
    let recentSelections: [SurfaceID]
}

extension BrowserWorkspaceController {
    func captureClosureFocus() -> SurfaceClosureFocusSnapshot {
        .init(selected: focusCoordinator.target ?? focus.windowOrNil?.surfaceID,
              recentSelections: recentSelections)
    }

    /// Called after the owner confirms removal, so a cancelled close/save dialog
    /// never changes selection. History spans browser pages and native apps.
    @discardableResult
    func restoreFocusAfterClosing(_ removed: Set<SurfaceID>, snapshot: SurfaceClosureFocusSnapshot,
                                 workspace: Workspace?) -> Bool {
        recentSelections.removeAll(where: removed.contains)
        selectedByWorkspace = selectedByWorkspace.filter { !removed.contains($0.value) }
        guard let selected = snapshot.selected, removed.contains(selected) else { return false }

        for id in snapshot.recentSelections where !removed.contains(id) && canRestoreFocusAfterClosure(id) {
            if select(id, deferNativeFocusUntilLayout: true) == .issued { return true }
        }
        if let workspace, let fallback = preferredSurface(in: workspace),
           !removed.contains(fallback), canRestoreFocusAfterClosure(fallback),
           select(fallback, deferNativeFocusUntilLayout: true) == .issued {
            return true
        }
        // Retire the dead target even when no visited surface remains.
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

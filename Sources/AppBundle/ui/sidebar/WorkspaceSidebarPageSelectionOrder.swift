import WorkspaceCore

/// Selection follows all displayed rows, including rows a lazy page has not
/// mounted yet. Collapsed arrangements still exclude their hidden children.
func workspaceSidebarPageSelectionOrder(
    workspaces: [WorkspaceSidebarWorkspaceViewModel],
    pinnedActiveWorkspace: WorkspaceSidebarWorkspaceViewModel? = nil,
    allowsActivation: Bool,
    collapsedWorkspaceNames: Set<String>,
    renamingWorkspaceName: String? = nil,
    isSearchFiltering: Bool = false
) -> [SurfacePane] {
    var result: [SurfacePane] = workspaceSidebarCombinedPins(workspaces)?.pins.compactMap {
        $0.isOpen && !$0.isGroup ? $0.surfaceID.map(SurfacePane.surface) : nil
    } ?? []

    func appendWorkspace(_ workspace: WorkspaceSidebarWorkspaceViewModel, allowsActivation: Bool) {
        if workspace.isPinnedGroup {
            result += workspace.floatingItems.flatMap(\.sidebarSelectionPanes)
        } else if !workspace.viewSurfaces.isEmpty, renamingWorkspaceName != workspace.name {
            if workspace.isSingleWindowView {
                if allowsActivation, let surface = workspace.viewSurfaces.first {
                    result.append(.surface(surface.surfaceID))
                }
            } else if collapsedWorkspaceNames.contains(workspace.name) && !isSearchFiltering {
                result += workspace.floatingItems.flatMap(\.sidebarSelectionPanes)
            } else {
                appendItems(workspace.items)
            }
        } else {
            appendItems(workspace.items)
        }
    }

    func appendItems(_ items: [WorkspaceSidebarItemViewModel]) {
        // Legacy pinned rows precede ordinary rows inside an arrangement.
        result += items.filter { if case .pinnedBrowserTab = $0.kind { return true }; return false }
            .flatMap(\.sidebarSelectionPanes)
        result += items.filter { if case .pinnedBrowserTab = $0.kind { return false }; return true }
            .flatMap(\.sidebarSelectionPanes)
    }

    if let pinnedActiveWorkspace { appendWorkspace(pinnedActiveWorkspace, allowsActivation: false) }
    for workspace in workspaces where workspace.showsWindowSection {
        appendWorkspace(workspace, allowsActivation: allowsActivation)
    }
    var seen: Set<SurfacePane> = []
    return result.filter { seen.insert($0).inserted }
}

private extension WorkspaceSidebarItemViewModel {
    var sidebarSelectionPanes: [SurfacePane] {
        switch kind {
        case .surface(let surface): [.surface(surface.surfaceID)]
        case .surfaceGroup(_, let children): children.flatMap(\.sidebarSelectionPanes)
        case .window(let window): [.surface(window.surfaceID)]
        case .browserTab(let tab): [.surface(tab.surfaceID)]
        case .tabGroup(let group): (group.searchVisibleTabs ?? group.tabs).map { .surface($0.surfaceID) }
        case .pinnedBrowserTab(let tab): tab.isOpen ? tab.pin.surfaceID.map { [.surface($0)] } ?? [] : []
        }
    }
}

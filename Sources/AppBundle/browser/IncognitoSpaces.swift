import AppKit
import Common
import WorkspaceCore

extension WorkspaceProjectId {
    var isIncognito: Bool { rawValue.hasPrefix("__incognito_") }
    static func incognito(_ profile: UUID) -> Self { Self("__incognito_" + profile.uuidString.lowercased()) }
}

extension BrowserWorkspaceController {
    func regularArrivalWorkspace(_ source: Workspace) -> Workspace {
        guard source.isIncognito else { return source }
        return incognitoReturnWorkspaces[source.projectId].flatMap { Workspace.existing(byName: $0) }
            ?? availablePreferredWorkspace(projectId: workspaceProjectDefaultId, monitor: source.workspaceMonitor)
            ?? createBlankWorkspace(projectId: workspaceProjectDefaultId, monitor: source.workspaceMonitor)
    }

    func isPrivateSurface(_ id: SurfaceID) -> Bool {
        privateSurfaces.contains(id) || owner(of: id)?.inventory.tabs[id]?.privateBrowsing == true
    }

    func canPlaceSurface(_ id: SurfaceID, in destination: Workspace) -> Bool {
        if isPrivateSurface(id) {
            return id.browserProfileID.map { destination.projectId == .incognito($0) } == true
        }
        return !destination.isIncognito
    }

    func incognitoDestination(_ id: SurfaceID, from source: Workspace) -> String {
        guard let profile = id.browserProfileID else { return source.name }
        privateSurfaces.insert(id)
        let space = WorkspaceProjectId.incognito(profile)
        if winMuxWorkspaceState.projectsById[space] == nil {
            incognitoReturnWorkspaces[space] = source.isIncognito ? nil : source.name
            winMuxWorkspaceState.registerProject(.init(id: space, name: "Incognito", order: winMuxWorkspaceState.nextProjectOrder()))
        }
        let context = (source.projectId == space ? source : nil) ?? projectWorkspaces(projectId: space).first
            ?? createBlankWorkspace(projectId: space, monitor: source.workspaceMonitor)
        return standaloneBrowserDestination(id, in: context)
    }

    /// The browser owns the private session. A closed/disconnected owner leaves
    /// no restored placement, pin, tombstone or remembered private selection.
    func retirePrivateSurface(_ id: SurfaceID) {
        surfaceTree.remove(id)
        placements.removeValue(forKey: id)
        standaloneBrowserViews.removeValue(forKey: id)
        closedBrowserTabs.remove(id)
        selectedByWorkspace = selectedByWorkspace.filter { $0.value != id }
        recentSelections.removeAll { $0 == id }
        pendingBrowserTabSelections.removeValue(forKey: id)
        if restoredSelection == id { restoredSelection = nil }
        privateSurfaces.remove(id)
    }

    func pruneIncognitoSpaces() {
        for space in winMuxWorkspaceState.projectsById.keys.filter(\.isIncognito) {
            guard !privateSurfaces.contains(where: { $0.browserProfileID.map { WorkspaceProjectId.incognito($0) == space } == true }) else { continue }
            let workspaces = projectWorkspaces(projectId: space)
            let fallbackName = incognitoReturnWorkspaces.removeValue(forKey: space)
            for workspace in workspaces {
                if workspace.isVisible || focus.workspace === workspace {
                    let monitor = workspace.workspaceMonitor
                    let fallback = fallbackName.flatMap { Workspace.existing(byName: $0) }
                        .flatMap { workspaceIsAvailableForMonitor($0, monitor: monitor) ? $0 : nil }
                        ?? availablePreferredWorkspace(projectId: workspaceProjectDefaultId, monitor: monitor)
                        ?? createBlankWorkspace(projectId: workspaceProjectDefaultId, monitor: monitor)
                    if workspace.isVisible { _ = monitor.setActiveWorkspace(fallback) }
                    if focus.workspace === workspace { _ = setFocus(to: fallback.toLiveFocus()) }
                }
                surfaceTree.removeWorkspace(workspace.name)
                mixedLayoutWorkspaces.remove(workspace.name)
                removeWorkspaceFromRegistry(workspace)
            }
            winMuxWorkspaceState.projectsById.removeValue(forKey: space)
        }
    }
}

private struct NativeSidebarCacheEntry {
    weak var owner: Workspace?
    let revision: NativePresentationRevision
    let items: [WorkspaceSidebarItemViewModel]
}

@MainActor private var nativeSidebarCache: [ObjectIdentifier: NativeSidebarCacheEntry] = [:]
@MainActor private(set) var nativeSidebarBuildCount = 0

@MainActor
func pruneNativeSidebarCache(_ workspaces: [Workspace]) {
    let live = Set(workspaces.map(ObjectIdentifier.init))
    nativeSidebarCache = nativeSidebarCache.filter { live.contains($0.key) && $0.value.owner != nil }
}

@MainActor
func buildWorkspaceSidebarNativeItems(
    for workspace: Workspace,
    currentFocus: LiveFocus,
) async -> [WorkspaceSidebarItemViewModel] {
    let revision = NativePresentationRevision(workspace, workspace: workspace, currentFocus: currentFocus)
    let identity = ObjectIdentifier(workspace)
    if let cached = nativeSidebarCache[identity], cached.owner === workspace, cached.revision == revision {
        return cached.items
    }
    nativeSidebarBuildCount += 1
    var items: [WorkspaceSidebarItemViewModel] = []
    if let root = workspace.existingRootTilingContainer {
        items = await buildWorkspaceSidebarItems(
            from: root, workspaceName: workspace.name, currentFocus: currentFocus
        )
    }
    for floatingWindow in workspace.floatingWindows where floatingWindow.isBound {
        items.append(.init(kind: .window(await makeWorkspaceSidebarWindowViewModel(
            for: floatingWindow,
            workspaceName: workspace.name,
            currentFocus: currentFocus,
        ))))
    }
    if NativePresentationRevision(workspace, workspace: workspace, currentFocus: focus) == revision {
        nativeSidebarCache[identity] = .init(owner: workspace, revision: revision, items: items)
    }
    return items
}

@MainActor
func buildWorkspaceSidebarNativeItems(
    for workspace: Workspace,
    currentFocus: LiveFocus,
) async -> [WorkspaceSidebarItemViewModel] {
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
    return items
}

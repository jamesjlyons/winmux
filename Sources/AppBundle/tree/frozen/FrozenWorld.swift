struct FrozenWorld: Codable, Equatable, Sendable {
    let workspaces: [FrozenWorkspace]
    let monitors: [FrozenMonitor]
    let windowIds: Set<UInt32>

    private enum CodingKeys: String, CodingKey { case workspaces, monitors, windowIds }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workspaces, forKey: .workspaces)
        try container.encode(monitors, forKey: .monitors)
        try container.encode(windowIds.sorted(), forKey: .windowIds)
    }
}

@MainActor
func snapshotCurrentFrozenWorld() -> FrozenWorld {
    let workspaces = restorableWorkspaces(Workspace.all)
    return FrozenWorld(
        workspaces: workspaces.map(FrozenWorkspace.init),
        monitors: monitors.map(FrozenMonitor.init),
        windowIds: workspaces.flatMap { collectAllWindowIds(workspace: $0) }.toSet(),
    )
}

@MainActor
func restorableWorkspaces(_ workspaces: [Workspace]) -> [Workspace] {
    workspaces.filter { !collectAllWindowIds(workspace: $0).isEmpty }
}

@MainActor
func collectAllWindowIds(workspace: Workspace) -> [UInt32] {
    workspace.floatingWindows.map { $0.windowId } +
        workspaceOwnedMinimizedWindows(workspace).map { $0.windowId } +
        (workspace.existingMacOsNativeFullscreenWindowsContainer?.children.filterIsInstance(of: Window.self).map { $0.windowId } ?? []) +
        (workspace.existingMacOsNativeHiddenAppsWindowsContainer?.children.filterIsInstance(of: Window.self).map { $0.windowId } ?? []) +
        collectAllWindowIdsRecursive(workspace.rootTilingContainer)
}

func collectAllWindowIdsRecursive(_ node: TreeNode) -> [UInt32] {
    switch node.nodeCases {
        case .macosFullscreenWindowsContainer,
             .macosHiddenAppsWindowsContainer,
             .macosMinimizedWindowsContainer,
             .macosPopupWindowsContainer,
             .workspace: []
        case .tilingContainer(let c):
            c.children.reduce(into: [UInt32]()) { partialResult, elem in
                partialResult += collectAllWindowIdsRecursive(elem)
            }
        case .window(let w): [w.windowId]
    }
}

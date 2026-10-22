import CoreGraphics

let workspaceTopBarHeight: CGFloat = 44

/// Reserve only the part below the display's existing menu-bar safe area.
func workspaceTopBarReservedHeight(_ configuration: WorkspaceSidebarConfig, visibleHeight: CGFloat, menuBarHeight: CGFloat) -> CGFloat {
    guard configuration.placement == .top else { return 0 }
    let offset = max(0, CGFloat(configuration.menuBarReserveHeight) - menuBarHeight) + CGFloat(configuration.topGap)
    return min(offset + workspaceTopBarHeight, max(0, visibleHeight - 1))
}

func workspaceTopBarFrame(screenFrame: CGRect, visibleFrame: CGRect, configuration: WorkspaceSidebarConfig) -> CGRect {
    let menuHeight = max(0, screenFrame.maxY - visibleFrame.maxY)
    let reserved = workspaceTopBarReservedHeight(configuration, visibleHeight: visibleFrame.height, menuBarHeight: menuHeight)
    let height = min(workspaceTopBarHeight, reserved)
    let edge = min(CGFloat(configuration.edgeGap), max(0, (screenFrame.width - 240) / 2))
    return CGRect(x: screenFrame.minX + edge, y: visibleFrame.maxY - reserved,
                  width: max(1, screenFrame.width - edge * 2), height: height)
}

/// Frozen positions are used during pickup; only the x axis determines reordering.
func workspaceTopTabReorderTarget(source: String, locationX: CGFloat, frames: [String: CGRect]) -> WorkspaceSidebarWorkspaceReorderTarget? {
    guard locationX.isFinite, let original = frames[source] else { return nil }
    let other = frames.filter { $0.key != source }.sorted { $0.value.midX < $1.value.midX }
    if locationX > original.midX, let target = other.last(where: { $0.value.midX < locationX && $0.value.midX > original.midX }) {
        return .init(name: target.key, placement: .after)
    }
    if locationX < original.midX, let target = other.first(where: { $0.value.midX > locationX && $0.value.midX < original.midX }) {
        return .init(name: target.key, placement: .before)
    }
    return nil
}

func workspaceTopBarWorkspaces(_ snapshot: WorkspaceSidebarSnapshot, allSpaces: Bool = false, query: String = "") -> [WorkspaceSidebarWorkspaceViewModel] {
    let grouped = workspaceSidebarVisibleWorkspacesByProject(workspaces: snapshot.workspaces,
        selectedScopeId: snapshot.selectedMonitorScopeId, focusedMonitorScopeId: snapshot.focusedMonitorScopeId)
    let filtered = workspaceSidebarFilteredWorkspacesByProject(grouped, projects: snapshot.projects, query: query)
    let projects = allSpaces ? snapshot.projects.map(\.id) : [snapshot.activeProjectId]
    return projects.flatMap { filtered[$0] ?? [] }.filter { !$0.isPinnedGroup || !$0.floatingItems.isEmpty }
}

func workspaceTopBarViewIsElsewhere(_ workspace: WorkspaceSidebarWorkspaceViewModel, monitor: String) -> Bool {
    workspace.isVisible && workspace.monitorScopeId != monitor
}

func workspaceTopBarPins(_ snapshot: WorkspaceSidebarSnapshot, allSpaces: Bool = false, query: String = "") -> [WorkspaceSidebarPinViewModel] {
    // Pins belong to a Space and stay reachable regardless of the display filter.
    let groups = Dictionary(grouping: snapshot.workspaces.filter(\.isPinnedGroup), by: \.projectId)
    let filtered = workspaceSidebarFilteredWorkspacesByProject(groups, projects: snapshot.projects, query: query)
    let projects = allSpaces ? snapshot.projects.map(\.id) : [snapshot.activeProjectId]
    return projects.flatMap { workspaceSidebarCombinedPins(filtered[$0] ?? [])?.pins ?? [] }
}

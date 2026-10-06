import SwiftUI

/// Shared by sidebar rows and the tab strip. Keep observation inside the menu so
/// destination changes don't make every tab strip observe the sidebar model.
struct WindowMoveMenu: View {
    let windowId: UInt32
    let workspaceName: String
    var subject: WindowDragSubject = .window
    var targetMonitorScopeId: String? = nil
    var actions: WorkspaceSidebarActions? = nil

    @ObservedObject private var sidebarModel = TrayMenuModel.shared

    var body: some View {
        let destinations = windowMoveMenuDestinations()
        Menu("Move to") {
            ForEach(destinations) { space in
                Menu(space.title) {
                    ForEach(space.groups) { group in
                        Button {
                            send(subject == .group
                                ? .moveTabGroup(windowId, toWorkspace: group.id)
                                : .moveWindow(windowId, toWorkspace: group.id))
                        } label: {
                            if group.id == workspaceName {
                                Label(group.title, systemImage: "checkmark")
                            } else {
                                Text(group.title)
                            }
                        }
                        .disabled(group.id == workspaceName)
                    }
                    Divider()
                    Button("New Group") {
                        let scope = targetMonitorScopeId
                            ?? Window.get(byId: windowId)?.nodeMonitor.map { workspaceSidebarMonitorScopeId(for: $0) }
                            ?? sidebarModel.workspaceSidebarFocusedMonitorScopeId
                        send(subject == .group
                            ? .moveTabGroupToNewWorkspace(windowId, projectId: space.id, monitorScopeId: scope)
                            : .moveWindowToNewWorkspace(windowId, projectId: space.id, monitorScopeId: scope))
                    }
                }
            }
        }
    }

    private func send(_ action: WorkspaceSidebarAction) {
        if let actions {
            actions.send(action)
        } else {
            handleWorkspaceSidebarAction(action)
        }
    }
}

struct WindowMoveMenuSpace: Identifiable, Equatable {
    let id: WorkspaceProjectId
    let title: String
    let groups: [WindowMoveMenuGroup]
}

struct WindowMoveMenuGroup: Identifiable, Equatable {
    let id: String
    let title: String
}

/// Use only local hierarchy metadata, including when the sidebar is disabled.
/// No window discovery or title fetching is needed to open the menu.
@MainActor
func windowMoveMenuDestinations(sourceSpace: WorkspaceProjectId? = nil) -> [WindowMoveMenuSpace] {
    let spaces = workspaceProjects().filter { sourceSpace?.isIncognito == true ? $0.id == sourceSpace : !$0.id.isIncognito }
    let workspaces = orderedWorkspacesForPresentation()
    let indices = automaticWorkspaceDisplayIndices(workspaces: workspaces, focusedWorkspace: focus.workspace)
    let controller = BrowserWorkspaceController.shared
    let destinations = workspaces.filter { workspace in
        guard !workspace.isArchived, !workspace.isPinnedGroup else { return false }
        guard config.workspaceInteractionMode == .views else { return true }
        // Count identities once even when a native window appears in both
        // trees. Retain saved/minimized group members without fetching titles.
        let organized = controller.usesSurfaceTree
            ? (controller.surfaceTree.roots[workspace.name] ?? []).flatMap(\.surfaces) : []
        let members = Set(organized)
            .union(workspace.allLeafWindowsRecursive.map(\.surfaceID))
            .union(workspaceOwnedMinimizedWindows(workspace).map(\.surfaceID))
        return members.count > 1 || (members.isEmpty && !workspace.usesAutomaticDisplayName)
    }
    return spaces.map { space in
        WindowMoveMenuSpace(
            id: space.id,
            title: space.name,
            groups: destinations.filter { $0.projectId == space.id }.map { workspace in
                WindowMoveMenuGroup(
                    id: workspace.name,
                    title: workspaceDisplayName(workspace.name, automaticIndices: indices),
                )
            },
        )
    }
}

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
func windowMoveMenuDestinations() -> [WindowMoveMenuSpace] {
    let spaces = workspaceProjects()
    let workspaces = orderedWorkspacesForPresentation()
    let indices = automaticWorkspaceDisplayIndices(workspaces: workspaces, focusedWorkspace: focus.workspace)
    return spaces.map { space in
        WindowMoveMenuSpace(
            id: space.id,
            title: space.name,
            groups: workspaces.filter { $0.projectId == space.id && !$0.isArchived }.map { workspace in
                WindowMoveMenuGroup(
                    id: workspace.name,
                    title: workspaceDisplayName(workspace.name, automaticIndices: indices),
                )
            },
        )
    }
}

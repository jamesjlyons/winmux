import SwiftUI
import WorkspaceCore

/// Reuse the original local Space/Group destination list for either owner and
/// whole shared subtrees. Opening this menu never discovers windows or tabs.
struct SurfaceMoveMenu: View {
    let subject: WorkspaceSidebarSurfaceDragSubject
    let workspaceName: String
    var targetMonitorScopeId: String? = nil
    let actions: WorkspaceSidebarActions
    @ObservedObject private var sidebarModel = TrayMenuModel.shared

    var body: some View {
        Menu("Move to") {
            ForEach(windowMoveMenuDestinations(sourceSpace: Workspace.existing(byName: workspaceName)?.projectId)) { space in
                Menu(space.title) {
                    ForEach(space.groups) { group in
                        Button { move(to: group.id) } label: {
                            if group.id == workspaceName {
                                Label(group.title, systemImage: "checkmark")
                            } else { Text(group.title) }
                        }
                        .disabled(group.id == workspaceName)
                    }
                    Divider()
                    Button("New View") { moveToNewGroup(in: space.id) }
                }
            }
        }
    }

    func move(to name: String) {
        guard name != workspaceName else { return }
        switch subject {
        case .pin: break // Pinned launchers use the separate Move to Space menu.
        case .surface(let id): actions.send(.moveSurface(id, toWorkspace: name))
        case .group(let id): actions.send(.moveSurfaceGroup(id, toWorkspace: name))
        }
    }

    func moveToNewGroup(in projectId: WorkspaceProjectId) {
        let scope = targetMonitorScopeId ?? sidebarModel.workspaceSidebarFocusedMonitorScopeId
        switch subject {
        case .pin: break
        case .surface(let id): actions.send(.moveSurfaceToNewWorkspace(id, projectId: projectId, monitorScopeId: scope))
        case .group(let id): actions.send(.moveSurfaceGroupToNewWorkspace(id, projectId: projectId, monitorScopeId: scope))
        }
    }
}

import Foundation

enum WorkspaceReorderPlacement: Equatable {
    case before
    case after
}

@MainActor
func canReorderWorkspace(_ name: String, relativeTo targetName: String) -> Bool {
    guard name != targetName,
          let workspace = Workspace.existing(byName: name),
          let target = Workspace.existing(byName: targetName)
    else { return false }
    return workspace.projectId == target.projectId && !workspace.isArchived && !target.isArchived
}

@MainActor
@discardableResult
func reorderWorkspace(_ name: String, relativeTo targetName: String, placement: WorkspaceReorderPlacement) -> Bool {
    guard canReorderWorkspace(name, relativeTo: targetName),
          let workspace = Workspace.existing(byName: name),
          let target = Workspace.existing(byName: targetName),
          var project = winMuxWorkspaceState.projectsById[workspace.projectId],
          let sourceIndex = project.workspaceOrder.firstIndex(of: workspace.id)
    else { return false }

    let originalOrder = project.workspaceOrder
    project.workspaceOrder.remove(at: sourceIndex)
    guard let targetIndex = project.workspaceOrder.firstIndex(of: target.id) else { return false }
    project.workspaceOrder.insert(workspace.id, at: targetIndex + (placement == .after ? 1 : 0))
    guard project.workspaceOrder != originalOrder else { return false }
    winMuxWorkspaceState.registerProject(project)
    return true
}

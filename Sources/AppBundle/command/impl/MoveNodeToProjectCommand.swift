import Common

struct MoveNodeToProjectCommand: Command {
    let args: MoveNodeToProjectCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        if let id = args.selectedBrowserTarget(env) {
            guard BrowserWorkspaceController.shared.isAvailable(id),
                  let name = BrowserWorkspaceController.shared.workspaceName(for: id),
                  let source = Workspace.existing(byName: name),
                  let project = resolveProjectTarget(args.target.val, currentProjectId: source.projectId, wrapAround: args.wrapAround) else {
                return io.err("Cannot resolve browser surface or destination project")
            }
            return moveSurfaceToWorkspace(id, firstWorkspaceForProjectMove(projectId: project.id, monitor: source.workspaceMonitor), io,
                focusFollowsSurface: args.focusFollowsWindow, failIfNoop: args.failIfNoop)
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        guard let window = target.windowOrNil else { return io.err(noWindowIsFocused) }
        guard let sourceWorkspace = window.nodeWorkspace else {
            return io.err("Window \(window.windowId) doesn't belong to any workspace")
        }
        guard let project = resolveProjectTarget(args.target.val, currentProjectId: sourceWorkspace.projectId, wrapAround: args.wrapAround) else {
            return io.err("Can't resolve project target")
        }
        let monitor = window.nodeMonitor ?? sourceWorkspace.workspaceMonitor
        let targetWorkspace = firstWorkspaceForProjectMove(projectId: project.id, monitor: monitor)
        return moveWindowToWorkspace(
            window,
            targetWorkspace,
            io,
            focusFollowsWindow: args.focusFollowsWindow,
            failIfNoop: args.failIfNoop,
            index: INDEX_BIND_LAST,
        )
    }
}

@MainActor
func resolveProjectTarget(
    _ target: ProjectTarget,
    currentProjectId: WorkspaceProjectId,
    wrapAround: Bool,
) -> WorkspaceProject? {
    let projects = workspaceProjects()
    guard !projects.isEmpty else { return nil }
    switch target {
        case .index(let index):
            return projects.getOrNil(atIndex: index - 1)
        case .relative(let nextPrev):
            guard let currentIndex = projects.firstIndex(where: { $0.id == currentProjectId }) else { return nil }
            let targetIndex = currentIndex + (nextPrev == .next ? 1 : -1)
            return wrapAround ? projects.get(wrappingIndex: targetIndex) : projects.getOrNil(atIndex: targetIndex)
    }
}

@MainActor
private func firstWorkspaceForProjectMove(projectId: WorkspaceProjectId, monitor: Monitor) -> Workspace {
    availablePreferredWorkspace(projectId: projectId, monitor: monitor)
        ?? createBlankWorkspace(projectId: projectId, monitor: monitor)
}

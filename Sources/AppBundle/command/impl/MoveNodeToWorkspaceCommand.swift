import Common

struct MoveNodeToWorkspaceCommand: Command {
    let args: MoveNodeToWorkspaceCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        if let id = args.selectedBrowserTarget(env) {
            guard BrowserWorkspaceController.shared.isAvailable(id),
                  let name = BrowserWorkspaceController.shared.workspaceName(for: id),
                  let source = Workspace.existing(byName: name),
                  let destination = resolveDestination(from: source, monitor: source.workspaceMonitor, io) else {
                return io.err("Cannot resolve browser surface or destination workspace")
            }
            return moveSurfaceToWorkspace(id, destination, io, focusFollowsSurface: args.focusFollowsWindow, failIfNoop: args.failIfNoop)
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        guard let window = target.windowOrNil else { return io.err(noWindowIsFocused) }
        guard let targetWorkspace = resolveDestination(from: window.nodeWorkspace ?? target.workspace,
            monitor: window.nodeMonitor ?? target.workspace.workspaceMonitor, io) else { return false }
        return moveWindowToWorkspace(window, targetWorkspace, io, focusFollowsWindow: args.focusFollowsWindow, failIfNoop: args.failIfNoop)
    }

    @MainActor private func resolveDestination(from subjectWs: Workspace, monitor: Monitor, _ io: CmdIo) -> Workspace? {
        switch args.target.val {
            case .relative(let nextPrev):
                let ws = getNextPrevWorkspace(
                    current: subjectWs,
                    isNext: nextPrev == .next,
                    wrapAround: args.wrapAround,
                    stdin: args.useStdin ? io.readStdin() : nil,
                )
                    ?? createNextTransientBlankWorkspaceForMoveIfAllowed(
                        from: subjectWs,
                        isNext: nextPrev == .next,
                        wrapAround: args.wrapAround,
                        usesStdin: args.useStdin,
                    )
                if ws == nil { io.err("Can't resolve next or prev workspace") }
                return ws
            case .direct(let name):
                guard let ws = resolveMoveTargetWorkspace(
                    named: name.raw,
                    sourceWorkspace: subjectWs,
                    sourceMonitor: monitor,
                ) else {
                    io.err("Workspace '\(name.raw)' doesn't exist")
                    return nil
                }
                return ws
        }
    }
}

@MainActor
private func createNextTransientBlankWorkspaceForMoveIfAllowed(
    from current: Workspace,
    isNext: Bool,
    wrapAround: Bool,
    usesStdin: Bool,
) -> Workspace? {
    guard isNext, !wrapAround, !usesStdin else { return nil }
    let nextWorkspaceIndex = scopedAutomaticDisplayWorkspaces(current: current).count + 1
    return createAdjacentTransientBlankWorkspaceIfAllowed(named: String(nextWorkspaceIndex), from: current)
}

@MainActor
func resolveMoveTargetWorkspace(
    named workspaceName: String,
    sourceWorkspace: Workspace,
    sourceMonitor: Monitor,
) -> Workspace? {
    if let targetIndex = parsePositiveWorkspaceDisplayIndex(workspaceName) {
        if let workspace = scopedAutomaticDisplayWorkspaces(current: sourceWorkspace).getOrNil(atIndex: targetIndex - 1) {
            return workspace
        }
        return createAdjacentTransientBlankWorkspaceIfAllowed(named: workspaceName, from: sourceWorkspace)
    }

    let existedBefore = Workspace.existing(byName: workspaceName) != nil
    let workspace = Workspace.get(byName: workspaceName)
    if !existedBefore {
        workspace.assignProject(sourceWorkspace.projectId)
    }
    workspace.seedMonitorIfNeeded(sourceMonitor)
    return workspace
}

@MainActor
func moveWindowToWorkspace(_ window: Window, _ targetWorkspace: Workspace, _ io: CmdIo, focusFollowsWindow: Bool, failIfNoop: Bool, index: Int = INDEX_BIND_LAST) -> Bool {
    if window.nodeWorkspace == targetWorkspace {
        if !failIfNoop {
            io.err("Window '\(window.windowId)' already belongs to workspace '\(targetWorkspace.name)'. Tip: use --fail-if-noop to exit with non-zero code")
        }
        return !failIfNoop
    }
    if window.isFloating {
        window.bind(to: targetWorkspace, adaptiveWeight: WEIGHT_AUTO, index: index)
    } else {
        let binding = workspaceAppendBindingData(targetWorkspace: targetWorkspace, index: index)
        window.bind(to: binding.parent, adaptiveWeight: binding.adaptiveWeight, index: binding.index)
    }
    BrowserWorkspaceController.shared.didMoveNativeSurface(window.surfaceID, to: targetWorkspace.name)
    return focusFollowsWindow ? window.focusWindow() : true
}

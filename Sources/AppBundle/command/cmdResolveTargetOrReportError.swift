import Common
import WorkspaceCore

extension CmdArgs {
    /// Explicit native IDs keep their established meaning. A missing/disconnected
    /// browser owner still counts as a browser selection: never fall back to AX.
    @MainActor
    func selectedBrowserTarget(_ env: CmdEnv) -> SurfaceID? {
        guard windowId == nil, workspaceName != nil || env.windowId == nil,
              let id = BrowserWorkspaceController.shared.focusCoordinator.target,
              case .browserTab = id else { return nil }
        if let workspace = workspaceName?.raw ?? env.workspaceName,
           workspace != BrowserWorkspaceController.shared.workspaceName(for: id) { return nil }
        return id
    }

    private var requiresNativeTarget: Bool {
        switch Self.info.kind {
        case .balanceSizes, .close, .closeAllWindowsButCurrent, .flattenWorkspaceTree,
             .fullscreen, .joinWith, .layout, .macosNativeFullscreen, .macosNativeMinimize,
             .move, .moveNodeToMonitor, .moveNodeToProject, .moveNodeToWorkspace,
             .resize, .split, .stackWith, .swap: true
        case .moveMouse:
            (self as? MoveMouseCmdArgs).map { $0.mouseTarget.val == .windowLazyCenter || $0.mouseTarget.val == .windowForceCenter } ?? false
        default: false
        }
    }

    @MainActor
    func resolveTargetOrReportError(_ env: CmdEnv, _ io: CmdIo) -> LiveFocus? {
        if requiresNativeTarget, selectedBrowserTarget(env) != nil {
            io.err("'\(Self.info.kind.rawValue)' does not support the selected browser tab; use a supported surface action or an explicit native --window-id")
            return nil
        }
        // Flags
        if let windowId {
            if let wi = Window.get(byId: windowId) {
                return wi.toLiveFocusOrReportError(io)
            } else {
                io.err("Invalid <window-id> \(windowId) passed to --window-id")
                return nil
            }
        }
        if let workspaceName {
            guard let workspace = Workspace.existing(byName: workspaceName.raw),
                  isUserFacingWorkspace(workspace, focusedWorkspace: focus.workspace)
            else {
                io.err("Workspace '\(workspaceName.raw)' doesn't exist")
                return nil
            }
            return workspace.toLiveFocus()
        }
        // Env
        if let windowId = env.windowId {
            if let wi = Window.get(byId: windowId) {
                return wi.toLiveFocusOrReportError(io)
            } else {
                io.err("Invalid <window-id> \(windowId) specified in \(WINMUX_WINDOW_ID) env variable")
                return nil
            }
        }
        if let wsName = env.workspaceName {
            guard let workspace = Workspace.existing(byName: wsName),
                  isUserFacingWorkspace(workspace, focusedWorkspace: focus.workspace)
            else {
                io.err("Workspace '\(wsName)' doesn't exist")
                return nil
            }
            return workspace.toLiveFocus()
        }
        // Real Focus
        return focus
    }
}

extension Window {
    @MainActor
    func toLiveFocusOrReportError(_ io: CmdIo) -> LiveFocus? {
        if let result = toLiveFocusOrNil() {
            return result
        } else {
            io.err("Window \(windowId) doesn't belong to any monitor. And thus can't even define a focused workspace")
            return nil
        }
    }
}

import AppKit
import Common

struct MoveNodeToMonitorCommand: Command {
    let args: MoveNodeToMonitorCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        if let id = args.selectedBrowserTarget(env) {
            guard BrowserWorkspaceController.shared.isAvailable(id),
                  let name = BrowserWorkspaceController.shared.workspaceName(for: id),
                  let source = Workspace.existing(byName: name) else { return io.err("Browser surface is unavailable") }
            switch args.target.val.resolve(source.workspaceMonitor, wrapAround: args.wrapAround) {
            case .success(let monitor):
                return moveSurfaceToWorkspace(id, monitor.activeWorkspace, io,
                    focusFollowsSurface: args.focusFollowsWindow, failIfNoop: args.failIfNoop)
            case .failure(let message): return io.err(message)
            }
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        guard let window = target.windowOrNil else {
            return io.err(noWindowIsFocused)
        }
        guard let currentMonitor = window.nodeMonitor else {
            return io.err(windowIsntPartOfTree(window))
        }
        switch args.target.val.resolve(currentMonitor, wrapAround: args.wrapAround) {
            case .success(let targetMonitor):
                let targetWs = targetMonitor.activeWorkspace
                let index = true == args.target.val.directionOrNil
                    .map { dir in dir.isPositive && targetWs.rootTilingContainer.orientation == dir.orientation }
                    ? 0
                    : INDEX_BIND_LAST
                return moveWindowToWorkspace(
                    window,
                    targetWs,
                    io,
                    focusFollowsWindow: args.focusFollowsWindow,
                    failIfNoop: args.failIfNoop,
                    index: index,
                )
            case .failure(let msg):
                return io.err(msg)
        }
    }
}

func windowIsntPartOfTree(_ window: Window) -> String {
    "Window \(window.windowId) is not part of tree (minimized or hidden)"
}

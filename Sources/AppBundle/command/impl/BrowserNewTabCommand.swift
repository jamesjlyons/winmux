import Common

struct BrowserNewTabCommand: Command {
    let args: BrowserNewTabCmdArgs
    let shouldResetClosedWindowsCache = false
    @MainActor func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        reportSurfaceAction(BrowserWorkspaceController.shared.openBrowserTab(), io)
    }
}

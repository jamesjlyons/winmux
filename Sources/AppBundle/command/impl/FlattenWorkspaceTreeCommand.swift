import AppKit
import Common

struct FlattenWorkspaceTreeCommand: Command {
    let args: FlattenWorkspaceTreeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        let controller = BrowserWorkspaceController.shared
        if let id = args.sharedOrganizationTarget(env), let name = controller.surfaceTree.workspace(of: id) {
            return controller.editOrganization(of: id) { $0.flatten(in: name) }
                || io.err("Cannot flatten this View: an owner is unavailable")
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        let workspace = target.workspace
        let windows = workspace.rootTilingContainer.allLeafWindowsRecursive
        for window in windows {
            window.bind(to: workspace.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        }
        return true
    }
}

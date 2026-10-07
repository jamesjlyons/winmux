import AppKit
import Common
import Foundation

struct BalanceSizesCommand: Command {
    let args: BalanceSizesCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        let controller = BrowserWorkspaceController.shared
        if let id = args.sharedOrganizationTarget(env), let name = controller.surfaceTree.workspace(of: id) {
            return controller.editOrganization(of: id) { $0.balance(in: name) }
                || io.err("Cannot balance this View: an owner is unavailable")
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        balance(target.workspace.rootTilingContainer)
        return true
    }
}

@MainActor
private func balance(_ parent: TilingContainer) {
    for child in parent.children {
        switch parent.layout {
            case .tiles: child.setWeight(parent.orientation, 1)
            case .tabGroup: break // Do nothing
        }
        if let child = child as? TilingContainer {
            balance(child)
        }
    }
}

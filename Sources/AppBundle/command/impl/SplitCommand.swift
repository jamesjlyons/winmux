import AppKit
import Common

struct SplitCommand: Command {
    let args: SplitCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        if config.enableNormalizationFlattenContainers {
            return io.err("'split' has no effect when 'enable-normalization-flatten-containers' normalization enabled. My recommendation: keep the normalizations enabled, and prefer 'join-with' over 'split'.")
        }
        let controller = BrowserWorkspaceController.shared
        if let id = args.sharedOrganizationTarget(env), let name = controller.surfaceTree.workspace(of: id) {
            let current = controller.surfaceTree.containingGroup(of: id).flatMap { controller.surfaceTree.layouts[$0] } ?? .horizontal
            // Shared Views do not retain invisible singleton containers. The
            // legacy split spelling changes the selected arrangement's axis.
            return controller.editOrganization(of: id) { tree in
                if (tree.roots[name] ?? []).flatMap(\.surfaces).count == 1 { return true }
                switch args.arg.val {
                case .horizontal: return tree.setLayout(containing: id, to: .horizontal)
                case .vertical: return tree.setLayout(containing: id, to: .vertical)
                case .opposite: return tree.setLayout(containing: id, to: current == .vertical ? .horizontal : .vertical)
                }
            } || io.err("Cannot split this View: an owner is unavailable")
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        guard let window = target.windowOrNil else {
            return io.err(noWindowIsFocused)
        }
        guard let parent = window.parent else { return false }
        switch parent.cases {
            case .workspace:
                // Nothing to do for floating and macOS native fullscreen windows
                return io.err("Can't split floating windows")
            case .tilingContainer(let parent):
                let orientation: Orientation = switch args.arg.val {
                    case .vertical: .v
                    case .horizontal: .h
                    case .opposite: parent.orientation.opposite
                }
                if parent.children.count == 1 {
                    parent.changeOrientation(orientation)
                } else {
                    let data = window.unbindFromParent()
                    let newParent = TilingContainer(
                        parent: parent,
                        adaptiveWeight: data.adaptiveWeight,
                        orientation,
                        .tiles,
                        index: data.index,
                    )
                    window.bind(to: newParent, adaptiveWeight: WEIGHT_AUTO, index: 0)
                }
                return true
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
                return io.err("Can't split macos fullscreen, minimized windows and windows of hidden apps. This behavior may change in the future")
            case .macosPopupWindowsContainer:
                return false // Impossible
        }
    }
}

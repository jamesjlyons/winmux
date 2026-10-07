import AppKit
import Common
import WorkspaceCore

struct SwapCommand: Command {
    let args: SwapCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = true

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        let controller = BrowserWorkspaceController.shared
        if let id = args.sharedOrganizationTarget(env), let name = controller.surfaceTree.workspace(of: id) {
            let neighbor: SurfaceID?
            switch args.target.val {
            case .direction(let direction):
                neighbor = controller.directionalNeighbor(of: id, toward: direction, wrapping: args.wrapAround)
            case .dfsRelative(let direction):
                let members = (controller.surfaceTree.roots[name] ?? []).flatMap(\.surfaces).filter(controller.isAvailable)
                guard let index = members.firstIndex(of: id) else { return false }
                let next = index + (direction == .dfsNext ? 1 : -1)
                neighbor = members.indices.contains(next) ? members[next]
                    : args.wrapAround ? members[(next + members.count) % members.count] : nil
            }
            guard let neighbor, controller.editOrganization(of: id, { $0.swapLeaves(id, neighbor) }) else { return false }
            return !args.swapFocus || controller.select(neighbor) == .issued
        }
        guard let target = args.resolveTargetOrReportError(env, io) else {
            return false
        }

        guard let currentWindow = target.windowOrNil else {
            return io.err(noWindowIsFocused)
        }

        let targetWindow: Window?
        switch args.target.val {
            case .direction(let direction):
                if let (parent, ownIndex) = currentWindow.closestParent(hasChildrenInDirection: direction, withLayout: nil) {
                    targetWindow = parent.children[ownIndex + direction.focusOffset].findLeafWindowRecursive(snappedTo: direction.opposite)
                } else if args.wrapAround {
                    targetWindow = target.workspace.findLeafWindowRecursive(snappedTo: direction.opposite)
                } else {
                    return false
                }
            case .dfsRelative(let nextPrev):
                let windows = target.workspace.rootTilingContainer.allLeafWindowsRecursive
                guard let currentIndex = windows.firstIndex(where: { $0 == target.windowOrNil }) else {
                    return false
                }
                var targetIndex = switch nextPrev {
                    case .dfsNext: currentIndex + 1
                    case .dfsPrev: currentIndex - 1
                }
                if !(0 ..< windows.count).contains(targetIndex) {
                    if !args.wrapAround {
                        return false
                    }
                    targetIndex = (targetIndex + windows.count) % windows.count
                }
                targetWindow = windows[targetIndex]
        }

        guard let targetWindow else {
            return false
        }

        swapWindows(currentWindow, targetWindow)

        if args.swapFocus {
            return targetWindow.focusWindow()
        }
        return true
    }
}

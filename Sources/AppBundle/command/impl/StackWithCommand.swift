import AppKit
import Common

struct StackWithCommand: Command {
    let args: StackWithCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        let controller = BrowserWorkspaceController.shared
        if let id = args.sharedOrganizationTarget(env) {
            let direction = args.direction.val
            if let other = controller.surfaceTree.stackItems(containing: id)?.first(where: { $0 != id }) {
                return controller.editOrganization(of: id) {
                    $0.split(id, beside: other, layout: direction.orientation == .h ? .horizontal : .vertical,
                        before: !direction.isPositive)
                } || io.err("Cannot separate this item: an owner is unavailable")
            }
            guard let neighbor = controller.directionalNeighbor(of: id, toward: direction) else {
                return io.err("No items in the specified direction")
            }
            return controller.editOrganization(of: id) { $0.insertIntoStack(id, with: neighbor) }
                || io.err("Cannot stack these items: an owner is unavailable")
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        guard let currentWindow = target.windowOrNil else {
            return io.err(noWindowIsFocused)
        }
        let direction = args.direction.val

        // If the window is already in a tab group, pop it out in the specified direction
        if let parent = currentWindow.parent as? TilingContainer, parent.layout == .tabGroup {
            guard removeWindowFromTabStack(currentWindow) else {
                return io.err("Failed to remove window from tab group")
            }
            // After removal, move the window in the specified direction
            // so it lands on the correct side of the (former) tab group
            let moveArgs = MoveCmdArgs(rawArgs: [], direction)
            return MoveCommand(args: moveArgs).run(env, io)
        }

        // Normal: stack with window in the specified direction
        guard let (parent, ownIndex) = currentWindow.closestParent(hasChildrenInDirection: direction, withLayout: nil) else {
            return io.err("No windows in the specified direction")
        }
        guard let targetWindow = parent.children[ownIndex + direction.focusOffset].findLeafWindowRecursive(snappedTo: direction.opposite) else {
            return io.err("No windows in the specified direction")
        }
        createOrAppendWindowTabStack(sourceWindow: currentWindow, onto: targetWindow)
        return true
    }
}

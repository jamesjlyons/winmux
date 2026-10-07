import Common
import Foundation
import WorkspaceCore

struct AgentWorkspaceLayout: Codable {
    let name: String
    let focusPane: AgentPaneRef?
    let layout: AgentLayoutNode
    let floating: [AgentPaneRef]?

    private enum CodingKeys: String, CodingKey {
        case name
        case focusPane = "focus"
        case layout
        case floating
    }

    @MainActor
    func validate(appendTo errors: inout [String]) async throws {
        if BrowserWorkspaceController.shared.usesSurfaceTree {
            do { _ = try sharedLayout(in: BrowserWorkspaceController.shared.surfaceTree) }
            catch let error as AgentEditError { errors.append(error.message) }
            return
        }
        var orderedWindowIds: [UInt32] = []
        layout.collectWindowIds(result: &orderedWindowIds)
        for ref in floating ?? [] {
            ref.resolveNode()?.allLeafWindowsRecursive.forEach { orderedWindowIds.append($0.windowId) }
        }

        let windowIds = Set(orderedWindowIds)
        for windowId in duplicateAgentWindowIds(in: orderedWindowIds) {
            errors.append("setWorkspaceLayout '\(name)': window \(windowId) appears more than once")
        }
        for windowId in windowIds where Window.get(byId: windowId) == nil {
            errors.append("setWorkspaceLayout '\(name)': window \(windowId) does not exist")
        }
        for ref in floating ?? [] where ref.resolveNode() == nil {
            errors.append("setWorkspaceLayout '\(name)': floating pane does not exist")
        }
    }

    @MainActor
    func apply() async throws {
        let controller = BrowserWorkspaceController.shared
        if controller.usesSurfaceTree {
            let plan = try sharedLayout(in: controller.surfaceTree)
            for (name, sourceName) in plan.destinations {
                let source = Workspace.existing(byName: sourceName) ?? focus.workspace
                let workspace = Workspace.get(byName: name)
                workspace.assignProject(source.projectId)
                workspace.retainsEmptyView = true
                workspace.seedMonitorIfNeeded(source.workspaceMonitor)
            }
            guard controller.editOrganization(in: plan.workspaces, selecting: plan.selection,
                admittingFloating: plan.admittedFloating, floating: plan.floating, { tree in
                guard tree == plan.before else { return false }
                tree = plan.after; return true
            }) else { throw AgentEditError("Cannot apply shared View layout: an owner is unavailable or a profile transfer is required") }
            if let selection = plan.selection { _ = controller.select(selection) }
            return
        }
        let existedBefore = Workspace.existing(byName: name) != nil
        let workspace = Workspace.get(byName: name)
        if !existedBefore {
            workspace.assignProject(focus.workspace.projectId)
        }
        workspace.retainsEmptyView = true
        workspace.seedMonitorIfNeeded(focusPane?.resolveNode()?.nodeMonitor ?? focus.workspace.workspaceMonitor)
        let oldWindows = workspace.allLeafWindowsRecursive
        var referenced: Set<UInt32> = []
        layout.collectWindowIds(result: &referenced)
        for ref in floating ?? [] {
            ref.resolveNode()?.allLeafWindowsRecursive.forEach { referenced.insert($0.windowId) }
        }

        workspace.rootTilingContainer.unbindFromParent()
        switch layout {
            case .split:
                _ = try await layout.bind(into: workspace, index: INDEX_BIND_LAST)
            case .window, .tabGroup, .surface, .stack:
                _ = try await layout.bind(into: workspace.rootTilingContainer, index: INDEX_BIND_LAST)
        }
        bindFloatingPanes(to: workspace)
        restoreUnreferencedWindows(oldWindows, referenced: referenced, root: workspace.rootTilingContainer)
        layout.applySizeRatios(to: workspace.rootTilingContainer)
        if let focusNode = focusPane?.resolveNode() {
            _ = focusNode.mostRecentWindowRecursive?.focusWindow()
        }
    }

    @MainActor
    private func bindFloatingPanes(to workspace: Workspace) {
        for ref in floating ?? [] {
            if let node = ref.resolveNode(), let window = node as? Window {
                window.bindAsFloatingWindow(to: workspace)
            }
        }
    }

    @MainActor
    private func restoreUnreferencedWindows(_ oldWindows: [Window], referenced: Set<UInt32>, root: TilingContainer) {
        for window in oldWindows where !referenced.contains(window.windowId) && window.isBound {
            if window.nodeWorkspace == nil || window.nodeWorkspace == root.nodeWorkspace {
                window.bind(to: root, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
        }
    }
}

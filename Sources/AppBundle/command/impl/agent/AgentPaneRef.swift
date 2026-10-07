import Foundation
import WorkspaceCore

struct AgentPaneRef: Codable {
    let paneId: String?
    let windowId: UInt32?
    let tabGroupId: String?
    var surfaceId: SurfaceID? = nil
    var groupId: UUID? = nil

    @MainActor
    func resolvePane(in tree: SurfaceTree, aliases: [String: UUID] = [:]) -> SurfacePane? {
        let candidate: SurfacePane?
        if let surfaceId { candidate = .surface(surfaceId) }
        else if let groupId { candidate = .group(groupId) }
        else if let paneId, let surface = SurfaceID(string: paneId) { candidate = .surface(surface) }
        else if let paneId, paneId.hasPrefix("group:"), let id = UUID(uuidString: String(paneId.dropFirst(6))) { candidate = .group(id) }
        else if let paneId, paneId.hasPrefix("pane-"), let id = UInt32(paneId.dropFirst(5)) {
            candidate = Window.get(byId: id).map { .surface($0.surfaceID) }
        } else if let windowId { candidate = Window.get(byId: windowId).map { .surface($0.surfaceID) } }
        else {
            let name = tabGroupId ?? paneId.map { $0.hasPrefix("pane-") ? String($0.dropFirst(5)) : $0 }
            if let name, let id = aliases[name] { candidate = .group(id) }
            else if let name, name.hasPrefix("group:"), let id = UUID(uuidString: String(name.dropFirst(6))) { candidate = .group(id) }
            else if let name, name.hasPrefix("tabgroup-"), let id = UInt32(name.dropFirst(9)),
                    let window = Window.get(byId: id), let group = tree.stack(containing: window.surfaceID) {
                candidate = .group(group)
            } else { candidate = nil }
        }
        return candidate.flatMap { tree.node(for: $0) == nil ? nil : $0 }
    }

    @MainActor
    func resolveNode(context: AgentApplyContext? = nil) -> TreeNode? {
        if let surfaceId { return Window.get(bySurfaceID: surfaceId) }
        if let paneId, let id = SurfaceID(string: paneId) { return Window.get(bySurfaceID: id) }
        if let paneId {
            if paneId.hasPrefix("pane-tabgroup-") {
                return resolveAgentTabGroup(String(paneId.dropFirst("pane-".count)), context: context)
            }
            if paneId.hasPrefix("pane-"), let windowId = UInt32(paneId.dropFirst("pane-".count)) {
                return Window.get(byId: windowId)
            }
        }
        if let windowId { return Window.get(byId: windowId) }
        if let tabGroupId { return resolveAgentTabGroup(tabGroupId, context: context) }
        return nil
    }

    @MainActor
    func canResolve(in context: AgentValidationContext) -> Bool {
        if let tree = context.sharedTree, resolvePane(in: tree, aliases: context.sharedGroupAliases) != nil { return true }
        if resolveNode() != nil { return true }
        if let tabGroupId, context.plannedTabGroups[tabGroupId] != nil { return true }
        if let paneId, paneId.hasPrefix("pane-tabgroup-") {
            return context.plannedTabGroups[String(paneId.dropFirst("pane-".count))] != nil
        }
        return false
    }
}

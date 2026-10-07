import Common
import Foundation
import WorkspaceCore

/// Query values project the canonical tree. Native IDs remain owner handles;
/// browser identities are never cast to native window IDs.
struct AgentSurfaceInfo: Encodable {
    let surfaceId: SurfaceID
    let windowId: UInt32?
    let workspace: String
    let paneId: String
    let groupId: UUID?
    let title: String
    let available: Bool
    let focused: Bool
    let size: Double?
    let sizeAxis: AgentLayoutDirection?
    let frame: AgentRect?

    @MainActor
    init(id: SurfaceID, workspace: String, tree: SurfaceTree, native: [UInt32: AgentWindowInfo]) {
        let controller = BrowserWorkspaceController.shared
        surfaceId = id; windowId = Window.get(bySurfaceID: id)?.windowId
        self.workspace = workspace
        groupId = tree.stack(containing: id)
        paneId = groupId.map { "group:" + $0.uuidString.lowercased() } ?? id.description
        let window = windowId.flatMap { native[$0] }
        title = window?.title ?? agentSurfaceLabel(id)
        available = controller.isAvailable(id)
        focused = (controller.focusCoordinator.target ?? focus.windowOrNil?.surfaceID) == id
        let allocation = tree.allocation(of: .surface(id))
        size = allocation?.ratio
        sizeAxis = allocation.map { $0.layout == .vertical ? .vertical : .horizontal }
        frame = window?.frame ?? controller.owner(of: id)?.inventory.tabs[id]?.hostFrame.map {
            AgentRect(Rect(topLeftX: CGFloat($0.x), topLeftY: CGFloat($0.y), width: CGFloat($0.width), height: CGFloat($0.height)))
        }
    }
}

@MainActor
func agentSurfaceLabel(_ id: SurfaceID) -> String {
    if let record = BrowserWorkspaceController.shared.owner(of: id)?.inventory.tabs[id] { return record.title }
    if let window = Window.get(bySurfaceID: id) { return window.app.name ?? "Window \(window.windowId)" }
    return "Unavailable item"
}

struct AgentSharedRawNode: Encodable {
    let kind: String
    var surfaceId: SurfaceID? = nil
    var windowId: UInt32? = nil
    var groupId: UUID? = nil
    var direction: AgentLayoutDirection? = nil
    var activeSurfaceId: SurfaceID? = nil
    var size: Double? = nil
    var children: [AgentSharedRawNode]? = nil

    @MainActor
    static func project(_ node: SurfaceTreeNode, tree: SurfaceTree) -> Self {
        // A stack's hidden members have no independent allocation.
        let parent = tree.ancestors(of: node.pane).last
        let inStack: Bool
        if case .group(let id, _) = parent { inStack = (tree.layouts[id] ?? .stack) == .stack }
        else { inStack = false }
        let ratio = inStack ? nil : tree.allocation(of: node.pane)?.ratio
        switch node {
        case .surface(let id):
            return .init(kind: "surface", surfaceId: id, windowId: Window.get(bySurfaceID: id)?.windowId, size: ratio)
        case .group(let id, let children):
            let layout = tree.layouts[id] ?? .stack
            return .init(kind: layout == .stack ? "stack" : "split", groupId: id,
                direction: layout == .stack ? nil : layout == .horizontal ? .horizontal : .vertical,
                activeSurfaceId: layout == .stack ? tree.activeSurfaces[id] ?? node.surfaces.first : nil,
                size: ratio, children: children.map { project($0, tree: tree) })
        }
    }
}

@MainActor
struct AgentSharedProjection {
    var panes: [AgentPaneInfo] = []
    var relations: [AgentPaneRelation] = []
    var tabGroups: [AgentTabGroupInfo] = []
    let rawTree: AgentRawWorkspaceTree

    init(workspace: Workspace, tree: SurfaceTree, nativeTitles: [UInt32: String]) {
        let nodes = tree.roots[workspace.name] ?? []
        rawTree = .init(workspace: workspace.name, tree: .shared(.init(kind: "split", direction: .horizontal,
            children: nodes.map { AgentSharedRawNode.project($0, tree: tree) })))
        func visit(_ node: SurfaceTreeNode) {
            let allocation = tree.allocation(of: node.pane)
            switch node {
            case .surface(let id):
                panes.append(.init(paneId: id.description, kind: .surface, workspace: workspace.name,
                    windowId: Window.get(bySurfaceID: id)?.windowId, tabGroupId: nil, label: agentSurfaceLabel(id),
                    size: allocation.map { CGFloat($0.ratio) }, sizeAxis: allocation.map { $0.layout == .vertical ? .vertical : .horizontal },
                    frame: nil, surfaceId: id))
            case .group(let id, let children):
                if (tree.layouts[id] ?? .stack) == .stack {
                    let key = "group:" + id.uuidString.lowercased()
                    panes.append(.init(paneId: key, kind: .tabGroup, workspace: workspace.name, windowId: nil,
                        tabGroupId: key, label: "Stack", size: allocation.map { CGFloat($0.ratio) },
                        sizeAxis: allocation.map { $0.layout == .vertical ? .vertical : .horizontal }, frame: nil, groupId: id))
                    tabGroups.append(.init(id: id, node: node, tree: tree, nativeTitles: nativeTitles))
                } else { children.forEach(visit) }
            }
        }
        nodes.forEach(visit)
        for window in workspace.floatingWindows {
            panes.append(.init(paneId: window.surfaceID.description, kind: .window, workspace: workspace.name,
                windowId: window.windowId, tabGroupId: nil, label: agentSurfaceLabel(window.surfaceID), size: nil,
                sizeAxis: nil, frame: window.lastKnownActualRect.map(AgentRect.init), surfaceId: window.surfaceID))
        }
        var byPane: [String: AgentPaneRelation] = [:]
        func relation(_ a: String, _ b: String, axis: SurfaceContainerLayout) {
            var lhs = byPane[a] ?? .init(workspace: workspace.name, paneId: a)
            var rhs = byPane[b] ?? .init(workspace: workspace.name, paneId: b)
            if axis == .horizontal { lhs.right = b; rhs.left = a } else { lhs.below = b; rhs.above = a }
            byPane[a] = lhs; byPane[b] = rhs
        }
        func paneIds(_ node: SurfaceTreeNode) -> [String] {
            switch node {
            case .surface(let id): [id.description]
            case .group(let id, let children):
                (tree.layouts[id] ?? .stack) == .stack ? ["group:" + id.uuidString.lowercased()] : children.flatMap(paneIds)
            }
        }
        func visitRelations(_ children: [SurfaceTreeNode], axis: SurfaceContainerLayout) {
            for pair in zip(children, children.dropFirst()) {
                for a in paneIds(pair.0) { for b in paneIds(pair.1) { relation(a, b, axis: axis) } }
            }
            for case .group(let id, let nested) in children where (tree.layouts[id] ?? .stack) != .stack {
                visitRelations(nested, axis: tree.layouts[id] ?? .stack)
            }
        }
        visitRelations(nodes, axis: .horizontal)
        relations = Array(byPane.values)
    }
}

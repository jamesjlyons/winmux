import Foundation
import WorkspaceCore

extension AgentWorkspaceLayout {
    @MainActor
    func sharedLayout(in tree: SurfaceTree, floatingWindows: Set<SurfaceID>? = nil) throws -> AgentSharedPaneEdit {
        var layouts: [UUID: SurfaceContainerLayout] = [:]
        var selections: [UUID: SurfaceID] = [:]
        var weights: [String: Double] = [:]
        var members: [SurfaceID] = []
        var admissions: Set<SurfaceID> = []

        func require(_ id: SurfaceID) throws -> SurfaceID {
            if tree.workspace(of: id) == nil {
                guard let window = Window.get(bySurfaceID: id), floatingWindows?.contains(id) ?? window.isFloating, window.nodeWorkspace != nil,
                      window.toLiveFocusOrNil() != nil else { throw AgentEditError("setWorkspaceLayout '\(name)': surface '\(id)' does not exist") }
                admissions.insert(id)
            }
            members.append(id)
            return id
        }
        func native(_ id: UInt32) throws -> SurfaceID {
            guard let window = Window.get(byId: id) else { throw AgentEditError("setWorkspaceLayout '\(name)': window \(id) does not exist") }
            return try require(window.surfaceID)
        }
        func size(_ nodes: [SurfaceTreeNode], specs: [AgentLayoutNode]) {
            let values = specs.map(\.sizeRatio)
            let ratios = agentResolvedSizeRatios(ratiosByChild: values,
                explicitTotal: values.compactMap { $0 }.reduce(0, +), unspecifiedCount: values.filter { $0 == nil }.count)
            for (node, ratio) in zip(nodes, ratios) { weights[node.pane.weightKey] = max(1, min(30000, Double(ratio) * 30000)) }
        }
        func stack(_ ids: [SurfaceID], active: SurfaceID?) throws -> SurfaceTreeNode {
            guard ids.count >= 2 else { throw AgentEditError("setWorkspaceLayout '\(name)': a stack requires at least two members") }
            if let active, !ids.contains(active) { throw AgentEditError("setWorkspaceLayout '\(name)': active item must belong to its stack") }
            let group = UUID()
            layouts[group] = .stack; selections[group] = active ?? ids.first
            return .group(group, ids.map(SurfaceTreeNode.surface))
        }
        func build(_ spec: AgentLayoutNode) throws -> SurfaceTreeNode {
            switch spec {
            case .window(let id, _): return .surface(try native(id))
            case .surface(let id, _): return .surface(try require(id))
            case .tabGroup(_, let tabs, let active, _):
                let ids = try tabs.map(native)
                if let active, !tabs.contains(active) { throw AgentEditError("setWorkspaceLayout '\(name)': activeWindowId must be in tabs") }
                return try stack(ids, active: active.flatMap { Window.get(byId: $0)?.surfaceID })
            case .stack(let ids, let active, _): return try stack(ids.map(require), active: active)
            case .split(let axis, let children, _):
                guard !children.isEmpty else { throw AgentEditError("setWorkspaceLayout '\(name)': a nested split cannot be empty") }
                let nodes = try children.map(build)
                size(nodes, specs: children)
                if nodes.count == 1 { return nodes[0] }
                let group = UUID(); layouts[group] = axis.sharedLayout
                return .group(group, nodes)
            }
        }
        let nodes: [SurfaceTreeNode]
        if case .split(.horizontal, let children, _) = layout {
            nodes = try children.map(build); size(nodes, specs: children)
        } else { nodes = [try build(layout)] }

        var floatingIDs: Set<SurfaceID> = []
        for ref in floating ?? [] {
            let window: Window?
            if let id = ref.surfaceId { window = Window.get(bySurfaceID: id) }
            else if let pane = ref.resolvePane(in: tree), case .surface(let id) = pane { window = Window.get(bySurfaceID: id) }
            else { window = ref.resolveNode() as? Window }
            guard let window else { throw AgentEditError("setWorkspaceLayout '\(name)': floating refs must name native windows") }
            floatingIDs.insert(try require(window.surfaceID))
        }
        var seen: Set<SurfaceID> = []
        for id in members where !seen.insert(id).inserted {
            let label = Window.get(bySurfaceID: id).map { "window \($0.windowId)" } ?? "surface '\(id)'"
            throw AgentEditError("setWorkspaceLayout '\(name)': \(label) appears more than once")
        }
        var baseline = tree
        for id in admissions.sorted(by: { $0.description < $1.description }) {
            let source = Window.get(bySurfaceID: id)!.nodeWorkspace!.name
            baseline.reconcile((baseline.roots[source] ?? []).flatMap(\.surfaces) + [id], in: source)
        }
        var affected = Set(members.compactMap { baseline.workspace(of: $0) }); affected.insert(name)
        let source = members.first.flatMap { baseline.workspace(of: $0) } ?? focus.workspace.name
        let targetProject = Workspace.existing(byName: name)?.projectId ?? Workspace.existing(byName: source)?.projectId
        for id in members where id.browserProfileID != nil {
            guard baseline.workspace(of: id).flatMap(Workspace.existing(byName:))?.projectId == targetProject else {
                throw AgentEditError("Move browser pages between Spaces with 'surface move' before applying a layout; a profile transaction is required")
            }
        }
        var candidate = baseline
        guard candidate.arrange(nodes, in: name, layouts: layouts, activeSurfaces: selections, weights: weights) else {
            throw AgentEditError("setWorkspaceLayout '\(name)': invalid arrangement")
        }
        for id in floatingIDs { _ = candidate.moveToRoot(id, in: name) }
        let selected: SurfaceID?
        if let focusPane {
            guard let pane = focusPane.resolvePane(in: candidate), let node = candidate.node(for: pane), candidate.workspace(of: pane) == name else {
                throw AgentEditError("setWorkspaceLayout '\(name)': focus must name a member of this View")
            }
            if case .group(let id) = pane { selected = candidate.activeSurfaces[id] ?? node.surfaces.first }
            else { selected = node.surfaces.first }
        } else { selected = nil }
        return .init(before: baseline, after: candidate, workspaces: affected, aliases: [:],
            destinations: Workspace.existing(byName: name) == nil ? [name: source] : [:], selection: selected,
            groupTransfer: nil, surfaceTransfer: nil, admittedFloating: admissions, floating: floatingIDs, mentioned: Set(members))
    }
}

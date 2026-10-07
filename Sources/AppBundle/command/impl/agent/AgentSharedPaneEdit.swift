import Foundation
import WorkspaceCore

struct AgentSharedPaneEdit {
    let before: SurfaceTree
    let after: SurfaceTree
    let workspaces: Set<String>
    let aliases: [String: UUID]
    let destinations: [String: String]
    let selection: SurfaceID?
    let groupTransfer: (id: UUID, workspace: String)?
    let surfaceTransfer: (id: SurfaceID, workspace: String)?
    var admittedFloating: Set<SurfaceID> = []
    var floating: Set<SurfaceID> = []
    var mentioned: Set<SurfaceID> = []

    var resultingTree: SurfaceTree {
        var result = after
        for id in floating { result.remove(id) }
        return result
    }
}

extension AgentOperation {
    /// The same value-only operation is used by check and apply. Validation
    /// carries the candidate forward so a later resize sees an earlier split.
    @MainActor
    func sharedPaneEdit(in tree: SurfaceTree, aliases: [String: UUID], floatingWindows: Set<SurfaceID>? = nil) throws -> AgentSharedPaneEdit? {
        var baseline = tree, candidate = tree
        var affected: Set<String> = []
        var newAliases = aliases
        var destinations: [String: String] = [:]
        var selection: SurfaceID?
        var groupTransfer: (id: UUID, workspace: String)?
        var surfaceTransfer: (id: SurfaceID, workspace: String)?
        var admittedFloating: Set<SurfaceID> = []
        var floating: Set<SurfaceID> = []
        func resolve(_ ref: AgentPaneRef) throws -> SurfacePane {
            guard let pane = ref.resolvePane(in: candidate, aliases: aliases),
                  let name = candidate.workspace(of: pane) else { throw AgentEditError("Shared pane does not exist") }
            affected.insert(name)
            return pane
        }
        func native(_ id: UInt32) throws -> SurfaceID {
            guard let window = Window.get(byId: id) else { throw AgentEditError("Window \(id) does not exist") }
            if candidate.workspace(of: window.surfaceID) == nil, floatingWindows?.contains(window.surfaceID) ?? window.isFloating,
               let source = window.nodeWorkspace?.name {
                affected.insert(source); admittedFloating.insert(window.surfaceID)
                candidate.reconcile((candidate.roots[source] ?? []).flatMap(\.surfaces) + [window.surfaceID], in: source)
                baseline.reconcile((baseline.roots[source] ?? []).flatMap(\.surfaces) + [window.surfaceID], in: source)
                return window.surfaceID
            }
            _ = try resolve(.init(paneId: nil, windowId: id, tabGroupId: nil))
            return window.surfaceID
        }
        func stack(_ name: String) throws -> UUID {
            let pane = try resolve(.init(paneId: nil, windowId: nil, tabGroupId: name))
            guard case .group(let id) = pane, (candidate.layouts[id] ?? .stack) == .stack else {
                throw AgentEditError("Tab group '\(name)' does not exist")
            }
            return id
        }
        func destination(_ name: String, from source: String) {
            affected.insert(name)
            if Workspace.existing(byName: name) == nil { destinations[name] = source }
        }
        let changed: Bool
        switch self {
        case .setWorkspaceLayout(let layout): return try layout.sharedLayout(in: tree, floatingWindows: floatingWindows)
        case .swapPanes(let a, let b):
            let first = try resolve(a), second = try resolve(b)
            changed = candidate.swap(first, second)
        case .placePane(let source, let relation, let target):
            let first = try resolve(source), second = try resolve(target)
            changed = candidate.place(first, beside: second, toward: relation.sharedDirection)
        case .setPaneSize(let ref, let axis, let size):
            let pane = try resolve(ref)
            changed = candidate.setProportion(Double(size), of: pane, axis: axis?.sharedLayout)
        case .createTabGroup(let alias, let workspace, let tabs, let activeWindowId):
            guard tabs.count >= 2 else { throw AgentEditError("createTabGroup requires at least two tabs") }
            if let duplicate = duplicateAgentWindowIds(in: tabs).first {
                throw AgentEditError("createTabGroup: window \(duplicate) appears more than once")
            }
            let ids = try tabs.map(native)
            let first = ids[0], source = candidate.workspace(of: first)!
            let target = workspace ?? source
            destination(target, from: source)
            if let activeWindowId, !tabs.contains(activeWindowId) { throw AgentEditError("createTabGroup: activeWindowId must be in tabs") }
            for id in ids { guard candidate.moveToRoot(id, in: target) else { throw AgentEditError("Cannot move stack member") } }
            for id in ids.dropFirst() {
                guard candidate.insertIntoStack(id, with: first) else { throw AgentEditError("Cannot combine stack members") }
            }
            guard let group = candidate.stack(containing: first) else { throw AgentEditError("Cannot create stack") }
            if let alias { newAliases[alias] = group }
            selection = activeWindowId.flatMap { Window.get(byId: $0)?.surfaceID }
            candidate.select(selection ?? first)
            changed = true
        case .addWindowToTabGroup(let windowId, let name, let activeWindowId):
            let id = try native(windowId), group = try stack(name)
            guard let node = candidate.group(group), let anchor = node.surfaces.first(where: { $0 != id }),
                  let target = candidate.workspace(ofGroup: group) else { throw AgentEditError("Cannot resolve stack members") }
            if candidate.workspace(of: id) != target { _ = candidate.moveToRoot(id, in: target) }
            changed = candidate.insertIntoStack(id, with: anchor)
            if let activeWindowId {
                let active = try native(activeWindowId)
                guard candidate.group(group)?.surfaces.contains(active) == true else { throw AgentEditError("Active window must belong to the stack") }
                selection = active; candidate.select(active)
            }
        case .moveWindowOutOfTabGroup(let windowId):
            let id = try native(windowId)
            if let group = candidate.stack(containing: id), let name = candidate.workspace(of: id),
               let anchor = candidate.group(group)?.surfaces.first(where: { $0 != id }) {
                changed = candidate.moveToRoot(id, in: name, after: anchor)
            } else { changed = true }
        case .setActiveTab(let name, let windowId):
            let group = try stack(name), id = try native(windowId)
            guard candidate.group(group)?.surfaces.contains(id) == true else { throw AgentEditError("setActiveTab: window \(windowId) is not in tab group '\(name)'") }
            selection = id; candidate.select(id); changed = true
        case .moveTabGroupToWorkspace(let name, let target, let shouldFocus):
            let group = try stack(name)
            let source = candidate.workspace(ofGroup: group)!
            destination(target, from: source)
            if shouldFocus == true { selection = candidate.activeSurfaces[group] ?? candidate.group(group)?.surfaces.first }
            changed = source == target || candidate.moveGroupToRoot(group, in: target)
            groupTransfer = (group, target)
        case .moveWindowToWorkspace(let windowId, let target, let shouldFocus):
            let id = try native(windowId), source = candidate.workspace(of: id)!
            if admittedFloating.contains(id) { floating.insert(id) }
            destination(target, from: source)
            if shouldFocus == true { selection = id }
            changed = source == target || candidate.moveToRoot(id, in: target)
        case .parkWindow(let ref, let workspace):
            if ref.resolvePane(in: candidate, aliases: aliases) == nil, let window = ref.resolveNode() as? Window,
               floatingWindows?.contains(window.surfaceID) ?? window.isFloating {
                floating.insert(try native(window.windowId))
            }
            let pane = try resolve(ref), target = workspace ?? "__agent_parked"
            let source = candidate.workspace(of: pane)!
            destination(target, from: source)
            switch pane {
            case .group(let id):
                changed = source == target || candidate.moveGroupToRoot(id, in: target)
                groupTransfer = (id, target)
            case .surface(let id):
                changed = source == target || candidate.moveToRoot(id, in: target)
                if id.browserProfileID != nil { surfaceTransfer = (id, target) }
            }
        case .setFloating(let windowId, let value):
            let id = try native(windowId)
            if value { floating.insert(id) }
            changed = true
        default: return nil
        }
        guard changed else { throw AgentEditError("Cannot edit shared panes: targets overlap or the pane has no matching split") }
        for name in affected where groupTransfer == nil && surfaceTransfer == nil {
            for id in (candidate.roots[name] ?? []).flatMap(\.surfaces) where id.browserProfileID != nil {
                guard let source = tree.workspace(of: id), source != name else { continue }
                guard Workspace.existing(byName: source)?.projectId == Workspace.existing(byName: name)?.projectId else {
                    throw AgentEditError("Move browser pages between Spaces with 'surface move' before arranging them; a profile transaction is required")
                }
            }
        }
        // Admission order must match the owner adapter even when native window
        // IDs and durable surface IDs sort differently.
        baseline = tree
        for id in admittedFloating.sorted(by: { $0.description < $1.description }) {
            let source = Window.get(bySurfaceID: id)!.nodeWorkspace!.name
            baseline.reconcile((baseline.roots[source] ?? []).flatMap(\.surfaces) + [id], in: source)
        }
        return .init(before: baseline, after: candidate, workspaces: affected, aliases: newAliases,
            destinations: destinations, selection: selection, groupTransfer: groupTransfer, surfaceTransfer: surfaceTransfer,
            admittedFloating: admittedFloating, floating: floating)
    }
}

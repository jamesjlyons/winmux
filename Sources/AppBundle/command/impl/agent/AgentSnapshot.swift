import AppKit
import Common
import Foundation
import WorkspaceCore

// MARK: - Query

struct AgentSnapshot: Encodable {
    let schemaVersion: Int
    let snapshotId: String
    let worldId: String
    let inventory: AgentInventory
    let reasoning: AgentReasoning
    let edit: AgentEditTemplate

    @MainActor
    static func query() async throws -> AgentSnapshot {
        let worldId = currentAgentWorldId()
        let controller = BrowserWorkspaceController.shared
        let sharedTree = controller.usesSurfaceTree ? controller.surfaceTree : nil
        let workspaces = userFacingWorkspaces(Workspace.all, focusedWorkspace: focus.workspace)
        var windows: [AgentWindowInfo] = []
        var tabGroups: [AgentTabGroupInfo] = []
        var workspaceInfos: [AgentWorkspaceInfo] = []
        var allPanes: [AgentPaneInfo] = []
        var allRelations: [AgentPaneRelation] = []
        var rawTrees: [AgentRawWorkspaceTree] = []

        for workspace in workspaces {
            if let sharedTree {
                var nativeTitles: [UInt32: String] = [:]
                for window in workspace.allLeafWindowsRecursive {
                    let info = try await AgentWindowInfo(window, tree: sharedTree)
                    windows.append(info); nativeTitles[info.windowId] = info.title
                }
                let projection = AgentSharedProjection(workspace: workspace, tree: sharedTree, nativeTitles: nativeTitles)
                allPanes.append(contentsOf: projection.panes)
                allRelations.append(contentsOf: projection.relations)
                rawTrees.append(projection.rawTree)
                workspaceInfos.append(.init(name: workspace.name, displayName: workspaceDisplayName(workspace.name),
                    visible: workspace.isVisible, focused: focus.workspace == workspace,
                    monitorId: workspace.workspaceMonitor.monitorId_oneBased, panes: projection.panes.map(\.paneId)))
                tabGroups.append(contentsOf: projection.tabGroups)
                continue
            }
            let panes = workspace.agentPaneInfos()
            let relations = workspace.agentPaneRelations()
            allPanes.append(contentsOf: panes)
            allRelations.append(contentsOf: relations)
            rawTrees.append(AgentRawWorkspaceTree(workspace: workspace.name, tree: workspace.rootTilingContainer.agentRawLayoutNode()))
            workspaceInfos.append(AgentWorkspaceInfo(
                name: workspace.name,
                displayName: workspaceDisplayName(workspace.name),
                visible: workspace.isVisible,
                focused: focus.workspace == workspace,
                monitorId: workspace.workspaceMonitor.monitorId_oneBased,
                panes: panes.map(\.paneId),
            ))
            for group in workspace.rootTilingContainer.allAgentTabGroupsRecursive {
                tabGroups.append(await AgentTabGroupInfo(group))
            }
            for window in workspace.allLeafWindowsRecursive {
                windows.append(try await AgentWindowInfo(window))
            }
        }

        var inventory = AgentInventory(
            windows: windows.sortedBy(\.windowId),
            tabGroups: tabGroups.sortedBy(\.tabGroupId),
            workspaces: workspaceInfos.sortedBy(\.name),
        )
        if let sharedTree {
            let native = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowId, $0) })
            inventory.surfaces = sharedTree.roots.keys.sorted().flatMap { name in
                (sharedTree.roots[name] ?? []).flatMap(\.surfaces).map { id in
                    AgentSurfaceInfo(id: id, workspace: name, tree: sharedTree, native: native)
                }
            }
            let included = Set(inventory.surfaces.map(\.surfaceId))
            for info in windows {
                if let window = Window.get(byId: info.windowId), let name = info.workspace, !included.contains(window.surfaceID) {
                    inventory.surfaces.append(.init(id: window.surfaceID, workspace: name, tree: sharedTree, native: native))
                }
            }
        }
        let reasoning = AgentReasoning(
            panes: allPanes.sortedBy(\.paneId),
            relations: allRelations.sortedBy([{ $0.workspace }, { $0.paneId }]),
            rawTrees: rawTrees.sortedBy(\.workspace),
        )
        guard worldId == currentAgentWorldId() else { throw AgentEditError("Layout changed while reading the agent snapshot. Query again.") }
        return AgentSnapshot(
            schemaVersion: sharedTree == nil ? 1 : 2,
            snapshotId: ISO8601DateFormatter().string(from: Date()),
            worldId: worldId,
            inventory: inventory,
            reasoning: reasoning,
            edit: AgentEditTemplate(operations: [], layout: nil),
        )
    }
}

struct AgentInventory: Encodable {
    let windows: [AgentWindowInfo]
    let tabGroups: [AgentTabGroupInfo]
    let workspaces: [AgentWorkspaceInfo]
    var surfaces: [AgentSurfaceInfo] = []
}

struct AgentWorkspaceInfo: Encodable {
    let name: String
    let displayName: String
    let visible: Bool
    let focused: Bool
    let monitorId: Int?
    let panes: [String]
}

struct AgentWindowInfo: Encodable {
    let windowId: UInt32
    let title: String
    let appName: String?
    let appBundleId: String?
    let pid: Int32
    let workspace: String?
    let paneId: String?
    let tabGroupId: String?
    let focused: Bool
    let winMuxFullscreen: Bool
    let noOuterGapsInFullscreen: Bool
    let layout: String
    let size: CGFloat?
    let sizeAxis: AgentLayoutDirection?
    let frame: AgentRect?

    @MainActor
    init(_ window: Window, tree: SurfaceTree? = nil) async throws {
        windowId = window.windowId
        title = try await window.title
        appName = window.app.name
        appBundleId = window.app.rawAppBundleId
        pid = window.app.pid
        workspace = window.nodeWorkspace?.name
        let group = tree?.stack(containing: window.surfaceID)
        tabGroupId = tree == nil ? window.nearestWindowTabGroup.map(agentTabGroupId) : group.map { "group:" + $0.uuidString.lowercased() }
        paneId = tree == nil ? window.agentPaneId : tabGroupId ?? window.surfaceID.description
        focused = focus.windowOrNil == window
        winMuxFullscreen = window.isFullscreen
        noOuterGapsInFullscreen = window.noOuterGapsInFullscreen
        layout = tree == nil || window.isFloating ? window.agentLayoutDescription : group == nil ? "tiles" : "tabGroup"
        let sizingNode = window.agentPaneSizingNode
        let allocation = tree?.allocation(of: .surface(window.surfaceID))
        size = tree == nil ? sizingNode.agentSizeRatio : allocation.map { CGFloat($0.ratio) }
        sizeAxis = tree == nil ? sizingNode.agentSizeAxis : allocation.map { $0.layout == .vertical ? .vertical : .horizontal }
        // lastKnownActualRect is invalidated on move/resize events; fetch live when it's stale
        // so the reported frame reflects reality rather than the last cached observation.
        var actualRect = window.lastKnownActualRect
        if actualRect == nil {
            actualRect = try? await window.getAxRect()
        }
        frame = (actualRect ?? window.lastAppliedLayoutPhysicalRect ?? window.lastAppliedLayoutVirtualRect).map(AgentRect.init)
    }
}

struct AgentTabGroupInfo: Encodable {
    let tabGroupId: String
    let paneId: String
    let workspace: String?
    let activeWindowId: UInt32?
    let tabs: [UInt32]
    let tabTitles: [String]
    let size: CGFloat?
    let sizeAxis: AgentLayoutDirection?
    let frame: AgentRect?
    var groupId: UUID? = nil
    var surfaces: [SurfaceID]? = nil
    var activeSurfaceId: SurfaceID? = nil

    @MainActor
    init(_ group: TilingContainer) async {
        tabGroupId = agentTabGroupId(group)
        paneId = agentPaneIdForTabGroup(tabGroupId: tabGroupId)
        workspace = group.nodeWorkspace?.name
        activeWindowId = group.tabActiveWindow?.windowId
        let windows = group.agentTabWindows
        tabs = windows.map(\.windowId)
        var titles: [String] = []
        for window in windows {
            titles.append((try? await window.title) ?? "")
        }
        tabTitles = titles
        size = group.agentSizeRatio
        sizeAxis = group.agentSizeAxis
        frame = (group.lastAppliedLayoutPhysicalRect ?? group.lastAppliedLayoutVirtualRect).map(AgentRect.init)
    }

    @MainActor
    init(id: UUID, node: SurfaceTreeNode, tree: SurfaceTree, nativeTitles: [UInt32: String]) {
        tabGroupId = "group:" + id.uuidString.lowercased()
        paneId = tabGroupId
        workspace = tree.workspace(ofGroup: id)
        let active = tree.activeSurfaces[id] ?? node.surfaces.first
        activeWindowId = active.flatMap { Window.get(bySurfaceID: $0)?.windowId }
        tabs = node.surfaces.compactMap { Window.get(bySurfaceID: $0)?.windowId }
        tabTitles = node.surfaces.map { id in
            Window.get(bySurfaceID: id).flatMap { nativeTitles[$0.windowId] } ?? agentSurfaceLabel(id)
        }
        let allocation = tree.allocation(of: .group(id))
        size = allocation.map { CGFloat($0.ratio) }
        sizeAxis = allocation.map { $0.layout == .vertical ? .vertical : .horizontal }
        frame = nil
        groupId = id; surfaces = node.surfaces; activeSurfaceId = active
    }
}

struct AgentReasoning: Encodable {
    let panes: [AgentPaneInfo]
    let relations: [AgentPaneRelation]
    let rawTrees: [AgentRawWorkspaceTree]
}

struct AgentPaneInfo: Encodable {
    let paneId: String
    let kind: AgentPaneKind
    let workspace: String
    let windowId: UInt32?
    let tabGroupId: String?
    let label: String
    let size: CGFloat?
    let sizeAxis: AgentLayoutDirection?
    let frame: AgentRect?
    var surfaceId: SurfaceID? = nil
    var groupId: UUID? = nil
}

enum AgentPaneKind: String, Codable {
    case window
    case tabGroup
    case surface
}

struct AgentPaneRelation: Encodable {
    let workspace: String
    let paneId: String
    var left: String?
    var right: String?
    var above: String?
    var below: String?
}

struct AgentRawWorkspaceTree: Encodable {
    let workspace: String
    let tree: AgentRawLayoutNode
}

indirect enum AgentRawLayoutNode: Encodable {
    case shared(AgentSharedRawNode)
    case split(direction: AgentLayoutDirection, layout: String, size: CGFloat?, children: [AgentRawLayoutNode])
    case window(windowId: UInt32, size: CGFloat?)
    case tabGroup(tabGroupId: String, activeWindowId: UInt32?, tabs: [UInt32], size: CGFloat?)

    enum CodingKeys: String, CodingKey {
        case kind
        case direction
        case layout
        case size
        case children
        case windowId
        case tabGroupId
        case activeWindowId
        case tabs
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
            case .shared(let node):
                try node.encode(to: encoder)
            case .split(let direction, let layout, let size, let children):
                try container.encode("split", forKey: .kind)
                try container.encode(direction, forKey: .direction)
                try container.encode(layout, forKey: .layout)
                try container.encodeIfPresent(size, forKey: .size)
                try container.encode(children, forKey: .children)
            case .window(let windowId, let size):
                try container.encode("window", forKey: .kind)
                try container.encode(windowId, forKey: .windowId)
                try container.encodeIfPresent(size, forKey: .size)
            case .tabGroup(let tabGroupId, let activeWindowId, let tabs, let size):
                try container.encode("tabGroup", forKey: .kind)
                try container.encode(tabGroupId, forKey: .tabGroupId)
                try container.encode(activeWindowId, forKey: .activeWindowId)
                try container.encode(tabs, forKey: .tabs)
                try container.encodeIfPresent(size, forKey: .size)
        }
    }
}

struct AgentRect: Codable, Equatable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(_ rect: Rect) {
        x = rect.topLeftX
        y = rect.topLeftY
        width = rect.width
        height = rect.height
    }
}

struct AgentEditTemplate: Encodable {
    let operations: [String]
    let layout: AgentLayoutEdit?
}

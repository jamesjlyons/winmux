import AppKit
import Common
import Foundation

struct RestartWindowIdentity: Codable, Equatable, Sendable {
    let pid: Int32
    let bundleId: String?
    let launchDate: Date?

    @MainActor init(_ app: any AbstractApp) {
        pid = app.pid
        bundleId = app.rawAppBundleId
        launchDate = (app as? MacApp)?.nsApp.launchDate
    }

    init(pid: Int32, bundleId: String?, launchDate: Date?) {
        self.pid = pid
        self.bundleId = bundleId
        self.launchDate = launchDate
    }
}

struct RestartWindow: Codable, Sendable {
    let id: UInt32
    let identity: RestartWindowIdentity
    let floatingFrame: CGRect?
}

struct RestartProject: Codable, Sendable {
    let id: WorkspaceProjectId
    let name: String
    let order: Int
    let workspaceNames: [String]
}

struct RestartSessionSnapshot: Codable, Sendable {
    var version = 2
    let savedAt: Date
    let bootSession: String?
    let world: FrozenWorld
    let windows: [RestartWindow]?
    let projects: [RestartProject]?
    let focusedWindowId: UInt32?
    let focusedWorkspace: String?

    @MainActor static func capture(now: Date = .now) -> RestartSessionSnapshot {
        let workspaces = Workspace.all.filter { !$0.isArchived }
        let world = FrozenWorld(workspaces: workspaces.map(FrozenWorkspace.init), monitors: monitors.map(FrozenMonitor.init),
                                windowIds: workspaces.flatMap(collectAllWindowIds).toSet())
        return RestartSessionSnapshot(
            savedAt: now, bootSession: currentBootSession(), world: world,
            windows: world.windowIds.sorted().compactMap { id in
                guard let window = Window.get(byId: id) else { return nil }
                let frame: CGRect? = window.isFloating ? (window as? MacWindow)?.frameForSessionRestore ?? window.lastKnownActualRect.map {
                    CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height)
                } : nil
                return RestartWindow(id: id, identity: RestartWindowIdentity(window.app), floatingFrame: frame)
            },
            projects: winMuxWorkspaceState.projectsById.values.sorted { $0.order < $1.order }.map { project in
                RestartProject(id: project.id, name: project.name, order: project.order,
                               workspaceNames: project.workspaceOrder.compactMap { winMuxWorkspaceState.workspaceById[$0]?.name })
            },
            focusedWindowId: focus.windowOrNil?.windowId, focusedWorkspace: focus.workspace.name
        )
    }

    func matches(windowId: UInt32, identity: RestartWindowIdentity, boot: String?) -> Bool {
        guard world.windowIds.contains(windowId) else { return false }
        if version == 1 { return true } // Only imported from this boot; legacy snapshots have no process identities.
        guard let bootSession, bootSession == boot else { return false }
        return windows?.contains { $0.id == windowId && $0.identity == identity } == true
    }
}

func currentBootSession() -> String? {
    var count = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &count, nil, 0) == 0, count > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: count)
    guard sysctlbyname("kern.bootsessionuuid", &buffer, &count, nil, 0) == 0 else { return nil }
    return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func restoredFloatingFrame(_ frame: CGRect, savedScreen: CGRect?, targetScreen: CGRect) -> CGRect {
    var result = frame
    if let savedScreen, savedScreen.width > 0, savedScreen.height > 0, savedScreen != targetScreen {
        result.origin.x = targetScreen.minX + (frame.minX - savedScreen.minX) / savedScreen.width * targetScreen.width
        result.origin.y = targetScreen.minY + (frame.minY - savedScreen.minY) / savedScreen.height * targetScreen.height
    }
    result.size.width = min(max(result.width, 1), targetScreen.width)
    result.size.height = min(max(result.height, 1), targetScreen.height)
    result.origin.x = min(max(result.minX, targetScreen.minX), targetScreen.maxX - result.width)
    result.origin.y = min(max(result.minY, targetScreen.minY), targetScreen.maxY - result.height)
    return result
}

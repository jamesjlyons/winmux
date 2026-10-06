import Common
import Foundation
import WorkspaceCore

struct SurfaceCommand: Command {
    let args: SurfaceCmdArgs
    var shouldResetClosedWindowsCache: Bool { args.operands.first != "list" }
    var canSkipPostCommandRefresh: Bool { args.operands.first == "list" }

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        let controller = BrowserWorkspaceController.shared
        if args.operands[0] == "list" {
            let rows = controller.knownSurfaces.sorted { $0.description < $1.description }.map { id in
                SurfaceReference(id: id.description, workspace: controller.workspaceName(for: id),
                    available: controller.isAvailable(id), selected: (controller.focusCoordinator.target ?? focus.windowOrNil?.surfaceID) == id,
                    pinnedDesktopID: controller.pinnedDesktops.first { controller.pinBindings(in: $0.workspaceName).values.contains(id) }?.id,
                    nativeWindowID: Window.get(bySurfaceID: id)?.windowId,
                    browser: controller.owner(of: id).flatMap { BrowserSurfaceState(session: $0, id: id) })
            }
            guard let data = try? JSONEncoder().encode(rows), let json = String(data: data, encoding: .utf8) else {
                return io.err("Cannot encode surface references")
            }
            return io.out(json)
        }
        let raw = args.operands[1]
        guard let id = raw == "selected" ? (controller.focusCoordinator.target ?? focus.windowOrNil?.surfaceID) : SurfaceID(string: raw) else {
            return io.err("Expected a typed surface ID or an available selection")
        }
        guard controller.isAvailable(id) else { return io.err("Surface '\(id)' is unavailable") }
        switch args.operands[0] {
        case "focus": return reportSurfaceAction(controller.select(id), io)
        case "close": return reportSurfaceAction(controller.close(id), io)
        case "pin": return reportOrganization(controller.pinSurface(id), io)
        case "unpin":
            guard let desktop = controller.pinnedDesktops.first(where: { controller.pinBindings(in: $0.workspaceName).values.contains(id) }) else {
                return io.err("Surface does not belong to a pinned desktop")
            }
            return reportOrganization(controller.unpin(desktop.id), io)
        case "group":
            let rawTarget = args.operands[2]
            let target: SurfaceID?
            if rawTarget == "next" || rawTarget == "prev" {
                let members = controller.surfaceTree.workspace(of: id)
                    .flatMap { controller.surfaceTree.roots[$0] }?.flatMap(\.surfaces) ?? []
                let index = members.firstIndex(of: id).map { $0 + (rawTarget == "next" ? 1 : -1) }
                target = index.flatMap { members.indices.contains($0) ? members[$0] : nil }
            } else { target = SurfaceID(string: rawTarget) }
            guard let target, controller.isAvailable(target), let style = SurfaceContainerLayout(rawValue: args.operands[3]) else {
                return io.err("Group target is unavailable or outside the workspace order")
            }
            return reportOrganization(controller.editOrganization(of: id) { $0.group(id, with: target, layout: style) }, io)
        case "layout":
            guard let style = SurfaceContainerLayout(rawValue: args.operands[2]) else { return false }
            return reportOrganization(controller.editOrganization(of: id) { $0.setLayout(containing: id, to: style) }, io)
        case "ungroup":
            guard let group = controller.surfaceTree.containingGroup(of: id) else { return io.err("Surface is not in a group") }
            return reportOrganization(controller.editOrganization(of: id) { $0.ungroup(group) }, io)
        case "reorder":
            return reportOrganization(controller.editOrganization(of: id) { $0.reorder(id, earlier: args.operands[2] == "earlier") }, io)
        case "move":
            guard let source = controller.workspaceName(for: id).flatMap(Workspace.existing(byName:)),
                  let target = resolveMoveTargetWorkspace(named: args.operands[2], sourceWorkspace: source,
                                                         sourceMonitor: source.workspaceMonitor) else {
                return io.err("Cannot resolve destination workspace")
            }
            return moveSurfaceToWorkspace(id, target, io, focusFollowsSurface: args.focusFollowsSurface, failIfNoop: false)
        default: return io.err("Unsupported surface action")
        }
    }
}

@MainActor
private func reportOrganization(_ applied: Bool, _ io: CmdIo) -> Bool {
    applied || io.err("Cannot change shared organization: check owner availability, layout support and container boundaries")
}

private struct SurfaceReference: Encodable {
    let id: String
    let workspace: String?
    let available: Bool
    let selected: Bool
    let pinnedDesktopID: UUID?
    let nativeWindowID: UInt32?
    let browser: BrowserSurfaceState?
}

/// Local control diagnostics omit page titles, URLs and profile paths.
private struct BrowserSurfaceState: Encodable {
    let lifecycle: BrowserPageLifecycle
    let keepActive: Bool
    let hostWindowID: UInt32?
    let managed: Bool
    let minimized: Bool
    let fullscreen: Bool
    let zoomed: Bool
    let frame: SurfaceFrame?
    let minimum: SurfaceMinimumSize?
    let inventoryRevision: UInt64
    let layoutReply: String?
    let layoutRevision: UInt64?
    let layoutGeneration: UInt64?
    let layoutTimeoutCount: UInt64
    let pendingLayoutMilliseconds: Double?
    let requestedFrame: SurfaceFrame?
    let requestedVisible: Bool?

    @MainActor init?(session: BrowserSurfaceSession, id: SurfaceID) {
        guard let tab = session.inventory.tabs[id] else { return nil }
        lifecycle = tab.lifecycle
        keepActive = tab.keepActive
        hostWindowID = tab.hostWindowID
        managed = tab.hostManaged
        minimized = tab.hostMinimized
        fullscreen = tab.hostFullscreen
        zoomed = tab.hostZoomed
        frame = tab.hostFrame
        minimum = tab.hostMinimumSize
        inventoryRevision = session.inventory.revision
        layoutReply = session.lastLayoutReply?.rawValue
        layoutRevision = session.lastLayoutRequest?.revision
        layoutGeneration = session.lastLayoutRequest?.generation
        layoutTimeoutCount = session.layoutTimeoutCount
        pendingLayoutMilliseconds = session.pendingLayoutMilliseconds
        let host = session.lastLayoutRequest?.hosts.first { $0.surfaces.contains(id) }
        requestedFrame = host.map { .init(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        requestedVisible = host?.visible
    }
}

@MainActor
func reportSurfaceAction(_ outcome: SurfaceActionOutcome, _ io: CmdIo) -> Bool {
    switch outcome {
    case .issued: true
    case .unavailable: io.err("Surface owner is unavailable; no action was dispatched")
    case .unsupported: io.err("The selected owner does not support this action")
    }
}

@MainActor
func moveSurfaceToWorkspace(_ id: SurfaceID, _ target: Workspace, _ io: CmdIo,
                            focusFollowsSurface: Bool, failIfNoop: Bool,
                            controller: BrowserWorkspaceController = .shared) -> Bool {
    guard controller.isAvailable(id), let sourceName = controller.workspaceName(for: id),
          let source = Workspace.existing(byName: sourceName) else { return io.err("Surface owner is unavailable") }
    if source === target { return failIfNoop ? io.err("Surface already belongs to destination workspace") : true }
    switch id {
    case .browserTab:
        guard controller.usesSurfaceTree, controller.owner(of: id)?.supportsLayout == true else {
            return io.err("Browser workspace moves require shared layouts and protocol 3")
        }
        controller.moveBrowserSurface(id, to: target.name)
    case .nativeWindow:
        guard let window = Window.get(bySurfaceID: id),
              moveWindowToWorkspace(window, target, io, focusFollowsWindow: false, failIfNoop: failIfNoop) else { return false }
    }
    if focusFollowsSurface { return reportSurfaceAction(controller.select(id), io) }
    // Do not reaffirm a tab on a now-hidden workspace after the layout reply.
    // Keep focus on the source when its selected item has moved away.
    if controller.usesSurfaceTree, controller.focusCoordinator.target == id {
        let remaining = (controller.surfaceTree.roots[source.name] ?? []).flatMap(\.surfaces)
            .first { $0 != id && controller.isAvailable($0) }
        if let remaining { _ = controller.select(remaining) }
        else { _ = source.focusWorkspace(); controller.nativeSelectionChanged(nil) }
    }
    return true
}

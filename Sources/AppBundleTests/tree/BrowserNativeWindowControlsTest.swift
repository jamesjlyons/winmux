@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor
final class BrowserNativeWindowControlsTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testNativeMinimizeFullscreenAndZoomRetainStackAndRestoreOriginalPlacement() throws {
        for action: BrowserSurfaceAction in [.minimize, .fullscreen, .zoom] {
            let controller = BrowserWorkspaceController(foregroundProcessID: { -2 })
            let connection = UUID(), epoch = UUID(), workspace = focus.workspace
            let profile = UUID(), first = SurfaceID.browserTab(profile: profile, tab: UUID())
            let second = SurfaceID.browserTab(profile: profile, tab: UUID())
            var tree = SurfaceTree(); tree.reconcile([first, second], in: workspace.name)
            tree.importStack([first, second], in: workspace.name); tree.select(first)
            let group = try XCTUnwrap(tree.containingGroup(of: first))
            controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [workspace.name],
                selected: nil, closedBrowserTabs: []))
            controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
            controller.received(.init(revision: 1, full: true, tabs: [record(first), record(second)]),
                epoch: epoch, connection: connection, protocolVersion: 4)
            let durable = controller.surfaceTree
            let before = controller.plannedSurfaces(in: workspace)
            XCTAssertTrue(before.contains { $0.surfaceID == first && $0.visible })

            controller.received(.init(revision: 2, full: false, tabs: [
                record(first, minimized: action == .minimize, fullscreen: action == .fullscreen, zoomed: action == .zoom),
            ]), epoch: epoch, connection: connection, protocolVersion: 4)
            _ = controller.organizedRows(native: [], in: workspace.name)
            XCTAssertEqual(controller.surfaceTree, durable)
            XCTAssertEqual(controller.surfaceTree.group(group)?.surfaces, [first, second])
            let during = controller.plannedSurfaces(in: workspace)
            XCTAssertFalse(during.contains { $0.surfaceID == first })
            XCTAssertTrue(during.contains { $0.surfaceID == second && $0.visible })
            XCTAssertTrue(controller.isAvailable(first), "The sidebar keeps the real owner available for restoration")

            controller.received(.init(revision: 3, full: false, tabs: [record(first)]),
                epoch: epoch, connection: connection, protocolVersion: 4)
            XCTAssertEqual(controller.surfaceTree, durable)
            XCTAssertEqual(controller.plannedSurfaces(in: workspace), before)
            controller.disconnected(connection)
        }
    }

    func testAutomaticGroupSelectionSkipsSuspendedMRUButSidebarCanExplicitlyRestore() {
        for action: BrowserSurfaceAction in [.minimize, .fullscreen, .zoom] {
            let controller = BrowserWorkspaceController(foregroundProcessID: { -2 }), workspace = focus.workspace
            let connection = UUID(), epoch = UUID(), first = SurfaceID.browserTab(profile: UUID(), tab: UUID())
            let second = SurfaceID.browserTab(profile: UUID(), tab: UUID())
            var requests: [BrowserActionRequest] = []
            var tree = SurfaceTree(); tree.reconcile([first, second], in: workspace.name)
            controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [workspace.name],
                selected: nil, closedBrowserTabs: []))
            controller.connected(connection, processID: -1) { request, reply in requests.append(request); reply(.issued) }
            controller.received(.init(revision: 1, full: true, tabs: [record(first), record(second)]),
                epoch: epoch, connection: connection, protocolVersion: 4)
            XCTAssertEqual(controller.select(first), .issued)
            XCTAssertEqual(controller.preferredSurface(in: workspace), first)
            controller.received(.init(revision: 2, full: false, tabs: [
                record(first, minimized: action == .minimize, fullscreen: action == .fullscreen, zoomed: action == .zoom),
            ]), epoch: epoch, connection: connection, protocolVersion: 4)
            XCTAssertEqual(controller.preferredSurface(in: workspace), second)
            XCTAssertTrue(controller.isAvailable(first))
            requests = []
            XCTAssertEqual(controller.select(first), .issued)
            XCTAssertEqual(requests.last?.action, .focus)
            XCTAssertEqual(requests.last?.surfaceID, first)
            controller.received(.init(revision: 3, full: false, tabs: [record(first)]),
                epoch: epoch, connection: connection, protocolVersion: 4)
            XCTAssertEqual(controller.preferredSurface(in: workspace), first)
            controller.disconnected(connection)
        }
    }

    func testMinimizingPassivePaneNeverActivatesItAndFocusedPaneRetiresPendingFocus() {
        let controller = BrowserWorkspaceController(foregroundProcessID: { -2 })
        let connection = UUID(), epoch = UUID(), first = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let second = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var requests: [BrowserActionRequest] = []
        controller.usesSurfaceTree = true
        controller.connected(connection, processID: -1) { request, reply in requests.append(request); reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [record(first), record(second)]),
            epoch: epoch, connection: connection, protocolVersion: 4)
        XCTAssertEqual(controller.select(first), .issued)
        requests = []
        controller.performToolbarAction(.minimize, for: second)
        XCTAssertEqual(requests.map(\.action), [.minimize])
        XCTAssertEqual(requests.map(\.surfaceID), [second])
        XCTAssertEqual(controller.focusCoordinator.target, first)

        requests = []
        controller.performToolbarAction(.minimize, for: first)
        XCTAssertEqual(requests.map(\.action), [.cancelFocus, .minimize])
        XCTAssertNil(controller.focusCoordinator.target)
        XCTAssertFalse(controller.holdsPendingBrowserFocus)
    }

    func testGreenButtonDispatchesFullscreenAndOptionGreenDispatchesZoom() {
        let controller = BrowserWorkspaceController(foregroundProcessID: { -2 })
        let connection = UUID(), epoch = UUID(), page = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var requests: [BrowserActionRequest] = []
        controller.usesSurfaceTree = true
        controller.connected(connection, processID: -1) { request, reply in requests.append(request); reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [record(page)]),
            epoch: epoch, connection: connection, protocolVersion: 4)
        for (toolbar, native) in [(BrowserToolbarAction.fullscreen, BrowserSurfaceAction.fullscreen), (.zoom, .zoom)] {
            requests = []
            controller.performToolbarAction(toolbar, for: page)
            XCTAssertEqual(requests.map(\.action), [.focus, native])
            XCTAssertEqual(requests.map(\.surfaceID), [page, page])
            XCTAssertFalse(controller.holdsPendingBrowserFocus)
        }
    }

    func testLayoutReplyCannotRestoreNativelyMinimizedPage() throws {
        let previousLease = BrowserNativeManagement.lease, previousEnabled = TrayMenuModel.shared.isEnabled
        let leasePath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        BrowserNativeManagement.lease = try NativeManagementLease(path: leasePath)
        TrayMenuModel.shared.isEnabled = true
        defer {
            BrowserNativeManagement.lease = previousLease
            TrayMenuModel.shared.isEnabled = previousEnabled
            try? FileManager.default.removeItem(atPath: leasePath)
        }
        let controller = BrowserWorkspaceController(foregroundProcessID: { -2 }), workspace = focus.workspace
        let connection = UUID(), epoch = UUID(), page = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var requests: [BrowserActionRequest] = [], replies: [@MainActor (BrowserActionReply) -> Void] = []
        var tree = SurfaceTree(); tree.reconcile([page], in: workspace.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [workspace.name],
            selected: nil, closedBrowserTabs: []))
        controller.connected(connection, processID: -1, sendLayout: { _, reply in replies.append(reply) }) { request, reply in
            requests.append(request); reply(.issued)
        }
        controller.received(.init(revision: 1, full: true, tabs: [record(page)]),
            epoch: epoch, connection: connection, protocolVersion: 4)
        XCTAssertEqual(controller.select(page), .issued)
        controller.publishBrowserLayouts()
        XCTAssertEqual(replies.count, 1)
        controller.received(.init(revision: 2, full: false, tabs: [record(page, minimized: true)]),
            epoch: epoch, connection: connection, protocolVersion: 4)
        let focusCount = requests.filter { $0.action == .focus }.count
        replies[0](.issued)
        XCTAssertEqual(requests.filter { $0.action == .focus }.count, focusCount)
        XCTAssertFalse(controller.plannedSurfaces(in: workspace).contains { $0.surfaceID == page })
    }

    private func record(_ id: SurfaceID, minimized: Bool = false, fullscreen: Bool = false, zoomed: Bool = false) -> BrowserTabRecord {
        .init(surfaceID: id, hostID: id.description, title: "Page", selected: true,
            hostManaged: true, hostMinimized: minimized, hostFullscreen: fullscreen, hostZoomed: zoomed)
    }
}

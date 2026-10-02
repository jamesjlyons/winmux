@testable import AppBundle
import AppKit
import Common
import WorkspaceCore
import XCTest

@MainActor final class BrowserPlacementRestoreTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }
    private func record(_ id: SurfaceID) -> BrowserTabRecord { .init(surfaceID: id, hostID: "test", title: "Synthetic", selected: true) }

    func testInterruptedSharedFrameCannotPoisonTheLayoutCache() async throws {
        let window = TestWindow.new(id: 51, parent: focus.workspace.rootTilingContainer)
        let rect = Rect(topLeftX: 240, topLeftY: 30, width: 1680, height: 480)
        do {
            try await window.applySharedLayoutFrame(rect) { throw CancellationError() }
            XCTFail("Expected frame application cancellation")
        } catch is CancellationError { }
        XCTAssertNil(window.lastAppliedLayoutPhysicalRect)
        XCTAssertNil(window.lastAppliedLayoutVirtualRect)
        try await window.applySharedLayoutFrame(rect) { }
        XCTAssertEqual(window.lastAppliedLayoutPhysicalRect, rect)
        $refreshSessionEvent.withValue(.startup) {
            XCTAssertFalse(canReuseLastAppliedWindowFrame(previousPhysicalRect: rect, nextPhysicalRect: rect))
        }
        $refreshSessionEvent.withValue(.ax(kAXMovedNotification as String)) {
            XCTAssertFalse(canReuseLastAppliedWindowFrame(previousPhysicalRect: rect, nextPhysicalRect: rect))
        }
        $refreshSessionEvent.withValue(.ax(kAXFocusedWindowChangedNotification as String)) {
            XCTAssertTrue(canReuseLastAppliedWindowFrame(previousPhysicalRect: rect, nextPhysicalRect: rect))
        }
    }

    func testRestoredPlacementWaitsForOwnerAndConfirmedRemovalPersists() async throws {
        let controller = BrowserWorkspaceController(), tab = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let native = TestWindow.new(id: 51, parent: focus.workspace.rootTilingContainer)
        var tree = SurfaceTree(); tree.reconcile([native.surfaceID, tab], in: focus.workspace.name)
        tree.group(tab, with: native.surfaceID, layout: .horizontal)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [focus.workspace.name], selected: tab, closedBrowserTabs: []))
        XCTAssertEqual(controller.select(tab), .unavailable)
        XCTAssertEqual(controller.surfaceTree, tree)
        let connection = UUID(), epoch = UUID()
        var requests: [BrowserActionRequest] = []
        controller.connected(connection, processID: -1) { request, reply in requests.append(request); reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [record(tab)]), epoch: epoch, connection: connection, protocolVersion: 3)
        XCTAssertEqual(controller.surfaceTree.workspace(of: tab), focus.workspace.name)
        controller.close(tab)
        XCTAssertFalse(try XCTUnwrap(controller.capturePlacementSnapshot()).closedBrowserTabs.contains(tab))
        controller.received(.init(revision: 2, full: false, tabs: [], removed: [tab]), epoch: epoch, connection: connection, protocolVersion: 3)
        let saved = try XCTUnwrap(controller.capturePlacementSnapshot())
        XCTAssertTrue(saved.closedBrowserTabs.contains(tab))
        XCTAssertNil(saved.tree.workspace(of: tab))
        let restarted = BrowserWorkspaceController(); restarted.restorePlacementSnapshot(saved)
        XCTAssertNil(restarted.surfaceTree.workspace(of: tab))
        XCTAssertEqual(requests.map(\.action), [.close])
    }

    func testV4KeepsBrowserPlacementAcrossBootWithoutTrustingNativeWindowNumber() throws {
        let native = TestWindow.new(id: 51, parent: focus.workspace.rootTilingContainer)
        let tab = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var tree = SurfaceTree(); tree.reconcile([native.surfaceID, tab], in: focus.workspace.name)
        let base = RestartSessionSnapshot.capture()
        let snapshot = RestartSessionSnapshot(version: 4, savedAt: .now, bootSession: "previous-boot", world: base.world,
            windows: base.windows, projects: base.projects, focusedWindowId: 51, focusedWorkspace: focus.workspace.name,
            surfaces: .init(tree: tree, layoutWorkspaces: [], selected: tab, closedBrowserTabs: []))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = RestartSessionFile(url: dir.appendingPathComponent("session.json")); try file.write(snapshot)
        let decoded = try XCTUnwrap(file.read())
        XCTAssertEqual(decoded.surfaces, snapshot.surfaces)
        XCTAssertFalse(decoded.matches(windowId: 51, identity: RestartWindowIdentity(native.app), boot: currentBootSession()))
    }

    func testSelectingRestoredTabActivatesItsWorkspace() {
        let controller = BrowserWorkspaceController(), tab = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let initial = focus.workspace.name
        var tree = SurfaceTree(); tree.reconcile([tab], in: "Saved browser workspace")
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        let connection = UUID()
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [record(tab)]), epoch: UUID(), connection: connection)
        XCTAssertEqual(focus.workspace.name, initial)
        XCTAssertEqual(controller.select(tab), .issued)
        XCTAssertEqual(focus.workspace.name, "Saved browser workspace")
    }

    func testInventoryBeforeRestoreIsRecoveredAndLaterNewTabsUseCurrentWorkspace() {
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID()
        let early = SurfaceID.browserTab(profile: UUID(), tab: UUID()), later = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [record(early)]), epoch: epoch, connection: connection)
        controller.restorePlacementSnapshot(.init(tree: SurfaceTree(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        XCTAssertEqual(controller.rows(in: "Recovered").map(\.id), [early.description])
        controller.received(.init(revision: 2, full: false, tabs: [record(later)]), epoch: epoch, connection: connection)
        XCTAssertEqual(controller.rows(in: focus.workspace.name).map(\.id), [later.description])
    }

    func testMixedCommandsAndGestureRejectChangedGroup() async throws {
        let controller = BrowserWorkspaceController(), tab = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let native = TestWindow.new(id: 51, parent: focus.workspace.rootTilingContainer)
        var tree = SurfaceTree(); tree.reconcile([native.surfaceID, tab], in: focus.workspace.name); tree.group(tab, with: native.surfaceID)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        let connection = UUID()
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [record(tab)]), epoch: UUID(), connection: connection)
        XCTAssertEqual(controller.select(native.surfaceID), .issued)
        let gesture = try XCTUnwrap(MixedTrackpadTarget.capture(controller))
        XCTAssertTrue(gesture.commit(next: true, controller: controller))
        XCTAssertEqual(controller.focusCoordinator.target, tab)
        XCTAssertFalse(gesture.commit(next: true, controller: controller))
        var args = FocusCmdArgs(rawArgs: [], targetArg: .tabRelative(.tabPrev))
        XCTAssertEqual(controller.navigate(args, workspace: focus.workspace), true)
        XCTAssertEqual(controller.focusCoordinator.target, native.surfaceID)
        let stale = try XCTUnwrap(MixedTrackpadTarget.capture(controller))
        controller.organize(tab, earlier: true)
        XCTAssertFalse(stale.commit(next: true, controller: controller))
        args = FocusCmdArgs(rawArgs: [], dfsIndex: 0)
        XCTAssertEqual(controller.navigate(args, workspace: focus.workspace), true)
        XCTAssertEqual(controller.focusCoordinator.target, tab)
    }

    func testTemporaryRootStackUsesMixedTabNavigationWithoutChangingSavedTree() {
        let controller = BrowserWorkspaceController(), tab = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let native = TestWindow.new(id: 51, parent: focus.workspace.rootTilingContainer)
        var tree = SurfaceTree(); tree.reconcile([native.surfaceID, tab], in: focus.workspace.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [focus.workspace.name], selected: nil, closedBrowserTabs: []))
        let width = Int(focus.workspace.workspaceMonitor.visibleRectPaddedByOuterGaps.width)
        let connection = UUID()
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [.init(surfaceID: tab, hostID: "test", title: "", selected: true,
            hostMinimumSize: .init(width: width, height: 100))]), epoch: UUID(), connection: connection)
        XCTAssertEqual(controller.select(native.surfaceID), .issued)
        XCTAssertEqual(controller.plannedSurfaces(in: focus.workspace).filter(\.visible).map(\.surfaceID), [native.surfaceID])
        XCTAssertEqual(controller.navigate(FocusCmdArgs(rawArgs: [], targetArg: .tabRelative(.tabNext)), workspace: focus.workspace), true)
        XCTAssertEqual(controller.plannedSurfaces(in: focus.workspace).filter(\.visible).map(\.surfaceID), [tab])
        XCTAssertEqual(controller.surfaceTree, tree)
    }
}

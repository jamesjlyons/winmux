@testable import AppBundle
import Common
import Foundation
import WorkspaceCore
import XCTest

@MainActor
final class BrowserRestartCleanupTest: XCTestCase {
    private let browser = BrowserWorkspaceController.shared
    private var connections: [UUID] = []
    private var previousLease: NativeManagementLease?
    private var leasePath = ""

    override func setUp() async throws {
        setUpWorkspacesForTests()
        previousLease = BrowserNativeManagement.lease
        leasePath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        BrowserNativeManagement.lease = try NativeManagementLease(path: leasePath)
    }

    override func tearDown() async throws {
        for connection in connections { browser.disconnected(connection) }
        connections = []
        browser.nativeSelectionChanged(nil)
        browser.restorePlacementSnapshot(.init(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        browser.usesSurfaceTree = false
        BrowserNativeManagement.lease = previousLease
        try? FileManager.default.removeItem(atPath: leasePath)
        appForTests = nil
    }

    func testCompletedDiscoveryRemovesMissingAndPreviouslyOrphanedNativeEntries() async throws {
        let live = TestWindow.new(id: 41, parent: focus.workspace.rootTilingContainer)
        let missingWorkspace = Workspace.get(byName: "26")
        let missing = TestWindow.new(id: 42, parent: missingWorkspace.rootTilingContainer)
        let orphan = SurfaceID.nativeWindow(UUID())
        var snapshot = RestartSessionSnapshot.capture()
        var tree = SurfaceTree()
        tree.reconcile([live.surfaceID], in: focus.workspace.name)
        tree.reconcile([missing.surfaceID, orphan], in: missingWorkspace.name)
        tree.group(orphan, with: missing.surfaceID)
        snapshot.surfaces = .init(tree: tree, layoutWorkspaces: [missingWorkspace.name], selected: orphan, closedBrowserTabs: [])
        missing.unbindFromParent()
        let restart = RestartSessionController(isAppStillRunning: { _ in false })
        restart.prepare(snapshot)

        XCTAssertTrue(browser.organizedRows(native: [], in: missingWorkspace.name).isEmpty,
                      "Pending discovery must not produce selectable placeholder rows")
        try await restart.restoreAfterDiscovery()
        Workspace.reconcileWorkspaceState()

        XCTAssertNil(restart.pending)
        XCTAssertNil(browser.surfaceTree.workspace(of: missing.surfaceID))
        XCTAssertNil(browser.surfaceTree.workspace(of: orphan))
        XCTAssertEqual(browser.surfaceTree.workspace(of: live.surfaceID), focus.workspace.name)
        XCTAssertFalse(browser.containsBrowserItems(in: missingWorkspace.name))
        XCTAssertNil(Workspace.existing(byName: missingWorkspace.name))
        let saved = try XCTUnwrap(browser.capturePlacementSnapshot())
        XCTAssertEqual(saved.selected, live.surfaceID, "The surviving native focus replaces the missing selection")
        XCTAssertTrue(saved.tree.layouts.isEmpty)
        XCTAssertNoThrow(try saved.validated())
        browser.restorePlacementSnapshot(saved)
        XCTAssertTrue(browser.organizedRows(native: [], in: missingWorkspace.name).isEmpty)
        XCTAssertFalse(browser.containsBrowserItems(in: missingWorkspace.name))
    }

    func testDelayedNativeDiscoveryKeepsItsSavedPositionUntilTheOwnerReturns() async throws {
        let late = TestWindow.new(id: 41, parent: focus.workspace.rootTilingContainer)
        let savedID = late.surfaceID
        var snapshot = RestartSessionSnapshot.capture()
        var tree = SurfaceTree(); tree.reconcile([savedID], in: focus.workspace.name)
        snapshot.surfaces = .init(tree: tree, layoutWorkspaces: [], selected: savedID, closedBrowserTabs: [])
        late.unbindFromParent()
        let restart = RestartSessionController(isAppStillRunning: { _ in true })
        restart.prepare(snapshot)
        try await restart.restoreAfterDiscovery()
        XCTAssertNotNil(restart.pending)
        XCTAssertEqual(browser.surfaceTree, tree)

        let discovered = TestWindow.new(id: 41, parent: focus.workspace.rootTilingContainer)
        try await restart.restoreAfterDiscovery()

        XCTAssertNil(restart.pending)
        XCTAssertEqual(discovered.surfaceID, savedID)
        XCTAssertEqual(browser.surfaceTree, tree)
        XCTAssertEqual(try XCTUnwrap(browser.capturePlacementSnapshot()).selected, savedID)
    }

    func testDiscoveryDeadlineRetiresMissingWindowEvenWhileItsAppIsRunning() async throws {
        let missing = TestWindow.new(id: 41, parent: focus.workspace.rootTilingContainer)
        var snapshot = RestartSessionSnapshot.capture()
        var tree = SurfaceTree(); tree.reconcile([missing.surfaceID], in: focus.workspace.name)
        snapshot.surfaces = .init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: [])
        missing.unbindFromParent()
        var now = Date.now
        let restart = RestartSessionController(isAppStillRunning: { _ in true }, now: { now })
        restart.prepare(snapshot)
        try await restart.restoreAfterDiscovery()
        XCTAssertNotNil(restart.pending)
        XCTAssertNotNil(browser.surfaceTree.workspace(of: missing.surfaceID))

        now = now.addingTimeInterval(11)
        try await restart.restoreAfterDiscovery()

        XCTAssertNil(restart.pending)
        XCTAssertNil(browser.surfaceTree.workspace(of: missing.surfaceID))
        XCTAssertEqual(restart.unmatchedCount, 1)
    }

    func testPreviousBootCannotLeaveAPlaceholderOrClaimAReusedWindowNumber() async throws {
        let old = TestWindow.new(id: 41, parent: focus.workspace.rootTilingContainer)
        let base = RestartSessionSnapshot.capture()
        var tree = SurfaceTree(); tree.reconcile([old.surfaceID], in: focus.workspace.name)
        let snapshot = RestartSessionSnapshot(version: 5, savedAt: .now, bootSession: "previous-boot", world: base.world,
            windows: base.windows, projects: base.projects, focusedWindowId: nil, focusedWorkspace: focus.workspace.name,
            surfaces: .init(tree: tree, layoutWorkspaces: [], selected: old.surfaceID, closedBrowserTabs: []))
        old.unbindFromParent()
        let replacement = TestWindow.new(id: 41, parent: focus.workspace.rootTilingContainer)
        let restart = RestartSessionController(isAppStillRunning: { _ in false })
        restart.prepare(snapshot)
        try await restart.restoreAfterDiscovery()

        XCTAssertNotEqual(replacement.surfaceID, old.surfaceID)
        XCTAssertTrue(replacement.isBound)
        XCTAssertNil(browser.surfaceTree.workspace(of: old.surfaceID))
        XCTAssertNil(try XCTUnwrap(browser.capturePlacementSnapshot()).selected)
    }

    func testFullBrowserInventoryRemovesAbsentSavedTabAndItsEmptyNumberedGroup() throws {
        let profile = UUID(), live = SurfaceID.browserTab(profile: profile, tab: UUID())
        let missing = SurfaceID.browserTab(profile: profile, tab: UUID())
        var tree = SurfaceTree()
        tree.reconcile([live], in: focus.workspace.name)
        tree.reconcile([missing], in: "26")
        browser.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: missing, closedBrowserTabs: []))
        connect([live])
        Workspace.reconcileWorkspaceState()

        XCTAssertEqual(browser.surfaceTree.workspace(of: live), focus.workspace.name)
        XCTAssertNil(browser.workspaceName(for: missing))
        XCTAssertNil(Workspace.existing(byName: "26"))
        let saved = try XCTUnwrap(browser.capturePlacementSnapshot())
        XCTAssertNil(saved.selected)
        XCTAssertTrue(saved.closedBrowserTabs.contains(missing))
        XCTAssertNoThrow(try saved.validated())
    }

    func testInventoryArrivingBeforeTheSessionFileAlsoRetiresStaleReferences() {
        let profile = UUID(), live = SurfaceID.browserTab(profile: profile, tab: UUID())
        let missing = SurfaceID.browserTab(profile: profile, tab: UUID())
        connect([live])
        var tree = SurfaceTree(); tree.reconcile([live, missing], in: "Saved")
        browser.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))

        XCTAssertEqual(browser.workspaceName(for: live), "Saved")
        XCTAssertNil(browser.workspaceName(for: missing))
    }

    func testAnUnconnectedProfileKeepsPlacementWithoutShowingAnEmptyGroup() {
        let live = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let later = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var tree = SurfaceTree()
        tree.reconcile([live], in: focus.workspace.name)
        tree.reconcile([later], in: "26")
        browser.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        connect([live])
        Workspace.reconcileWorkspaceState()

        let waiting = Workspace.get(byName: "26")
        XCTAssertEqual(browser.workspaceName(for: later), waiting.name)
        XCTAssertTrue(browser.containsBrowserItems(in: waiting.name))
        XCTAssertFalse(isUserFacingWorkspace(waiting))
        connect([later])
        XCTAssertTrue(isUserFacingWorkspace(waiting))
        XCTAssertEqual(browser.rows(in: waiting.name).flatMap(\.surfaceIDs), [later])
    }

    func testDeltaAndRejectedFullInventoryCannotRetireUnclaimedPlacement() {
        let profile = UUID(), live = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let added = SurfaceID.browserTab(profile: profile, tab: UUID())
        let waiting = SurfaceID.browserTab(profile: profile, tab: UUID())
        var tree = SurfaceTree(); tree.reconcile([waiting], in: "Saved")
        browser.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        let (connection, epoch) = connect([live])
        browser.received(.init(revision: 2, full: false, tabs: [record(added)]), epoch: epoch, connection: connection)
        XCTAssertEqual(browser.workspaceName(for: waiting), "Saved")
        browser.received(.init(revision: 1, full: true, tabs: [record(added)]), epoch: epoch, connection: connection)
        XCTAssertEqual(browser.workspaceName(for: waiting), "Saved")
        browser.received(.init(revision: 3, full: true, tabs: [record(live), record(added)]), epoch: epoch, connection: connection)
        XCTAssertNil(browser.workspaceName(for: waiting))
    }

    func testFullInventoryDoesNotDiscardANewTabWhoseCreationReplyArrivedFirst() {
        let profile = UUID(), live = SurfaceID.browserTab(profile: profile, tab: UUID())
        let created = SurfaceID.browserTab(profile: profile, tab: UUID())
        browser.restorePlacementSnapshot(.init(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        let (connection, epoch) = connect([live])
        let destination = Workspace.get(byName: "New page")
        browser.placeCreatedBrowserTab(created, in: destination.name, focusAddress: false,
            selectCreated: false, focusGeneration: browser.focusCoordinator.generation)
        browser.received(.init(revision: 2, full: true, tabs: [record(live)]), epoch: epoch, connection: connection)
        XCTAssertEqual(browser.workspaceName(for: created), destination.name)
        browser.received(.init(revision: 3, full: false, tabs: [record(created)]), epoch: epoch, connection: connection)
        XCTAssertEqual(browser.workspaceName(for: created), destination.name)
        XCTAssertEqual(browser.rows(in: destination.name).flatMap(\.surfaceIDs), [created])
    }

    func testReconnectRetiresTabsClosedWhileTheHelperWasDisconnected() {
        let profile = UUID(), live = SurfaceID.browserTab(profile: profile, tab: UUID())
        let closed = SurfaceID.browserTab(profile: profile, tab: UUID())
        var tree = SurfaceTree(); tree.reconcile([live, closed], in: focus.workspace.name)
        browser.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        let (connection, _) = connect([live, closed])
        browser.disconnected(connection)
        XCTAssertNotNil(browser.workspaceName(for: closed))
        connect([live])
        XCTAssertNil(browser.workspaceName(for: closed))
        XCTAssertEqual(browser.workspaceName(for: live), focus.workspace.name)
    }

    @discardableResult
    private func connect(_ tabs: [SurfaceID]) -> (UUID, UUID) {
        let connection = UUID(), epoch = UUID()
        connections.append(connection)
        browser.connected(connection, processID: -1) { _, reply in reply(.issued) }
        browser.received(.init(revision: 1, full: true, tabs: tabs.map(record)), epoch: epoch, connection: connection)
        return (connection, epoch)
    }

    private func record(_ id: SurfaceID) -> BrowserTabRecord {
        .init(surfaceID: id, hostID: id.description, title: "Page", selected: true)
    }
}

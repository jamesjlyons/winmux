@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor
final class ThreeSpaceRestartTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }
    override func tearDown() async throws { setUpWorkspacesForTests() }

    func testTabsKeepThreeSpacesAndNestedLayoutsThroughPartialInventoriesAndTwoRestarts() throws {
        let profile = UUID()
        let spaces = (0..<3).map { _ in createWorkspaceProject() }
        let workspaces = spaces.enumerated().map { index, space in
            let workspace = Workspace.get(byName: "Saved \(index)")
            workspace.assignProject(space.id)
            return workspace
        }
        let tabs = (0..<6).map { _ in SurfaceID.browserTab(profile: profile, tab: UUID()) }
        var tree = SurfaceTree()
        for index in workspaces.indices {
            let pair = Array(tabs[(index * 2)..<(index * 2 + 2)])
            tree.reconcile(pair, in: workspaces[index].name)
            XCTAssertTrue(tree.insertIntoStack(pair[1], with: pair[0]))
            tree.select(pair[1])
        }
        let controller = BrowserWorkspaceController()
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: Set(workspaces.map(\.name)), selected: nil, closedBrowserTabs: []))
        let connection = UUID(), epoch = UUID()
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [record(tabs[0])]), epoch: epoch, connection: connection)
        // Checkpoint while Chromium has restored only its first tab, then restart
        // the helper again before the rest of the browser session arrives.
        let checkpoint = try XCTUnwrap(controller.capturePlacementSnapshot()).validated()
        let restarted = BrowserWorkspaceController()
        restarted.restorePlacementSnapshot(try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: JSONEncoder().encode(checkpoint)))
        restarted.connected(connection, processID: -1) { _, reply in reply(.issued) }
        restarted.received(.init(revision: 1, full: true, tabs: [record(tabs[5])]), epoch: epoch, connection: connection)
        for (index, tab) in tabs.dropLast().reversed().enumerated() {
            _ = workspaces[index % 3].focusWorkspace()
            restarted.received(.init(revision: UInt64(index + 2), full: false, tabs: [record(tab)]), epoch: epoch, connection: connection)
        }
        restarted.reconcileSharedOrganization()
        for index in tabs.indices {
            XCTAssertEqual(restarted.workspaceName(for: tabs[index]), workspaces[index / 2].name)
            XCTAssertEqual(Workspace.existing(byName: workspaces[index / 2].name)?.projectId, spaces[index / 2].id)
        }
        XCTAssertEqual(restarted.surfaceTree, tree)
        XCTAssertNoThrow(try restarted.capturePlacementSnapshot()?.validated())
    }

    func testExplicitRemovalRetiresAReturnedRestoredTab() throws {
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID()
        let tab = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var tree = SurfaceTree(); tree.reconcile([tab], in: "Saved")
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: tab, closedBrowserTabs: []))
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: []), epoch: epoch, connection: connection)
        controller.received(.init(revision: 2, full: false, tabs: [record(tab)]), epoch: epoch, connection: connection)
        controller.received(.init(revision: 3, full: false, tabs: [], removed: [tab]), epoch: epoch, connection: connection)
        XCTAssertNil(controller.workspaceName(for: tab))
        XCTAssertNil(controller.surfaceTree.workspace(of: tab))
        XCTAssertTrue(controller.closedBrowserTabs.contains(tab))
        XCTAssertNoThrow(try controller.capturePlacementSnapshot()?.validated())
    }

    func testLateFocusedTabDoesNotActivateItsSavedSpaceOverTheUsersCurrentSpace() {
        config.newItemPlacement = .newView
        let controller = BrowserWorkspaceController(foregroundProcessID: { -1 })
        let connection = UUID(), epoch = UUID(), profile = UUID()
        let late = SurfaceID.browserTab(profile: profile, tab: UUID())
        let current = SurfaceID.browserTab(profile: profile, tab: UUID())
        let saved = Workspace.get(byName: "Background saved space")
        saved.assignProject(createWorkspaceProject().id)
        let active = focus.workspace
        var tree = SurfaceTree(); tree.reconcile([late], in: saved.name); tree.reconcile([current], in: active.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [record(current)]), epoch: epoch, connection: connection, protocolVersion: 5)
        XCTAssertEqual(controller.select(current), .issued)
        controller.cancelPendingBrowserFocusHold()
        controller.received(.init(revision: 2, full: false, tabs: [
            .init(surfaceID: late, hostID: "late", title: "Restored", selected: true, focused: true),
        ]), epoch: epoch, connection: connection, protocolVersion: 5)
        XCTAssertEqual(controller.workspaceName(for: late), saved.name)
        XCTAssertEqual(controller.focusCoordinator.target, current)
        XCTAssertEqual(focus.workspace, active)
    }

    func testRelaunchedNativeWindowsReturnToThreeSpacesWithReusedIDsAndDelayedDiscovery() async throws {
        let workspaces = (0..<3).map { index in
            let space = createWorkspaceProject()
            let workspace = Workspace.get(byName: "Native \(index)")
            workspace.assignProject(space.id)
            return workspace
        }
        let originals = workspaces.enumerated().map { index, workspace in
            let window = TestWindow.new(id: UInt32(index + 1), parent: workspace.rootTilingContainer)
            window.titleForTesting = "Document \(index)"
            return window
        }
        for window in originals { _ = await getCachedWindowTitle(window) }
        let captured = RestartSessionSnapshot.capture()
        let snapshot = RestartSessionSnapshot(version: 3, savedAt: captured.savedAt, bootSession: "previous-boot",
            world: captured.world, windows: captured.windows, projects: captured.projects,
            focusedWindowId: nil, focusedWorkspace: workspaces[0].name)
        for window in originals { window.unbindFromParent() }
        var now = Date.now
        let restart = RestartSessionController(isAppStillRunning: { _ in false }, now: { now })
        restart.prepare(snapshot)
        // The operating system reuses the old numbers for different documents.
        let second = TestWindow.new(id: 1, parent: workspaces[0].rootTilingContainer)
        second.titleForTesting = "Document 1"
        try await restart.restoreAfterDiscovery()
        XCTAssertEqual(second.nodeWorkspace, workspaces[1])
        XCTAssertEqual(second.surfaceID, originals[1].surfaceID)
        XCTAssertNotNil(restart.pending)
        now = now.addingTimeInterval(30)
        let first = TestWindow.new(id: 3, parent: workspaces[1].rootTilingContainer)
        first.titleForTesting = "Document 0"
        let third = TestWindow.new(id: 2, parent: workspaces[1].rootTilingContainer)
        third.titleForTesting = "Document 2"
        try await restart.restoreAfterDiscovery()
        XCTAssertEqual(first.nodeWorkspace, workspaces[0])
        XCTAssertEqual(third.nodeWorkspace, workspaces[2])
        XCTAssertEqual(second.nodeWorkspace, workspaces[1])
        XCTAssertEqual(first.surfaceID, originals[0].surfaceID)
        XCTAssertEqual(third.surfaceID, originals[2].surfaceID)
        XCTAssertEqual(restart.matchedCount, 3)
        XCTAssertNil(restart.pending)
    }

    func testDuplicateNativeTitlesAcrossSpacesCannotClaimEachOtherAfterReboot() async throws {
        let other = Workspace.get(byName: "Other")
        let first = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let second = TestWindow.new(id: 2, parent: other.rootTilingContainer)
        for window in [first, second] { window.titleForTesting = "Untitled"; _ = await getCachedWindowTitle(window) }
        let captured = RestartSessionSnapshot.capture()
        let snapshot = RestartSessionSnapshot(version: 3, savedAt: captured.savedAt, bootSession: "previous-boot",
            world: captured.world, windows: captured.windows, projects: captured.projects,
            focusedWindowId: nil, focusedWorkspace: nil)
        first.unbindFromParent(); second.unbindFromParent()
        let replacement = TestWindow.new(id: 1, parent: other.rootTilingContainer)
        replacement.titleForTesting = "Untitled"
        let originalID = replacement.surfaceID
        let restart = RestartSessionController(isAppStillRunning: { _ in false })
        restart.prepare(snapshot)
        try await restart.restoreAfterDiscovery()
        XCTAssertEqual(restart.matchedCount, 0)
        XCTAssertEqual(replacement.surfaceID, originalID)
        XCTAssertEqual(replacement.nodeWorkspace, other)
    }

    func testDraggingARelaunchedWindowCancelsItsSavedDestinationBeforeRebinding() async throws {
        let saved = focus.workspace
        let original = TestWindow.new(id: 1, parent: saved.rootTilingContainer)
        original.titleForTesting = "Document"
        _ = await getCachedWindowTitle(original)
        let captured = RestartSessionSnapshot.capture()
        let snapshot = RestartSessionSnapshot(version: 3, savedAt: captured.savedAt, bootSession: "previous-boot",
            world: captured.world, windows: captured.windows, projects: captured.projects,
            focusedWindowId: nil, focusedWorkspace: nil)
        original.unbindFromParent()
        let chosen = Workspace.get(byName: "User's destination")
        let returning = TestWindow.new(id: 2, parent: chosen.rootTilingContainer)
        returning.titleForTesting = "Document"
        _ = await getCachedWindowTitle(returning)
        let restart = RestartSessionController(isAppStillRunning: { _ in false })
        restart.prepare(snapshot)
        XCTAssertTrue(restart.claims(returning))
        restart.cancelRestoreForInteraction(windowId: returning.windowId)
        try await restart.restoreAfterDiscovery()
        XCTAssertEqual(returning.nodeWorkspace, chosen)
        XCTAssertNotEqual(returning.surfaceID, original.surfaceID)
    }

    func testNativeRelaunchDescriptorsSurviveSessionFileAcrossBoots() async throws {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        window.titleForTesting = "Saved document"
        _ = await getCachedWindowTitle(window)
        let captured = RestartSessionSnapshot.capture()
        let snapshot = RestartSessionSnapshot(version: 3, savedAt: captured.savedAt, bootSession: "previous-boot",
            world: captured.world, windows: captured.windows, projects: captured.projects,
            focusedWindowId: nil, focusedWorkspace: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = RestartSessionFile(url: directory.appendingPathComponent("session.json"))
        try file.write(snapshot)
        XCTAssertEqual(try file.read()?.windows, captured.windows)
        XCTAssertEqual(try file.read()?.bootSession, "previous-boot")
    }

    private func record(_ id: SurfaceID) -> BrowserTabRecord {
        .init(surfaceID: id, hostID: id.description, title: "Page", selected: false)
    }
}

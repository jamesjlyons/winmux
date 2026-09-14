@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class RestartSessionTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testIdentityRejectsReusedWindowAndProcessIds() {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let snapshot = RestartSessionSnapshot.capture()
        let identity = RestartWindowIdentity(window.app)
        XCTAssertTrue(snapshot.matches(windowId: 1, identity: identity, boot: currentBootSession()))
        XCTAssertFalse(snapshot.matches(windowId: 1, identity: identity, boot: "another-boot"))
        XCTAssertFalse(snapshot.matches(windowId: 2, identity: identity, boot: currentBootSession()))
        XCTAssertFalse(snapshot.matches(windowId: 1, identity: .init(pid: identity.pid, bundleId: identity.bundleId, launchDate: .now), boot: currentBootSession()))
        XCTAssertFalse(snapshot.matches(windowId: 1, identity: .init(pid: identity.pid, bundleId: "another-app", launchDate: nil), boot: currentBootSession()))
    }

    func testRestoresNestedStacksOrderSelectionWeightsAndSkipsMissingLeaves() async throws {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let missingFirst = TestWindow.new(id: 1, parent: root)
        let stack = TilingContainer(parent: root, adaptiveWeight: 3, .v, .tabGroup, index: INDEX_BIND_LAST)
        let left = TestWindow.new(id: 2, parent: stack)
        let missingMiddle = TestWindow.new(id: 3, parent: stack)
        let selected = TestWindow.new(id: 4, parent: stack)
        let right = TestWindow.new(id: 5, parent: root, adaptiveWeight: 2)
        selected.markAsMostRecentChild()
        selected.isFullscreen = true
        let saved = FrozenWorkspace(workspace)
        missingFirst.unbindFromParent()
        missingMiddle.unbindFromParent()
        selected.isFullscreen = false
        for window in [left, selected, right] { window.bindAsFloatingWindow(to: workspace) }

        try await restoreRestartWorkspace(saved, matchedIds: [2, 4, 5], records: [])

        let restored = workspace.rootTilingContainer
        XCTAssertEqual(restored.children.count, 2)
        let restoredStack = try XCTUnwrap(restored.children.first as? TilingContainer)
        XCTAssertEqual(restoredStack.layout, .tabGroup)
        XCTAssertEqual(restoredStack.orientation, .v)
        XCTAssertEqual(restoredStack.children.compactMap { ($0 as? Window)?.windowId }, [2, 4])
        XCTAssertTrue(restoredStack.mostRecentChild === selected)
        XCTAssertTrue(restored.children.last === right)
        XCTAssertTrue(selected.isFullscreen)
        XCTAssertEqual(restoredStack.getWeight(root.orientation), 3)
        XCTAssertEqual(right.getWeight(root.orientation), 2)
    }

    func testEmptySavedContainersDisappearAndNewWindowsRemain() async throws {
        let workspace = focus.workspace
        let emptyAfterClose = TilingContainer(parent: workspace.rootTilingContainer, adaptiveWeight: 1, .h, .tabGroup, index: 0)
        let closed = TestWindow.new(id: 1, parent: emptyAfterClose)
        let survivor = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        let saved = FrozenWorkspace(workspace)
        closed.unbindFromParent()
        let newlyOpened = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)

        try await restoreRestartWorkspace(saved, matchedIds: [2], records: [])

        XCTAssertEqual(workspace.rootTilingContainer.children.compactMap { ($0 as? Window)?.windowId }, [2, 3])
        XCTAssertTrue(survivor.nodeWorkspace === workspace)
        XCTAssertTrue(newlyOpened.nodeWorkspace === workspace)
    }

    func testFloatingFrameRestoresAfterQuitCleanupMovedIt() async throws {
        let workspace = focus.workspace
        let expected = Rect(topLeftX: 100, topLeftY: 100, width: 300, height: 200)
        let floating = TestWindow.new(id: 1, parent: workspace, rect: expected)
        let snapshot = RestartSessionSnapshot.capture()
        floating.setAxFrame(CGPoint(x: 10, y: 10), CGSize(width: 500, height: 400))
        let saved = try XCTUnwrap(snapshot.world.workspaces.first { $0.name == workspace.name })

        try await restoreRestartWorkspace(saved, matchedIds: [1], records: snapshot.windows ?? [])

        let actual = try await floating.getAxRect()
        XCTAssertEqual(actual?.topLeftCorner, expected.topLeftCorner)
        XCTAssertEqual(actual?.width, expected.width)
        XCTAssertEqual(actual?.height, expected.height)
        XCTAssertTrue(floating.isFloating)
    }

    func testFloatingFrameAdaptsToRemovedDisplayAndClampsOnscreen() {
        let saved = CGRect(x: -2000, y: 0, width: 2000, height: 1200)
        let target = CGRect(x: 0, y: 30, width: 1000, height: 700)
        let restored = restoredFloatingFrame(CGRect(x: -1000, y: 600, width: 400, height: 200), savedScreen: saved, targetScreen: target)
        XCTAssertEqual(restored, CGRect(x: 500, y: 380, width: 400, height: 200))
        let oversized = restoredFloatingFrame(CGRect(x: 5000, y: -500, width: 2000, height: 1500), savedScreen: nil, targetScreen: target)
        XCTAssertEqual(oversized, target)
    }

    func testProjectNamesAndWorkspaceOrderSurviveRoundTrip() throws {
        let project = WorkspaceProject(id: WorkspaceProjectId(rawValue: "restart-test"), name: "Tap Five", order: 9)
        winMuxWorkspaceState.registerProject(project)
        let first = Workspace.get(byName: "first")
        let second = Workspace.get(byName: "second")
        first.assignProject(project.id)
        second.assignProject(project.id)
        var ordered = project
        ordered.workspaceOrder = [second.id, first.id]
        winMuxWorkspaceState.registerProject(ordered)
        let data = try JSONEncoder.winMuxDefault.encode(RestartSessionSnapshot.capture())
        setUpWorkspacesForTests()

        restoreRestartMetadata(try JSONDecoder().decode(RestartSessionSnapshot.self, from: data))

        let restored = try XCTUnwrap(winMuxWorkspaceState.projectsById[project.id])
        XCTAssertEqual(restored.name, "Tap Five")
        XCTAssertEqual(restored.order, 9)
        XCTAssertEqual(restored.workspaceOrder.compactMap { winMuxWorkspaceState.workspaceById[$0]?.name }, ["second", "first"])
    }

    func testUserEditsCancelOnlyTheirWorkspaceRestore() async throws {
        let first = focus.workspace
        let second = Workspace.get(byName: "second")
        let a = TestWindow.new(id: 1, parent: first.rootTilingContainer)
        let b = TestWindow.new(id: 2, parent: second.rootTilingContainer)
        first.rootTilingContainer.layout = .tabGroup
        second.rootTilingContainer.layout = .tabGroup
        let controller = RestartSessionController()
        controller.prepare(RestartSessionSnapshot.capture())
        let before = controller.workspaceSignatures()
        a.bindAsFloatingWindow(to: first)
        controller.cancelChangedWorkspaces(since: before)
        b.bindAsFloatingWindow(to: second)

        try await controller.restoreAfterDiscovery()

        XCTAssertTrue(a.isFloating)
        XCTAssertTrue(b.parent === second.rootTilingContainer)
        XCTAssertEqual(second.rootTilingContainer.layout, .tabGroup)
        XCTAssertNil(controller.pending)
        b.bindAsFloatingWindow(to: second)
        try await controller.restoreAfterDiscovery()
        XCTAssertTrue(b.isFloating, "A completed restore must never reapply an old tree")
    }

    func testBackupRecoversCorruptionWithoutOverwritingLastGoodBackup() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        let first = RestartSessionSnapshot.capture(now: Date(timeIntervalSince1970: 100))
        try file.write(first)
        try file.write(RestartSessionSnapshot.capture(now: Date(timeIntervalSince1970: 200)))
        try Data("broken".utf8).write(to: file.url)
        XCTAssertEqual(try file.read()?.savedAt, first.savedAt)
        try file.write(RestartSessionSnapshot.capture(now: Date(timeIntervalSince1970: 300)))
        XCTAssertEqual(try JSONDecoder().decode(RestartSessionSnapshot.self, from: Data(contentsOf: file.backupURL)).savedAt, first.savedAt)
        XCTAssertEqual(try file.read()?.savedAt, Date(timeIntervalSince1970: 300))
    }

    func testDelayedDiscoveryRestoresLaterWindowsWithoutResettingFinishedWorkspaces() async throws {
        let first = focus.workspace
        let second = Workspace.get(byName: "second")
        let a = TestWindow.new(id: 1, parent: first.rootTilingContainer)
        let b = TestWindow.new(id: 2, parent: second.rootTilingContainer)
        second.rootTilingContainer.layout = .tabGroup
        let controller = RestartSessionController(isAppStillRunning: { _ in true })
        controller.prepare(RestartSessionSnapshot.capture())
        config.automaticallyTileNewWindows = false
        XCTAssertTrue(controller.claims(a), "Restoring existing windows must not depend on the new-window tiling preference")
        b.unbindFromParent()
        try await controller.restoreAfterDiscovery()
        XCTAssertNotNil(controller.pending)
        XCTAssertEqual(controller.matchedCount, 1)
        a.bindAsFloatingWindow(to: first)
        b.bindAsFloatingWindow(to: second)

        try await controller.restoreAfterDiscovery()

        XCTAssertNil(controller.pending)
        XCTAssertTrue(a.isFloating)
        XCTAssertTrue(b.parent === second.rootTilingContainer)
        XCTAssertEqual(second.rootTilingContainer.layout, .tabGroup)
        XCTAssertEqual(controller.matchedCount, 2)
    }

    func testRemembersEachProjectsLastWorkspaceAcrossRestart() {
        let project = WorkspaceProject(id: WorkspaceProjectId("another-project"), name: "Another", order: 1)
        winMuxWorkspaceState.registerProject(project)
        let first = focus.workspace
        let second = Workspace.get(byName: "project-workspace")
        second.assignProject(project.id)
        _ = second.focusWorkspace()
        _ = first.focusWorkspace()
        let snapshot = RestartSessionSnapshot.capture()
        let viewportId = MonitorViewportId(mainMonitor)
        winMuxWorkspaceState.monitorViewportsById[viewportId]?.lastActiveWorkspaceByProject = [:]

        restoreRestartFocus(snapshot, matchedIds: [], excluding: [])

        XCTAssertEqual(winMuxWorkspaceState.monitorViewportsById[viewportId]?.lastActiveWorkspaceByProject[project.id], second.id)
        XCTAssertTrue(mainMonitor.activeWorkspace === first)
    }

    func testManualDragStopsPendingRestoreEvenBeforeItsTreeChanges() async throws {
        let workspace = focus.workspace
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let controller = RestartSessionController()
        controller.prepare(RestartSessionSnapshot.capture())
        controller.cancelRestoreForInteraction(windowId: window.windowId)
        window.bindAsFloatingWindow(to: workspace)

        try await controller.restoreAfterDiscovery()

        XCTAssertTrue(window.isFloating)
        XCTAssertFalse(controller.claims(window))
    }

    func testFutureSessionVersionDoesNotFallBackOrGetReplaced() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        try file.write(RestartSessionSnapshot.capture())
        try file.write(RestartSessionSnapshot.capture())
        let future = Data("{\"version\":999}".utf8)
        try future.write(to: file.url)
        XCTAssertThrowsError(try file.read())
        let controller = RestartSessionController(file: file)
        XCTAssertFalse(controller.load())
        XCTAssertTrue(controller.lastRestore.contains("999"))
        XCTAssertEqual(try Data(contentsOf: file.url), future)
    }

    func testLegacySnapshotLoadsOnlyFromThisBoot() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        struct Legacy: Encodable { let version = 1; let world: FrozenWorld }
        TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        try JSONEncoder().encode(Legacy(world: snapshotCurrentFrozenWorld())).write(to: file.url)
        XCTAssertEqual(try file.read()?.version, 1)
        XCTAssertEqual(try file.read()?.world.windowIds, [1])
        let beforeBoot = Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime - 60)
        try FileManager.default.setAttributes([.modificationDate: beforeBoot], ofItemAtPath: file.url.path)
        XCTAssertThrowsError(try file.read())
    }

    func testBuildsAndExplicitConfigsUseIndependentSessionFiles() {
        let base = URL(filePath: "/tmp/session-location-tests")
        let release = RestartSessionFile.location(appSupport: base, appName: "WinMux", explicitConfigPath: nil)
        let dev = RestartSessionFile.location(appSupport: base, appName: "WinMux-Debug", explicitConfigPath: nil)
        let a = RestartSessionFile.location(appSupport: base, appName: "WinMux-Debug", explicitConfigPath: "/tmp/a.toml")
        let b = RestartSessionFile.location(appSupport: base, appName: "WinMux-Debug", explicitConfigPath: "/tmp/b.toml")
        XCTAssertEqual(Set([release, dev, a, b]).count, 4)
        XCTAssertEqual(a, RestartSessionFile.location(appSupport: base, appName: "WinMux-Debug", explicitConfigPath: "/tmp/unused/../a.toml"))
    }

    func testShutdownCompletesPromptlyAndBoundsUnresponsiveCleanup() async {
        var cleaned = false
        await runBoundedShutdown(timeout: .seconds(1)) { cleaned = true }
        XCTAssertTrue(cleaned)
        let start = ContinuousClock.now
        var suspended: CheckedContinuation<Void, Never>?
        await runBoundedShutdown(timeout: .milliseconds(20)) {
            await withCheckedContinuation { suspended = $0 }
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertNotNil(suspended)
        suspended?.resume()
        await Task.yield()
    }

    private func temporaryFile() -> RestartSessionFile {
        RestartSessionFile(url: FileManager.default.temporaryDirectory.appendingPathComponent("winmux-restart-test-\(UUID())/window-state.json"))
    }
}

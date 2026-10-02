@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor final class SurfaceCommandTest: XCTestCase {
    let controller = BrowserWorkspaceController.shared
    var connection = UUID()
    var tab = SurfaceID.browserTab(profile: UUID(), tab: UUID())
    var requests: [BrowserActionRequest] = []

    override func setUp() async throws {
        setUpWorkspacesForTests()
        connection = UUID(); tab = .browserTab(profile: UUID(), tab: UUID()); requests = []
        let native = TestWindow.new(id: 71, parent: focus.workspace.rootTilingContainer)
        _ = native.focusWindow()
        var tree = SurfaceTree(); tree.reconcile([native.surfaceID, tab], in: focus.workspace.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        controller.connected(connection, processID: -1) { [weak self] request, reply in self?.requests.append(request); reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [.init(surfaceID: tab, hostID: "synthetic", title: "Synthetic", selected: true)]),
            epoch: UUID(), connection: connection, protocolVersion: 3)
        XCTAssertEqual(controller.select(tab), .issued)
    }

    override func tearDown() async throws {
        controller.disconnected(connection)
        controller.nativeSelectionChanged(nil)
        controller.restorePlacementSnapshot(.init(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        controller.usesSurfaceTree = false
    }

    private func run(_ operands: [String]) async throws -> CmdResult {
        let command = try XCTUnwrap(parseCommand(operands).cmdOrNil)
        return try await command.run(.defaultEnv, .emptyStdin)
    }

    private func checkCommand(_ operands: [String], exit: Int32 = 0, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await run(operands)
        XCTAssertEqual(result.exitCode, exit, operands.description + result.stderr.joined(), file: file, line: line)
    }

    func testCloseRoutesToBrowserAndExplicitNativeStillWorks() async throws {
        let result = try await run(["close"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(requests.last?.action, .close)
        XCTAssertNotNil(Window.get(byId: 71))
        XCTAssertTrue(controller.isAvailable(tab), "Issued close is not a confirmed tombstone")
        let native = try XCTUnwrap(Window.get(byId: 71))
        let explicit = try await run(["surface", "close", native.surfaceID.description])
        XCTAssertEqual(explicit.exitCode, 0)
        XCTAssertNil(Window.get(byId: 71))
    }

    func testUnsupportedLegacyActionsNeverTargetPriorNativeWindow() async throws {
        for command in [["resize", "width", "+40"], ["move", "left"], ["split", "horizontal"],
                        ["macos-native-minimize"], ["close-all-windows-but-current"], ["close", "--quit-if-last-window"]] {
            let result = try await run(command)
            XCTAssertEqual(result.exitCode, 1, command.description)
            XCTAssertFalse(result.stderr.isEmpty)
            XCTAssertNotNil(Window.get(byId: 71))
            XCTAssertEqual(controller.focusCoordinator.target, tab)
        }
        controller.disconnected(connection)
        let stale = try await run(["close"])
        XCTAssertEqual(stale.exitCode, 1)
        XCTAssertNotNil(Window.get(byId: 71))
        let native = try await run(["close", "--window-id", "71"])
        XCTAssertEqual(native.exitCode, 0)
        XCTAssertNil(Window.get(byId: 71))
    }

    func testMoveWithoutFollowEnablesBothWorkspacesAndRetiresHiddenSelection() async throws {
        let source = focus.workspace.name
        let result = try await run(["move-node-to-workspace", "Destination"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(controller.workspaceName(for: tab), "Destination")
        XCTAssertEqual(controller.surfaceTree.workspace(of: tab), "Destination")
        XCTAssertEqual(focus.workspace.name, source)
        XCTAssertEqual(controller.focusCoordinator.target, Window.get(byId: 71)?.surfaceID)
        XCTAssertEqual(controller.capturePlacementSnapshot()?.layoutWorkspaces, [source, "Destination"])
        let follow = try await run(["surface", "move", tab.description, "Third", "--focus-follows-surface"])
        XCTAssertEqual(follow.exitCode, 0)
        XCTAssertEqual(focus.workspace.name, "Third")
        XCTAssertEqual(controller.focusCoordinator.target, tab)
        XCTAssertEqual(Window.get(byId: 71)?.nodeWorkspace?.name, source)
    }

    func testTypedNativeMoveUpdatesSharedPlacement() async throws {
        let native = try XCTUnwrap(Window.get(byId: 71))
        let result = try await run(["surface", "move", native.surfaceID.description, "Native-destination"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(native.nodeWorkspace?.name, "Native-destination")
        XCTAssertEqual(controller.surfaceTree.workspace(of: native.surfaceID), "Native-destination")
        XCTAssertEqual(controller.focusCoordinator.target, tab)
    }

    func testListingAndUnavailableTypedIdentityNeverFallsBack() async throws {
        let result = try await run(["surface", "list"])
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.joined().utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0["id"] as? String == tab.description }?["selected"] as? Bool, true)
        XCTAssertNil(rows.first?["title"])
        let unavailable = try await run(["surface", "close", SurfaceID.nativeWindow(UUID()).description])
        XCTAssertEqual(unavailable.exitCode, 1)
        XCTAssertNotNil(Window.get(byId: 71))
        let malformed = try await run(["surface", "focus", "71"])
        XCTAssertEqual(malformed.exitCode, 1)
    }

    func testNativeSelectionAfterDisconnectRetiresBrowserTarget() async throws {
        controller.disconnected(connection)
        XCTAssertEqual(controller.focusCoordinator.target, tab)
        _ = Window.get(byId: 71)?.focusWindow()
        XCTAssertEqual(controller.focusCoordinator.target, Window.get(byId: 71)?.surfaceID)
        let result = try await run(["close"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(Window.get(byId: 71))
    }

    func testParserRejectsMissingOrExtraOperands() {
        for args in [["surface"], ["surface", "move", "selected"], ["surface", "list", "extra"],
                     ["surface", "focus", "selected", "--focus-follows-surface"], ["surface", "unknown"],
                     ["surface", "move", "selected", "next"], ["surface", "move", "selected", "bad name"],
                     ["surface", "group", "selected", "next"], ["surface", "group", "selected", "prev", "floating"],
                     ["surface", "layout", "selected", "diagonal"], ["surface", "reorder", "selected", "first"],
                     ["surface", "ungroup", "selected", "extra"]] {
            XCTAssertNil(parseCommand(args).cmdOrNil, args.description)
        }
        XCTAssertNotNil(parseCommand(["surface", "list"]).cmdOrNil)
    }

    func testSharedGroupLayoutReorderAndUngroupPreserveOwnersAndSelection() async throws {
        let native = try XCTUnwrap(Window.get(byId: 71)), workspace = focus.workspace.name
        let originalNativeParent = native.parent
        try await checkCommand(["surface", "group", "selected", "prev", "stack"])
        let group = try XCTUnwrap(controller.surfaceTree.containingGroup(of: tab))
        XCTAssertEqual(controller.surfaceTree.layouts[group], .stack)
        XCTAssertEqual(controller.surfaceTree.activeSurfaces[group], tab)
        try await checkCommand(["surface", "reorder", "selected", "earlier"])
        XCTAssertEqual(controller.surfaceTree.roots[workspace]?.flatMap(\.surfaces), [tab, native.surfaceID])
        try await checkCommand(["surface", "layout", "selected", "vertical"])
        XCTAssertEqual(controller.surfaceTree.layouts[group], .vertical)
        XCTAssertEqual(controller.surfaceTree.containingGroup(of: tab), group)
        XCTAssertEqual(controller.capturePlacementSnapshot()?.layoutWorkspaces, [workspace])
        let saved = try XCTUnwrap(controller.capturePlacementSnapshot())
        XCTAssertEqual(try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: JSONEncoder().encode(saved)).validated(), saved)
        try await checkCommand(["surface", "ungroup", "selected"])
        XCTAssertEqual(controller.surfaceTree.roots[workspace], [.surface(tab), .surface(native.surfaceID)])
        XCTAssertTrue(native.parent === originalNativeParent)
        XCTAssertEqual(controller.focusCoordinator.target, tab)
        XCTAssertEqual(controller.owner(of: tab)?.inventory.tabs.count, 1)
        XCTAssertFalse(requests.contains { $0.action == .close })
    }

    func testExistingLayoutShortcutUsesSharedTreeForBothOwnersAndExplicitNativeOverride() async throws {
        let native = try XCTUnwrap(Window.get(byId: 71))
        try await checkCommand(["layout", "horizontal", "vertical"])
        let group = try XCTUnwrap(controller.surfaceTree.containingGroup(of: tab))
        XCTAssertEqual(controller.surfaceTree.layouts[group], .vertical)
        _ = native.focusWindow()
        try await checkCommand(["layout", "horizontal", "vertical"])
        XCTAssertEqual(controller.surfaceTree.layouts[group], .horizontal)
        XCTAssertEqual(controller.focusCoordinator.target, native.surfaceID)
        let shared = controller.surfaceTree
        try await checkCommand(["layout", "vertical", "--window-id", "71"])
        XCTAssertEqual(controller.surfaceTree, shared)
    }

    func testInvalidGroupTargetsAndBoundariesAreAtomic() async throws {
        let before = controller.capturePlacementSnapshot()
        for args in [["surface", "group", "selected", "next", "stack"],
                     ["surface", "group", "selected", tab.description, "horizontal"],
                     ["surface", "group", "selected", SurfaceID.nativeWindow(UUID()).description, "stack"],
                     ["surface", "ungroup", "selected"], ["surface", "reorder", "selected", "later"],
                     ["layout", "horizontal", "floating"]] {
            try await checkCommand(args, exit: 1)
            XCTAssertEqual(controller.capturePlacementSnapshot(), before)
        }
        let other = TestWindow.new(id: 72, parent: Workspace.get(byName: "Other").rootTilingContainer)
        try await checkCommand(["surface", "group", "selected", other.surfaceID.description, "stack"], exit: 1)
        XCTAssertEqual(controller.capturePlacementSnapshot(), before)
    }

    func testDisconnectedOrOldProtocolOwnerPreventsPartialStructuralEdits() async throws {
        controller.disconnected(connection)
        _ = Window.get(byId: 71)?.focusWindow()
        let before = controller.surfaceTree
        try await checkCommand(["surface", "layout", "selected", "stack"], exit: 1)
        XCTAssertEqual(controller.surfaceTree, before)
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [.init(surfaceID: tab, hostID: "old", title: "", selected: false)]),
            epoch: UUID(), connection: connection, protocolVersion: 2)
        try await checkCommand(["surface", "group", "selected", tab.description, "horizontal"], exit: 1)
        XCTAssertEqual(controller.surfaceTree, before)
    }

    func testCrossWorkspaceRowDropMovesOwnerBeforeReordering() async throws {
        let source = focus.workspace.name
        let destination = Workspace.get(byName: "Drop-destination")
        let other = TestWindow.new(id: 72, parent: destination.rootTilingContainer)
        controller.didMoveNativeSurface(other.surfaceID, to: destination.name)
        // Newly discovered native rows are normally reconciled by the sidebar.
        var saved = try XCTUnwrap(controller.capturePlacementSnapshot())
        var tree = saved.tree; tree.reconcile([other.surfaceID], in: destination.name)
        saved = .init(tree: tree, layoutWorkspaces: saved.layoutWorkspaces, selected: nil, closedBrowserTabs: [])
        controller.restorePlacementSnapshot(saved)
        controller.organize(tab, before: other.surfaceID)
        XCTAssertEqual(controller.workspaceName(for: tab), destination.name)
        XCTAssertEqual(controller.surfaceTree.roots[destination.name]?.flatMap(\.surfaces), [tab, other.surfaceID])
        XCTAssertEqual(Window.get(byId: 71)?.nodeWorkspace?.name, source)
        XCTAssertEqual(focus.workspace.name, source)
        controller.organize(other.surfaceID, before: Window.get(byId: 71)!.surfaceID)
        XCTAssertEqual(other.nodeWorkspace?.name, source)
        XCTAssertEqual(controller.surfaceTree.workspace(of: other.surfaceID), source)
    }

    func testBrowserMonitorAndProjectMovesPreserveNativeSource() async throws {
        let main = TestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Main",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080), isMain: true)
        let second = TestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Second",
            rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080), isMain: false)
        setMonitorsForTests([main, second])
        let source = focus.workspace
        let destination = Workspace.get(byName: "External")
        _ = second.setActiveWorkspace(destination)
        let moved = try await run(["move-node-to-monitor", "next", "--focus-follows-window"])
        XCTAssertEqual(moved.exitCode, 0)
        XCTAssertEqual(controller.workspaceName(for: tab), destination.name)
        XCTAssertEqual(focus.workspace.name, destination.name)
        XCTAssertEqual(Window.get(byId: 71)?.nodeWorkspace, source)
        let project = createWorkspaceProject()
        let index = try XCTUnwrap(workspaceProjects().firstIndex { $0.id == project.id }) + 1
        let projectMove = try await run(["move-node-to-project", String(index), "--focus-follows-window"])
        XCTAssertEqual(projectMove.exitCode, 0)
        XCTAssertEqual(focus.workspace.projectId, project.id)
        XCTAssertEqual(controller.focusCoordinator.target, tab)
        XCTAssertEqual(Window.get(byId: 71)?.nodeWorkspace, source)
    }
}

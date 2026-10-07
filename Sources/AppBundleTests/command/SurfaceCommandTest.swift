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
        for command in [["macos-native-minimize"], ["close-all-windows-but-current"], ["close", "--quit-if-last-window"]] {
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

    func testPinCommandCreatesDedicatedDesktopAndUnpinRetainsItsLayout() async throws {
        let regular = focus.workspace.name
        try await checkCommand(["surface", "pin", tab.description])
        let desktop = try XCTUnwrap(controller.pinnedViews.first)
        XCTAssertNotEqual(desktop.workspaceName, regular)
        XCTAssertEqual(controller.workspaceName(for: tab), desktop.workspaceName)
        XCTAssertEqual(Window.get(byId: 71)?.nodeWorkspace?.name, regular)
        let tree = controller.surfaceTree
        let result = try await run(["surface", "list"])
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.joined().utf8)) as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["id"] as? String == tab.description })
        XCTAssertEqual(row["pinnedDesktopID"] as? String, desktop.id.uuidString)
        XCTAssertEqual((row["browser"] as? [String: Any])?["lifecycle"] as? String, "active")
        try await checkCommand(["surface", "unpin", tab.description])
        XCTAssertTrue(controller.pinnedViews.isEmpty)
        XCTAssertEqual(controller.surfaceTree, tree)
        XCTAssertTrue(controller.isAvailable(tab))
        try await checkCommand(["surface", "unpin", tab.description], exit: 1)
    }

    func testPinCommandKeepsExplicitGroupAndExcludesOtherRoots() async throws {
        let other = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        controller.received(.init(revision: 2, full: false, tabs: [.init(surfaceID: other, hostID: "other", title: "Other", selected: false)]),
                            epoch: try XCTUnwrap(controller.owner(of: tab)?.epoch), connection: connection, protocolVersion: 3)
        _ = controller.organizedRows(native: [], in: focus.workspace.name)
        try await checkCommand(["surface", "group", tab.description, other.description, "horizontal"])
        let group = try XCTUnwrap(controller.surfaceTree.containingGroup(of: tab))
        try await checkCommand(["surface", "pin", tab.description])
        XCTAssertEqual(controller.pinnedViews.first?.memberIDs.count, 2)
        XCTAssertEqual(controller.workspaceName(for: tab), controller.workspaceName(for: other))
        XCTAssertEqual(controller.surfaceTree.containingGroup(of: other), group)
        XCTAssertEqual(controller.surfaceTree.layouts[group], .horizontal)
        XCTAssertNotEqual(controller.workspaceName(for: tab), Window.get(byId: 71)?.nodeWorkspace?.name)
    }

    func testSocketListingPreservesBrowserSelectionWithoutLayoutOrDiscovery() async throws {
        appForTests = nil
        TrayMenuModel.shared.isEnabled = true
        let native = try XCTUnwrap(Window.get(byId: 71) as? TestWindow)
        let writes = native.frameWriteCount
        let requestCount = requests.count
        var refreshes = 0
        setScheduledRefreshOverrideForTests { _, _, _ in refreshes += 1 }
        defer { setScheduledRefreshOverrideForTests(nil) }
        let command = try XCTUnwrap(parseCommand(["surface", "list"]).cmdOrNil)
        let result = try await runSocketCommandSession(command, .forceRun) {
            try await command.run(.defaultEnv, .emptyStdin)
        }
        try await waitForScheduledRefreshForTests()
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.joined().utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.first { $0["id"] as? String == tab.description }?["selected"] as? Bool, true)
        XCTAssertEqual(controller.focusCoordinator.target, tab)
        XCTAssertEqual(native.frameWriteCount, writes)
        XCTAssertEqual(requests.count, requestCount)
        XCTAssertEqual(refreshes, 0)
        XCTAssertFalse(command.shouldResetClosedWindowsCache)
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

    func testResizeBrowserSelectionChangesSharedAllocation() async throws {
        let before = controller.plannedSurfaces(in: focus.workspace).first { $0.surfaceID == tab }?.frame.width
        let result = try await run(["resize", "width", "+40"])
        XCTAssertEqual(result.exitCode, 0, result.stderr.joined())
        let after = controller.plannedSurfaces(in: focus.workspace).first { $0.surfaceID == tab }?.frame.width
        XCTAssertEqual(after, before.map { $0 + 40 })
        XCTAssertNotNil(Window.get(byId: 71), "Resizing a browser page must not alter native membership")
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

    func testLayoutUsesSharedOrganizationForSelectionAndExplicitNativeTarget() async throws {
        let native = try XCTUnwrap(Window.get(byId: 71))
        try await checkCommand(["layout", "horizontal", "vertical"])
        let group = try XCTUnwrap(controller.surfaceTree.containingGroup(of: tab))
        XCTAssertEqual(controller.surfaceTree.layouts[group], .vertical)
        _ = native.focusWindow()
        try await checkCommand(["layout", "horizontal", "vertical"])
        XCTAssertEqual(controller.surfaceTree.layouts[group], .horizontal)
        XCTAssertEqual(controller.focusCoordinator.target, native.surfaceID)
        let nativeParent = native.parent as? TilingContainer
        let nativeOrientation = nativeParent?.orientation
        try await checkCommand(["layout", "vertical", "--window-id", "71"])
        XCTAssertEqual(controller.surfaceTree.layouts[group], .vertical)
        XCTAssertEqual(nativeParent?.orientation, nativeOrientation)
        XCTAssertEqual(controller.focusCoordinator.target, native.surfaceID)
    }

    func testExplicitAndEnvironmentNativeResizeUseSharedWeightsWithoutChangingSelection() async throws {
        let native = try XCTUnwrap(Window.get(byId: 71)), workspace = focus.workspace
        let nativeWeight = native.getWeight(.h)
        let before = try XCTUnwrap(controller.plannedSurfaces(in: workspace).first { $0.surfaceID == native.surfaceID }?.frame.width)
        try await checkCommand(["resize", "width", "+40", "--window-id", "71"])
        XCTAssertEqual(controller.plannedSurfaces(in: workspace).first { $0.surfaceID == native.surfaceID }?.frame.width, before + 40)
        let command = try XCTUnwrap(parseCommand(["resize", "width", "+40"]).cmdOrNil)
        var env = CmdEnv.defaultEnv
        env.windowId = 71
        let result = try await command.run(env, .emptyStdin)
        XCTAssertEqual(result.exitCode, 0, result.stderr.joined())
        XCTAssertEqual(controller.plannedSurfaces(in: workspace).first { $0.surfaceID == native.surfaceID }?.frame.width, before + 80)
        XCTAssertEqual(native.getWeight(.h), nativeWeight)
        XCTAssertEqual(controller.focusCoordinator.target, tab)
    }

    func testBalanceAndFlattenOperateOnMixedArrangementAndKeepNativeBinding() async throws {
        let native = try XCTUnwrap(Window.get(byId: 71)), workspace = focus.workspace
        let parent = native.parent
        try await checkCommand(["surface", "group", "selected", "prev", "horizontal"])
        let group = try XCTUnwrap(controller.surfaceTree.containingGroup(of: tab))
        try await checkCommand(["resize", "width", "+60"])
        try await checkCommand(["balance-sizes"])
        let frames = controller.plannedSurfaces(in: workspace)
        XCTAssertEqual(frames.first { $0.surfaceID == tab }?.frame.width,
                       frames.first { $0.surfaceID == native.surfaceID }?.frame.width)
        XCTAssertEqual(controller.surfaceTree.containingGroup(of: tab), group)
        try await checkCommand(["flatten-workspace-tree"])
        XCTAssertNil(controller.surfaceTree.containingGroup(of: tab))
        XCTAssertEqual(Set(controller.surfaceTree.roots[workspace.name]?.flatMap(\.surfaces) ?? []), [tab, native.surfaceID])
        XCTAssertTrue(native.parent === parent)
        XCTAssertEqual(controller.focusCoordinator.target, tab)
    }

    func testNativeMoveCommandCommitsSharedMembershipWithoutChangingBrowserSelection() async throws {
        let native = try XCTUnwrap(Window.get(byId: 71)), source = focus.workspace.name
        try await checkCommand(["move-node-to-workspace", "NativeTarget", "--window-id", "71"])
        XCTAssertEqual(native.nodeWorkspace?.name, "NativeTarget")
        XCTAssertEqual(controller.surfaceTree.workspace(of: native.surfaceID), "NativeTarget")
        XCTAssertEqual(controller.surfaceTree.workspace(of: tab), source)
        XCTAssertEqual(controller.focusCoordinator.target, tab)
        XCTAssertTrue(controller.hasSharedLayout(in: try XCTUnwrap(native.nodeWorkspace)))
    }

    func testStackSeparateJoinAndSwapUseSharedOwnersWithoutNativeContainers() async throws {
        let native = try XCTUnwrap(Window.get(byId: 71))
        let parent = native.parent
        try await checkCommand(["stack-with", "left"])
        XCTAssertEqual(controller.surfaceTree.stackItems(containing: tab), [native.surfaceID, tab])
        XCTAssertEqual(controller.focusCoordinator.target, tab)
        try await checkCommand(["stack-with", "right"])
        XCTAssertNil(controller.surfaceTree.stackItems(containing: tab))
        try await checkCommand(["join-with", "left"])
        let group = try XCTUnwrap(controller.surfaceTree.containingGroup(of: tab))
        XCTAssertEqual(controller.surfaceTree.layouts[group], .vertical)
        try await checkCommand(["swap", "dfs-prev"])
        XCTAssertEqual(controller.surfaceTree.group(group)?.surfaces, [tab, native.surfaceID])
        XCTAssertTrue(native.parent === parent)
        XCTAssertEqual(controller.focusCoordinator.target, tab)
        try await checkCommand(["swap", "dfs-next", "--swap-focus"])
        XCTAssertEqual(controller.focusCoordinator.target, native.surfaceID)
    }

    func testDirectionalMovementAndSplitAliasChangeOnlySharedArrangement() async throws {
        let previousNormalization = config.enableNormalizationFlattenContainers
        defer { config.enableNormalizationFlattenContainers = previousNormalization }
        let native = try XCTUnwrap(Window.get(byId: 71)), workspace = focus.workspace
        let parent = native.parent
        try await checkCommand(["move", "left"])
        XCTAssertEqual(controller.surfaceTree.roots[workspace.name]?.flatMap(\.surfaces), [tab, native.surfaceID])
        let boundary = controller.surfaceTree
        try await checkCommand(["move", "left", "--boundaries-action", "fail"], exit: 1)
        try await checkCommand(["move", "left", "--boundaries-action", "stop"])
        XCTAssertEqual(controller.surfaceTree, boundary)
        try await checkCommand(["move", "up"])
        let group = try XCTUnwrap(controller.surfaceTree.containingGroup(of: tab))
        XCTAssertEqual(controller.surfaceTree.layouts[group], .vertical)
        config.enableNormalizationFlattenContainers = false
        try await checkCommand(["split", "horizontal"])
        XCTAssertEqual(controller.surfaceTree.layouts[group], .horizontal)
        XCTAssertTrue(native.parent === parent)
        XCTAssertEqual(controller.focusCoordinator.target, tab)
    }

    func testNativeFloatingTogglePreservesMixedBrowserOwnersAndSourceFocus() async throws {
        let native = try XCTUnwrap(Window.get(byId: 71)), source = focus.workspace
        let otherPage = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let browserRecords = [
            BrowserTabRecord(surfaceID: tab, hostID: "synthetic", title: "Synthetic", selected: true,
                             hostWindowID: 901, url: "https://example.com/first", hostManaged: true),
            BrowserTabRecord(surfaceID: otherPage, hostID: "second", title: "Second", selected: true,
                             hostWindowID: 902, url: "https://example.com/second", hostManaged: true),
        ]
        let epoch = try XCTUnwrap(controller.owner(of: tab)?.epoch)
        controller.received(.init(revision: 2, full: true, tabs: browserRecords),
                            epoch: epoch, connection: connection, protocolVersion: 4)
        var tree = SurfaceTree()
        tree.reconcile([native.surfaceID, tab, otherPage], in: source.name)
        tree.importStack([native.surfaceID, tab, otherPage], in: source.name)
        tree.select(tab)
        let group = try XCTUnwrap(tree.containingGroup(of: tab))
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [source.name], selected: nil, closedBrowserTabs: []))
        native.lastFloatingSize = .init(width: 480, height: 320)
        try await checkCommand(["surface", "focus", native.surfaceID.description])
        let browserMinimum = controller.minimumSizes(in: source)[tab]

        try await checkCommand(["layout", "floating", "tiling"])
        XCTAssertTrue(native.isFloating)
        XCTAssertNil(controller.surfaceTree.workspace(of: native.surfaceID))
        XCTAssertFalse(controller.plannedSurfaces(in: source).contains { $0.surfaceID == native.surfaceID })
        XCTAssertEqual(controller.surfaceTree.group(group)?.surfaces, [tab, otherPage])
        XCTAssertEqual(controller.surfaceTree.layouts[group], .stack)
        XCTAssertEqual(controller.focusCoordinator.target, native.surfaceID)
        XCTAssertTrue(focus.windowOrNil === native)
        XCTAssertTrue(focus.workspace === source)
        XCTAssertEqual(native.lastFloatingSize, .init(width: 480, height: 320))

        try await checkCommand(["layout", "floating", "tiling"])
        XCTAssertTrue(native.parent is TilingContainer)
        XCTAssertEqual(controller.surfaceTree.workspace(of: native.surfaceID), source.name)
        XCTAssertTrue(controller.plannedSurfaces(in: source).contains { $0.surfaceID == native.surfaceID && $0.visible })
        XCTAssertEqual(controller.surfaceTree.group(group)?.surfaces, [tab, otherPage])
        XCTAssertEqual(controller.surfaceTree.layouts[group], .stack)
        XCTAssertEqual(controller.focusCoordinator.target, native.surfaceID)
        XCTAssertTrue(focus.windowOrNil === native)
        XCTAssertTrue(focus.workspace === source)
        XCTAssertEqual(controller.minimumSizes(in: source)[tab], browserMinimum, "Page chrome size remains part of browser layout")
        for record in browserRecords {
            XCTAssertEqual(controller.owner(of: record.surfaceID)?.inventory.tabs[record.surfaceID], record)
            XCTAssertEqual(controller.workspaceName(for: record.surfaceID), source.name)
        }
        XCTAssertFalse(requests.contains { $0.action == .close || $0.action == .newTab })

        try await checkCommand(["surface", "focus", tab.description])
        let before = controller.capturePlacementSnapshot()
        try await checkCommand(["layout", "floating"], exit: 1)
        try await checkCommand(["layout", "tiling"], exit: 1)
        XCTAssertEqual(controller.capturePlacementSnapshot(), before)
        XCTAssertTrue(native.parent is TilingContainer)
    }

    func testExplicitNativeFloatingConversionKeepsBrowserSelection() async throws {
        let native = try XCTUnwrap(Window.get(byId: 71)), source = focus.workspace
        try await checkCommand(["layout", "floating", "--window-id", "71"])
        XCTAssertTrue(native.isFloating)
        XCTAssertNil(controller.surfaceTree.workspace(of: native.surfaceID))
        XCTAssertEqual(controller.focusCoordinator.target, tab)
        try await checkCommand(["layout", "tiling", "--window-id", "71"])
        XCTAssertTrue(native.parent is TilingContainer)
        XCTAssertEqual(controller.surfaceTree.workspace(of: native.surfaceID), source.name)
        XCTAssertEqual(controller.focusCoordinator.target, tab)
        XCTAssertEqual(controller.workspaceName(for: tab), source.name)
    }

    func testInvalidGroupTargetsAndBoundariesAreAtomic() async throws {
        // Settle owner discovery before testing the command transaction itself.
        refreshModel()
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
        refreshModel()
        let afterDiscovery = controller.capturePlacementSnapshot()
        try await checkCommand(["surface", "group", "selected", other.surfaceID.description, "stack"], exit: 1)
        XCTAssertEqual(controller.capturePlacementSnapshot(), afterDiscovery)
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
        // Explicitly model discovery before testing the cross-workspace edit.
        var saved = try XCTUnwrap(controller.capturePlacementSnapshot())
        var tree = saved.tree; tree.reconcile([other.surfaceID], in: destination.name)
        saved = .init(tree: tree, layoutWorkspaces: saved.layoutWorkspaces, selected: nil, closedBrowserTabs: [])
        controller.restorePlacementSnapshot(saved)
        XCTAssertEqual(controller.select(tab), .issued)
        controller.organize(tab, before: other.surfaceID)
        XCTAssertEqual(controller.workspaceName(for: tab), destination.name)
        XCTAssertEqual(controller.surfaceTree.roots[destination.name]?.flatMap(\.surfaces), [tab, other.surfaceID])
        XCTAssertEqual(Window.get(byId: 71)?.nodeWorkspace?.name, source)
        XCTAssertEqual(focus.workspace.name, source)
        XCTAssertEqual(controller.focusCoordinator.target, Window.get(byId: 71)?.surfaceID)
        controller.organize(other.surfaceID, before: Window.get(byId: 71)!.surfaceID)
        XCTAssertEqual(other.nodeWorkspace?.name, source)
        XCTAssertEqual(controller.surfaceTree.workspace(of: other.surfaceID), source)
    }

    func testDirectionalMoveTransfersWholeStackAcrossMonitorBoundary() async throws {
        let main = TestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Main",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080), isMain: true)
        let second = TestMonitor(monitorAppKitNsScreenScreensId: 2, name: "Second",
            rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080), isMain: false)
        setMonitorsForTests([main, second])
        let source = focus.workspace, destination = Workspace.get(byName: "External")
        _ = second.setActiveWorkspace(destination)
        let native = try XCTUnwrap(Window.get(byId: 71))
        let resident = TestWindow.new(id: 72, parent: destination.rootTilingContainer)
        refreshModel()
        XCTAssertTrue(controller.editOrganization(of: tab) { $0.insertIntoStack(tab, with: native.surfaceID) })
        let group = try XCTUnwrap(controller.surfaceTree.containingGroup(of: tab))
        try await checkCommand(["move", "right", "--boundaries", "all-monitors-outer-frame"])
        XCTAssertEqual(controller.surfaceTree.workspace(ofGroup: group), destination.name)
        XCTAssertEqual(controller.surfaceTree.roots[destination.name]?.first, controller.surfaceTree.group(group))
        XCTAssertEqual(controller.surfaceTree.roots[destination.name]?.last, .surface(resident.surfaceID))
        XCTAssertEqual(Set(controller.surfaceTree.group(group)?.surfaces ?? []), [native.surfaceID, tab])
        XCTAssertEqual(controller.surfaceTree.roots[source.name], [])
        XCTAssertEqual(native.nodeWorkspace, destination)
        XCTAssertEqual(controller.focusCoordinator.target, tab)
        XCTAssertEqual(focus.workspace, destination)
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

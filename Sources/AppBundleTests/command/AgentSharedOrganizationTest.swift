@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor final class AgentSharedOrganizationTest: XCTestCase {
    let controller = BrowserWorkspaceController.shared
    var connection = UUID()
    var tab = SurfaceID.browserTab(profile: UUID(), tab: UUID())
    var workspaceName = ""

    override func setUp() async throws {
        setUpWorkspacesForTests()
        connection = UUID(); tab = .browserTab(profile: UUID(), tab: UUID())
        workspaceName = focus.workspace.name
        let root = focus.workspace.rootTilingContainer
        let first = TestWindow.new(id: 71, parent: root)
        let second = TestWindow.new(id: 72, parent: root)
        _ = first.focusWindow()
        var tree = SurfaceTree(); tree.reconcile([first.surfaceID, tab, second.surfaceID], in: workspaceName)
        XCTAssertTrue(tree.group(tab, with: first.surfaceID))
        tree.select(tab)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [workspaceName], selected: nil, closedBrowserTabs: []))
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [.init(surfaceID: tab, hostID: "synthetic", title: "Browser page", selected: true)]),
            epoch: UUID(), connection: connection, protocolVersion: 3)
        XCTAssertEqual(controller.select(tab), .issued)
    }

    override func tearDown() async throws {
        controller.disconnected(connection)
        controller.nativeSelectionChanged(nil)
        controller.restorePlacementSnapshot(.init(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        controller.usesSurfaceTree = false
    }

    private func run(_ operations: String, check: Bool = false, worldId: String? = nil) async throws -> CmdResult {
        let world = worldId.map { "\"worldId\": \"\($0)\"," } ?? ""
        let path = try writeAgentJson("{\"schemaVersion\":2,\(world)\"edit\":{\"operations\":[\(operations)]}}")
        defer { try? FileManager.default.removeItem(at: path) }
        return try await parseCommand("agent \(check ? "check" : "apply") --path \(path.path)").cmdOrDie.run(.defaultEnv, .emptyStdin)
    }

    func testQueryProjectsMixedStackInsteadOfNativeHierarchyAndDoesNotMutate() async throws {
        let before = controller.surfaceTree
        let group = try XCTUnwrap(before.stack(containing: tab))
        let query = try await AgentSnapshot.query()
        XCTAssertEqual(query.schemaVersion, 2)
        XCTAssertEqual(query.inventory.surfaces.count, 3)
        XCTAssertEqual(query.inventory.surfaces.first { $0.surfaceId == tab }?.title, "Browser page")
        XCTAssertNil(query.inventory.surfaces.first { $0.surfaceId == tab }?.windowId)
        let stack = try XCTUnwrap(query.inventory.tabGroups.first { $0.groupId == group })
        XCTAssertEqual(stack.surfaces, before.group(group)?.surfaces)
        XCTAssertEqual(stack.activeSurfaceId, tab)
        XCTAssertEqual(stack.tabs, [71])
        XCTAssertEqual(stack.size, 0.5)
        XCTAssertEqual(query.inventory.windows.first { $0.windowId == 71 }?.tabGroupId, "group:\(group.uuidString.lowercased())")
        XCTAssertEqual(query.reasoning.panes.filter { $0.workspace == workspaceName }.count, 2)
        XCTAssertEqual(query.reasoning.relations.first { $0.paneId == stack.paneId }?.right, Window.get(byId: 72)?.surfaceID.description)
        let encoded = try JSONEncoder().encode(query)
        let raw = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(raw.contains("\"kind\":\"stack\""))
        XCTAssertTrue(raw.contains(tab.description))
        XCTAssertEqual(controller.surfaceTree, before)
        XCTAssertTrue(focus.workspace.rootTilingContainer.children.allSatisfy { $0 is Window })
    }

    func testPlaceThenResizeUsesCandidateLayoutAndLegacyWindowAlias() async throws {
        let group = try XCTUnwrap(controller.surfaceTree.stack(containing: tab))
        let operations = """
            {"type":"placePane","pane":{"groupId":"\(group)"},"relation":"below","target":{"windowId":72}},
            {"type":"setPaneSize","pane":{"tabGroupId":"tabgroup-71"},"axis":"vertical","size":0.75}
            """
        let before = controller.surfaceTree
        let check = try await run(operations, check: true)
        XCTAssertEqual(check.exitCode, 0, check.stderr.joined())
        XCTAssertEqual(controller.surfaceTree, before)
        let result = try await run(operations)
        XCTAssertEqual(result.exitCode, 0, result.stderr.joined())
        let allocation = try XCTUnwrap(controller.surfaceTree.allocation(of: .group(group), axis: .vertical))
        XCTAssertEqual(allocation.ratio, 0.75, accuracy: 0.00001)
        XCTAssertEqual(controller.surfaceTree.group(group)?.surfaces, before.group(group)?.surfaces)
        XCTAssertEqual(controller.surfaceTree.activeSurfaces[group], tab)
        XCTAssertTrue(focus.workspace.rootTilingContainer.children.allSatisfy { $0 is Window })
    }

    func testCrossViewSwapCommitsBothOwnerMembershipsAndPreservesStack() async throws {
        let group = try XCTUnwrap(controller.surfaceTree.stack(containing: tab))
        let destination = Workspace.get(byName: "destination")
        destination.assignProject(focus.workspace.projectId)
        let third = TestWindow.new(id: 73, parent: destination.rootTilingContainer)
        controller.reconcileSharedOrganization()
        let result = try await run("""
            {"type":"swapPanes","a":{"groupId":"\(group)"},"b":{"surfaceId":"\(third.surfaceID)"}}
            """)
        XCTAssertEqual(result.exitCode, 0, result.stderr.joined())
        XCTAssertEqual(controller.surfaceTree.workspace(ofGroup: group), destination.name)
        XCTAssertEqual(controller.placements[tab], destination.name)
        XCTAssertEqual(Window.get(byId: 71)?.nodeWorkspace, destination)
        XCTAssertEqual(third.nodeWorkspace?.name, workspaceName)
        XCTAssertEqual(controller.surfaceTree.activeSurfaces[group], tab)
    }

    func testInvalidLaterPaneEditRejectsBatchBeforeMutation() async throws {
        let group = try XCTUnwrap(controller.surfaceTree.stack(containing: tab))
        let before = controller.surfaceTree
        let result = try await run("""
            {"type":"setPaneSize","pane":{"groupId":"\(group)"},"size":0.7},
            {"type":"swapPanes","a":{"groupId":"\(group)"},"b":{"surfaceId":"\(tab)"}}
            """)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.joined().contains("overlap"))
        XCTAssertEqual(controller.surfaceTree, before)
    }

    func testWorldIdIncludesSharedArrangementAndRejectsStaleEdits() async throws {
        let first = currentAgentWorldId()
        let group = try XCTUnwrap(controller.surfaceTree.stack(containing: tab))
        XCTAssertTrue(controller.editOrganization(of: tab) { $0.setProportion(0.7, of: .group(group)) })
        let second = currentAgentWorldId()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second, currentAgentWorldId())
        let before = controller.surfaceTree
        let result = try await run("{\"type\":\"setPaneSize\",\"pane\":{\"surfaceId\":\"\(tab)\"},\"size\":0.4}", worldId: first)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.joined().contains("stale"))
        XCTAssertEqual(controller.surfaceTree, before)
    }

    func testCreateAliasPlaceResizeAndMoveOperateOnSharedStack() async throws {
        let originalBrowser = tab
        let result = try await run("""
            {"type":"createTabGroup","tabGroupId":"tabgroup-new","tabs":[71,72],"activeWindowId":72},
            {"type":"placePane","pane":{"tabGroupId":"tabgroup-new"},"relation":"below","target":{"surfaceId":"\(tab)"}},
            {"type":"setPaneSize","pane":{"tabGroupId":"tabgroup-new"},"axis":"vertical","size":0.8},
            {"type":"moveTabGroupToWorkspace","tabGroupId":"tabgroup-new","workspace":"new-view"}
            """)
        XCTAssertEqual(result.exitCode, 0, result.stderr.joined())
        let first = try XCTUnwrap(Window.get(byId: 71))
        let second = try XCTUnwrap(Window.get(byId: 72))
        let group = try XCTUnwrap(controller.surfaceTree.stack(containing: first.surfaceID))
        XCTAssertEqual(controller.surfaceTree.group(group)?.surfaces, [first.surfaceID, second.surfaceID])
        XCTAssertEqual(controller.surfaceTree.activeSurfaces[group], second.surfaceID)
        XCTAssertEqual(controller.surfaceTree.workspace(ofGroup: group), "new-view")
        XCTAssertEqual(first.nodeWorkspace?.name, "new-view")
        XCTAssertEqual(second.nodeWorkspace?.name, "new-view")
        XCTAssertEqual(controller.surfaceTree.workspace(of: originalBrowser), workspaceName)
        XCTAssertTrue(Workspace.existing(byName: "new-view")?.retainsEmptyView == true)
    }

    func testAddSelectAndSeparateUseReturnedSharedGroupIdentifier() async throws {
        let group = try XCTUnwrap(controller.surfaceTree.stack(containing: tab))
        let reference = "group:" + group.uuidString.lowercased()
        let first = try await run("""
            {"type":"addWindowToTabGroup","tabGroupId":"\(reference)","windowId":72,"activeWindowId":72},
            {"type":"setActiveTab","tabGroupId":"\(reference)","windowId":71}
            """)
        XCTAssertEqual(first.exitCode, 0, first.stderr.joined())
        XCTAssertEqual(controller.surfaceTree.activeSurfaces[group], Window.get(byId: 71)?.surfaceID)
        XCTAssertEqual(controller.surfaceTree.group(group)?.surfaces.count, 3)
        let second = try await run("{\"type\":\"moveWindowOutOfTabGroup\",\"windowId\":72}")
        XCTAssertEqual(second.exitCode, 0, second.stderr.joined())
        XCTAssertEqual(controller.surfaceTree.group(group)?.surfaces.count, 2)
        XCTAssertNil(Window.get(byId: 72).flatMap { controller.surfaceTree.stack(containing: $0.surfaceID) })
    }

    func testDeclarativeMixedLayoutUsesTypedOwnersAndRequestedProportions() async throws {
        let native = try XCTUnwrap(Window.get(byId: 71))
        let result = try await run("""
            {"type":"setWorkspaceLayout","layout":{"name":"\(workspaceName)","layout":{
              "kind":"split","direction":"horizontal","children":[
                {"kind":"stack","surfaces":["\(tab)","\(native.surfaceID)"],"activeSurfaceId":"\(tab)","size":0.8},
                {"kind":"window","windowId":72,"size":0.2}
              ]
            }}}
            """)
        XCTAssertEqual(result.exitCode, 0, result.stderr.joined())
        let group = try XCTUnwrap(controller.surfaceTree.stack(containing: tab))
        XCTAssertEqual(controller.surfaceTree.group(group)?.surfaces, [tab, native.surfaceID])
        XCTAssertEqual(controller.surfaceTree.activeSurfaces[group], tab)
        XCTAssertEqual(try XCTUnwrap(controller.surfaceTree.allocation(of: .group(group))).ratio, 0.8, accuracy: 0.0001)
        XCTAssertTrue(native.nodeWorkspace?.rootTilingContainer.children.allSatisfy { $0 is Window } == true)
    }

    func testDeclarativeLayoutPreservesUnmentionedMixedArrangement() async throws {
        let group = try XCTUnwrap(controller.surfaceTree.stack(containing: tab))
        let original = controller.surfaceTree.group(group)
        let result = try await run("""
            {"type":"setWorkspaceLayout","layout":{"name":"\(workspaceName)","layout":{"kind":"window","windowId":72}}}
            """)
        XCTAssertEqual(result.exitCode, 0, result.stderr.joined())
        XCTAssertEqual(controller.surfaceTree.group(group), original)
        XCTAssertEqual(controller.surfaceTree.activeSurfaces[group], tab)
        XCTAssertEqual(controller.surfaceTree.roots[workspaceName]?.last, original)
    }

    func testDeclarativeLayoutCommitsFloatingTransitionsWithBothOwnerMoves() async throws {
        let source = try XCTUnwrap(Workspace.existing(byName: workspaceName))
        let first = try XCTUnwrap(Window.get(byId: 71))
        let second = try XCTUnwrap(Window.get(byId: 72))
        second.bindAsFloatingWindow(to: source)
        let untouched = TestWindow.new(id: 73, parent: source.rootTilingContainer)
        controller.reconcileSharedOrganization()
        let result = try await run("""
            {"type":"setWorkspaceLayout","layout":{"name":"arranged","layout":{
              "kind":"split","direction":"horizontal","children":[
                {"kind":"surface","surfaceId":"\(tab)"},{"kind":"window","windowId":72}
              ]},"floating":[{"windowId":71}]}}
            """)
        XCTAssertEqual(result.exitCode, 0, result.stderr.joined())
        XCTAssertEqual(first.nodeWorkspace?.name, "arranged")
        XCTAssertTrue(first.isFloating)
        XCTAssertNil(controller.surfaceTree.workspace(of: first.surfaceID))
        XCTAssertEqual(second.nodeWorkspace?.name, "arranged")
        XCTAssertFalse(second.isFloating)
        XCTAssertEqual(controller.surfaceTree.workspace(of: second.surfaceID), "arranged")
        XCTAssertEqual(controller.placements[tab], "arranged")
        XCTAssertEqual(untouched.nodeWorkspace, source)
    }

    func testInvalidFloatingLayoutCannotMutateNativeOrBrowserMembership() async throws {
        let before = controller.surfaceTree
        let first = try XCTUnwrap(Window.get(byId: 71))
        let result = try await run("""
            {"type":"setWorkspaceLayout","layout":{"name":"arranged","layout":{"kind":"window","windowId":71},
              "floating":[{"surfaceId":"\(tab)"}]}}
            """)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.joined().contains("native windows"))
        XCTAssertEqual(controller.surfaceTree, before)
        XCTAssertEqual(first.nodeWorkspace?.name, workspaceName)
        XCTAssertNil(Workspace.existing(byName: "arranged"))
    }

    func testFloatingTransitionsAreVisibleToLaterOperationsInTheSameBatch() async throws {
        let result = try await run("""
            {"type":"setFloating","windowId":71,"value":true},
            {"type":"setFloating","windowId":71,"value":false},
            {"type":"createTabGroup","tabs":[71,72],"activeWindowId":71}
            """)
        XCTAssertEqual(result.exitCode, 0, result.stderr.joined())
        let first = try XCTUnwrap(Window.get(byId: 71))
        XCTAssertFalse(first.isFloating)
        let group = try XCTUnwrap(controller.surfaceTree.stack(containing: first.surfaceID))
        XCTAssertEqual(controller.surfaceTree.group(group)?.surfaces.count, 2)
        XCTAssertEqual(controller.surfaceTree.workspace(of: tab), workspaceName)
    }

    func testUnavailableOwnerPreventsNativeFloatingMutation() async throws {
        controller.disconnected(connection)
        let before = controller.surfaceTree
        let first = try XCTUnwrap(Window.get(byId: 71))
        let result = try await run("{\"type\":\"setFloating\",\"windowId\":71,\"value\":true}")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(first.isFloating)
        XCTAssertEqual(controller.surfaceTree, before)
    }

    func testSnapshotAndValidationRejectLayoutChangesDuringTitleReads() async throws {
        let source = try XCTUnwrap(Workspace.existing(byName: workspaceName))
        let window = AgentTitleReadWindow(id: 74, parent: source.rootTilingContainer)
        TestApp.shared._windows.append(window)
        controller.reconcileSharedOrganization()
        window.onTitleRead = { [controller, tab] in _ = controller.surfaceTree.setProportion(0.7, of: .surface(tab)) }
        let query = try await parseCommand("agent query").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(query.exitCode, 1)
        XCTAssertTrue(query.stderr.joined().contains("changed while reading"))

        let world = currentAgentWorldId()
        window.onTitleRead = { [controller, tab] in _ = controller.surfaceTree.setProportion(0.4, of: .surface(tab)) }
        let result = try await run("{\"type\":\"focusWindow\",\"match\":{\"titleContains\":\"Race fixture\"}}", check: true, worldId: world)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.joined().contains("stale"))
    }

    func testFullLayoutRejectsDuplicateOwnerAcrossViewsBeforeCreatingEither() async throws {
        let path = try writeAgentJson("""
            {"edit":{"layout":{"workspaces":[
              {"name":"first-layout","layout":{"kind":"window","windowId":71}},
              {"name":"second-layout","layout":{"kind":"window","windowId":71}}
            ]}}}
            """)
        defer { try? FileManager.default.removeItem(at: path) }
        let before = controller.surfaceTree
        let result = try await parseCommand("agent apply --path \(path.path)").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.joined().contains("more than one"))
        XCTAssertEqual(controller.surfaceTree, before)
        XCTAssertNil(Workspace.existing(byName: "first-layout"))
        XCTAssertNil(Workspace.existing(byName: "second-layout"))
    }
}

@MainActor private final class AgentTitleReadWindow: Window {
    var onTitleRead: (() -> Void)?
    init(id: UInt32, parent: TilingContainer) {
        super.init(id: id, TestApp.shared, lastFloatingSize: nil, parent: parent, adaptiveWeight: 1, index: INDEX_BIND_LAST)
    }
    override var title: String {
        get async throws { let action = onTitleRead; onTitleRead = nil; action?(); return "Race fixture" }
    }
    override func closeAxWindow() { unbindFromParent() }
    override func getAxRect() async throws -> Rect? { nil }
    override var isMacosFullscreen: Bool { get async throws { false } }
    override var isMacosMinimized: Bool { get async throws { false } }
}

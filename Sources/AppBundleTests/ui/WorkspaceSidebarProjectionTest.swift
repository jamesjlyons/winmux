@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor
final class WorkspaceSidebarProjectionTest: XCTestCase {
    override func setUp() async throws {
        BrowserWorkspaceController.shared.restorePlacementSnapshot(.init(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        BrowserWorkspaceController.shared.usesSurfaceTree = false
        setUpWorkspacesForTests()
    }

    override func tearDown() async throws {
        BrowserWorkspaceController.shared.restorePlacementSnapshot(.init(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        BrowserWorkspaceController.shared.usesSurfaceTree = false
    }

    func testEmptySidebarReadsDoNotCreateContainersProjectsOrPinWorkspaces() async {
        let controller = BrowserWorkspaceController.shared
        controller.usesSurfaceTree = true
        config.workspaceSidebar.projectLabels["not-yet-materialized"] = "Saved Space"
        let beforeProjects = winMuxWorkspaceState.projectsById
        let beforeWorkspaces = Workspace.all.map(\.id)
        let workspace = focus.workspace
        XCTAssertNil(workspace.existingRootTilingContainer)

        for _ in 0..<2 { _ = await buildWorkspaceSidebarModelState() }

        XCTAssertEqual(winMuxWorkspaceState.projectsById, beforeProjects)
        XCTAssertEqual(Workspace.all.map(\.id), beforeWorkspaces)
        XCTAssertNil(workspace.existingRootTilingContainer)
        XCTAssertTrue(controller.spacePinnedGroups.isEmpty)
        XCTAssertEqual(controller.surfaceTree, SurfaceTree())
    }

    func testModelRefreshAdoptsNativeArrangementWithSidebarDisabled() throws {
        let controller = BrowserWorkspaceController.shared
        controller.usesSurfaceTree = true
        config.workspaceSidebar.enabled = false
        let workspace = focus.workspace
        let split = TilingContainer.newVTiles(parent: workspace.rootTilingContainer, adaptiveWeight: 600, index: INDEX_BIND_LAST)
        let a = TestWindow.new(id: 3101, parent: split, adaptiveWeight: 200)
        let b = TestWindow.new(id: 3102, parent: split, adaptiveWeight: 400)
        XCTAssertTrue(b.focusWindow())

        refreshModel()

        let group = try XCTUnwrap(controller.surfaceTree.containingGroup(of: a.surfaceID))
        XCTAssertEqual(controller.surfaceTree.group(group)?.surfaces, [a.surfaceID, b.surfaceID])
        XCTAssertEqual(controller.surfaceTree.layouts[group], .vertical)
        XCTAssertEqual(controller.surfaceTree.weights[a.surfaceID.description], 200)
        XCTAssertEqual(controller.surfaceTree.weights[b.surfaceID.description], 400)
        XCTAssertTrue(controller.editOrganization(of: a.surfaceID) { $0.setLayout(containing: a.surfaceID, to: .stack) })
    }

    func testSidebarReadsNeverImportOrRepairOrganization() async {
        let controller = BrowserWorkspaceController(), workspace = focus.workspace
        controller.usesSurfaceTree = true
        let window = TestWindow.new(id: 3103, parent: workspace.rootTilingContainer)
        let rows = await buildWorkspaceSidebarNativeItems(for: workspace, currentFocus: focus)

        XCTAssertTrue(controller.organizedRows(native: rows, in: workspace.name).isEmpty)
        XCTAssertEqual(controller.surfaceTree, SurfaceTree())

        controller.reconcileSharedOrganization()
        let before = controller.surfaceTree
        for _ in 0..<2 {
            XCTAssertEqual(controller.organizedRows(native: rows, in: workspace.name).flatMap(\.surfaceIDs), [window.surfaceID])
        }
        XCTAssertEqual(controller.surfaceTree, before)
    }

    func testLateNativeDiscoveryKeepsItsSplitAndExistingBrowserOrder() throws {
        let controller = BrowserWorkspaceController(), workspace = focus.workspace
        controller.usesSurfaceTree = true
        let connection = UUID(), page = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [
            .init(surfaceID: page, hostID: "page", title: "Page", selected: false),
        ]), epoch: UUID(), connection: connection, protocolVersion: 4)
        let split = TilingContainer.newVTiles(parent: workspace.rootTilingContainer, adaptiveWeight: 600, index: INDEX_BIND_LAST)
        let first = TestWindow.new(id: 3105, parent: split, adaptiveWeight: 200)
        let second = TestWindow.new(id: 3106, parent: split, adaptiveWeight: 400)

        controller.reconcileSharedOrganization()

        let group = try XCTUnwrap(controller.surfaceTree.containingGroup(of: first.surfaceID))
        XCTAssertEqual(controller.surfaceTree.layouts[group], .vertical)
        XCTAssertEqual(controller.surfaceTree.group(group)?.surfaces, [first.surfaceID, second.surfaceID])
        XCTAssertEqual(controller.surfaceTree.roots[workspace.name]?.flatMap(\.surfaces), [page, first.surfaceID, second.surfaceID])
        XCTAssertEqual(controller.surfaceTree.weights[first.surfaceID.description], 200)
        XCTAssertTrue(controller.surfaceTree.group(first.surfaceID, with: page))
        let mixed = controller.surfaceTree
        controller.reconcileSharedOrganization()
        XCTAssertEqual(controller.surfaceTree, mixed)
        controller.disconnected(connection)
    }

    func testStaleTitleRowsCannotMoveOrResurrectNativeOwners() async {
        let controller = BrowserWorkspaceController(), source = focus.workspace
        controller.usesSurfaceTree = true
        let window = TestWindow.new(id: 3104, parent: source.rootTilingContainer)
        controller.reconcileSharedOrganization()
        let rows = await buildWorkspaceSidebarNativeItems(for: source, currentFocus: focus)
        let destination = Workspace.get(byName: "destination")
        window.bind(to: destination.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        controller.reconcileSharedOrganization()
        let moved = controller.surfaceTree

        XCTAssertTrue(controller.organizedRows(native: rows, in: source.name).isEmpty)
        XCTAssertEqual(controller.surfaceTree, moved)
        XCTAssertEqual(controller.surfaceTree.workspace(of: window.surfaceID), destination.name)

        window.unbindFromParent()
        controller.reconcileSharedOrganization()
        let closed = controller.surfaceTree
        XCTAssertTrue(controller.organizedRows(native: rows, in: source.name).isEmpty)
        XCTAssertNil(controller.surfaceTree.workspace(of: window.surfaceID))
        XCTAssertEqual(controller.surfaceTree, closed)
    }

    func testPinProjectionDoesNotClearAbsentBindings() {
        let controller = BrowserWorkspaceController()
        controller.usesSurfaceTree = true
        let pin = NativeAppSidebarPin(workspaceName: focus.workspace.name,
            bundleIdentifier: "dev.winmux.missing", bundlePath: "/Missing.app", title: "Missing",
            surfaceID: .nativeWindow(UUID()))
        controller.nativeAppSidebarPins = [pin]

        _ = controller.pinTilesByWorkspace()
        _ = controller.legacyPinTilesByWorkspace()
        _ = controller.pinnedBrowserRows(in: focus.workspace.name)

        XCTAssertEqual(controller.nativeAppSidebarPins, [pin])
        controller.reconcileSharedOrganization()
        XCTAssertNil(controller.nativeAppSidebarPins.first?.surfaceID)
    }

    func testInventoryCommitsBrowserMembershipBeforeAnySidebarRead() {
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID()
        controller.usesSurfaceTree = true
        let id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [
            .init(surfaceID: id, hostID: "page", title: "Page", selected: false),
        ]), epoch: epoch, connection: connection, protocolVersion: 4)
        XCTAssertEqual(controller.surfaceTree.workspace(of: id), focus.workspace.name)
        XCTAssertTrue(controller.plannedSurfaces(in: focus.workspace).contains { $0.surfaceID == id })
        controller.received(.init(revision: 2, full: false, tabs: [], removed: [id]),
            epoch: epoch, connection: connection, protocolVersion: 4)
        XCTAssertNil(controller.surfaceTree.workspace(of: id))
        controller.disconnected(connection)
    }
}

@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor final class SharedFullscreenLayoutTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = true
        config.workspaceSidebar.visibility = .compact
        config.workspaceSidebar.collapsedWidth = 28
        config.gaps = .zero
    }

    override func tearDown() async throws {
        let controller = BrowserWorkspaceController.shared
        controller.nativeSelectionChanged(nil)
        controller.restorePlacementSnapshot(.init(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        controller.usesSurfaceTree = false
    }

    func testSharedStackFullscreenIgnoresOldNativeGroupsAndRestoresSavedLayout() async throws {
        let controller = BrowserWorkspaceController.shared, workspace = focus.workspace
        // The binding tree still has three siblings. Only WorkspaceCore knows
        // that the first two form a stack.
        let windows = (901...903).map { TestWindow.new(id: UInt32($0), parent: workspace.rootTilingContainer) }
        var tree = SurfaceTree(); tree.reconcile(windows.map(\.surfaceID), in: workspace.name)
        XCTAssertTrue(tree.group(windows[1].surfaceID, with: windows[0].surfaceID))
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [workspace.name], selected: nil, closedBrowserTabs: []))
        controller.nativeSelectionChanged(windows[0].surfaceID)
        let saved = controller.surfaceTree
        let original = controller.plannedSurfaces(in: workspace)
        windows[0].isFullscreen = true
        controller.reconcileSharedOrganization()
        XCTAssertTrue(shouldSuppressWorkspaceSidebarForFullscreenContent(on: mainMonitor))
        XCTAssertEqual(mainMonitor.workspaceSidebarInset, 0)
        XCTAssertTrue(controller.plannedLayout(in: workspace).stacks.isEmpty)
        try await withLease {
            let handled = try await controller.applyNativeLayout(in: workspace)
            XCTAssertTrue(handled)
        }
        XCTAssertEqual(windows[0].lastAppliedLayoutPhysicalRect, mainMonitor.visibleRect)
        XCTAssertNil(windows[1].lastAppliedLayoutPhysicalRect)
        XCTAssertNil(windows[2].lastAppliedLayoutPhysicalRect)
        XCTAssertEqual(controller.surfaceTree, saved)
        controller.nativeSelectionChanged(windows[1].surfaceID)
        try await withLease {
            let handled = try await controller.applyNativeLayout(in: workspace)
            XCTAssertTrue(handled)
        }
        XCTAssertEqual(windows[1].lastAppliedLayoutPhysicalRect, mainMonitor.visibleRect)
        XCTAssertNil(windows[0].lastAppliedLayoutPhysicalRect)
        windows[0].isFullscreen = false
        controller.nativeSelectionChanged(windows[0].surfaceID)
        XCTAssertFalse(shouldSuppressWorkspaceSidebarForFullscreenContent(on: mainMonitor))
        XCTAssertEqual(controller.plannedSurfaces(in: workspace), original)
        XCTAssertEqual(controller.surfaceTree, saved)
    }

    func testFullscreenStackCanSelectBrowserPageAndHideAllSiblings() throws {
        let controller = BrowserWorkspaceController.shared, workspace = focus.workspace
        let native = TestWindow.new(id: 911, parent: workspace.rootTilingContainer)
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID()), sibling = TestWindow.new(id: 912, parent: workspace.rootTilingContainer)
        let connection = UUID()
        defer { controller.disconnected(connection) }
        var tree = SurfaceTree(); tree.reconcile([native.surfaceID, page, sibling.surfaceID], in: workspace.name)
        XCTAssertTrue(tree.group(page, with: native.surfaceID))
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [workspace.name], selected: nil, closedBrowserTabs: []))
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [.init(surfaceID: page, hostID: "fullscreen", title: "Page", selected: true)]),
            epoch: UUID(), connection: connection, protocolVersion: 4)
        native.isFullscreen = true
        native.noOuterGapsInFullscreen = true
        XCTAssertEqual(controller.select(page), .issued)
        let plan = controller.plannedSurfaces(in: workspace)
        XCTAssertEqual(plan.filter(\.visible).map(\.surfaceID), [page])
        XCTAssertEqual(plan.first(where: { $0.surfaceID == page })?.frame.width, Int(mainMonitor.visibleRect.width))
        XCTAssertEqual(controller.navigationStackItems(for: page, in: workspace), [native.surfaceID, page])
        XCTAssertTrue(shouldSuppressWorkspaceSidebarForFullscreenContent(on: mainMonitor))
    }

    func testInactiveFullscreenLeafDoesNotHideOtherRootsAndNativeFullscreenStaysUnmanaged() {
        let controller = BrowserWorkspaceController.shared, workspace = focus.workspace
        let first = TestWindow.new(id: 921, parent: workspace.rootTilingContainer)
        let second = TestWindow.new(id: 922, parent: workspace.rootTilingContainer)
        var tree = SurfaceTree(); tree.reconcile([first.surfaceID, second.surfaceID], in: workspace.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [workspace.name], selected: nil, closedBrowserTabs: []))
        first.isFullscreen = true
        controller.nativeSelectionChanged(second.surfaceID)
        XCTAssertNil(controller.sharedFullscreenPane(in: workspace))
        XCTAssertEqual(controller.plannedSurfaces(in: workspace).filter(\.visible).count, 2)
        first.recordObservedNativeState(fullscreen: true, minimized: false, token: first.nativeStateObservationToken())
        controller.nativeSelectionChanged(first.surfaceID)
        XCTAssertNil(controller.sharedFullscreenPane(in: workspace))
        XCTAssertEqual(controller.plannedSurfaces(in: workspace).map(\.surfaceID), [second.surfaceID])
        XCTAssertEqual(controller.surfaceTree.workspace(of: first.surfaceID), workspace.name)
    }

    private func withLease(_ body: () async throws -> Void) async throws {
        let old = BrowserNativeManagement.lease, enabled = TrayMenuModel.shared.isEnabled
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        BrowserNativeManagement.lease = try NativeManagementLease(path: path)
        TrayMenuModel.shared.isEnabled = true
        defer {
            BrowserNativeManagement.lease = old; TrayMenuModel.shared.isEnabled = enabled
            try? FileManager.default.removeItem(atPath: path)
        }
        try await body()
    }
}

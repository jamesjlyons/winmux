@testable import AppBundle
import WorkspaceCore
import XCTest

@MainActor final class BrowserLiveLayoutTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testUnrestoredBrowserPaneDoesNotReserveFirstTile() throws {
        let controller = BrowserWorkspaceController(), workspace = focus.workspace
        let missing = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let native = TestWindow.new(id: 9501, parent: workspace.rootTilingContainer)
        var tree = SurfaceTree(); tree.reconcile([missing, native.surfaceID], in: workspace.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [workspace.name], selected: missing, closedBrowserTabs: []))

        try assertFillsWorkspace(native.surfaceID, controller: controller)
        XCTAssertEqual(controller.surfaceTree, tree)
        XCTAssertEqual(try XCTUnwrap(controller.capturePlacementSnapshot()).tree, tree)
    }

    func testDisconnectClosesGapAndReconnectRestoresSavedOrderAndSize() throws {
        let controller = BrowserWorkspaceController(), workspace = focus.workspace
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let native = TestWindow.new(id: 9502, parent: workspace.rootTilingContainer)
        var tree = SurfaceTree(); tree.reconcile([page, native.surfaceID], in: workspace.name)
        tree.setWeights([page.description: 2, native.surfaceID.description: 3])
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [workspace.name], selected: nil, closedBrowserTabs: []))
        let connection = connect(page, to: controller)
        let before = controller.plannedLayout(in: workspace)
        XCTAssertEqual(before.surfaces.map(\.surfaceID), [page, native.surfaceID])
        controller.disconnected(connection)

        try assertFillsWorkspace(native.surfaceID, controller: controller)
        XCTAssertEqual(controller.surfaceTree, tree)
        connect(page, to: controller)
        XCTAssertEqual(controller.plannedLayout(in: workspace), before)
        XCTAssertEqual(controller.surfaceTree, tree)
    }

    func testPartialBrowserRestorationDoesNotLeaveGapBesideLivePageFromSameProfile() throws {
        let controller = BrowserWorkspaceController(), workspace = focus.workspace
        let profile = UUID(), connection = UUID(), epoch = UUID()
        let missing = SurfaceID.browserTab(profile: profile, tab: UUID())
        let live = SurfaceID.browserTab(profile: profile, tab: UUID())
        let native = TestWindow.new(id: 9505, parent: workspace.rootTilingContainer)
        var tree = SurfaceTree(); tree.reconcile([missing, native.surfaceID, live], in: workspace.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [workspace.name], selected: native.surfaceID, closedBrowserTabs: []))
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        let liveRecord = BrowserTabRecord(surfaceID: live, hostID: "live", title: "Live page", selected: true,
            hostMinimumSize: .init(width: 160, height: 120))

        // Repeated full inventories may precede a late restored tab. Its saved
        // position must survive without taking space from the connected owners.
        for revision: UInt64 in 1...2 {
            controller.received(.init(revision: revision, full: true, tabs: [liveRecord]),
                epoch: epoch, connection: connection, protocolVersion: 11)
            controller.reconcileSharedOrganization()
            let placements = controller.plannedSurfaces(in: workspace)
            XCTAssertEqual(placements.map(\.surfaceID), [native.surfaceID, live])
            XCTAssertTrue(placements.allSatisfy(\.visible))
            let rect = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
            XCTAssertEqual(try XCTUnwrap(placements.first).frame.x, Int(rect.topLeftX.rounded()))
            XCTAssertEqual(placements.reduce(0) { $0 + $1.frame.width } + controller.layoutGaps(in: workspace).horizontal,
                Int(rect.width.rounded()))
            XCTAssertEqual(controller.surfaceTree, tree)
            XCTAssertEqual(try XCTUnwrap(controller.capturePlacementSnapshot()).tree, tree)
        }

        controller.received(.init(revision: 3, full: false, tabs: [
            .init(surfaceID: missing, hostID: "returned", title: "Returned page", selected: true,
                  hostMinimumSize: .init(width: 160, height: 120))
        ]), epoch: epoch, connection: connection, protocolVersion: 11)
        controller.reconcileSharedOrganization()
        XCTAssertEqual(controller.plannedSurfaces(in: workspace).map(\.surfaceID), [missing, native.surfaceID, live])
        XCTAssertEqual(controller.surfaceTree, tree)
    }

    func testUnrestoredSelectedBrowserStackMemberDoesNotHideNativeSibling() throws {
        let controller = BrowserWorkspaceController(), workspace = focus.workspace
        let missing = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let native = TestWindow.new(id: 9503, parent: workspace.rootTilingContainer)
        var tree = SurfaceTree(); tree.reconcile([missing, native.surfaceID], in: workspace.name)
        tree.group(native.surfaceID, with: missing)
        tree.select(missing)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [workspace.name], selected: missing, closedBrowserTabs: []))

        try assertFillsWorkspace(native.surfaceID, controller: controller)
        XCTAssertEqual(controller.surfaceTree, tree)
    }

    func testWhollyUnavailableBrowserGroupDoesNotReserveFirstTile() throws {
        let controller = BrowserWorkspaceController(), workspace = focus.workspace
        let first = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let second = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let native = TestWindow.new(id: 9504, parent: workspace.rootTilingContainer)
        var tree = SurfaceTree(); tree.reconcile([first, second, native.surfaceID], in: workspace.name)
        tree.group(second, with: first, layout: .vertical)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [workspace.name], selected: nil, closedBrowserTabs: []))

        try assertFillsWorkspace(native.surfaceID, controller: controller)
        XCTAssertEqual(controller.surfaceTree, tree)
    }

    private func assertFillsWorkspace(_ id: SurfaceID, controller: BrowserWorkspaceController,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let placements = controller.plannedSurfaces(in: focus.workspace)
        XCTAssertEqual(placements.map(\.surfaceID), [id], file: file, line: line)
        let placement = try XCTUnwrap(placements.first { $0.surfaceID == id }, file: file, line: line)
        XCTAssertTrue(placement.visible, file: file, line: line)
        let rect = focus.workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        XCTAssertEqual(placement.frame, .init(x: Int(rect.topLeftX.rounded()), y: Int(rect.topLeftY.rounded()),
            width: Int(rect.width.rounded()), height: Int(rect.height.rounded())), file: file, line: line)
    }

    @discardableResult
    private func connect(_ page: SurfaceID, to controller: BrowserWorkspaceController) -> UUID {
        let connection = UUID()
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [
            .init(surfaceID: page, hostID: page.description, title: "Page", selected: true,
                  hostMinimumSize: .init(width: 160, height: 120))
        ]), epoch: UUID(), connection: connection, protocolVersion: 11)
        return connection
    }
}

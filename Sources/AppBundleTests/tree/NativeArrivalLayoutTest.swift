@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor
final class NativeArrivalLayoutTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.newItemPlacement = .tile
    }

    func testClosedNativeOwnerDoesNotReserveFirstTileForSubsequentArrivals() throws {
        let controller = BrowserWorkspaceController(), workspace = focus.workspace
        let previous = TestWindow.new(id: 9401, parent: workspace.rootTilingContainer)
        controller.usesSurfaceTree = true
        controller.reconcileSharedOrganization()
        _ = controller.plannedSurfaces(in: workspace)
        previous.unregisterSurface()
        previous.unbindFromParent()

        var arrivals: [SurfaceID] = []
        for id: UInt32 in 9402...9404 {
            let window = TestWindow.new(id: id, parent: workspace.rootTilingContainer)
            arrivals.append(window.surfaceID)
            controller.placeOrdinaryNativeArrival(window, in: workspace)
            try assertTilesFillWorkspace(arrivals, controller: controller, workspace: workspace)
        }
        controller.reconcileSharedOrganization()
        try assertTilesFillWorkspace(arrivals, controller: controller, workspace: workspace)
        XCTAssertNil(controller.surfaceTree.workspace(of: previous.surfaceID))
    }

    func testNativeOwnerInAnotherViewDoesNotReserveFirstTile() throws {
        let controller = BrowserWorkspaceController(), workspace = focus.workspace
        let previous = TestWindow.new(id: 9411, parent: workspace.rootTilingContainer)
        controller.usesSurfaceTree = true
        controller.reconcileSharedOrganization()
        _ = controller.plannedSurfaces(in: workspace)
        let other = Workspace.get(byName: "Other view")
        previous.bind(to: other.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)

        let arrival = TestWindow.new(id: 9412, parent: workspace.rootTilingContainer)
        controller.placeOrdinaryNativeArrival(arrival, in: workspace)
        let saved = controller.surfaceTree
        try assertTilesFillWorkspace([arrival.surfaceID], controller: controller, workspace: workspace)
        XCTAssertEqual(controller.surfaceTree, saved, "Rendering must not rewrite saved organization")
        XCTAssertTrue(previous.nodeWorkspace === other)
        controller.reconcileSharedOrganization()
        try assertTilesFillWorkspace([arrival.surfaceID], controller: controller, workspace: workspace)
        XCTAssertEqual(controller.surfaceTree.workspace(of: previous.surfaceID), other.name)
    }

    func testClosedSelectedNativeStackMemberDoesNotHideArrival() throws {
        let controller = BrowserWorkspaceController(), workspace = focus.workspace
        let previous = TestWindow.new(id: 9421, parent: workspace.rootTilingContainer)
        let arrival = TestWindow.new(id: 9422, parent: workspace.rootTilingContainer)
        controller.usesSurfaceTree = true
        controller.reconcileSharedOrganization()
        XCTAssertTrue(controller.surfaceTree.group(arrival.surfaceID, with: previous.surfaceID))
        controller.surfaceTree.select(previous.surfaceID)
        previous.unregisterSurface()
        previous.unbindFromParent()
        try assertTilesFillWorkspace([arrival.surfaceID], controller: controller, workspace: workspace)
    }

    private func assertTilesFillWorkspace(_ ids: [SurfaceID], controller: BrowserWorkspaceController,
                                         workspace: Workspace, file: StaticString = #filePath, line: UInt = #line) throws {
        let placements = controller.plannedSurfaces(in: workspace)
        XCTAssertEqual(placements.map(\.surfaceID), ids, file: file, line: line)
        XCTAssertTrue(placements.allSatisfy(\.visible), file: file, line: line)
        let rect = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        XCTAssertEqual(try XCTUnwrap(placements.first).frame.x, Int(rect.topLeftX.rounded()), file: file, line: line)
        XCTAssertEqual(placements.reduce(0) { $0 + $1.frame.width } +
            max(0, placements.count - 1) * controller.layoutGaps(in: workspace).horizontal,
            Int(rect.width.rounded()), file: file, line: line)
    }
}

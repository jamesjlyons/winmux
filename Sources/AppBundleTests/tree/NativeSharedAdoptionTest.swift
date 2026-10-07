@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor final class NativeSharedAdoptionTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }
    override func tearDown() async throws {
        let controller = BrowserWorkspaceController.shared
        controller.nativeSelectionChanged(nil)
        controller.restorePlacementSnapshot(.init(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        controller.usesSurfaceTree = false
    }

    func testNativeImportImmediatelyUsesSharedGeometryAndSurvivesBindingTreeChanges() throws {
        let controller = BrowserWorkspaceController.shared, workspace = focus.workspace
        let first = TestWindow.new(id: 9301, parent: workspace.rootTilingContainer)
        let second = TestWindow.new(id: 9302, parent: workspace.rootTilingContainer)
        controller.usesSurfaceTree = true
        controller.reconcileSharedOrganization()
        XCTAssertTrue(controller.hasSharedLayout(in: workspace))
        XCTAssertTrue(controller.editOrganization(of: first.surfaceID) { $0.insertIntoStack(first.surfaceID, with: second.surfaceID) })
        let saved = controller.surfaceTree
        workspace.rootTilingContainer.layout = .tabGroup
        workspace.rootTilingContainer.changeOrientation(.v)
        controller.reconcileSharedOrganization()
        XCTAssertEqual(controller.surfaceTree, saved)
        XCTAssertEqual(controller.plannedLayout(in: workspace).stacks.count, 1)
        let snapshot = try XCTUnwrap(controller.capturePlacementSnapshot())
        XCTAssertEqual(snapshot.layoutWorkspaces, Set(snapshot.tree.roots.keys))
    }

    func testNativeArrivalFollowsSharedStackEvenWhenBindingsAreFlat() throws {
        let controller = BrowserWorkspaceController.shared, workspace = focus.workspace
        let first = TestWindow.new(id: 9311, parent: workspace.rootTilingContainer)
        let second = TestWindow.new(id: 9312, parent: workspace.rootTilingContainer)
        var tree = SurfaceTree(); tree.reconcile([first.surfaceID, second.surfaceID], in: workspace.name)
        XCTAssertTrue(tree.group(second.surfaceID, with: first.surfaceID))
        let stack = try XCTUnwrap(tree.stack(containing: first.surfaceID))
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        controller.nativeSelectionChanged(first.surfaceID)
        let arrival = TestWindow.new(id: 9313, parent: workspace.rootTilingContainer)
        controller.placeOrdinaryNativeArrival(arrival, in: workspace)
        XCTAssertEqual(controller.surfaceTree.group(stack)?.surfaces, [first.surfaceID, arrival.surfaceID, second.surfaceID])
        XCTAssertEqual(controller.surfaceTree.activeSurfaces[stack], first.surfaceID)
        controller.reconcileSharedOrganization()
        XCTAssertEqual(controller.surfaceTree.stack(containing: arrival.surfaceID), stack)
        config.newItemPlacement = .tile
        let tile = TestWindow.new(id: 9314, parent: workspace.rootTilingContainer)
        controller.placeOrdinaryNativeArrival(tile, in: workspace)
        XCTAssertEqual(controller.surfaceTree.roots[workspace.name]?.last, .surface(tile.surfaceID))
        XCTAssertNil(controller.surfaceTree.stack(containing: tile.surfaceID))
    }

    func testSharedFrameAndResizeHonorConfiguredInnerGaps() throws {
        let controller = BrowserWorkspaceController.shared, workspace = focus.workspace
        let first = TestWindow.new(id: 9321, parent: workspace.rootTilingContainer)
        let second = TestWindow.new(id: 9322, parent: workspace.rootTilingContainer)
        controller.usesSurfaceTree = true
        controller.reconcileSharedOrganization()
        config.gaps.inner.horizontal = .constant(24)
        config.gaps.inner.vertical = .constant(30)
        let before = controller.plannedSurfaces(in: workspace)
        XCTAssertEqual(before[1].frame.x - (before[0].frame.x + before[0].frame.width), 24)
        XCTAssertTrue(controller.resizeSurface(first.surfaceID, in: workspace, dimension: .width, amount: 50))
        let after = controller.plannedSurfaces(in: workspace)
        XCTAssertEqual(after[0].frame.width, before[0].frame.width + 50)
        XCTAssertEqual(after[1].frame.width, before[1].frame.width - 50)
        XCTAssertEqual(after[1].frame.x - (after[0].frame.x + after[0].frame.width), 24)
        XCTAssertEqual(after[1].surfaceID, second.surfaceID)
    }

    func testHiddenOwnerPolicyIgnoresStaleNativeTabSelection() {
        let controller = BrowserWorkspaceController.shared, workspace = focus.workspace
        let first = TestWindow.new(id: 9331, parent: workspace.rootTilingContainer)
        let second = TestWindow.new(id: 9332, parent: workspace.rootTilingContainer)
        workspace.rootTilingContainer.layout = .tabGroup
        first.markAsMostRecentChild()
        controller.usesSurfaceTree = true
        controller.reconcileSharedOrganization()
        controller.nativeSelectionChanged(second.surfaceID)
        XCTAssertTrue(shouldKeepWindowHiddenForVisibleWorkspaceLayout(first, hiddenSharedSurfaces: [first.surfaceID]))
        XCTAssertFalse(shouldKeepWindowHiddenForVisibleWorkspaceLayout(second, hiddenSharedSurfaces: [first.surfaceID]))
    }
}

@testable import AppBundle
import AppKit
import WorkspaceCore
import XCTest

@MainActor final class BrowserNativeReservationTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testUnresolvedNativeReservationDoesNotOccupyAColumnOrBlockLiveSplit() throws {
        let (controller, page, other, reserved) = fixture()
        let saved = controller.surfaceTree
        let planned = controller.plannedSurfaces(in: focus.workspace)
        XCTAssertEqual(Set(planned.map(\.surfaceID)), [page, other])
        XCTAssertEqual(planned.reduce(0) { $0 + $1.frame.width } + controller.layoutGaps(in: focus.workspace).horizontal,
            Int(focus.workspace.workspaceMonitor.visibleRectPaddedByOuterGaps.width.rounded()))
        XCTAssertEqual(controller.surfaceTree, saved, "Projection must preserve saved reservations")
        XCTAssertTrue(controller.editOrganization(of: page) {
            $0.split(page, beside: other, layout: .vertical, before: true)
        })
        XCTAssertEqual(controller.surfaceTree.workspace(of: reserved), focus.workspace.name)
        XCTAssertNotNil(try XCTUnwrap(controller.capturePlacementSnapshot()).tree.workspace(of: reserved))
        XCTAssertEqual(Set(controller.plannedSurfaces(in: focus.workspace).map(\.surfaceID)), [page, other])
        XCTAssertFalse(controller.editOrganization(of: reserved) { $0.reorder(reserved, earlier: true) })
    }

    func testUnresolvedSelectedStackMemberDoesNotHideItsLivePage() throws {
        let controller = BrowserWorkspaceController(), page = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let reserved = SurfaceID.nativeWindow(UUID())
        var tree = SurfaceTree(); tree.reconcile([reserved, page], in: focus.workspace.name)
        tree.group(page, with: reserved)
        let group = try XCTUnwrap(tree.containingGroup(of: page))
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [focus.workspace.name], selected: reserved, closedBrowserTabs: []))
        connect([page], to: controller)
        let planned = controller.plannedSurfaces(in: focus.workspace)
        XCTAssertEqual(planned.map(\.surfaceID), [page])
        XCTAssertEqual(planned.first?.visible, true)
        XCTAssertEqual(controller.surfaceTree.containingGroup(of: reserved), group)
        XCTAssertEqual(controller.surfaceTree.activeSurfaces[group], reserved)
        XCTAssertEqual(controller.surfaceTree, tree)
    }

    func testEditsCannotDeleteOrMoveUnresolvedReservations() {
        let (controller, page, _, reserved) = fixture()
        let before = controller.surfaceTree
        XCTAssertFalse(controller.editOrganization(of: page) { tree in tree.remove(reserved); return true })
        XCTAssertEqual(controller.surfaceTree, before)
        XCTAssertFalse(controller.editOrganization(of: page) { $0.moveToRoot(reserved, in: "Elsewhere") })
        XCTAssertEqual(controller.surfaceTree, before)
    }

    func testMatchingNativeBindingReclaimsReservationAndLaterClosureIsNotExempt() {
        let (controller, page, other, reserved) = fixture()
        let native = TestWindow.new(id: 8001, parent: focus.workspace.rootTilingContainer)
        XCTAssertTrue(native.restoreSurfaceID(reserved))
        XCTAssertEqual(Set(controller.plannedSurfaces(in: focus.workspace).map(\.surfaceID)), [page, other, reserved])
        native.unbindFromParent()
        let before = controller.surfaceTree
        XCTAssertFalse(controller.editOrganization(of: page) { $0.split(page, beside: other, layout: .vertical, before: false) })
        XCTAssertEqual(controller.surfaceTree, before, "An observed native window cannot revert to a restore placeholder after closing")
    }

    func testUnavailableBrowserIsNotTreatedAsAnUnresolvedNativeReservation() {
        let controller = BrowserWorkspaceController(), page = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let native = TestWindow.new(id: 8002, parent: focus.workspace.rootTilingContainer)
        var tree = SurfaceTree(); tree.reconcile([native.surfaceID, page], in: focus.workspace.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [focus.workspace.name], selected: nil, closedBrowserTabs: []))
        let connection = connect([page], to: controller)
        controller.disconnected(connection)
        XCTAssertEqual(Set(controller.plannedSurfaces(in: focus.workspace).map(\.surfaceID)), [native.surfaceID, page])
        XCTAssertFalse(controller.editOrganization(of: native.surfaceID) { $0.setLayout(containing: native.surfaceID, to: .vertical) })
        XCTAssertEqual(controller.surfaceTree, tree)
    }

    func testResizeChangesVisiblePaneByExactAmountBesideReservation() throws {
        let (controller, page, other, reserved) = fixture()
        let before = controller.plannedSurfaces(in: focus.workspace)
        let pageWidth = try XCTUnwrap(before.first { $0.surfaceID == page }?.frame.width)
        let otherWidth = try XCTUnwrap(before.first { $0.surfaceID == other }?.frame.width)
        XCTAssertTrue(controller.resizeSurface(page, in: focus.workspace, dimension: .width, amount: 40))
        let after = controller.plannedSurfaces(in: focus.workspace)
        XCTAssertEqual(after.first { $0.surfaceID == page }?.frame.width, pageWidth + 40)
        XCTAssertEqual(after.first { $0.surfaceID == other }?.frame.width, otherWidth - 40)
        XCTAssertEqual(controller.surfaceTree.workspace(of: reserved), focus.workspace.name)
    }

    func testReservationAloneDoesNotCreateAResizableNeighbor() {
        let (controller, page, other, reserved) = fixture()
        var tree = controller.surfaceTree
        tree.remove(other)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [focus.workspace.name], selected: nil, closedBrowserTabs: []))
        let before = controller.surfaceTree
        XCTAssertFalse(controller.resizeSurface(page, in: focus.workspace, dimension: .width, amount: 40))
        XCTAssertEqual(controller.surfaceTree, before)
        XCTAssertEqual(controller.surfaceTree.workspace(of: reserved), focus.workspace.name)
        XCTAssertEqual(controller.plannedSurfaces(in: focus.workspace).map(\.surfaceID), [page])
    }

    func testProjectedResizePreservesCollapsedReservedGroupAndMetadata() throws {
        let (controller, page, other, reserved) = fixture()
        var tree = controller.surfaceTree
        tree.group(page, with: reserved, layout: .horizontal)
        let group = try XCTUnwrap(tree.containingGroup(of: page))
        tree.setWeights(["group:" + group.uuidString.lowercased(): 230, reserved.description: 110])
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [focus.workspace.name], selected: nil, closedBrowserTabs: []))
        let before = try XCTUnwrap(controller.plannedSurfaces(in: focus.workspace).first { $0.surfaceID == page })
        XCTAssertTrue(controller.resizeSurface(page, in: focus.workspace, dimension: .width, amount: 40))
        let after = try XCTUnwrap(controller.plannedSurfaces(in: focus.workspace).first { $0.surfaceID == page })
        XCTAssertEqual(after.frame.width, before.frame.width + 40)
        XCTAssertEqual(controller.surfaceTree.roots, tree.roots)
        XCTAssertEqual(controller.surfaceTree.layouts, tree.layouts)
        XCTAssertEqual(controller.surfaceTree.activeSurfaces, tree.activeSurfaces)
        XCTAssertEqual(controller.surfaceTree.weights["group:" + group.uuidString.lowercased()], 230)
        XCTAssertEqual(controller.surfaceTree.weights[reserved.description], 110)
        XCTAssertEqual(controller.surfaceTree.containingGroup(of: reserved), group)
        XCTAssertEqual(Set(controller.plannedSurfaces(in: focus.workspace).map(\.surfaceID)), [page, other])
    }

    private func fixture() -> (BrowserWorkspaceController, SurfaceID, SurfaceID, SurfaceID) {
        let controller = BrowserWorkspaceController(), reserved = SurfaceID.nativeWindow(UUID())
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID()), other = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var tree = SurfaceTree(); tree.reconcile([reserved, page, other], in: focus.workspace.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [focus.workspace.name], selected: nil, closedBrowserTabs: []))
        connect([page, other], to: controller)
        return (controller, page, other, reserved)
    }

    @discardableResult
    private func connect(_ pages: [SurfaceID], to controller: BrowserWorkspaceController) -> UUID {
        let connection = UUID()
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: pages.map {
            .init(surfaceID: $0, hostID: $0.description, title: "Page", selected: true, hostMinimumSize: .init(width: 160, height: 120))
        }), epoch: UUID(), connection: connection, protocolVersion: 4)
        return connection
    }
}

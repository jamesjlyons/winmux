import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceOrganizationChangeTests: XCTestCase {
    let native = SurfaceID.nativeWindow(UUID())
    let page = SurfaceID.browserTab(profile: UUID(), tab: UUID())

    func testMixedGroupTransferProducesOneCompletePlanAndOwnerEffects() throws {
        var tree = SurfaceTree()
        tree.reconcile([native, page], in: "source")
        XCTAssertTrue(tree.group(page, with: native, layout: .horizontal))
        let group = try XCTUnwrap(tree.containingGroup(of: page))
        tree.setWeights([page.description: 2, native.description: 3])
        let change = try XCTUnwrap(tree.preparingOrganizationChange(in: ["source", "destination"], selected: page) {
            $0.moveGroupToRoot(group, in: "destination")
        })

        XCTAssertEqual(tree.workspace(ofGroup: group), "source")
        XCTAssertEqual(change.tree.workspace(ofGroup: group), "destination")
        XCTAssertEqual(change.tree.layouts, tree.layouts)
        XCTAssertEqual(change.tree.weights, tree.weights)
        XCTAssertEqual(change.tree.activeSurfaces[group], page)
        XCTAssertEqual(Set(change.membership.map(\.surfaceID)), [native, page])
        XCTAssertTrue(change.membership.allSatisfy { $0.source == "source" && $0.destination == "destination" })
    }

    func testFailedEditCannotPartlyMoveMembers() {
        var tree = SurfaceTree(); tree.reconcile([native, page], in: "source")
        let before = tree
        XCTAssertNil(tree.preparingOrganizationChange(in: ["source", "destination"]) {
            _ = $0.moveToRoot(page, in: "destination")
            return $0.group(page, with: native)
        })
        XCTAssertEqual(tree, before)
    }

    func testReservationsCanRemainBesideEditsButCannotBeMovedOrRemoved() throws {
        var tree = SurfaceTree(); tree.reconcile([native, page], in: "source")
        let reservation = [native: "source"]
        XCTAssertNotNil(tree.preparingOrganizationChange(in: ["source"], reserving: reservation) {
            $0.group(page, with: native, layout: .vertical)
        })
        XCTAssertNil(tree.preparingOrganizationChange(in: ["source", "destination"], reserving: reservation) {
            $0.moveToRoot(native, in: "destination")
        })
        XCTAssertNil(tree.preparingOrganizationChange(in: ["source"], reserving: reservation) {
            $0.remove(native); return true
        })
    }

    func testOrganizationCannotInventCloseOrMoveUnpreflightedOwners() {
        var tree = SurfaceTree(); tree.reconcile([native, page], in: "source")
        XCTAssertNil(tree.preparingOrganizationChange(in: ["source"]) { $0.remove(page); return true })
        XCTAssertNil(tree.preparingOrganizationChange(in: ["source"]) {
            $0.reconcile([native, page, .nativeWindow(UUID())], in: "source"); return true
        })
        XCTAssertNil(tree.preparingOrganizationChange(in: ["source"]) { $0.moveToRoot(page, in: "elsewhere") })
    }

    func testUnrelatedWorkspaceMetadataCannotChangeBehindIdenticalRoots() throws {
        var tree = SurfaceTree(); tree.reconcile([native, page], in: "unrelated")
        XCTAssertTrue(tree.group(page, with: native, layout: .horizontal))
        XCTAssertNil(tree.preparingOrganizationChange(in: ["source"]) {
            $0.setLayout(containing: page, to: .vertical)
        })
        XCTAssertNil(tree.preparingOrganizationChange(in: ["source"]) {
            $0.setWeights([page.description: 200]); return true
        })
        let unchanged = try XCTUnwrap(tree.preparingOrganizationChange(in: ["source"], selected: native) { _ in true })
        XCTAssertEqual(unchanged.tree, tree)
        XCTAssertTrue(unchanged.membership.isEmpty)
    }
}

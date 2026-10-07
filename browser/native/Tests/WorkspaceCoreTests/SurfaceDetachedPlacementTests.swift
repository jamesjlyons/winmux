import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceDetachedPlacementTests: XCTestCase {
    func testRestoreCollapsedStackPreservesIdentityWeightsAndOtherViews() throws {
        let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let c = SurfaceID.nativeWindow(UUID()), d = SurfaceID.nativeWindow(UUID())
        var tree = SurfaceTree(); tree.reconcile([a, b, c], in: "work")
        XCTAssertTrue(tree.group(a, with: b, layout: .stack))
        let group = try XCTUnwrap(tree.containingGroup(of: a))
        tree.setWeights(["group:" + group.uuidString.lowercased(): 700, c.description: 300])
        let original = tree
        let saved = try XCTUnwrap(tree.detachedPlacement(of: a))
        tree.remove(a)
        tree.reconcile([d], in: "other")
        tree.reconcile([b, c, a], in: "work")
        XCTAssertTrue(tree.restorePlacement(of: a, from: saved))
        XCTAssertEqual(tree.roots["work"], original.roots["work"])
        XCTAssertEqual(tree.layouts[group], .stack)
        XCTAssertEqual(tree.weights["group:" + group.uuidString.lowercased()], 700)
        XCTAssertEqual(tree.roots["other"], [.surface(d)])
        XCTAssertEqual(try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree)), tree)
    }

    func testEditedOrMovedDestinationRejectsOldPlacementAtomically() throws {
        let ids = (0..<3).map { _ in SurfaceID.nativeWindow(UUID()) }
        var original = SurfaceTree(); original.reconcile(ids, in: "work")
        let saved = try XCTUnwrap(original.detachedPlacement(of: ids[1]))
        for change in 0..<4 {
            var tree = original
            tree.remove(ids[1])
            switch change {
            case 0: XCTAssertTrue(tree.reorder(ids[0], earlier: false))
            case 1: tree.setWeights([ids[0].description: 50])
            case 2: tree.reconcile([ids[0], ids[2], .nativeWindow(UUID())], in: "work")
            default: break
            }
            let destination = change == 3 ? "other" : "work"
            tree.reconcile((tree.roots[destination] ?? []).flatMap(\.surfaces) + [ids[1]], in: destination)
            let before = tree
            XCTAssertFalse(tree.restorePlacement(of: ids[1], from: saved))
            XCTAssertEqual(tree, before)
        }
    }
}

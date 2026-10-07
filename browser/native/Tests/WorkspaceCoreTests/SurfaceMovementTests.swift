import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceMovementTests: XCTestCase {
    let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.browserTab(profile: UUID(), tab: UUID())
    let c = SurfaceID.nativeWindow(UUID()), d = SurfaceID.browserTab(profile: UUID(), tab: UUID())

    func testNeighborMoveAndBoundaryPreserveIdentitiesAndWeights() {
        var tree = SurfaceTree(); tree.reconcile([a, b, c], in: "view")
        tree.setWeights([b.description: 3])
        XCTAssertEqual(tree.move(b, toward: .left), .moved)
        XCTAssertEqual(tree.roots["view"]?.flatMap(\.surfaces), [b, a, c])
        XCTAssertEqual(tree.weights[b.description], 3)
        let before = tree
        XCTAssertEqual(tree.move(b, toward: .left), .boundary)
        XCTAssertEqual(tree, before)
        XCTAssertEqual(tree.move(d, toward: .right), .unavailable)
        XCTAssertEqual(tree, before)
    }

    func testStackMovesAsOneUnitAndKeepsItsMetadata() throws {
        var tree = SurfaceTree(); tree.reconcile([a, b, c], in: "view")
        tree.group(b, with: a, layout: .stack)
        let group = try XCTUnwrap(tree.containingGroup(of: b))
        tree.select(b)
        XCTAssertEqual(tree.move(b, toward: .right), .moved)
        XCTAssertEqual(tree.roots["view"], [.surface(c), .group(group, [.surface(a), .surface(b)])])
        XCTAssertEqual(tree.activeSurfaces[group], b)
        XCTAssertEqual(tree.layouts[group], .stack)
    }

    func testLeafEntersAdjacentSplitAndExitsItOnTheOtherAxis() throws {
        var tree = SurfaceTree(); tree.reconcile([a, b, c], in: "view")
        tree.group(c, with: b, layout: .vertical)
        let group = try XCTUnwrap(tree.containingGroup(of: b))
        tree.select(c)
        XCTAssertEqual(tree.move(a, toward: .right), .moved)
        XCTAssertEqual(tree.group(group)?.surfaces, [b, c, a])
        XCTAssertEqual(tree.move(a, toward: .left), .moved)
        XCTAssertEqual(tree.roots["view"], [.surface(a), .group(group, [.surface(b), .surface(c)])])
        XCTAssertEqual(tree.layouts[group], .vertical)
    }

    func testMoveIntoAlignedNestedSplitUsesThatContainer() throws {
        var tree = SurfaceTree(); tree.reconcile([a, b, c, d], in: "view")
        tree.group(d, with: c, layout: .horizontal)
        tree.group(b, with: c, layout: .vertical)
        let horizontal = try XCTUnwrap(tree.outermostGroup(containing: d))
        XCTAssertEqual(tree.move(a, toward: .right), .moved)
        XCTAssertEqual(tree.group(horizontal)?.surfaces.first, a)
        XCTAssertEqual(Set(tree.roots["view"]?.flatMap(\.surfaces) ?? []), [a, b, c, d])
    }

    func testBoundaryContainerUsesRequestedAxisAndRetainsOtherArrangement() throws {
        for direction in [SurfaceDirection.up, .down] {
            var tree = SurfaceTree(); tree.reconcile([a, b, c], in: "view")
            tree.group(c, with: b, layout: .horizontal)
            let retained = try XCTUnwrap(tree.containingGroup(of: b))
            XCTAssertEqual(tree.move(a, toward: direction, creatingContainerAtBoundary: true), .moved)
            let outer = try XCTUnwrap(tree.outermostGroup(containing: a))
            XCTAssertEqual(tree.layouts[outer], .vertical)
            XCTAssertEqual(tree.group(retained)?.surfaces, [b, c])
            let frames = tree.placements(in: "view", frame: .init(x: 0, y: 0, width: 1200, height: 800))
            XCTAssertEqual(frames.first { $0.surfaceID == a }?.frame.y, direction == .up ? 0 : 400)
            XCTAssertNoThrow(try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree)))
        }
    }

    func testSingleItemBoundaryDoesNotCreateAnEmptyContainer() {
        var tree = SurfaceTree(); tree.reconcile([a], in: "view")
        let before = tree
        XCTAssertEqual(tree.move(a, toward: .down, creatingContainerAtBoundary: true), .moved)
        XCTAssertEqual(tree, before)
    }

    func testLeavingAContainerClearsItsOldSelectionEvenWhenItDoesNotCollapse() throws {
        var tree = SurfaceTree(); tree.reconcile([a, b, c, d], in: "view")
        tree.setLayout(containing: c, to: .vertical)
        let group = try XCTUnwrap(tree.containingGroup(of: c))
        tree.select(c)
        XCTAssertEqual(tree.move(c, toward: .left), .moved)
        XCTAssertEqual(tree.group(group)?.surfaces, [a, b, d])
        XCTAssertNil(tree.activeSurfaces[group])
        XCTAssertEqual(try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree)), tree)
    }

    func testRepeatedNestedMovesPreserveEveryOwnerAndValidGeometry() throws {
        let ids = (0..<12).map { _ in SurfaceID.nativeWindow(UUID()) }
        let directions: [SurfaceDirection] = [.left, .up, .right, .down]
        var tree = SurfaceTree(); tree.reconcile(ids, in: "view")
        tree.reconcile([d], in: "other")
        for index in stride(from: 1, to: ids.count, by: 2) {
            tree.group(ids[index], with: ids[index - 1], layout: index % 3 == 0 ? .stack : .vertical)
        }
        var seed: UInt64 = 7123
        for step in 0..<500 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let before = tree
            let surface = ids[Int((seed >> 12) % UInt64(ids.count))]
            let result = tree.move(surface, toward: directions[Int((seed >> 28) % 4)], creatingContainerAtBoundary: step % 3 == 0)
            XCTAssertNotEqual(result, .unavailable)
            if result == .boundary { XCTAssertEqual(tree, before) }
            XCTAssertEqual(tree.roots["other"], [.surface(d)])
            XCTAssertEqual(tree.roots["view"]?.flatMap(\.surfaces).count, ids.count)
            XCTAssertEqual(Set(tree.roots["view"]?.flatMap(\.surfaces) ?? []), Set(ids))
            XCTAssertEqual(try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree)), tree)
            let plan = tree.placements(in: "view", frame: .init(x: -1000, y: 0, width: 1800, height: 1200))
            XCTAssertEqual(Set(plan.map(\.surfaceID)), Set(ids))
            XCTAssertTrue(plan.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })
        }
    }
}

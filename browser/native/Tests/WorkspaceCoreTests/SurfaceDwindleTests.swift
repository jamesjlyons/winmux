import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceDwindleTests: XCTestCase {
    private let a = SurfaceID.nativeWindow(UUID())
    private let b = SurfaceID.browserTab(profile: UUID(), tab: UUID())
    private let c = SurfaceID.nativeWindow(UUID())
    private let d = SurfaceID.browserTab(profile: UUID(), tab: UUID())
    private let landscape = SurfaceFrame(x: 0, y: 0, width: 1200, height: 800)
    private let portrait = SurfaceFrame(x: 0, y: 0, width: 600, height: 800)

    func testAlternatingSplitsStayAtFocusedPaneInsteadOfJoiningAnAncestor() throws {
        var tree = SurfaceTree(); tree.reconcile([a, b], in: "work")
        XCTAssertTrue(tree.insertDwindle(b, beside: a, frame: landscape))
        XCTAssertEqual(tree.roots["work"], [.surface(a), .surface(b)])
        tree.reconcile([a, b, c], in: "work")
        XCTAssertTrue(tree.insertDwindle(c, beside: b, frame: portrait))
        let vertical = try XCTUnwrap(tree.containingGroup(of: b))
        XCTAssertEqual(tree.layouts[vertical], .vertical)
        tree.reconcile([a, b, c, d], in: "work")
        XCTAssertTrue(tree.insertDwindle(d, beside: c, frame: .init(x: 0, y: 0, width: 600, height: 400)))
        let horizontal = try XCTUnwrap(tree.containingGroup(of: c))
        XCTAssertEqual(tree.layouts[horizontal], .horizontal)
        XCTAssertEqual(tree.roots["work"], [.surface(a), .group(vertical, [.surface(b), .group(horizontal, [.surface(c), .surface(d)])])])
        let plan = tree.layout(in: "work", frame: landscape, visible: true)
        XCTAssertEqual(plan.frames[.surface(a)], .init(x: 0, y: 0, width: 600, height: 800))
        XCTAssertEqual(plan.frames[.surface(b)], .init(x: 600, y: 0, width: 600, height: 400))
        XCTAssertEqual(plan.frames[.surface(c)], .init(x: 600, y: 400, width: 300, height: 400))
        XCTAssertEqual(plan.frames[.surface(d)], .init(x: 900, y: 400, width: 300, height: 400))
        XCTAssertEqual(try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree)), tree)
    }

    func testMatchingParentPreservesResizedRatiosAndInsertsAfterFocus() throws {
        var tree = SurfaceTree(); tree.reconcile([a, b, c], in: "work")
        tree.setWeights([a.description: 900, b.description: 300])
        XCTAssertTrue(tree.insertDwindle(c, beside: a, frame: landscape))
        XCTAssertEqual(tree.roots["work"], [.surface(a), .surface(c), .surface(b)])
        XCTAssertEqual(tree.weights[a.description], 900)
        XCTAssertEqual(tree.weights[b.description], 300)
        XCTAssertEqual(tree.weights[c.description], 600)
        XCTAssertTrue(tree.insertDwindle(c, beside: a, frame: landscape))
        XCTAssertEqual(tree.weights[c.description], 600)
    }

    func testNestedSplitPreservesOuterAllocationIncludingImplicitWeights() throws {
        for explicit in [false, true] {
            var tree = SurfaceTree(); tree.reconcile([a, b, c], in: "work")
            tree.setWeights(explicit ? [a.description: 700, b.description: 300] : [a.description: 700])
            XCTAssertTrue(tree.insertDwindle(c, beside: b, frame: portrait))
            let group = try XCTUnwrap(tree.containingGroup(of: b))
            XCTAssertEqual(tree.weights[SurfacePane.group(group).weightKey], explicit ? 300 : 700)
            XCTAssertEqual(tree.weights[b.description], 1)
            XCTAssertEqual(tree.weights[c.description], 1)
            tree.remove(c)
            XCTAssertEqual(tree.weights[b.description], explicit ? 300 : 700)
            XCTAssertEqual(tree.roots["work"], [.surface(a), .surface(b)])
        }
    }

    func testExplicitStackStaysIntactAndKeepsItsSelection() throws {
        var tree = SurfaceTree(); tree.reconcile([a, b, c], in: "work")
        XCTAssertTrue(tree.group(b, with: a, layout: .stack))
        tree.select(b)
        let stack = try XCTUnwrap(tree.stack(containing: b))
        XCTAssertTrue(tree.insertDwindle(c, beside: b, frame: portrait))
        XCTAssertEqual(tree.group(stack)?.surfaces, [a, b])
        XCTAssertEqual(tree.activeSurfaces[stack], b)
        let split = try XCTUnwrap(tree.containingGroup(of: c))
        XCTAssertEqual(tree.group(split), .group(split, [.group(stack, [.surface(a), .surface(b)]), .surface(c)]))
    }

    func testMinimumSizeOverflowDoesNotDestroyTheDwindleTree() throws {
        var tree = SurfaceTree(); tree.reconcile([a, b], in: "work")
        XCTAssertTrue(tree.insertDwindle(b, beside: a, frame: portrait))
        let saved = tree
        let plan = tree.layout(in: "work", frame: .init(x: 0, y: 0, width: 500, height: 500), visible: true,
            minimumSizes: [a: .init(width: 400, height: 400), b: .init(width: 400, height: 400)], selectedSurface: b)
        XCTAssertEqual(plan.surfaces.filter(\.visible).map(\.surfaceID), [b])
        XCTAssertEqual(tree, saved)
        XCTAssertEqual(tree.layout(in: "work", frame: portrait, visible: true).surfaces.filter(\.visible).count, 2)
    }

    func testInvalidInsertionIsAtomic() {
        var tree = SurfaceTree(); tree.reconcile([a, b], in: "work"); tree.reconcile([c], in: "other")
        let saved = tree
        XCTAssertFalse(tree.insertDwindle(c, beside: a, frame: landscape))
        XCTAssertFalse(tree.insertDwindle(a, beside: a, frame: landscape))
        XCTAssertFalse(tree.insertDwindle(b, beside: a, frame: .init(x: 0, y: 0, width: 0, height: 1)))
        XCTAssertEqual(tree, saved)
    }
}

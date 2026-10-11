import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceTiledArrivalTests: XCTestCase {
    private let a = SurfaceID.nativeWindow(UUID())
    private let b = SurfaceID.browserTab(profile: UUID(), tab: UUID())
    private let c = SurfaceID.nativeWindow(UUID())
    private let d = SurfaceID.browserTab(profile: UUID(), tab: UUID())

    func testAdaptiveArrivalUsesNestedSplitAndPreservesResizedSiblings() throws {
        var tree = SurfaceTree(); tree.reconcile([a, b, c, d], in: "work")
        XCTAssertTrue(tree.group(b, with: a, layout: .vertical))
        let split = try XCTUnwrap(tree.containingGroup(of: a))
        tree.setWeights([a.description: 200, b.description: 400,
            SurfacePane.group(split).weightKey: 600, c.description: 900])
        XCTAssertTrue(tree.insertAdaptive(d, beside: a))
        XCTAssertEqual(tree.roots["work"], [.group(split, [.surface(a), .surface(d), .surface(b)]), .surface(c)])
        XCTAssertEqual(tree.weights[d.description], 300)
        XCTAssertEqual(tree.weights[a.description], 200)
        XCTAssertEqual(tree.weights[b.description], 400)
        XCTAssertEqual(tree.weights[SurfacePane.group(split).weightKey], 600)
        XCTAssertEqual(tree.weights[c.description], 900)
        let saved = tree
        XCTAssertTrue(tree.insertAdaptive(d, beside: a))
        XCTAssertEqual(tree, saved, "Inventory and reply may both place the arrival")
        let plan = tree.layout(in: "work", frame: .init(x: 0, y: 0, width: 1500, height: 900), visible: true)
        XCTAssertEqual(plan.frames[.surface(c)], .init(x: 600, y: 0, width: 900, height: 900))
        XCTAssertEqual(plan.frames[.surface(d)], .init(x: 0, y: 200, width: 600, height: 300))
    }

    func testAdaptiveArrivalTilesBesideWholeStackWithoutChangingSelection() throws {
        var tree = SurfaceTree(); tree.reconcile([a, b, c, d], in: "work")
        XCTAssertTrue(tree.group(c, with: a, layout: .vertical))
        let split = try XCTUnwrap(tree.containingGroup(of: a))
        XCTAssertTrue(tree.group(b, with: a, layout: .stack))
        let stack = try XCTUnwrap(tree.stack(containing: b))
        tree.select(b)
        XCTAssertTrue(tree.insertAdaptive(d, beside: b))
        XCTAssertEqual(tree.group(split), .group(split, [.group(stack, [.surface(a), .surface(b)]), .surface(d), .surface(c)]))
        XCTAssertEqual(tree.activeSurfaces[stack], b)
        XCTAssertEqual(tree.layouts[split], .vertical)
    }

    func testAdaptiveRejectsInvalidArrivalsWithoutChangingOrganization() {
        var tree = SurfaceTree(); tree.reconcile([a, b], in: "work"); tree.reconcile([c], in: "other")
        let saved = tree
        XCTAssertFalse(tree.insertAdaptive(a, beside: a))
        XCTAssertFalse(tree.insertAdaptive(c, beside: a))
        XCTAssertFalse(tree.insertAdaptive(d, beside: a))
        XCTAssertEqual(tree, saved)
    }
}

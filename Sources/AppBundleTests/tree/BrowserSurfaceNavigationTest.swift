@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

final class BrowserSurfaceNavigationTest: XCTestCase {
    func testDirectionsFollowTheSameRowAndColumnAcrossGrid() throws {
        let ids = (0..<4).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(ids, in: "work")
        tree.group(ids[2], with: ids[0], layout: .vertical)
        tree.group(ids[3], with: ids[1], layout: .vertical)
        let plan = tree.placements(in: "work", frame: .init(x: -500, y: 40, width: 1200, height: 800))
        let topRight = try XCTUnwrap(plan.first { $0.surfaceID == ids[1] })
        let bottomLeft = try XCTUnwrap(plan.first { $0.surfaceID == ids[2] })
        XCTAssertEqual(browserDirectionalSurface(from: topRight, others: plan, direction: .down, wrapping: false), ids[3])
        XCTAssertEqual(browserDirectionalSurface(from: bottomLeft, others: plan, direction: .right, wrapping: false), ids[3])
        XCTAssertEqual(browserDirectionalSurface(from: topRight, others: plan, direction: .left, wrapping: false), ids[0])
        XCTAssertEqual(browserDirectionalSurface(from: bottomLeft, others: plan, direction: .up, wrapping: false), ids[0])
        XCTAssertEqual(browserDirectionalSurface(from: topRight, others: plan, direction: .right, wrapping: true), ids[0])
        XCTAssertNil(browserDirectionalSurface(from: topRight, others: plan, direction: .up, wrapping: false))
    }

    func testHiddenStackLeavesAreExcludedFromDirectionalTargets() throws {
        let ids = (0..<3).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(ids, in: "work")
        tree.group(ids[2], with: ids[1], layout: .stack)
        let plan = tree.placements(in: "work", frame: .init(x: 0, y: 0, width: 1200, height: 800))
        let source = try XCTUnwrap(plan.first { $0.surfaceID == ids[0] })
        XCTAssertEqual(browserDirectionalSurface(from: source, others: plan, direction: .right, wrapping: false), ids[1])
        tree.select(ids[2])
        let selected = tree.placements(in: "work", frame: .init(x: 0, y: 0, width: 1200, height: 800))
        XCTAssertEqual(browserDirectionalSurface(from: source, others: selected, direction: .right, wrapping: false), ids[2])
    }
}

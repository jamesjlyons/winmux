import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceResizingTests: XCTestCase {
    let frame = SurfaceFrame(x: -500, y: 40, width: 1200, height: 800)

    func testResizeMixedPagesPreservesTotalAndRestoresWeights() throws {
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID()), app = SurfaceID.nativeWindow(UUID())
        var tree = SurfaceTree(); tree.reconcile([page, app], in: "work")
        XCTAssertTrue(tree.resize(page, dimension: .width, amount: 150, frame: frame))
        let placements = tree.placements(in: "work", frame: frame)
        XCTAssertEqual(placements.map(\.frame.width), [750, 450])
        XCTAssertEqual(placements.map(\.frame.x), [-500, 250])
        let restored = try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree))
        XCTAssertEqual(restored.placements(in: "work", frame: frame), placements)
        tree.remove(page)
        XCTAssertTrue(tree.weights.isEmpty == false) // remaining sibling keeps its relative size
        XCTAssertEqual(tree.placements(in: "work", frame: frame).first?.frame.width, 1200)
    }

    func testNewPageGetsNormalShareBesideResizedSiblings() {
        let ids = (0..<3).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(Array(ids.prefix(2)), in: "work")
        XCTAssertTrue(tree.resize(ids[0], dimension: .width, amount: 150, frame: frame))
        tree.reconcile(ids, in: "work")
        XCTAssertEqual(tree.placements(in: "work", frame: frame).map(\.frame.width), [500, 300, 400])
    }

    func testResizeClampsToBothOwnerMinimumsAndRejectsTemporaryStack() {
        let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.nativeWindow(UUID())
        var tree = SurfaceTree(); tree.reconcile([a, b], in: "work")
        let minimums: [SurfaceID: SurfaceMinimumSize] = [a: .init(width: 400, height: 200), b: .init(width: 450, height: 200)]
        XCTAssertTrue(tree.resize(a, dimension: .width, amount: 10000, frame: frame, minimumSizes: minimums))
        XCTAssertEqual(tree.placements(in: "work", frame: frame, minimumSizes: minimums).map(\.frame.width), [750, 450])
        XCTAssertFalse(tree.resize(a, dimension: .width, amount: 1, frame: frame, minimumSizes: minimums))
        XCTAssertTrue(tree.resize(a, dimension: .width, amount: 10, absolute: true, frame: frame, minimumSizes: minimums))
        XCTAssertEqual(tree.placements(in: "work", frame: frame, minimumSizes: minimums).map(\.frame.width), [400, 800])
        XCTAssertFalse(tree.resize(a, dimension: .width, amount: 50, frame: .init(x: 0, y: 0, width: 700, height: 800), minimumSizes: minimums))
    }

    func testNestedSmartAndOppositeResizeTargetMatchingContainer() {
        let ids = (0..<3).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(ids, in: "work")
        tree.group(ids[1], with: ids[0], layout: .vertical)
        XCTAssertTrue(tree.resize(ids[0], dimension: .smart, amount: 100, frame: frame))
        XCTAssertEqual(tree.placements(in: "work", frame: frame).map(\.frame.height), [500, 300, 800])
        XCTAssertTrue(tree.resize(ids[0], dimension: .smartOpposite, amount: 100, frame: frame))
        XCTAssertEqual(tree.placements(in: "work", frame: frame).map(\.frame.width), [700, 700, 500])
    }

    func testFractionalResizeWeightsKeepTheFinalPoint() {
        let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.nativeWindow(UUID())
        var tree = SurfaceTree(); tree.reconcile([a, b], in: "work")
        tree.setWeights([a.description: 1596.072103622685, b.description: 634.7766486683962])
        let placements = tree.placements(in: "work", frame: .init(x: -100, y: 40, width: 1991, height: 800))
        XCTAssertEqual(placements.reduce(0) { $0 + $1.frame.width }, 1991)
        XCTAssertEqual(placements.last.map { $0.frame.x + $0.frame.width }, 1891)
        XCTAssertEqual(placements[0].frame.x + placements[0].frame.width, placements[1].frame.x)
    }

    func testLegacySnapshotAndInvalidWeights() throws {
        let id = SurfaceID.nativeWindow(UUID())
        var tree = SurfaceTree(); tree.reconcile([id], in: "work")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(tree)) as? [String: Any])
        json.removeValue(forKey: "weights")
        XCTAssertEqual(try JSONDecoder().decode(SurfaceTree.self, from: JSONSerialization.data(withJSONObject: json)), tree)
        json["weights"] = [id.description: -1]
        XCTAssertThrowsError(try JSONDecoder().decode(SurfaceTree.self, from: JSONSerialization.data(withJSONObject: json)))
    }
}

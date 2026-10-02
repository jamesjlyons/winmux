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

    func testAdaptiveGridResizesBothAxesAndRestoresWithoutChangingOrganization() throws {
        let ids = (0..<4).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(ids, in: "work")
        let organization = tree.roots
        let minimums = Dictionary(uniqueKeysWithValues: ids.map { ($0, SurfaceMinimumSize(width: 500, height: 300)) })
        let original = tree.placements(in: "work", frame: frame, minimumSizes: minimums)
        XCTAssertTrue(original.allSatisfy(\.visible))
        XCTAssertTrue(tree.resize(ids[0], dimension: .width, amount: 100, frame: frame, minimumSizes: minimums))
        let wider = tree.placements(in: "work", frame: frame, minimumSizes: minimums)
        let target = try XCTUnwrap(wider.first { $0.surfaceID == ids[0] })
        XCTAssertEqual(Double(target.frame.width), 700, accuracy: 1)
        XCTAssertEqual(Double(target.frame.height), 400, accuracy: 1)
        XCTAssertEqual(Double(wider.map(\.frame.width).min()!), 500, accuracy: 1)
        XCTAssertEqual(Double(wider.map(\.frame.width).max()!), 700, accuracy: 1)
        XCTAssertTrue(tree.resize(ids[0], dimension: .height, amount: 80, frame: frame, minimumSizes: minimums))
        let taller = tree.placements(in: "work", frame: frame, minimumSizes: minimums)
        let resized = try XCTUnwrap(taller.first { $0.surfaceID == ids[0] })
        XCTAssertEqual(Double(resized.frame.width), 700, accuracy: 1)
        XCTAssertEqual(Double(resized.frame.height), 480, accuracy: 1)
        XCTAssertEqual(Double(taller.map(\.frame.height).min()!), 320, accuracy: 1)
        XCTAssertEqual(Double(taller.map(\.frame.height).max()!), 480, accuracy: 1)
        XCTAssertTrue(taller.allSatisfy(\.visible))
        XCTAssertEqual(tree.roots, organization)
        XCTAssertFalse(tree.resize(ids[0], dimension: .width, amount: 10000, frame: frame, minimumSizes: minimums))
        let restored = try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree))
        XCTAssertEqual(restored.placements(in: "work", frame: frame, minimumSizes: minimums), taller)
    }

    func testAdaptiveVerticalRootCanResizeHeight() throws {
        let ids = (0..<2).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(ids, in: "work")
        let minimums = Dictionary(uniqueKeysWithValues: ids.map { ($0, SurfaceMinimumSize(width: 800, height: 300)) })
        XCTAssertTrue(tree.resize(ids[0], dimension: .smart, amount: 100, frame: frame, minimumSizes: minimums))
        let plan = tree.placements(in: "work", frame: frame, minimumSizes: minimums)
        XCTAssertEqual(plan.map(\.frame.height), [500, 300])
        XCTAssertEqual(plan.map(\.frame.width), [1200, 1200])
        XCTAssertFalse(tree.resize(ids[0], dimension: .width, amount: 100, frame: frame, minimumSizes: minimums))
    }

    func testPartialGridResizePreservesOtherAxis() {
        let ids = (0..<3).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(ids, in: "work")
        let minimums = Dictionary(uniqueKeysWithValues: ids.map { ($0, SurfaceMinimumSize(width: 500, height: 300)) })
        let original = tree.placements(in: "work", frame: frame, minimumSizes: minimums)
        XCTAssertTrue(tree.resize(ids[0], dimension: .width, amount: 80, frame: frame, minimumSizes: minimums))
        let plan = tree.placements(in: "work", frame: frame, minimumSizes: minimums)
        XCTAssertTrue(plan.allSatisfy(\.visible))
        for (before, after) in zip(original, plan) { XCTAssertEqual(Double(after.frame.height), Double(before.frame.height), accuracy: 1) }
        XCTAssertEqual(Double(plan[0].frame.width), Double(original[0].frame.width + 80), accuracy: 1)
    }

    func testAdaptiveSingleRowOverflowStacksResizeAsCells() {
        let ids = (0..<4).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(ids, in: "work")
        let rect = SurfaceFrame(x: -500, y: 40, width: 1600, height: 600)
        let minimums = Dictionary(uniqueKeysWithValues: ids.map { ($0, SurfaceMinimumSize(width: 500, height: 500)) })
        let original = tree.placements(in: "work", frame: rect, minimumSizes: minimums)
        XCTAssertEqual(original.filter(\.visible).count, 3)
        XCTAssertTrue(tree.resize(ids[0], dimension: .width, amount: 50, frame: rect, minimumSizes: minimums))
        let plan = tree.placements(in: "work", frame: rect, minimumSizes: minimums)
        XCTAssertEqual(plan.filter(\.visible).count, 3)
        XCTAssertEqual(plan.filter(\.visible).reduce(0) { $0 + $1.frame.width }, 1600)
        XCTAssertTrue(plan.allSatisfy { $0.frame.height == 600 })
        XCTAssertEqual(Double(plan[0].frame.width), Double(original[0].frame.width + 50), accuracy: 1)
        XCTAssertEqual(plan.last?.navigationStack, [ids[2], ids[3]])
    }

    func testUnrepresentablePartialGridResizeDoesNotDistortOtherAxis() {
        let ids = (0..<3).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(ids, in: "work")
        let minimums = Dictionary(uniqueKeysWithValues: ids.map { ($0, SurfaceMinimumSize(width: 500, height: 10)) })
        let before = tree
        XCTAssertFalse(tree.resize(ids[2], dimension: .height, amount: 390, frame: frame, minimumSizes: minimums))
        XCTAssertEqual(tree, before)
    }
}

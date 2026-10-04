import Foundation
import XCTest
@testable import WorkspaceCore

final class SelectedRootLayoutTests: XCTestCase {
    let frame = SurfaceFrame(x: 24, y: 32, width: 1200, height: 800)

    func testHiddenRootsRemainInPlanWithoutSyntheticTabs() {
        let ids = (0..<3).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(ids, in: "pins")
        let plan = tree.placements(in: "pins", frame: frame, selectedSurface: ids[1], rootPresentation: .selectedRoot)
        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(plan.filter(\.visible).map(\.surfaceID), [ids[1]])
        XCTAssertTrue(plan.allSatisfy { $0.frame == frame && $0.navigationStack.isEmpty })
        XCTAssertFalse(tree.resize(ids[1], dimension: .width, amount: 100, frame: frame, rootPresentation: .selectedRoot))
        XCTAssertTrue(tree.layouts.isEmpty)
    }

    func testExplicitSplitResizesWithoutHiddenRootSiblings() throws {
        let ids = (0..<3).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(ids, in: "pins")
        XCTAssertTrue(tree.group(ids[1], with: ids[0], layout: .horizontal))
        XCTAssertTrue(tree.resize(ids[0], dimension: .width, amount: 100, frame: frame, rootPresentation: .selectedRoot))
        let plan = tree.placements(in: "pins", frame: frame, selectedSurface: ids[0], rootPresentation: .selectedRoot)
        XCTAssertEqual(plan.filter(\.visible).map(\.frame.width), [700, 500])
        XCTAssertEqual(plan.first { $0.surfaceID == ids[2] }?.frame, frame)
        XCTAssertFalse(try XCTUnwrap(plan.first { $0.surfaceID == ids[2] }).visible)
        let switched = tree.placements(in: "pins", frame: frame, selectedSurface: ids[2], rootPresentation: .selectedRoot)
        XCTAssertEqual(switched.filter(\.visible).map(\.surfaceID), [ids[2]])
        XCTAssertEqual(switched.filter(\.visible).first?.frame, frame)
    }

    func testExplicitStackOnlyListsItsOwnMembersAndSelectionFallback() {
        let ids = (0..<3).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(ids, in: "pins")
        tree.group(ids[1], with: ids[0], layout: .stack)
        let plan = tree.placements(in: "pins", frame: frame, selectedSurface: ids[1], rootPresentation: .selectedRoot)
        XCTAssertEqual(plan.filter(\.visible).map(\.surfaceID), [ids[1]])
        XCTAssertEqual(Set(plan.first { $0.surfaceID == ids[1] }!.navigationStack), Set(ids.prefix(2)))
        tree.remove(ids[1]); tree.remove(ids[0])
        XCTAssertEqual(tree.placements(in: "pins", frame: frame, selectedSurface: ids[1], rootPresentation: .selectedRoot)
            .filter(\.visible).map(\.surfaceID), [ids[2]])
    }

    func testSelectionSnapshotValidatesMembershipAndReadsLegacy() throws {
        let id = SurfaceID.nativeWindow(UUID())
        var tree = SurfaceTree(); tree.reconcile([id], in: "pins")
        var snapshot = SurfaceWorkspaceSnapshot(tree: tree, layoutWorkspaces: ["pins"], selected: nil,
            closedBrowserTabs: [], selectedByWorkspace: ["pins": id])
        let data = try JSONEncoder().encode(snapshot.validated())
        XCTAssertEqual(try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: data).validated(), snapshot)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "selectedByWorkspace")
        XCTAssertTrue(try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self,
            from: JSONSerialization.data(withJSONObject: json)).validated().selectedByWorkspace.isEmpty)
        snapshot.selectedByWorkspace = ["wrong": id]
        XCTAssertThrowsError(try snapshot.validated())
    }

    func testCombiningWholeArrangementsPreservesNestedLayoutsAndWeights() throws {
        let ids = (0..<4).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(Array(ids.prefix(2)), in: "source")
        tree.reconcile(Array(ids.suffix(2)), in: "target")
        XCTAssertTrue(tree.group(ids[1], with: ids[0], layout: .horizontal))
        XCTAssertTrue(tree.group(ids[3], with: ids[2], layout: .stack))
        let source = try XCTUnwrap(tree.containingGroup(of: ids[0]))
        let target = try XCTUnwrap(tree.containingGroup(of: ids[2]))
        tree.setWeights([ids[0].description: 2, ids[1].description: 3])
        tree.select(ids[3])
        XCTAssertTrue(tree.moveGroupToRoot(source, in: "target"))
        XCTAssertTrue(tree.combineRootGroup(source, with: ids[2], layout: .vertical, before: true))
        XCTAssertEqual(tree.roots["target"]?.count, 1)
        XCTAssertEqual(tree.roots["target"]?.first?.surfaces, ids)
        XCTAssertEqual(tree.layouts[source], .horizontal)
        XCTAssertEqual(tree.layouts[target], .stack)
        XCTAssertEqual(tree.activeSurfaces[target], ids[3])
        XCTAssertEqual(tree.weights[ids[0].description], 2)
        XCTAssertEqual(tree.weights[ids[1].description], 3)
        let unchanged = tree
        XCTAssertFalse(tree.combineRootGroup(source, with: ids[0], layout: .stack, before: false))
        XCTAssertEqual(tree, unchanged)
        XCTAssertNoThrow(try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree)))
    }
}

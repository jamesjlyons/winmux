import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceExpansionTests: XCTestCase {
    func testExpansionPreservesSavedArrangementAndExplicitHiddenPlacements() throws {
        let ids = (0..<4).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(ids, in: "one")
        XCTAssertTrue(tree.group(ids[1], with: ids[0]))
        let stack = try XCTUnwrap(tree.stack(containing: ids[0]))
        let saved = tree, frame = SurfaceFrame(x: -900, y: 20, width: 900, height: 700)
        let plan = tree.layout(in: "one", frame: frame, selectedSurface: ids[1],
            stackChrome: .init(headerHeight: 36, sideInset: 3, bottomInset: 3), expandedPane: .group(stack))
        XCTAssertEqual(plan.surfaces.filter(\.visible).map(\.surfaceID), [ids[1]])
        XCTAssertEqual(plan.frames[.surface(ids[1])], frame)
        XCTAssertEqual(plan.surfaces.count, 4)
        XCTAssertEqual(plan.surfaces.first?.navigationStack, Array(ids.prefix(2)))
        XCTAssertTrue(plan.stacks.isEmpty)
        XCTAssertEqual(tree, saved)
        let switched = tree.layout(in: "one", frame: frame, selectedSurface: ids[0], expandedPane: .group(stack))
        XCTAssertEqual(switched.surfaces.filter(\.visible).map(\.surfaceID), [ids[0]])
        let hidden = tree.layout(in: "one", frame: frame, visible: false, expandedPane: .group(stack))
        XCTAssertFalse(hidden.surfaces.contains(where: \.visible))
        let stale = tree.layout(in: "one", frame: frame, expandedPane: .group(UUID()))
        XCTAssertEqual(stale, tree.layout(in: "one", frame: frame))
    }

    func testExpandingStackCanDisplayCompleteNestedSplit() throws {
        let ids = (0..<4).map { _ in SurfaceID.nativeWindow(UUID()) }, stack = UUID(), split = UUID()
        var tree = SurfaceTree(); tree.reconcile(ids, in: "one")
        XCTAssertTrue(tree.importOrganization([.group(stack, [.surface(ids[0]), .group(split,
            [.surface(ids[1]), .surface(ids[2])])]), .surface(ids[3])], in: "one",
            layouts: [stack: .stack, split: .vertical], activeSurfaces: [stack: ids[1]], weights: [:]))
        let frame = SurfaceFrame(x: 0, y: 0, width: 1000, height: 800)
        let plan = tree.layout(in: "one", frame: frame, expandedPane: .group(stack))
        XCTAssertEqual(plan.surfaces.filter(\.visible).map(\.surfaceID), [ids[1], ids[2]])
        XCTAssertEqual(plan.frames[.group(split)], frame)
        XCTAssertEqual(plan.frames[.surface(ids[1])]?.height, 400)
        XCTAssertEqual(plan.frames[.surface(ids[2])]?.y, 400)
        XCTAssertTrue(plan.stacks.isEmpty)
    }
}

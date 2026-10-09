import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceTabBatchTests: XCTestCase {
    let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.nativeWindow(UUID())
    let c = SurfaceID.browserTab(profile: UUID(), tab: UUID()), d = SurfaceID.nativeWindow(UUID())

    func testGroupExtractsExactlySelectedTabsAndPreservesTheirOrder() throws {
        var tree = SurfaceTree(); tree.reconcile([a, b, c, d], in: "work")
        XCTAssertTrue(tree.insertIntoStack(b, with: a)); XCTAssertTrue(tree.insertIntoStack(c, with: a))
        XCTAssertTrue(tree.arrangeTabs([.surface(c), .surface(a)], in: "work", grouping: .stack))
        let selectedGroup = try XCTUnwrap(tree.stack(containing: c))
        XCTAssertEqual(tree.group(selectedGroup)?.surfaces, [c, a])
        XCTAssertEqual(tree.roots["work"]?.prefix(2), [.surface(b), .surface(d)])
        XCTAssertNil(tree.stack(containing: b))
    }

    func testBatchMoveRetainsNestedArrangementsAndInternalSelection() throws {
        var tree = SurfaceTree(); tree.reconcile([a, b, c], in: "one"); tree.reconcile([d], in: "two")
        XCTAssertTrue(tree.group(b, with: a, layout: .vertical))
        let group = try XCTUnwrap(tree.containingGroup(of: a)); tree.select(b)
        tree.setWeights([a.description: 20, b.description: 80])
        XCTAssertTrue(tree.arrangeTabs([.group(group), .surface(d)], in: "destination"))
        XCTAssertEqual(tree.roots["one"], [.surface(c)])
        XCTAssertEqual(tree.roots["two"], [])
        XCTAssertEqual(tree.roots["destination"], [.group(group, [.surface(a), .surface(b)]), .surface(d)])
        XCTAssertEqual(tree.layouts[group], .vertical)
        XCTAssertEqual(tree.activeSurfaces[group], b)
        XCTAssertEqual(tree.weights[a.description], 20)
    }

    func testMissingDuplicateAndOverlappingSelectionsLeaveTreeUntouched() throws {
        var tree = SurfaceTree(); tree.reconcile([a, b, c], in: "one")
        XCTAssertTrue(tree.group(b, with: a))
        let group = try XCTUnwrap(tree.containingGroup(of: a)), before = tree
        for panes: [SurfacePane] in [[.surface(a), .surface(a)], [.group(group), .surface(a)], [.surface(d)], []] {
            XCTAssertFalse(tree.arrangeTabs(panes, in: "two", grouping: .stack))
            XCTAssertEqual(tree, before)
        }
    }

    func testGroupingAcrossViewsLeavesUnselectedMembersInTheirOriginalViews() throws {
        for layout in [SurfaceContainerLayout.stack, .horizontal, .vertical] {
            var tree = SurfaceTree(); tree.reconcile([a, b], in: "one"); tree.reconcile([c, d], in: "two")
            XCTAssertTrue(tree.arrangeTabs([.surface(a), .surface(c)], in: "one", grouping: layout))
            let group = try XCTUnwrap(tree.containingGroup(of: a))
            XCTAssertEqual(tree.group(group)?.surfaces, [a, c])
            XCTAssertEqual(tree.layouts[group], layout)
            XCTAssertEqual(tree.workspace(of: b), "one"); XCTAssertEqual(tree.workspace(of: d), "two")
            XCTAssertEqual(try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree)), tree)
        }
    }
}

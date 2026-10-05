import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceTreeTests: XCTestCase {
    let native = SurfaceID.nativeWindow(UUID())
    let browser = SurfaceID.browserTab(profile: UUID(), tab: UUID())
    let second = SurfaceID.browserTab(profile: UUID(), tab: UUID())

    func testMixedOrderSurvivesOwnerRefreshAndMetadataChanges() {
        var tree = SurfaceTree()
        tree.reconcile([native, browser, second], in: "one")
        XCTAssertTrue(tree.move(browser, before: native))
        tree.reconcile([native, browser, second], in: "one")
        XCTAssertEqual(tree.roots["one"]?.flatMap(\.surfaces), [browser, native, second])
    }

    func testNestedGroupingRemovalAndUngroupKeepExactProfileIdentities() throws {
        var tree = SurfaceTree()
        tree.reconcile([native, browser, second], in: "one")
        XCTAssertTrue(tree.group(browser, with: native))
        XCTAssertTrue(tree.group(second, with: browser))
        XCTAssertEqual(tree.roots["one"]?.flatMap(\.surfaces), [native, browser, second])
        tree.remove(browser)
        let roots = try XCTUnwrap(tree.roots["one"])
        guard case .group(let group, _) = roots.first else { return XCTFail("Mixed group lost") }
        XCTAssertTrue(tree.ungroup(group))
        XCTAssertEqual(tree.roots["one"], [.surface(native), .surface(second)])
    }

    func testDisconnectRetainsOrganizationButAuthoritativeClosePrunesIt() {
        var tree = SurfaceTree()
        tree.reconcile([native, browser], in: "one")
        tree.group(browser, with: native)
        let before = tree
        tree.reconcile([native], in: "one", retaining: [browser])
        XCTAssertEqual(tree, before)
        tree.remove(browser)
        XCTAssertEqual(tree.roots["one"], [.surface(native)])
    }

    func testCrossWorkspaceReconciliationNeverDuplicatesLeaves() {
        var tree = SurfaceTree()
        tree.reconcile([native, browser], in: "one")
        tree.group(browser, with: native)
        tree.reconcile([native], in: "two")
        XCTAssertEqual(tree.workspace(of: native), "two")
        XCTAssertEqual(tree.roots["one"], [.surface(browser)])
        XCTAssertTrue(tree.moveToRoot(browser, in: "two"))
        XCTAssertEqual(tree.roots.values.flatMap { $0.flatMap(\.surfaces) }.count, 2)
    }

    func testUnchangedReconciliationPreservesMetadataAndLaterRemovalStillPrunes() throws {
        var tree = SurfaceTree()
        tree.reconcile([native, browser], in: "one")
        tree.group(browser, with: native)
        let firstGroup = try XCTUnwrap(tree.containingGroup(of: native))
        let other = SurfaceID.nativeWindow(UUID())
        tree.reconcile([second, other], in: "two")
        tree.group(other, with: second, layout: .horizontal)
        let otherGroup = try XCTUnwrap(tree.containingGroup(of: second))
        tree.select(browser)
        tree.setWeights([native.description: 2, browser.description: 3, second.description: 4])
        let before = tree
        for _ in 0..<100 { tree.reconcile([native], in: "one", retaining: [browser]) }
        XCTAssertEqual(tree, before)

        tree.reconcile([native, native], in: "one")
        XCTAssertEqual(tree.roots["one"], [.surface(native)])
        XCTAssertNil(tree.layouts[firstGroup])
        XCTAssertNil(tree.activeSurfaces[firstGroup])
        XCTAssertNil(tree.weights[browser.description])
        XCTAssertEqual(tree.layouts[otherGroup], .horizontal)
        XCTAssertEqual(tree.weights[second.description], 4)
        XCTAssertEqual(tree, try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree)))
        tree.reconcile([], in: "empty")
        XCTAssertEqual(tree.roots["empty"], [])
    }

    func testInvalidOrStaleOperationsAreAtomic() {
        var tree = SurfaceTree()
        tree.reconcile([native, browser], in: "one")
        tree.reconcile([second], in: "two")
        let before = tree
        XCTAssertFalse(tree.group(native, with: native))
        XCTAssertFalse(tree.group(native, with: second))
        XCTAssertFalse(tree.move(browser, before: second))
        XCTAssertFalse(tree.reorder(native, earlier: true))
        XCTAssertFalse(tree.moveToRoot(.nativeWindow(UUID()), in: "two"))
        XCTAssertEqual(tree, before)
    }

    func testReorderStaysInsideContainingGroup() {
        var tree = SurfaceTree()
        tree.reconcile([native, browser, second], in: "one")
        tree.group(browser, with: native)
        XCTAssertFalse(tree.reorder(native, earlier: true))
        XCTAssertTrue(tree.reorder(browser, earlier: true))
        XCTAssertEqual(tree.roots["one"]?.flatMap(\.surfaces), [browser, native, second])
    }

    func testChangingLayoutPreservesNearestGroupIdentityAndRestores() throws {
        var tree = SurfaceTree()
        tree.reconcile([native, browser, second], in: "one")
        XCTAssertTrue(tree.group(browser, with: native))
        let group = try XCTUnwrap(tree.containingGroup(of: browser))
        XCTAssertTrue(tree.setLayout(containing: browser, to: .vertical))
        XCTAssertEqual(tree.containingGroup(of: native), group)
        XCTAssertEqual(tree.layouts[group], .vertical)
        XCTAssertEqual(tree.roots["one"]?.flatMap(\.surfaces), [native, browser, second])
        let restored = try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree))
        XCTAssertEqual(tree, restored)
        let before = tree
        XCTAssertFalse(tree.setLayout(containing: .nativeWindow(UUID()), to: .stack))
        XCTAssertEqual(before, tree)
    }

    func testRootLayoutWrapsExistingNodesWithoutFlatteningNestedGroups() throws {
        var tree = SurfaceTree()
        tree.reconcile([native, browser, second], in: "one")
        tree.group(browser, with: native)
        let original = tree.roots["one"]
        let inner = try XCTUnwrap(tree.containingGroup(of: browser))
        XCTAssertTrue(tree.setLayout(containing: second, to: .vertical))
        let outer = try XCTUnwrap(tree.containingGroup(of: second))
        XCTAssertNotEqual(inner, outer)
        XCTAssertEqual(tree.containingGroup(of: browser), inner)
        XCTAssertEqual(tree.layouts[inner], .stack)
        XCTAssertEqual(tree.layouts[outer], .vertical)
        XCTAssertTrue(tree.ungroup(outer))
        XCTAssertEqual(tree.roots["one"], original)
        tree.remove(second); tree.remove(browser)
        XCTAssertFalse(tree.setLayout(containing: native, to: .stack))
    }
}

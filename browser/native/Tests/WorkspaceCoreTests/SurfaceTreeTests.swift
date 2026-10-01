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
}

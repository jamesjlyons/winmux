import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceSnapshotTests: XCTestCase {
    func testRoundTripPreservesNestedGeometrySelectionAndReferencesOnly() throws {
        let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let c = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var tree = SurfaceTree()
        tree.reconcile([a, b, c], in: "Saved")
        tree.group(b, with: a, layout: .vertical)
        tree.group(c, with: b)
        tree.select(c)
        let snapshot = SurfaceWorkspaceSnapshot(tree: tree, layoutWorkspaces: ["Saved"], selected: c, closedBrowserTabs: [])
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: data).validated(), snapshot)
        XCTAssertEqual(tree.stackItems(containing: c), [b, c])
        XCTAssertNil(tree.stackItems(containing: a))
        tree.remove(c)
        // Removing an active child must not leave invalid saved selection metadata.
        XCTAssertNoThrow(try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree)))
    }

    func testRejectsDuplicateReferencesAndConflictingTombstones() throws {
        let id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let invalid = "{\"roots\":{\"a\":[{\"surface\":\"\(id)\"},{\"surface\":\"\(id)\"}]},\"layouts\":[],\"activeSurfaces\":[]}"
        XCTAssertThrowsError(try JSONDecoder().decode(SurfaceTree.self, from: Data(invalid.utf8)))
        var tree = SurfaceTree(); tree.reconcile([id], in: "a")
        XCTAssertThrowsError(try SurfaceWorkspaceSnapshot(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: [id]).validated())
        XCTAssertThrowsError(try SurfaceWorkspaceSnapshot(tree: tree, layoutWorkspaces: ["missing"], selected: nil, closedBrowserTabs: []).validated())
    }

    func testNativeImportPreservesExistingMixedOrganization() {
        let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.nativeWindow(UUID()), c = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var tree = SurfaceTree(); tree.reconcile([a, b, c], in: "a")
        tree.importStack([a, b], in: "a")
        XCTAssertEqual(tree.stackItems(containing: a), [a, b])
        tree.group(c, with: b)
        let mixed = tree
        tree.importStack([a, b], in: "a")
        XCTAssertEqual(tree, mixed)
    }

    func testSavedViewsRejectDuplicateBindingsAndConflictingOwnership() {
        let native = SurfaceID.nativeWindow(UUID()), member = ViewMember(title: "Editor", surfaceID: native)
        var tree = SurfaceTree()
        tree.reconcile([native], in: "one")
        let first = SavedView(spaceID: "work", workspaceName: "one", title: "One",
            members: [member], layout: [.member(member.id, 1)])
        var second = first
        second.id = UUID(); second.workspaceName = "two"
        second.members = [.init(title: "Other", surfaceID: native)]
        second.layout = [.member(second.members[0].id, 1)]
        XCTAssertThrowsError(try SurfaceWorkspaceSnapshot(tree: tree, layoutWorkspaces: [], selected: nil,
            closedBrowserTabs: [], savedViews: [first, second]).validated())
        XCTAssertThrowsError(try SurfaceWorkspaceSnapshot(tree: tree, layoutWorkspaces: [], selected: nil,
            closedBrowserTabs: [], savedViews: [second]).validated())
        XCTAssertNoThrow(try SurfaceWorkspaceSnapshot(tree: tree, layoutWorkspaces: [], selected: nil,
            closedBrowserTabs: [], savedViews: [first]).validated())
    }
}

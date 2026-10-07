import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceTreeGroupMoveTests: XCTestCase {
    func testMovingNestedSubtreePreservesIdentitySelectionLayoutAndWeights() throws {
        let native = SurfaceID.nativeWindow(UUID())
        let first = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let second = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let remaining = SurfaceID.nativeWindow(UUID())
        let existing = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var tree = SurfaceTree()
        tree.reconcile([native, first, second, remaining], in: "source")
        tree.reconcile([existing], in: "destination")
        XCTAssertTrue(tree.group(first, with: native, layout: .vertical))
        XCTAssertTrue(tree.group(second, with: first))
        let outer = try XCTUnwrap(tree.containingGroup(of: native))
        let inner = try XCTUnwrap(tree.containingGroup(of: second))
        tree.select(second)
        tree.setWeights([native.description: 260, first.description: 140, second.description: 220,
                         "group:" + outer.uuidString.lowercased(): 620,
                         "group:" + inner.uuidString.lowercased(): 360])
        let subtree = try XCTUnwrap(tree.group(outer))
        let beforeLayouts = tree.layouts
        let beforeActive = tree.activeSurfaces
        let beforeWeights = tree.weights
        XCTAssertTrue(tree.moveGroupToRoot(outer, in: "destination"))
        XCTAssertEqual(tree.roots["source"], [.surface(remaining)])
        XCTAssertEqual(tree.roots["destination"], [.surface(existing), subtree])
        XCTAssertEqual(tree.workspace(ofGroup: outer), "destination")
        XCTAssertEqual(tree.group(inner)?.surfaces, [first, second])
        XCTAssertEqual(tree.layouts, beforeLayouts)
        XCTAssertEqual(tree.activeSurfaces, beforeActive)
        XCTAssertEqual(tree.weights, beforeWeights)
        XCTAssertEqual(try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree)), tree)
    }

    func testMoveToFreshRootCollapsesOnlySourceAncestorsAndInvalidMovesAreAtomic() throws {
        let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.nativeWindow(UUID()), c = SurfaceID.nativeWindow(UUID())
        var tree = SurfaceTree(); tree.reconcile([a, b, c], in: "source")
        tree.group(b, with: a)
        let moved = try XCTUnwrap(tree.containingGroup(of: a))
        tree.setLayout(containing: c, to: .horizontal)
        let ancestor = try XCTUnwrap(tree.containingGroup(of: c))
        XCTAssertTrue(tree.moveGroupToRoot(moved, in: "fresh"))
        XCTAssertEqual(tree.roots["source"], [.surface(c)])
        XCTAssertNil(tree.group(ancestor))
        XCTAssertNil(tree.layouts[ancestor])
        XCTAssertEqual(tree.group(moved)?.surfaces, [a, b])
        let before = tree
        XCTAssertFalse(tree.moveGroupToRoot(moved, in: "fresh"))
        XCTAssertFalse(tree.moveGroupToRoot(UUID(), in: "missing"))
        XCTAssertFalse(tree.moveGroupToRoot(moved, in: ""))
        XCTAssertEqual(tree, before)
    }

    func testNativeImportKeepsNestedOrganizationAndRejectsDuplicateIdentity() throws {
        let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.nativeWindow(UUID()), c = SurfaceID.nativeWindow(UUID())
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let outer = UUID(), stack = UUID()
        var tree = SurfaceTree(); tree.reconcile([a, b, c, page], in: "source")
        let nodes: [SurfaceTreeNode] = [.group(outer, [.surface(a), .group(stack, [.surface(b), .surface(c)])])]
        XCTAssertTrue(tree.importOrganization(nodes, in: "source", layouts: [outer: .vertical, stack: .stack],
                                             activeSurfaces: [stack: c], weights: [a.description: 250]))
        XCTAssertEqual(tree.roots["source"], nodes + [.surface(page)])
        XCTAssertEqual(tree.layouts[outer], .vertical)
        XCTAssertEqual(tree.activeSurfaces[stack], c)
        let before = tree
        XCTAssertFalse(tree.importOrganization(nodes, in: "source", layouts: [:], activeSurfaces: [:], weights: [:]))
        XCTAssertEqual(tree, before)
        XCTAssertEqual(try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree)), tree)
    }

    func testLateImportPreservesPrecedingSurfacesAndTheirWeights() {
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.nativeWindow(UUID()), group = UUID()
        var tree = SurfaceTree()
        tree.reconcile([page, a, b], in: "view")
        tree.setWeights([page.description: 300])

        XCTAssertTrue(tree.importOrganization([.group(group, [.surface(a), .surface(b)])], in: "view",
            layouts: [group: .vertical], activeSurfaces: [:], weights: [a.description: 200, page.description: 1]))

        XCTAssertEqual(tree.roots["view"], [.surface(page), .group(group, [.surface(a), .surface(b)])])
        XCTAssertEqual(tree.weights[page.description], 300)
        XCTAssertEqual(tree.weights[a.description], 200)
    }
}

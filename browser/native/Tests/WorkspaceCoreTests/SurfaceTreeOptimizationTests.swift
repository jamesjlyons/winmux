import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceTreeOptimizationTests: XCTestCase {
    func testBulkReconciliationTransfersOnceAndPreservesSurvivorAllocations() throws {
        let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.nativeWindow(UUID())
        let c = SurfaceID.nativeWindow(UUID()), x = SurfaceID.nativeWindow(UUID())
        let retained = SurfaceID.nativeWindow(UUID()), fresh = SurfaceID.nativeWindow(UUID())
        let inner = UUID(), outer = UUID(), unrelated = UUID()
        var tree = SurfaceTree()
        tree.roots = [
            "source": [.group(outer, [.group(inner, [.surface(a), .surface(b)]), .surface(c)])],
            "destination": [.surface(x), .surface(retained)],
            "unrelated": [.group(unrelated, [.surface(.nativeWindow(UUID())), .surface(.nativeWindow(UUID()))])],
        ]
        tree.layouts = [inner: .stack, outer: .horizontal, unrelated: .vertical]
        tree.activeSurfaces = [inner: b, outer: b]
        tree.weights = ["group:" + outer.uuidString.lowercased(): 900,
                        "group:" + inner.uuidString.lowercased(): 600,
                        a.description: 100, b.description: 500, c.description: 300, x.description: 400]
        let other = tree.roots["unrelated"]
        tree.reconcile([x, b, a, fresh, b], in: "destination", retaining: [retained])
        XCTAssertEqual(tree.roots["destination"], [x, retained, b, a, fresh].map(SurfaceTreeNode.surface))
        XCTAssertEqual(tree.roots["source"], [.surface(c)])
        XCTAssertEqual(tree.roots["unrelated"], other)
        XCTAssertEqual(tree.layouts, [unrelated: .vertical])
        XCTAssertTrue(tree.activeSurfaces.isEmpty)
        XCTAssertEqual(tree.weights, [c.description: 900, x.description: 400])
        XCTAssertEqual(tree, try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree)))
        let before = tree
        tree.reconcile([fresh, a, x, b, a], in: "destination", retaining: [retained])
        XCTAssertEqual(tree, before, "An owner refresh must preserve the user's existing order")
    }

    func testProjectionKeepsSavedTreeAndDoesNotInheritCollapsedAllocations() throws {
        let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.nativeWindow(UUID())
        let other = SurfaceID.nativeWindow(UUID()), group = UUID()
        var tree = SurfaceTree()
        tree.roots = ["one": [.group(group, [.surface(a), .surface(b)])], "two": [.surface(other)]]
        tree.layouts[group] = .horizontal
        tree.activeSurfaces[group] = b
        tree.weights = ["group:" + group.uuidString.lowercased(): 800, a.description: 200, b.description: 600, other.description: 300]
        let saved = tree
        XCTAssertEqual(tree.projecting(in: "one", excluding: []), saved)
        XCTAssertEqual(tree.projecting(in: "one", excluding: [other]), saved)
        let projected = tree.projecting(in: "one", excluding: [b])
        XCTAssertEqual(projected.roots, ["one": [.surface(a)], "two": [.surface(other)]])
        XCTAssertEqual(projected.weights, [a.description: 200, other.description: 300])
        XCTAssertTrue(projected.layouts.isEmpty)
        XCTAssertTrue(projected.activeSurfaces.isEmpty)
        XCTAssertEqual(tree, saved)
        XCTAssertEqual(projected, try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(projected)))
        XCTAssertEqual(tree.projecting(in: "one", excluding: [a, b]).roots["one"], [])
    }

    private func assertValidity(_ tree: SurfaceTree, _ expected: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(tree.isValidOrganization, expected, file: file, line: line)
        let decoded = (try? JSONEncoder().encode(tree)).flatMap { try? JSONDecoder().decode(SurfaceTree.self, from: $0) }
        XCTAssertEqual(decoded != nil, expected, file: file, line: line)
        if expected { XCTAssertEqual(decoded, tree, file: file, line: line) }
    }

    func testValidatorRejectsDuplicateIDsMalformedGroupsAndForeignSelections() {
        let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.nativeWindow(UUID()), c = SurfaceID.nativeWindow(UUID())
        let group = UUID()
        var tree = SurfaceTree()
        tree.roots = ["one": [.surface(c), .group(group, [.surface(a), .surface(b)])]]
        tree.layouts[group] = .stack
        tree.activeSurfaces[group] = b
        assertValidity(tree, true)
        var invalid = tree
        invalid.roots["two"] = [.surface(a)]
        assertValidity(invalid, false)
        invalid = tree
        invalid.roots["two"] = [.group(group, [.surface(.nativeWindow(UUID())), .surface(.nativeWindow(UUID()))])]
        assertValidity(invalid, false)
        for children in [[], [.surface(a)]] as [[SurfaceTreeNode]] {
            invalid = tree; invalid.roots["one"] = [.group(group, children)]
            assertValidity(invalid, false)
        }
        for selected in [c, .nativeWindow(UUID())] {
            invalid = tree; invalid.activeSurfaces[group] = selected
            assertValidity(invalid, false)
        }
        // A selection outside the subtree is invalid regardless of traversal order.
        invalid = tree; invalid.roots["one"] = [.group(group, [.surface(a), .surface(b)]), .surface(c)]
        invalid.activeSurfaces[group] = c
        assertValidity(invalid, false)
    }

    func testValidatorChecksWorkspaceNamesAndMetadata() {
        let a = SurfaceID.nativeWindow(UUID())
        var tree = SurfaceTree(); tree.roots["one"] = [.surface(a)]
        for name in ["", String(repeating: "x", count: 4097), String(repeating: "é", count: 2049)] {
            var invalid = tree; invalid.roots[name] = []
            assertValidity(invalid, false)
        }
        tree.roots[String(repeating: "x", count: 4096)] = []
        assertValidity(tree, true)
        var invalid = tree; invalid.layouts[UUID()] = .stack
        assertValidity(invalid, false)
        invalid = tree; invalid.activeSurfaces[UUID()] = a
        assertValidity(invalid, false)
        invalid = tree; invalid.weights["missing"] = 1
        assertValidity(invalid, false)
        for value in [0, 30001, Double.infinity, Double.nan] {
            invalid = tree; invalid.weights[a.description] = value
            assertValidity(invalid, false)
        }
        for value in [1.0, 30000.0] {
            var valid = tree; valid.weights[a.description] = value
            assertValidity(valid, true)
        }
    }

    func testValidatorPreservesDepthAndInventoryLimits() {
        var tree = SurfaceTree()
        var node = SurfaceTreeNode.surface(.nativeWindow(UUID()))
        for _ in 0..<32 { node = .group(UUID(), [node, .surface(.nativeWindow(UUID()))]) }
        tree.roots["deep"] = [node]
        assertValidity(tree, true)
        tree.roots["deep"] = [.group(UUID(), [node, .surface(.nativeWindow(UUID()))])]
        assertValidity(tree, false)
        tree.roots = ["large": (0..<10000).map { _ in .surface(.nativeWindow(UUID())) }]
        assertValidity(tree, true)
        tree.roots["large"]?.append(.surface(.nativeWindow(UUID())))
        assertValidity(tree, false)
        tree.roots = Dictionary(uniqueKeysWithValues: (0..<1024).map { ("view-\($0)", []) })
        assertValidity(tree, true)
        tree.roots["extra"] = []
        assertValidity(tree, false)
    }

    func testInvalidOrganizationEditRemainsAtomic() {
        let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.nativeWindow(UUID())
        var tree = SurfaceTree(); tree.reconcile([a, b], in: "one")
        let before = tree
        XCTAssertNil(tree.preparingOrganizationChange(in: ["one"]) {
            $0.roots["one"] = [.surface(a), .surface(a)]; return true
        })
        XCTAssertEqual(tree, before)
        XCTAssertFalse(tree.arrange([.group(UUID(), [.surface(a)])], in: "one"))
        XCTAssertEqual(tree, before)
    }

    func testMembershipEffectsKeepDeterministicOrderingAndExcludeUnchangedOwners() throws {
        let moved = (0..<4).map { _ in SurfaceID.nativeWindow(UUID()) }
        let stationary = SurfaceID.nativeWindow(UUID())
        var tree = SurfaceTree()
        tree.reconcile(moved + [stationary], in: "source")
        tree.reconcile([.nativeWindow(UUID())], in: "unrelated")
        let change = try XCTUnwrap(tree.preparingOrganizationChange(in: ["source", "destination"], selected: moved[0]) {
            $0.reconcile(moved.reversed(), in: "destination"); return true
        })
        XCTAssertEqual(change.membership.map(\.surfaceID), moved.sorted { $0.description < $1.description })
        XCTAssertTrue(change.membership.allSatisfy { $0.source == "source" && $0.destination == "destination" })
        XCTAssertEqual(change.tree.roots["source"], [.surface(stationary)])
        XCTAssertEqual(change.tree.roots["unrelated"], tree.roots["unrelated"])
    }
}

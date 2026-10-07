import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceArrangementTests: XCTestCase {
    func testArrangementPreservesUnmentionedSubtreesAndMovesCompleteOwnerIdentities() throws {
        let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let c = SurfaceID.nativeWindow(UUID()), d = SurfaceID.nativeWindow(UUID())
        var tree = SurfaceTree(); tree.reconcile([a, b, c], in: "source"); tree.reconcile([d], in: "target")
        XCTAssertTrue(tree.group(b, with: a))
        let oldGroup = try XCTUnwrap(tree.stack(containing: a))
        tree.select(b)
        let newGroup = UUID()
        XCTAssertTrue(tree.arrange([.group(newGroup, [.surface(c), .surface(d)])], in: "target",
            layouts: [newGroup: .vertical], weights: [c.description: 3, d.description: 1]))
        XCTAssertEqual(tree.group(oldGroup)?.surfaces, [a, b])
        XCTAssertEqual(tree.activeSurfaces[oldGroup], b)
        XCTAssertEqual(tree.workspace(of: c), "target")
        XCTAssertEqual(tree.layouts[newGroup], .vertical)
        XCTAssertEqual(try XCTUnwrap(tree.allocation(of: .surface(c))).ratio, 0.75, accuracy: 0.00001)
        XCTAssertEqual(try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree)), tree)
    }

    func testInvalidArrangementDoesNotChangeAnyWorkspace() throws {
        let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.nativeWindow(UUID())
        var tree = SurfaceTree(); tree.reconcile([a, b], in: "source")
        let before = tree, group = UUID()
        XCTAssertFalse(tree.arrange([.surface(a), .surface(a)], in: "target"))
        XCTAssertFalse(tree.arrange([.surface(.nativeWindow(UUID()))], in: "target"))
        XCTAssertFalse(tree.arrange([.group(group, [.surface(a)])], in: "target"))
        XCTAssertFalse(tree.arrange([.group(group, [.surface(a), .surface(b)])], in: "target", weights: [a.description: -1]))
        XCTAssertEqual(tree, before)
    }
}

import Foundation
import XCTest
@testable import WorkspaceCore

final class PinnedViewGroupTests: XCTestCase {
    func testClosedMembersAndReplacementKeepSplitAndStackTemplate() throws {
        let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let c = SurfaceID.nativeWindow(UUID()), pins = [UUID(), UUID(), UUID()]
        var tree = SurfaceTree(); tree.reconcile([a, b, c], in: "Pins")
        tree.group(b, with: a, layout: .stack)
        tree.split(c, beside: a, layout: .horizontal, before: false)
        let root = try XCTUnwrap(tree.roots["Pins"]?.first)
        guard case .group(let id, _) = root else { return XCTFail("Missing split") }
        tree.setWeights([c.description: 3]); tree.select(b)
        let view = PinnedViewGroup(id: id, title: "Research", template: tree, members: [a: pins[0], b: pins[1], c: pins[2]])
        XCTAssertTrue(view.isValid(in: "Pins"))
        let restored = try JSONDecoder().decode(PinnedViewGroup.self, from: JSONEncoder().encode(view))
        XCTAssertEqual(view, restored)
        let closed = view.layout(using: [pins[0]: a, pins[2]: c], in: "Pins")
        XCTAssertEqual(closed.group(id)?.surfaces, [a, c])
        XCTAssertEqual(closed.layouts[id], .horizontal)
        let new = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let opened = view.layout(using: [pins[0]: a, pins[1]: new, pins[2]: c], in: "Elsewhere")
        XCTAssertEqual(opened.group(id)?.surfaces, [a, new, c])
        XCTAssertEqual(opened.layouts, tree.layouts)
        XCTAssertEqual(opened.weights[c.description], 3)
        XCTAssertEqual(opened.activeSurfaces[id], new)
        XCTAssertNil(opened.roots["Pins"])
        XCTAssertEqual(view.template, tree, "A partial live projection never edits the saved arrangement")
    }

    func testSavedGroupRejectsUnknownOrOverlappingPinReferences() throws {
        let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.nativeWindow(UUID())
        var tree = SurfaceTree(); tree.reconcile([a, b], in: "Pins"); tree.group(a, with: b)
        let id = try XCTUnwrap(tree.containingGroup(of: a)), pinA = UUID(), pinB = UUID()
        let view = PinnedViewGroup(id: id, title: "Pair", template: tree, members: [a: pinA, b: pinB])
        var space = SpacePinnedGroup(spaceID: "Space", workspaceName: "Pins", pinOrder: [pinA, pinB]); space.views = [view]
        XCTAssertTrue(space.isValid)
        space.pinOrder = [pinA]; XCTAssertFalse(space.isValid)
        space.pinOrder = [pinA, pinB]; space.views = [view, view]; XCTAssertFalse(space.isValid)
        var invalid = view; invalid.members[b] = pinA; XCTAssertFalse(invalid.isValid(in: "Pins"))
    }

    func testOldSpacePinsDecodeWithoutSavedArrangements() throws {
        let data = try JSONSerialization.data(withJSONObject: ["spaceID": "Space", "workspaceName": "Pins", "pinOrder": []])
        let space = try JSONDecoder().decode(SpacePinnedGroup.self, from: data)
        XCTAssertTrue(space.views.isEmpty); XCTAssertTrue(space.isValid)
    }
}

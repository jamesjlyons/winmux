import AppKit
@testable import AppBundle
import XCTest
import WorkspaceCore

final class WorkspaceSidebarTabReorderTest: XCTestCase {
    func testMovingGapCrossesHalfPitchInBothDirectionsAndReverses() throws {
        let layout = try fiveRows(source: "D")
        XCTAssertEqual(layout.insertionIndex(translation: -18.4), 3)
        XCTAssertEqual(layout.insertionIndex(translation: -18.6), 2)
        XCTAssertEqual(layout.insertionIndex(translation: -55.6), 1)
        XCTAssertEqual(layout.insertionIndex(translation: -55.4), 2)
        XCTAssertEqual(layout.insertionIndex(translation: -18.4), 3)
        XCTAssertEqual(layout.insertionIndex(translation: 18.4), 3)
        XCTAssertEqual(layout.insertionIndex(translation: 18.6), 4)
        XCTAssertEqual(layout.insertionIndex(translation: 18.4), 3)
    }

    func testOnlyCrossedNeighborsMoveOneSlot() throws {
        let layout = try fiveRows(source: "D")
        for (index, expected) in [(2, [0.0, 0, 37, -37, 0]), (1, [0.0, 37, 37, -74, 0]), (4, [0.0, 0, 0, 37, -37])] {
            XCTAssertEqual(layout.items.map { layout.offset(for: $0.name, destinationIndex: index) }, expected)
        }
        XCTAssertEqual(layout.items.map { layout.offset(for: $0.name, destinationIndex: 3) }, [0, 0, 0, 0, 0])
    }

    func testMixedHeightArrangementsLeaveRowsOutsideTheAffectedRangeFixed() throws {
        let layout = try XCTUnwrap(WorkspaceSidebarTabReorderLayout(items: [
            .init(name: "A", frame: .init(x: 0, y: 0, width: 177, height: 34)),
            .init(name: "B", frame: .init(x: 0, y: 37, width: 177, height: 108)),
            .init(name: "C", frame: .init(x: 0, y: 148, width: 177, height: 34)),
            .init(name: "D", frame: .init(x: 0, y: 185, width: 177, height: 34)),
        ], sourceName: "C"))
        XCTAssertEqual(layout.insertionIndex(translation: -55.4), 2)
        XCTAssertEqual(layout.insertionIndex(translation: -55.6), 1)
        XCTAssertEqual(layout.offset(for: "A", destinationIndex: 1), 0)
        XCTAssertEqual(layout.offset(for: "B", destinationIndex: 1), 37)
        XCTAssertEqual(layout.offset(for: "C", destinationIndex: 1), -111)
        XCTAssertEqual(layout.offset(for: "D", destinationIndex: 1), 0)
    }

    func testGrabOffsetAndHorizontalAlignmentSurviveLeavingAndReenteringSidebar() {
        let geometry = WorkspaceSidebarTabDragGeometry(row: .init(x: 8, y: 111, width: 177, height: 34),
            sidebar: .init(x: 0, y: 0, width: 194, height: 950), start: .init(x: 130, y: 118))
        XCTAssertEqual(geometry.frame(at: .init(x: 180, y: 98)), .init(x: 8, y: 91, width: 177, height: 34))
        XCTAssertEqual(geometry.frame(at: .init(x: 194, y: 98)).minX, 8)
        XCTAssertEqual(geometry.frame(at: .init(x: 195, y: 98)).minX, 9)
        XCTAssertEqual(geometry.frame(at: .init(x: 300, y: 98)).minX, 114)
        XCTAssertEqual(geometry.frame(at: .init(x: 190, y: 98)).minX, 8)
        XCTAssertEqual(geometry.splitProgress(at: .init(x: 194, y: 98)), 0)
        XCTAssertEqual(geometry.splitProgress(at: .init(x: 234, y: 98)), 0.5)
        XCTAssertEqual(geometry.splitProgress(at: .init(x: 300, y: 98)), 1)
        XCTAssertEqual(geometry.splitProgress(at: .init(x: 180, y: 98)), 0)
    }

    func testScrollRebasesSlotsWithoutChangingTheirOffsets() throws {
        let layout = try fiveRows(source: "D")
        let scrolled = layout.shifted(by: -74)
        XCTAssertEqual(scrolled.source.frame.minY, layout.source.frame.minY - 74)
        XCTAssertEqual(scrolled.insertionIndex(translation: -19 + 74), 4)
        XCTAssertEqual(scrolled.items.map { scrolled.offset(for: $0.name, destinationIndex: 1) },
            layout.items.map { layout.offset(for: $0.name, destinationIndex: 1) })
    }

    func testExtremeMotionClampsAndInvalidGeometryCannotCreateADrag() throws {
        let layout = try fiveRows(source: "D")
        XCTAssertEqual(layout.insertionIndex(translation: -10_000), 0)
        XCTAssertEqual(layout.insertionIndex(translation: 10_000), 4)
        XCTAssertEqual(layout.insertionIndex(translation: .nan), 3)
        XCTAssertEqual(layout.insertionIndex(translation: .infinity), 3)
        XCTAssertNil(WorkspaceSidebarTabReorderLayout(items: [], sourceName: "D"))
        XCTAssertNil(WorkspaceSidebarTabReorderLayout(items: [layout.source, layout.source], sourceName: "D"))
        let single = try XCTUnwrap(WorkspaceSidebarTabReorderLayout(items: [layout.source], sourceName: "D"))
        XCTAssertEqual(single.insertionIndex(translation: 500), 0)
    }

    private func fiveRows(source: String) throws -> WorkspaceSidebarTabReorderLayout {
        try XCTUnwrap(WorkspaceSidebarTabReorderLayout(items: ["A", "B", "C", "D", "E"].enumerated().map {
            .init(name: $0.element, frame: .init(x: 8, y: CGFloat($0.offset) * 37, width: 177, height: 34))
        }, sourceName: source))
    }

    @MainActor
    func testCommitAdoptsTheProposedOrderWithoutChangingSelectionOrStackIdentity() throws {
        setUpWorkspacesForTests()
        let windows = (0..<5).map { TestWindow.new(id: UInt32(8500 + $0), parent: focus.workspace.rootTilingContainer) }
        var tree = SurfaceTree()
        let ids = windows.map(\.surfaceID)
        tree.reconcile(ids, in: focus.workspace.name)
        for id in ids.dropFirst() { XCTAssertTrue(tree.insertIntoStack(id, with: ids[0])) }
        tree.select(ids[0])
        let group = try XCTUnwrap(tree.containingGroup(of: ids[0]))
        let controller = BrowserWorkspaceController()
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [focus.workspace.name], selected: ids[0], closedBrowserTabs: []))
        XCTAssertEqual(controller.select(ids[0]), .issued)
        let layout = try XCTUnwrap(WorkspaceSidebarTabReorderLayout(items: ids.enumerated().map {
            .init(name: $0.element.description, frame: .init(x: 0, y: CGFloat($0.offset) * 37, width: 177, height: 34))
        }, sourceName: ids[3].description))
        let original = try XCTUnwrap(tree.roots[focus.workspace.name])
        XCTAssertTrue(commitWorkspaceSidebarTabReorder(source: ids[3], workspace: focus.workspace.name, originalNodes: original,
            layout: layout, destinationIndex: 1, reordersWorkspaces: false, controller: controller))
        XCTAssertEqual(controller.surfaceTree.group(group)?.surfaces, [ids[0], ids[3], ids[1], ids[2], ids[4]])
        XCTAssertEqual(controller.surfaceTree.activeSurfaces[group], ids[0])
        XCTAssertEqual(controller.focusCoordinator.target, ids[0])
        let committed = controller.surfaceTree
        XCTAssertFalse(commitWorkspaceSidebarTabReorder(source: ids[3], workspace: focus.workspace.name, originalNodes: original,
            layout: layout, destinationIndex: 4, reordersWorkspaces: false, controller: controller),
            "A stale gesture cannot reorder a tree changed since pickup")
        XCTAssertEqual(controller.surfaceTree, committed)
    }
}

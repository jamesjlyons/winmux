@testable import AppBundle
import AppKit
import SwiftUI
import WorkspaceCore
import XCTest

final class TabMultiSelectionTest: XCTestCase {
    func testShiftRangeCanGrowShrinkAndReverseWithoutMovingAnchor() {
        var selection = TabMultiSelection<Int>()
        let order = [1, 2, 3, 4, 5]
        selection.click(3, order: order, shift: false, command: false)
        selection.click(5, order: order, shift: true, command: false)
        XCTAssertEqual(selection.selected, [3, 4, 5])
        selection.click(4, order: order, shift: true, command: false)
        XCTAssertEqual(selection.selected, [3, 4])
        selection.click(1, order: order, shift: true, command: false)
        XCTAssertEqual(selection.selected, [1, 2, 3])
        XCTAssertEqual(selection.anchor, 3)
    }

    func testCommandToggleAndAdditiveRangeKeepVisualOrder() {
        var selection = TabMultiSelection<Int>()
        let order = [5, 4, 3, 2, 1]
        selection.click(5, order: order, shift: false, command: false)
        selection.click(3, order: order, shift: false, command: true)
        selection.click(1, order: order, shift: true, command: true)
        XCTAssertEqual(selection.targets(for: 3, order: order), [5, 3, 2, 1])
        selection.click(3, order: order, shift: false, command: true)
        XCTAssertEqual(selection.selected, [5, 2, 1])
        selection.click(2, order: order, shift: false, command: true)
        selection.click(1, order: order, shift: false, command: true)
        XCTAssertEqual(selection.selected, [5])
        XCTAssertTrue(selection.isEditingSelection, "The final remaining batch member must stay visibly marked")
    }

    func testRightClickUnselectedTabNeverTargetsPreviousBatchAndPlainClickResets() {
        var selection = TabMultiSelection<Int>()
        selection.click(1, order: [1, 2, 3], shift: false, command: false)
        selection.click(2, order: [1, 2, 3], shift: true, command: false)
        XCTAssertEqual(selection.targets(for: 1, order: [1, 2, 3]), [1, 2])
        XCTAssertEqual(selection.targets(for: 3, order: [1, 2, 3]), [3])
        selection.click(3, order: [1, 2, 3], shift: false, command: false)
        XCTAssertEqual(selection.selected, [3])
        XCTAssertFalse(selection.isEditingSelection)
    }

    func testFilteredOrClosedRowsArePrunedAndHiddenRowsNeverEnterRange() {
        var selection = TabMultiSelection<Int>()
        selection.click(1, order: [1, 3, 5], shift: false, command: false)
        selection.click(5, order: [1, 3, 5], shift: true, command: false)
        XCTAssertEqual(selection.selected, [1, 3, 5])
        selection.prune(to: [3, 5])
        XCTAssertNil(selection.anchor)
        XCTAssertEqual(selection.selected, [3, 5])
        XCTAssertEqual(selection.targets(for: 5, order: [5]), [5])
    }

    func testInitialShiftUsesActiveTabAndMissingAnchorFallsBackToSingle() {
        var selection = TabMultiSelection<Int>()
        selection.click(4, order: [1, 2, 3, 4], shift: true, command: false, fallback: 2)
        XCTAssertEqual(selection.selected, [2, 3, 4])
        XCTAssertEqual(selection.anchor, 2)
        selection.click(7, order: [6, 7], shift: true, command: false, fallback: 2)
        XCTAssertEqual(selection.selected, [7])
    }

    func testInitialCommandClickIncludesActiveTabAndContextClickReplacesSelection() {
        var selection = TabMultiSelection<Int>()
        selection.click(3, order: [1, 2, 3], shift: false, command: true, fallback: 1)
        XCTAssertEqual(selection.selected, [1, 3])
        selection.contextClick(1, order: [1, 2, 3])
        XCTAssertEqual(selection.selected, [1, 3])
        selection.contextClick(2, order: [1, 2, 3])
        XCTAssertEqual(selection.selected, [2])
        XCTAssertEqual(selection.anchor, 2)
    }

    @MainActor
    func testMenuDispatchCapturesOrderedCompletePanes() {
        let panes: [SurfacePane] = [.group(UUID()), .surface(.nativeWindow(UUID()))]
        var sent: [WorkspaceSidebarAction] = []
        let menu = TabBatchMenu(panes: panes, workspaceName: "source", monitorScopeID: "display-two",
            actions: .init(send: { sent.append($0) }))
        menu.send(.group(.stack)); menu.send(.move("destination"))
        menu.send(.newView("work", monitorScopeID: "display-two")); menu.send(.close)
        XCTAssertEqual(sent, [.batchTabs(panes, .group(.stack)), .batchTabs(panes, .move("destination")),
            .batchTabs(panes, .newView("work", monitorScopeID: "display-two")), .batchTabs(panes, .close)])
    }
}

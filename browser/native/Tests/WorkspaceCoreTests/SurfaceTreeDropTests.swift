import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceTreeDropTests: XCTestCase {
    let native = SurfaceID.nativeWindow(UUID())
    let page = SurfaceID.browserTab(profile: UUID(), tab: UUID())
    let other = SurfaceID.browserTab(profile: UUID(), tab: UUID())

    func testDirectionalSplitsAllocateTheRequestedSideAndPreserveIdentities() throws {
        for layout in [SurfaceContainerLayout.horizontal, .vertical] {
            for before in [false, true] {
                var tree = SurfaceTree(); tree.reconcile([native, page], in: "work")
                XCTAssertTrue(tree.split(page, beside: native, layout: layout, before: before))
                XCTAssertEqual(tree.roots["work"]?.flatMap(\.surfaces), before ? [page, native] : [native, page])
                let frames = tree.placements(in: "work", frame: .init(x: -100, y: 30, width: 1000, height: 800))
                let browser = try XCTUnwrap(frames.first { $0.surfaceID == page })
                let app = try XCTUnwrap(frames.first { $0.surfaceID == native })
                XCTAssertTrue(browser.visible && app.visible)
                if layout == .horizontal {
                    XCTAssertEqual(browser.frame.width, 500)
                    XCTAssertEqual(browser.frame.x, before ? -100 : 400)
                    XCTAssertEqual(app.frame.height, 800)
                } else {
                    XCTAssertEqual(browser.frame.height, 400)
                    XCTAssertEqual(browser.frame.y, before ? 30 : 430)
                    XCTAssertEqual(app.frame.width, 1000)
                }
                try assertRoundTrip(tree)
            }
        }
    }

    func testSplitWrapsExistingStackWithoutLosingItsInactivePages() throws {
        var tree = SurfaceTree(); tree.reconcile([native, page, other], in: "work")
        tree.group(page, with: native); tree.select(page)
        let stack = try XCTUnwrap(tree.containingGroup(of: page))
        XCTAssertTrue(tree.split(other, beside: page, layout: .horizontal, before: true))
        XCTAssertEqual(tree.containingGroup(of: page), stack)
        XCTAssertEqual(tree.layouts[stack], .stack)
        let placements = tree.placements(in: "work", frame: .init(x: 0, y: 0, width: 1000, height: 600))
        XCTAssertEqual(Set(placements.filter(\.visible).map(\.surfaceID)), [other, page])
        XCTAssertEqual(placements.first { $0.surfaceID == other }?.frame.width, 500)
        XCTAssertEqual(placements.first { $0.surfaceID == page }?.frame.x, 500)
        try assertRoundTrip(tree)
    }

    func testSplittingTabOutOfItsOwnStackCollapsesOldContainer() throws {
        var tree = SurfaceTree(); tree.reconcile([native, page], in: "work")
        tree.group(page, with: native)
        let old = try XCTUnwrap(tree.containingGroup(of: page))
        XCTAssertTrue(tree.split(page, beside: native, layout: .vertical, before: false))
        XCTAssertNil(tree.layouts[old])
        XCTAssertNil(tree.activeSurfaces[old])
        XCTAssertEqual(tree.roots["work"]?.flatMap(\.surfaces), [native, page])
        try assertRoundTrip(tree)
    }

    func testStackInsertionAppendsWithoutNestedGroupsAndKeepsTwoTabIdentity() throws {
        var tree = SurfaceTree(); tree.reconcile([native, page, other], in: "work")
        tree.group(page, with: native)
        let stack = try XCTUnwrap(tree.containingGroup(of: page))
        XCTAssertTrue(tree.insertIntoStack(native, with: page))
        XCTAssertEqual(tree.containingGroup(of: native), stack)
        XCTAssertEqual(tree.roots["work"]?.flatMap(\.surfaces), [page, native, other])
        XCTAssertTrue(tree.insertIntoStack(other, with: native))
        XCTAssertEqual(tree.roots["work"], [.group(stack, [.surface(page), .surface(native), .surface(other)])])
        XCTAssertEqual(tree.activeSurfaces[stack], other)
        XCTAssertEqual(tree.layouts.count, 1)
        try assertRoundTrip(tree)
    }

    func testSwapKeepsPositionsWeightsAndStackVisibility() throws {
        var tree = SurfaceTree(); tree.reconcile([native, page, other], in: "work")
        tree.group(page, with: native); tree.select(page)
        let stack = try XCTUnwrap(tree.containingGroup(of: page))
        tree.setWeights([page.description: 70, other.description: 190])
        XCTAssertTrue(tree.swapLeaves(page, other))
        XCTAssertEqual(tree.roots["work"], [.group(stack, [.surface(native), .surface(other)]), .surface(page)])
        XCTAssertEqual(tree.activeSurfaces[stack], other)
        XCTAssertEqual(tree.weights[other.description], 70)
        XCTAssertEqual(tree.weights[page.description], 190)
        try assertRoundTrip(tree)
    }

    func testDropOperationsRejectStaleSelfAndCrossWorkspaceWithoutMutation() {
        var tree = SurfaceTree(); tree.reconcile([native, page], in: "work"); tree.reconcile([other], in: "elsewhere")
        let before = tree, missing = SurfaceID.nativeWindow(UUID())
        for target in [native, missing, other] {
            XCTAssertFalse(tree.split(native, beside: target, layout: .horizontal, before: false))
            XCTAssertFalse(tree.insertIntoStack(native, with: target))
            XCTAssertFalse(tree.swapLeaves(native, target))
        }
        XCTAssertFalse(tree.split(page, beside: native, layout: .stack, before: false))
        XCTAssertEqual(tree, before)
    }

    func testMinimumSizeFallbackDoesNotDiscardSavedSplit() throws {
        var tree = SurfaceTree(); tree.reconcile([native, page], in: "work")
        tree.split(page, beside: native, layout: .horizontal, before: true)
        let saved = tree
        let placements = tree.placements(in: "work", frame: .init(x: 0, y: 0, width: 500, height: 400),
            minimumSizes: [native: .init(width: 350, height: 100), page: .init(width: 350, height: 100)], selectedSurface: page)
        XCTAssertEqual(placements.filter(\.visible).map(\.surfaceID), [page])
        XCTAssertEqual(placements.first?.navigationStack, [page, native])
        XCTAssertEqual(tree, saved)
        try assertRoundTrip(tree)
    }

    private func assertRoundTrip(_ tree: SurfaceTree) throws {
        XCTAssertEqual(try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree)), tree)
    }
}

import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceLayoutTests: XCTestCase {
    let native = SurfaceID.nativeWindow(UUID())
    let web = SurfaceID.browserTab(profile: UUID(), tab: UUID())
    let frame = SurfaceFrame(x: -1000, y: 50, width: 1001, height: 700)

    func testMinimumWidthsRedistributeSpaceWithoutOverlap() {
        let secondNative = SurfaceID.nativeWindow(UUID()), secondWeb = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var tree = SurfaceTree(); tree.reconcile([native, secondNative, web, secondWeb], in: "one")
        let rect = SurfaceFrame(x: 240, y: 30, width: 1680, height: 960)
        let constraints: [SurfaceID: SurfaceMinimumSize] = [native: .init(width: 80, height: 80), secondNative: .init(width: 80, height: 80),
            web: .init(width: 500, height: 300), secondWeb: .init(width: 500, height: 300)]
        let plan = tree.placements(in: "one", frame: rect, minimumSizes: constraints)
        XCTAssertEqual(plan.map(\.frame.width), [340, 340, 500, 500])
        XCTAssertEqual(plan.map(\.frame.x), [240, 580, 920, 1420])
        XCTAssertTrue(plan.allSatisfy(\.visible))
        XCTAssertEqual(plan.last!.frame.x + plan.last!.frame.width, 1920)
    }

    func testInsufficientSplitBecomesTemporarySelectedStackAndExpandsAgain() {
        var tree = SurfaceTree(); tree.reconcile([native, web], in: "one")
        tree.group(web, with: native, layout: .horizontal)
        let saved = tree
        let sizes: [SurfaceID: SurfaceMinimumSize] = [native: .init(width: 600, height: 400), web: .init(width: 500, height: 300)]
        let small = tree.placements(in: "one", frame: frame, minimumSizes: sizes, selectedSurface: web)
        XCTAssertEqual(small.filter(\.visible).map(\.surfaceID), [web])
        XCTAssertTrue(small.allSatisfy { $0.frame == frame })
        let large = tree.placements(in: "one", frame: .init(x: -1000, y: 50, width: 1301, height: 700), minimumSizes: sizes, selectedSurface: web)
        XCTAssertEqual(large.map(\.frame.width), [650, 651])
        XCTAssertTrue(large.allSatisfy(\.visible))
        XCTAssertEqual(tree, saved, "Fit fallback must not overwrite the saved split")
    }

    func testRootAndVerticalFallbackKeepSelectedOwnerReachable() {
        var tree = SurfaceTree(); tree.reconcile([native, web], in: "one")
        let sizes: [SurfaceID: SurfaceMinimumSize] = [native: .init(width: 800, height: 500), web: .init(width: 500, height: 400)]
        XCTAssertEqual(tree.placements(in: "one", frame: frame, minimumSizes: sizes, selectedSurface: web).filter(\.visible).map(\.surfaceID), [web])
        tree.group(web, with: native, layout: .vertical)
        XCTAssertEqual(tree.placements(in: "one", frame: frame, minimumSizes: sizes, selectedSurface: native).filter(\.visible).map(\.surfaceID), [native])
        let expanded = tree.placements(in: "one", frame: .init(x: 0, y: 0, width: 1100, height: 1001), minimumSizes: sizes)
        XCTAssertEqual(expanded.map(\.frame.height), [500, 501])
        XCTAssertEqual(expanded.map(\.frame.y), [0, 500])
    }

    func testNestedTemporaryStackOverridesOuterSavedStackForNavigation() throws {
        let sibling = SurfaceID.nativeWindow(UUID())
        var tree = SurfaceTree(); tree.reconcile([native, web, sibling], in: "one")
        tree.group(sibling, with: native, layout: .stack)
        tree.group(web, with: native, layout: .horizontal)
        let saved = tree
        let sizes: [SurfaceID: SurfaceMinimumSize] = [native: .init(width: 600, height: 300), web: .init(width: 600, height: 300)]
        let small = tree.placements(in: "one", frame: frame, minimumSizes: sizes, selectedSurface: native)
        XCTAssertEqual(try XCTUnwrap(small.first { $0.surfaceID == native }).navigationStack, [native, web])
        XCTAssertEqual(try XCTUnwrap(small.first { $0.surfaceID == web }).navigationStack, [native, web])
        XCTAssertEqual(try XCTUnwrap(small.first { $0.surfaceID == sibling }).navigationStack, [native, web, sibling])
        XCTAssertEqual(small.filter(\.visible).map(\.surfaceID), [native])
        let large = tree.placements(in: "one", frame: .init(x: -1000, y: 50, width: 1400, height: 700), minimumSizes: sizes, selectedSurface: native)
        XCTAssertEqual(try XCTUnwrap(large.first { $0.surfaceID == native }).navigationStack, [native, web, sibling])
        XCTAssertEqual(large.filter(\.visible).map(\.surfaceID), [native, web])
        XCTAssertEqual(tree, saved)
    }

    func testIndependentStacksDoNotIncludeOtherVisiblePanes() {
        let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var tree = SurfaceTree(); tree.reconcile([native, web, a, b], in: "one")
        tree.group(web, with: native); tree.group(b, with: a)
        let plan = tree.placements(in: "one", frame: frame)
        XCTAssertEqual(plan.map(\.navigationStack), [[native, web], [native, web], [a, b], [a, b]])
        XCTAssertEqual(plan.filter(\.visible).map(\.surfaceID), [native, a])
    }

    func testRootUsesVerticalSpaceBeforeStackingAndSingleLeafDoesNotInventAStack() {
        var tree = SurfaceTree(); tree.reconcile([native, web], in: "one")
        let sizes: [SurfaceID: SurfaceMinimumSize] = [native: .init(width: 600, height: 300), web: .init(width: 600, height: 300)]
        let vertical = tree.placements(in: "one", frame: frame, minimumSizes: sizes)
        XCTAssertEqual(vertical.map(\.frame.height), [350, 350])
        XCTAssertEqual(vertical.map(\.frame.y), [50, 400])
        XCTAssertTrue(vertical.allSatisfy(\.visible))
        XCTAssertEqual(vertical.map(\.navigationStack), [[], []])
        let cramped = SurfaceFrame(x: -1000, y: 50, width: 1001, height: 500)
        XCTAssertEqual(tree.placements(in: "one", frame: cramped, minimumSizes: sizes).map(\.navigationStack), [[native, web], [native, web]])
        tree.remove(web)
        XCTAssertEqual(tree.placements(in: "one", frame: frame, minimumSizes: sizes).map(\.navigationStack), [[]])
    }

    func testIndependentMixedRootItemsTileInRowsWithoutChangingSavedOrganization() {
        let ids = [native, web, .nativeWindow(UUID()), .browserTab(profile: UUID(), tab: UUID())]
        var tree = SurfaceTree(); tree.reconcile(ids, in: "one")
        let saved = tree
        let rect = SurfaceFrame(x: -1600, y: 40, width: 1600, height: 1000)
        let sizes = Dictionary(uniqueKeysWithValues: ids.map { ($0, SurfaceMinimumSize(width: 500, height: 300)) })
        let plan = tree.placements(in: "one", frame: rect, minimumSizes: sizes, selectedSurface: ids[3])
        XCTAssertEqual(plan.map(\.surfaceID), ids)
        XCTAssertTrue(plan.allSatisfy(\.visible))
        XCTAssertEqual(plan.map(\.frame), [
            .init(x: -1600, y: 40, width: 800, height: 500), .init(x: -800, y: 40, width: 800, height: 500),
            .init(x: -1600, y: 540, width: 800, height: 500), .init(x: -800, y: 540, width: 800, height: 500)])
        XCTAssertTrue(plan.allSatisfy { $0.navigationStack.isEmpty })
        assertValidTiles(plan, within: rect, minimumSizes: sizes)
        XCTAssertEqual(tree, saved)
    }

    func testRootOverflowRetainsSeveralTilesAndReachableSelectedStacks() {
        let ids = (0..<12).map { index in index.isMultiple(of: 2)
            ? SurfaceID.nativeWindow(UUID()) : .browserTab(profile: UUID(), tab: UUID()) }
        var tree = SurfaceTree(); tree.reconcile(ids, in: "one")
        let saved = tree
        let rect = SurfaceFrame(x: 50, y: -1000, width: 1600, height: 1000)
        let sizes = Dictionary(uniqueKeysWithValues: ids.map { ($0, SurfaceMinimumSize(width: 500, height: 400)) })
        for selected in ids {
            let plan = tree.placements(in: "one", frame: rect, minimumSizes: sizes, selectedSurface: selected)
            XCTAssertEqual(plan.count, ids.count)
            XCTAssertEqual(plan.filter(\.visible).count, 6)
            XCTAssertTrue(plan.first { $0.surfaceID == selected }!.visible)
            XCTAssertEqual(plan.map(\.navigationStack), ids.indices.map { index in Array(ids[(index / 2 * 2)..<(index / 2 * 2 + 2)]) })
            assertValidTiles(plan, within: rect, minimumSizes: sizes)
        }
        let large = SurfaceFrame(x: 50, y: -1000, width: 3000, height: 1600)
        XCTAssertTrue(tree.placements(in: "one", frame: large, minimumSizes: sizes).allSatisfy(\.visible))
        for removed in ids.suffix(8) { tree.remove(removed) }
        XCTAssertTrue(tree.placements(in: "one", frame: rect, minimumSizes: sizes).allSatisfy(\.visible))
        XCTAssertEqual(saved.layouts, [:], "Adaptive grids must not persist synthetic groups")
    }

    func testAdaptiveRootKeepsExplicitStacksAndSplitFallbacks() {
        let other = SurfaceID.nativeWindow(UUID()), last = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var tree = SurfaceTree(); tree.reconcile([native, web, other, last], in: "one")
        tree.group(web, with: native)
        let sizes: [SurfaceID: SurfaceMinimumSize] = [native: .init(width: 600, height: 300), web: .init(width: 600, height: 300),
            other: .init(width: 600, height: 300), last: .init(width: 600, height: 300)]
        let saved = tree
        let plan = tree.placements(in: "one", frame: .init(x: 0, y: 0, width: 1200, height: 900), minimumSizes: sizes, selectedSurface: web)
        XCTAssertEqual(plan.filter(\.visible).map(\.surfaceID), [web, other, last])
        XCTAssertEqual(plan.first { $0.surfaceID == native }?.navigationStack, [native, web])
        XCTAssertEqual(plan.first { $0.surfaceID == web }?.navigationStack, [native, web])
        XCTAssertEqual(tree, saved)
    }

    func testRootOverflowRetainsOtherCellsSelectionsAsFocusMoves() {
        let ids = (0..<12).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(ids, in: "one")
        let saved = tree
        let rect = SurfaceFrame(x: 0, y: 0, width: 1600, height: 1000)
        let sizes = Dictionary(uniqueKeysWithValues: ids.map { ($0, SurfaceMinimumSize(width: 500, height: 400)) })
        var recent: [SurfaceID] = []
        for selected in [ids[1], ids[3], ids[5]] {
            recent.insert(selected, at: 0)
            let plan = tree.placements(in: "one", frame: rect, minimumSizes: sizes,
                                       selectedSurface: selected, recentSelections: recent)
            for remembered in recent { XCTAssertTrue(plan.first { $0.surfaceID == remembered }!.visible) }
            XCTAssertEqual(plan.filter(\.visible).count, 6)
        }
        XCTAssertEqual(tree, saved)
    }

    func testRememberedOverflowMemberDoesNotOverrideExplicitStackSelection() {
        let ids = (0..<9).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(ids, in: "one")
        tree.group(ids[1], with: ids[0]); tree.select(ids[1])
        let saved = tree
        let sizes = Dictionary(uniqueKeysWithValues: ids.map { ($0, SurfaceMinimumSize(width: 500, height: 400)) })
        let plan = tree.placements(in: "one", frame: .init(x: 0, y: 0, width: 1100, height: 900),
                                   minimumSizes: sizes, selectedSurface: ids.last, recentSelections: [ids[0]])
        XCTAssertTrue(plan.first { $0.surfaceID == ids[1] }!.visible)
        XCTAssertFalse(plan.first { $0.surfaceID == ids[0] }!.visible)
        XCTAssertEqual(tree, saved)
    }

    func testLargeRootInventoryUsesBoundedDeterministicPlanning() {
        let ids = (0..<512).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(ids, in: "one")
        let sizes = Dictionary(uniqueKeysWithValues: ids.map { ($0, SurfaceMinimumSize(width: 500, height: 400)) })
        let rect = SurfaceFrame(x: 0, y: 0, width: 1600, height: 1000)
        let first = tree.placements(in: "one", frame: rect, minimumSizes: sizes, selectedSurface: ids.last)
        XCTAssertEqual(first, tree.placements(in: "one", frame: rect, minimumSizes: sizes, selectedSurface: ids.last))
        XCTAssertEqual(first.count, ids.count)
        XCTAssertEqual(first.filter(\.visible).count, 6)
        XCTAssertTrue(first.last!.visible)
        XCTAssertEqual(Set(first.flatMap(\.navigationStack)), Set(ids))
        assertValidTiles(first, within: rect, minimumSizes: sizes)
    }

    func testAllocationsStayBoundedAcrossDifferentCapacities() {
        let ids = (0..<7).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(ids, in: "one")
        let minima = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, SurfaceMinimumSize(width: 40 + $0.offset * 70, height: 100)) })
        for width in stride(from: 461, through: 2801, by: 39) {
            let plan = tree.placements(in: "one", frame: .init(x: -800, y: 10, width: width, height: 600), minimumSizes: minima, selectedSurface: ids[5])
            let shown = plan.filter(\.visible)
            assertValidTiles(plan, within: .init(x: -800, y: 10, width: width, height: 600), minimumSizes: minima)
            XCTAssertTrue(shown.contains { $0.surfaceID == ids[5] })
            if width >= minima.values.reduce(0, { $0 + $1.width }) {
                XCTAssertEqual(shown.reduce(0) { $0 + $1.frame.width }, width)
                for index in shown.indices.dropFirst() {
                    XCTAssertEqual(shown[index - 1].frame.x + shown[index - 1].frame.width, shown[index].frame.x)
                }
            }
        }
    }

    private func assertValidTiles(_ plan: [SurfacePlacement], within frame: SurfaceFrame,
                                  minimumSizes: [SurfaceID: SurfaceMinimumSize], file: StaticString = #filePath, line: UInt = #line) {
        let visible = plan.filter(\.visible)
        for placement in visible {
            let minimum = minimumSizes[placement.surfaceID]!
            XCTAssertGreaterThanOrEqual(placement.frame.width, minimum.width, file: file, line: line)
            XCTAssertGreaterThanOrEqual(placement.frame.height, minimum.height, file: file, line: line)
            XCTAssertGreaterThanOrEqual(placement.frame.x, frame.x, file: file, line: line)
            XCTAssertGreaterThanOrEqual(placement.frame.y, frame.y, file: file, line: line)
            XCTAssertLessThanOrEqual(placement.frame.x + placement.frame.width, frame.x + frame.width, file: file, line: line)
            XCTAssertLessThanOrEqual(placement.frame.y + placement.frame.height, frame.y + frame.height, file: file, line: line)
        }
        for (index, first) in visible.enumerated() {
            for second in visible.dropFirst(index + 1) {
                let a = first.frame, b = second.frame
                XCTAssertTrue(a.x + a.width <= b.x || b.x + b.width <= a.x || a.y + a.height <= b.y || b.y + b.height <= a.y,
                              "Visible tiles overlap", file: file, line: line)
            }
        }
    }

    func testInvalidOwnerMinimumRejectsWholeInventoryRevision() {
        var inventory = BrowserInventory()
        XCTAssertFalse(inventory.apply(.init(revision: 1, full: true, tabs: [.init(surfaceID: web, hostID: "test", title: "", selected: true,
            hostMinimumSize: .init(width: 0, height: 500))])))
        XCTAssertEqual(inventory.revision, 0)
        XCTAssertTrue(inventory.apply(.init(revision: 1, full: true, tabs: [.init(surfaceID: web, hostID: "test", title: "", selected: true,
            hostMinimumSize: .init(width: 500, height: 300))])))
    }

    func testSplitUsesEveryPointAndStackSelectionHidesOtherOwner() {
        var tree = SurfaceTree()
        tree.reconcile([native, web], in: "one")
        XCTAssertTrue(tree.group(web, with: native, layout: .horizontal))
        let split = tree.placements(in: "one", frame: frame)
        XCTAssertEqual(split.map(\.frame.width), [500, 501])
        XCTAssertEqual(split.map(\.frame.x), [-1000, -500])
        XCTAssertTrue(split.allSatisfy(\.visible))
        guard case .group(let group, _) = tree.roots["one"]?.first else { return XCTFail() }
        tree.ungroup(group)
        tree.group(web, with: native)
        tree.select(web)
        let stack = tree.placements(in: "one", frame: frame)
        XCTAssertEqual(stack.filter(\.visible).map(\.surfaceID), [web])
        XCTAssertEqual(stack[0].containerID, stack[1].containerID)
        XCTAssertEqual(stack.map(\.frame), [frame, frame])
        XCTAssertTrue(tree.placements(in: "one", frame: frame, visible: false).allSatisfy { !$0.visible })
        tree.remove(web)
        XCTAssertTrue(tree.activeSurfaces.isEmpty)
        XCTAssertTrue(tree.layouts.isEmpty)
    }

    func testVerticalNestedSplitAndInvalidFrame() {
        let other = SurfaceID.nativeWindow(UUID())
        var tree = SurfaceTree()
        tree.reconcile([native, web, other], in: "one")
        tree.group(web, with: native, layout: .vertical)
        tree.group(other, with: native)
        tree.select(other)
        let plan = tree.placements(in: "one", frame: frame)
        XCTAssertEqual(plan.filter(\.visible).map(\.surfaceID), [other, web])
        XCTAssertEqual(plan.first { $0.surfaceID == web }?.frame.y, 400)
        XCTAssertTrue(tree.placements(in: "one", frame: .init(x: 0, y: 0, width: 0, height: 1)).isEmpty)
    }

    @MainActor func testLayoutCoalescesAndRejectsReplyFromPreviousEpoch() {
        var requests: [BrowserLayoutRequest] = []
        var replies: [@MainActor (BrowserActionReply) -> Void] = []
        let session = BrowserSurfaceSession(sendLayout: { request, reply in requests.append(request); replies.append(reply) }, send: { _, _ in })
        session.supportsLayout = true
        let epoch = UUID()
        session.connect(epoch: epoch)
        XCTAssertTrue(session.reconcile(.init(revision: 1, full: true, tabs: []), epoch: epoch))
        let a = BrowserHostPlacement(containerID: UUID(), surfaces: [web], selected: web, frame: frame, visible: true)
        let b = BrowserHostPlacement(containerID: a.containerID, surfaces: [web], selected: nil, frame: frame, visible: false)
        var completed: [Bool] = []
        session.requestLayout([a]) { _ in completed.append(true) }
        session.requestLayout([b]) { _ in completed.append(false) }
        XCTAssertEqual(requests.count, 1)
        replies[0](.issued)
        XCTAssertTrue(completed.isEmpty)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].hosts, [b])
        session.disconnect(epoch: epoch)
        session.connect(epoch: UUID())
        replies[1](.issued)
        XCTAssertTrue(completed.isEmpty)
    }
}

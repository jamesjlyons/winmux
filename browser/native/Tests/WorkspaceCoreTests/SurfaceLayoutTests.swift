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

    func testAllocationsStayBoundedAcrossDifferentCapacities() {
        let ids = (0..<7).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(ids, in: "one")
        let minima = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, SurfaceMinimumSize(width: 40 + $0.offset * 70, height: 100)) })
        for width in stride(from: 461, through: 2801, by: 39) {
            let plan = tree.placements(in: "one", frame: .init(x: -800, y: 10, width: width, height: 600), minimumSizes: minima, selectedSurface: ids[5])
            let shown = plan.filter(\.visible)
            XCTAssertEqual(shown.reduce(0) { $0 + $1.frame.width }, width)
            for placement in shown {
                XCTAssertGreaterThanOrEqual(placement.frame.width, minima[placement.surfaceID]!.width)
                XCTAssertGreaterThanOrEqual(placement.frame.x, -800)
                XCTAssertLessThanOrEqual(placement.frame.x + placement.frame.width, -800 + width)
            }
            for index in shown.indices.dropFirst() {
                XCTAssertEqual(shown[index - 1].frame.x + shown[index - 1].frame.width, shown[index].frame.x)
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

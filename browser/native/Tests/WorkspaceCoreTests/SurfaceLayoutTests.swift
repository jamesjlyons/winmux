import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceLayoutTests: XCTestCase {
    let native = SurfaceID.nativeWindow(UUID())
    let web = SurfaceID.browserTab(profile: UUID(), tab: UUID())
    let frame = SurfaceFrame(x: -1000, y: 50, width: 1001, height: 700)

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

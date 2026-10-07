import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceStackChromeTests: XCTestCase {
    let frame = SurfaceFrame(x: -1000, y: 40, width: 1200, height: 800)
    let chrome = SurfaceStackChrome(headerHeight: 36, sideInset: 3, bottomInset: 3)
    let ids = (0..<5).map { _ in SurfaceID.nativeWindow(UUID()) }

    func testOnlyExplicitStacksReserveChromeAndKeepSavedTreeUnchanged() throws {
        var tree = SurfaceTree(); tree.reconcile(Array(ids.prefix(3)), in: "one")
        XCTAssertTrue(tree.group(ids[1], with: ids[0]))
        let before = tree
        let group = try XCTUnwrap(tree.stack(containing: ids[0]))
        let plan = tree.layout(in: "one", frame: frame, stackChrome: chrome)
        XCTAssertEqual(plan.stacks.count, 1)
        XCTAssertEqual(plan.stacks[0].groupID, group)
        XCTAssertEqual(plan.stacks[0].headerFrame, .init(x: -1000, y: 40, width: 600, height: 36))
        XCTAssertEqual(plan.frames[.group(group)], .init(x: -1000, y: 40, width: 600, height: 800))
        XCTAssertEqual(plan.surfaces[0].frame, .init(x: -997, y: 76, width: 594, height: 761))
        XCTAssertEqual(plan.surfaces[0].frame, plan.surfaces[1].frame)
        XCTAssertEqual(plan.surfaces[2].frame, .init(x: -400, y: 40, width: 600, height: 800))
        XCTAssertEqual(tree, before)
        XCTAssertTrue(tree.layout(in: "one", frame: frame).stacks.isEmpty)
        tree.remove(ids[1])
        XCTAssertTrue(tree.layout(in: "one", frame: frame, stackChrome: chrome).stacks.isEmpty)
        let minima = Dictionary(uniqueKeysWithValues: [ids[0], ids[2]].map { ($0, SurfaceMinimumSize(width: 1200, height: 800)) })
        let overflow = tree.layout(in: "one", frame: frame, minimumSizes: minima, stackChrome: chrome)
        XCTAssertTrue(overflow.stacks.isEmpty)
        XCTAssertEqual(overflow.surfaces.filter(\.visible).count, 1)
        XCTAssertEqual(overflow.surfaces.first?.frame, frame)
    }

    func testNestedHeadersFollowSelectedPaneAndClampTinyViewports() throws {
        let outer = UUID(), inner = UUID(), split = UUID()
        var tree = SurfaceTree(); tree.reconcile(ids, in: "one")
        XCTAssertTrue(tree.importOrganization([.group(outer, [.surface(ids[0]),
            .group(split, [.group(inner, [.surface(ids[1]), .surface(ids[2])]), .surface(ids[3])])]), .surface(ids[4])],
            in: "one", layouts: [outer: .stack, inner: .stack, split: .horizontal],
            activeSurfaces: [outer: ids[0], inner: ids[2]], weights: [:]))
        var plan = tree.layout(in: "one", frame: frame, stackChrome: chrome)
        XCTAssertEqual(plan.stacks.filter(\.visible).map(\.groupID), [outer])
        tree.select(ids[2])
        plan = tree.layout(in: "one", frame: frame, stackChrome: chrome)
        XCTAssertEqual(plan.stacks.filter(\.visible).map(\.groupID), [outer, inner])
        XCTAssertEqual(plan.stacks[0].selected, .group(split))
        XCTAssertEqual(plan.stacks[1].frame.y, frame.y + 36)
        XCTAssertEqual(plan.surfaces.first(where: { $0.surfaceID == ids[2] })?.frame.y, frame.y + 72)
        let tiny = tree.layout(in: "one", frame: .init(x: 0, y: 0, width: 2, height: 2), stackChrome: chrome)
        XCTAssertTrue(tiny.surfaces.allSatisfy { $0.frame.isValid })
        XCTAssertTrue(tiny.stacks.allSatisfy { $0.headerFrame.isValid })
    }

    func testResizeAccountsForCompleteStackAllocationAndOwnerMinimums() throws {
        var tree = SurfaceTree(); tree.reconcile(Array(ids.prefix(4)), in: "one")
        let stack = UUID(), split = UUID()
        XCTAssertTrue(tree.importOrganization([.group(split, [.surface(ids[0]),
            .group(stack, [.surface(ids[1]), .surface(ids[2])]), .surface(ids[3])])], in: "one",
            layouts: [split: .vertical, stack: .stack], activeSurfaces: [stack: ids[2]], weights: [:]))
        let minima = Dictionary(uniqueKeysWithValues: ids.map { ($0, SurfaceMinimumSize(width: 100, height: 100)) })
        let before = tree.layout(in: "one", frame: frame, minimumSizes: minima, stackChrome: chrome)
        XCTAssertTrue(tree.resize(ids[2], dimension: .height, amount: 80, frame: frame,
            minimumSizes: minima, stackChrome: chrome, edge: .up))
        let after = tree.layout(in: "one", frame: frame, minimumSizes: minima, stackChrome: chrome)
        XCTAssertEqual(after.surfaces[0].frame.height, before.surfaces[0].frame.height - 80)
        XCTAssertEqual(after.surfaces[2].frame.height, before.surfaces[2].frame.height + 80)
        XCTAssertEqual(after.surfaces[3].frame, before.surfaces[3].frame)
        XCTAssertEqual(after.stacks[0].headerFrame.height, 36)
        XCTAssertTrue(tree.resize(ids[2], dimension: .height, amount: -1000, frame: frame,
            minimumSizes: minima, stackChrome: chrome, edge: .down))
        let clamped = tree.layout(in: "one", frame: frame, minimumSizes: minima, stackChrome: chrome)
        XCTAssertEqual(clamped.surfaces[2].frame.height, 100)
        XCTAssertEqual(clamped.frames[.group(stack)]?.height, 139)
        XCTAssertEqual(tree.activeSurfaces[stack], ids[2])
    }

    func testTabReorderDetachAndJoinKeepCompleteNestedPane() throws {
        var tree = SurfaceTree(); tree.reconcile(Array(ids.prefix(4)), in: "one")
        let stack = UUID(), split = UUID()
        let nested = SurfaceTreeNode.group(split, [.surface(ids[1]), .surface(ids[2])])
        XCTAssertTrue(tree.importOrganization([.group(stack, [.surface(ids[0]), nested]), .surface(ids[3])], in: "one",
            layouts: [stack: .stack, split: .horizontal], activeSurfaces: [stack: ids[2], split: ids[2]], weights: [:]))
        XCTAssertTrue(tree.reorder(.group(split), inStack: stack, toIndex: 0))
        XCTAssertEqual(tree.group(stack), .group(stack, [nested, .surface(ids[0])]))
        XCTAssertEqual(tree.activeSurfaces[stack], ids[2])
        XCTAssertTrue(tree.separate(.group(split)))
        XCTAssertNil(tree.group(stack))
        XCTAssertEqual(tree.group(split), nested)
        XCTAssertEqual(tree.layouts[split], .horizontal)
        XCTAssertTrue(tree.insertIntoStack(.group(split), with: ids[3]))
        let next = try XCTUnwrap(tree.stack(containing: ids[3]))
        XCTAssertEqual(tree.group(next), .group(next, [.surface(ids[3]), nested]))
        let before = tree
        XCTAssertFalse(tree.insertIntoStack(.group(next), with: ids[2]))
        XCTAssertEqual(tree, before)
        XCTAssertEqual(try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree)), tree)
    }

    func testAdaptiveGridResizeUsesFullStackFrameRatherThanInsetContent() throws {
        let members = (0..<7).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(members, in: "one")
        XCTAssertTrue(tree.group(members[1], with: members[0]))
        let stack = try XCTUnwrap(tree.stack(containing: members[0]))
        let minima = Dictionary(uniqueKeysWithValues: members.map { ($0, SurfaceMinimumSize(width: 300, height: 240)) })
        let before = tree.layout(in: "one", frame: frame, minimumSizes: minima, stackChrome: chrome)
        XCTAssertEqual(Set(before.frames.values.map(\.y)).count, 3, "Two grid rows plus the stack's inset content")
        XCTAssertTrue(tree.resize(members[0], dimension: .width, amount: 50, frame: frame, minimumSizes: minima, stackChrome: chrome))
        let after = tree.layout(in: "one", frame: frame, minimumSizes: minima, stackChrome: chrome)
        XCTAssertEqual(after.frames[.group(stack)]?.width, (before.frames[.group(stack)]?.width ?? 0) + 50)
        XCTAssertEqual(after.surfaces[0].frame.width, before.surfaces[0].frame.width + 50)
        for (old, new) in zip(before.surfaces, after.surfaces) {
            XCTAssertEqual(old.frame.y, new.frame.y)
            XCTAssertEqual(old.frame.height, new.frame.height)
        }
    }
}

import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceLayoutGapsTests: XCTestCase {
    func testNestedSplitResizeKeepsConfiguredGapsAndOwnerMinimums() throws {
        let ids = (0..<4).map { _ in SurfaceID.nativeWindow(UUID()) }, group = UUID()
        var tree = SurfaceTree(); tree.reconcile(ids, in: "one")
        XCTAssertTrue(tree.importOrganization([.surface(ids[0]), .group(group, [.surface(ids[1]), .surface(ids[2])]), .surface(ids[3])],
            in: "one", layouts: [group: .vertical], activeSurfaces: [:], weights: [:]))
        let gaps = SurfaceLayoutGaps(horizontal: 12, vertical: 20), frame = SurfaceFrame(x: -800, y: 20, width: 1000, height: 800)
        let minima = Dictionary(uniqueKeysWithValues: ids.map { ($0, SurfaceMinimumSize(width: 100, height: 100)) })
        let before = tree.layout(in: "one", frame: frame, minimumSizes: minima, gaps: gaps)
        XCTAssertEqual(before.surfaces[1].frame.x - (before.surfaces[0].frame.x + before.surfaces[0].frame.width), 12)
        XCTAssertEqual(before.surfaces[2].frame.y - (before.surfaces[1].frame.y + before.surfaces[1].frame.height), 20)
        XCTAssertEqual(before.surfaces[3].frame.x + before.surfaces[3].frame.width, frame.x + frame.width)
        XCTAssertTrue(tree.resize(ids[1], dimension: .height, amount: 60, frame: frame, minimumSizes: minima, gaps: gaps, edge: .down))
        let resized = tree.layout(in: "one", frame: frame, minimumSizes: minima, gaps: gaps)
        XCTAssertEqual(resized.surfaces[1].frame.height, before.surfaces[1].frame.height + 60)
        XCTAssertEqual(resized.surfaces[2].frame.y, before.surfaces[2].frame.y + 60)
        XCTAssertEqual(resized.surfaces[2].frame.height, before.surfaces[2].frame.height - 60)
        XCTAssertTrue(tree.resize(ids[1], dimension: .height, amount: 1000, frame: frame, minimumSizes: minima, gaps: gaps))
        XCTAssertEqual(tree.layout(in: "one", frame: frame, minimumSizes: minima, gaps: gaps).surfaces[2].frame.height, 100)
    }

    func testAdaptiveGridResizePreservesBothGapAxes() throws {
        let ids = (0..<6).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(ids, in: "one")
        let frame = SurfaceFrame(x: 0, y: 0, width: 1220, height: 810), gaps = SurfaceLayoutGaps(horizontal: 10, vertical: 10)
        let minima = Dictionary(uniqueKeysWithValues: ids.map { ($0, SurfaceMinimumSize(width: 300, height: 300)) })
        let before = tree.layout(in: "one", frame: frame, minimumSizes: minima, gaps: gaps)
        XCTAssertEqual(Set(before.surfaces.map(\.frame.x)), [0, 410, 820])
        XCTAssertEqual(Set(before.surfaces.map(\.frame.y)), [0, 410])
        XCTAssertTrue(tree.resize(ids[0], dimension: .width, amount: 50, frame: frame, minimumSizes: minima, gaps: gaps))
        let after = tree.layout(in: "one", frame: frame, minimumSizes: minima, gaps: gaps)
        XCTAssertEqual(after.surfaces[0].frame.width, before.surfaces[0].frame.width + 50)
        XCTAssertEqual(after.surfaces[1].frame.x, after.surfaces[0].frame.width + 10)
        XCTAssertEqual(Set(after.surfaces.map(\.frame.y)), [0, 410])
        XCTAssertEqual(after.surfaces[2].frame.x + after.surfaces[2].frame.width, 1220)
    }

    func testStackChromeAndGapsFitTogetherWithoutGapsBetweenStackMembers() throws {
        let ids = (0..<3).map { _ in SurfaceID.nativeWindow(UUID()) }
        var tree = SurfaceTree(); tree.reconcile(ids, in: "one")
        XCTAssertTrue(tree.group(ids[1], with: ids[0]))
        let gaps = SurfaceLayoutGaps(horizontal: 15, vertical: 25), chrome = SurfaceStackChrome(headerHeight: 36, sideInset: 3, bottomInset: 3)
        let frame = SurfaceFrame(x: 0, y: 0, width: 1200, height: 800)
        let plan = tree.layout(in: "one", frame: frame, stackChrome: chrome, gaps: gaps)
        XCTAssertEqual(plan.surfaces[0].frame, plan.surfaces[1].frame)
        XCTAssertEqual(plan.surfaces[2].frame.x - (plan.stacks[0].frame.x + plan.stacks[0].frame.width), 15)
        let tiny = tree.layout(in: "one", frame: .init(x: 0, y: 0, width: 2, height: 2), stackChrome: chrome, gaps: gaps)
        XCTAssertTrue(tiny.surfaces.allSatisfy { $0.frame.isValid })
        XCTAssertEqual(tiny.surfaces.filter(\.visible).count, 1)
    }
}

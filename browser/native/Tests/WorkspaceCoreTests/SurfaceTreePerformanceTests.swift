import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceTreePerformanceTests: XCTestCase {
    private func fixture(count: Int) -> (SurfaceTree, [String], [UUID], [SurfaceID]) {
        var tree = SurfaceTree()
        let profile = UUID()
        let names = (0..<count).map { "view-\($0)" }
        let groups = names.map { _ in UUID() }
        let leaves = (0..<(count * 3)).map { _ in SurfaceID.browserTab(profile: profile, tab: UUID()) }
        for index in names.indices {
            let members = Array(leaves[(index * 3)..<(index * 3 + 3)])
            tree.roots[names[index]] = [.group(groups[index], members.map(SurfaceTreeNode.surface))]
            tree.layouts[groups[index]] = .horizontal
            tree.activeSurfaces[groups[index]] = members[1]
            tree.weights["group:" + groups[index].uuidString.lowercased()] = 600
            for member in members { tree.weights[member.description] = 200 }
        }
        return (tree, names, groups, leaves)
    }

    private func benchmark(_ name: String, count: Int, _ body: () throws -> Void) rethrows {
        var samples: [Double] = []
        for iteration in 0..<11 {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if iteration > 0 { samples.append(elapsed) }
        }
        samples.sort()
        print("SURFACE_TREE_BENCHMARK name=\(name) count=\(count) samples=\(samples.count) median_ms=\(samples[samples.count / 2]) p95_ms=\(samples.last!)")
    }

    func testLayoutProjectionBenchmark() {
        for count in [50, 200] {
            let (tree, names, _, _) = fixture(count: count)
            let frame = SurfaceFrame(x: 0, y: 0, width: 1200, height: 800)
            benchmark("projection_and_layout", count: count) {
                var placed = 0
                for name in names {
                    let projected = tree.projecting(in: name, excluding: [])
                    let plan = projected.layout(in: name, frame: frame)
                    placed += plan.surfaces.count
                    XCTAssertTrue(plan.surfaces.allSatisfy { $0.visible && $0.frame.width == 400 })
                }
                XCTAssertEqual(placed, count * 3)
            }
        }
    }

    func testBulkArrivalBenchmark() {
        for count in [50, 200] {
            let (tree, _, _, _) = fixture(count: count)
            let arrivals = (0..<count).map { _ in SurfaceID.nativeWindow(UUID()) }
            benchmark("bulk_arrival", count: count) {
                var updated = tree
                updated.reconcile(arrivals, in: "incoming")
                XCTAssertEqual(updated.roots["incoming"]?.flatMap(\.surfaces), arrivals)
                XCTAssertEqual(updated.layouts, tree.layouts)
                XCTAssertEqual(updated.weights, tree.weights)
            }
        }
    }

    func testOrganizationEditBenchmark() throws {
        for count in [50, 200] {
            let (tree, names, groups, leaves) = fixture(count: count)
            try benchmark("organization_edit", count: count) {
                let change = try XCTUnwrap(tree.preparingOrganizationChange(in: [names[0], "destination"], selected: leaves[1]) {
                    $0.moveGroupToRoot(groups[0], in: "destination")
                })
                XCTAssertEqual(change.membership.count, 3)
                XCTAssertEqual(change.tree.roots["destination"], tree.roots[names[0]])
                XCTAssertEqual(change.tree.weights, tree.weights)
            }
        }
    }
}

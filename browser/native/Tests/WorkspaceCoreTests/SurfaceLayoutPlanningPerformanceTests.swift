import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfaceLayoutPlanningPerformanceTests: XCTestCase {
    func testStackAndSplitPlanningBenchmark() {
        for count in [40, 200] {
            let profile = UUID()
            let ids = (0..<count).map { _ in SurfaceID.browserTab(profile: profile, tab: UUID()) }
            let minimums = Dictionary(uniqueKeysWithValues: ids.map { ($0, SurfaceMinimumSize(width: 80, height: 80)) })
            for style in [SurfaceContainerLayout.stack, .horizontal] {
                var tree = SurfaceTree()
                let groups = stride(from: 0, to: count, by: 4).map { offset -> SurfaceTreeNode in
                    let id = UUID()
                    tree.layouts[id] = style
                    return .group(id, ids[offset..<(offset + 4)].map(SurfaceTreeNode.surface))
                }
                let outer = UUID()
                tree.roots["bench"] = [.group(outer, groups)]
                tree.layouts[outer] = .stack
                let frame = SurfaceFrame(x: 0, y: 0, width: 1600, height: 1000)
                let expected = tree.layout(in: "bench", frame: frame, minimumSizes: minimums, selectedSurface: ids.last)
                XCTAssertEqual(expected.surfaces.map(\.surfaceID), ids)
                XCTAssertEqual(expected.surfaces.filter(\.visible).count, style == .stack ? 1 : 4)
                var samples: [Double] = []
                for _ in 0..<20 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let plan = tree.layout(in: "bench", frame: frame, minimumSizes: minimums, selectedSurface: ids.last)
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                    XCTAssertEqual(plan, expected)
                }
                samples.sort()
                print("LAYOUT_PLANNING_BENCHMARK style=\(style) count=\(count) median_ms=\(samples[10]) p95_ms=\(samples[18])")
            }
        }
    }
}

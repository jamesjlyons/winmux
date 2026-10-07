@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor
final class WorkspaceViewsPerformanceTest: XCTestCase {
    func testStandaloneSidebarRefreshBenchmark() throws {
        for count in [50, 200] {
            setUpWorkspacesForTests()
            config.workspaceInteractionMode = .views
            let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID(), profile = UUID()
            let names = (0..<count).map { "view-benchmark-\($0)" }
            let ids = names.map { _ in SurfaceID.browserTab(profile: profile, tab: UUID()) }
            var tree = SurfaceTree()
            for index in names.indices { tree.reconcile([ids[index]], in: names[index]) }
            controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
            controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
            controller.received(.init(revision: 1, full: true, tabs: ids.map {
                .init(surfaceID: $0, hostID: $0.description, title: "Synthetic website", selected: false)
            }), epoch: epoch, connection: connection)

            var durations: [Double] = []
            var updateDurations: [Double] = []
            for iteration in 0..<11 {
                let updateStart = DispatchTime.now().uptimeNanoseconds
                controller.reconcileSharedOrganization()
                let start = DispatchTime.now().uptimeNanoseconds
                let projection = controller.sidebarProjection()
                let rows = names.flatMap { controller.organizedRows(native: [], in: $0, projection: projection) }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                XCTAssertEqual(rows.flatMap(\.surfaceItems).map(\.surfaceID), ids)
                if iteration > 0 {
                    durations.append(elapsed)
                    updateDurations.append(Double(DispatchTime.now().uptimeNanoseconds - updateStart) / 1_000_000)
                }
            }
            durations.sort()
            print("VIEWS_SIDEBAR_BENCHMARK count=\(count) samples=\(durations.count) median_ms=\(durations[durations.count / 2]) p95_ms=\(durations.last!)")
            updateDurations.sort()
            print("VIEWS_MODEL_AND_SIDEBAR_BENCHMARK count=\(count) samples=\(updateDurations.count) median_ms=\(updateDurations[updateDurations.count / 2]) p95_ms=\(updateDurations.last!)")
            controller.disconnected(connection)
        }
        config.workspaceInteractionMode = .tiling
    }
}

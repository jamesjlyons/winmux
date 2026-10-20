@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor
final class SharedLayoutPlanningPerformanceTest: XCTestCase {
    func testBrowserOnlyPlanningDoesNotCreateNativeContainers() {
        setUpWorkspacesForTests()
        config.workspaceSidebar.enabled = false
        let controller = BrowserWorkspaceController(), workspace = focus.workspace
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var tree = SurfaceTree()
        tree.reconcile([page], in: workspace.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        let connection = UUID()
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [
            .init(surfaceID: page, hostID: page.description, title: "Page", selected: true)
        ]), epoch: UUID(), connection: connection)
        XCTAssertNil(workspace.existingRootTilingContainer)
        for _ in 0..<3 {
            XCTAssertNil(controller.sharedFullscreenPane(in: workspace))
            XCTAssertEqual(controller.plannedLayout(in: workspace).surfaces.map(\.surfaceID), [page])
        }
        XCTAssertNil(workspace.existingRootTilingContainer, "Presentation reads must not create native layout state")
        XCTAssertEqual(controller.surfaceTree, tree)
    }

    func testManyViewPlanningBenchmark() {
        for count in [50, 200] {
            setUpWorkspacesForTests()
            config.workspaceSidebar.enabled = false
            let controller = BrowserWorkspaceController()
            let profile = UUID(), connection = UUID()
            let names = (0..<count).map { "planning-\($0)" }
            let ids = names.map { _ in SurfaceID.browserTab(profile: profile, tab: UUID()) }
            var tree = SurfaceTree()
            for index in names.indices { tree.reconcile([ids[index]], in: names[index]) }
            controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
            controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
            controller.received(.init(revision: 1, full: true, tabs: ids.map {
                .init(surfaceID: $0, hostID: $0.description, title: "Planning benchmark", selected: false)
            }), epoch: UUID(), connection: connection)
            let workspaces = names.map { Workspace.get(byName: $0) }
            var samples: [Double] = []
            for iteration in 0..<11 {
                let start = DispatchTime.now().uptimeNanoseconds
                let plans = workspaces.map { controller.plannedLayout(in: $0) }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                XCTAssertEqual(plans.flatMap(\.surfaces).map(\.surfaceID), ids)
                if iteration > 0 { samples.append(elapsed) }
            }
            samples.sort()
            print("SHARED_LAYOUT_PLANNING_BENCHMARK count=\(count) median_ms=\(samples[5]) p95_ms=\(samples[9])")
            controller.disconnected(connection)
        }
    }
}

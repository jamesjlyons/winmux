@testable import AppBundle
import Common
import XCTest

@MainActor
final class ModelRefreshBenchmarkTest: XCTestCase {
    func testSidebarSnapshotBenchmark() async throws {
        for count in [8, 32] {
            setUpWorkspacesForTests()
            config.workspaceSidebar.enabled = true
            for index in 1 ... count {
                let workspace = Workspace.get(byName: String(index))
                workspace.markAsAutomaticallyNamed()
                for offset in 0 ..< 4 {
                    TestWindow.new(id: UInt32(index * 10 + offset), parent: workspace.rootTilingContainer)
                }
            }
            _ = Workspace.get(byName: "1").focusWorkspace()
            _ = await buildWorkspaceSidebarModelState()
            await waitForBackgroundWindowTitlesForTests()
            var samples: [Double] = []
            for _ in 0 ..< 15 {
                let start = DispatchTime.now().uptimeNanoseconds
                let state = await buildWorkspaceSidebarModelState()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                XCTAssertEqual(state.workspaces.filter { $0.displayName.hasPrefix("Group ") }.count, count)
            }
            report("sidebar-\(count)-groups", samples)
        }
    }

    func testTabSnapshotBenchmark() async {
        setUpWorkspacesForTests()
        config.windowTabs.enabled = true
        let container = focus.workspace.rootTilingContainer
        container.layout = .tabGroup
        for id in 1 ... 40 { TestWindow.new(id: UInt32(id), parent: container) }
        _ = makeWindowTabChromeTabs(container: container, activeWindowId: 1)
        await waitForBackgroundWindowTitlesForTests()
        var samples: [Double] = []
        for _ in 0 ..< 30 {
            let start = DispatchTime.now().uptimeNanoseconds
            let tabs = makeWindowTabChromeTabs(container: container, activeWindowId: 1)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertEqual(tabs.map(\.id), Array(1 ... 40).map(UInt32.init))
            XCTAssertEqual(tabs.filter(\.isActive).map(\.id), [1])
        }
        report("tabs-40-windows", samples)
    }

    func testFrozenSnapshotAndClosedCacheBenchmark() {
        setUpWorkspacesForTests()
        resetClosedWindowsCache()
        let workspace = focus.workspace
        for id in 1 ... 256 { TestWindow.new(id: UInt32(id), parent: workspace.rootTilingContainer) }
        var snapshotSamples: [Double] = []
        var cacheSamples: [Double] = []
        cacheClosedWindowIfNeeded()
        defer { resetClosedWindowsCache() }
        for _ in 0 ..< 20 {
            let start = DispatchTime.now().uptimeNanoseconds
            let snapshot = snapshotCurrentFrozenWorld()
            snapshotSamples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertEqual(snapshot.windowIds.count, 256)
            let cacheStart = DispatchTime.now().uptimeNanoseconds
            cacheClosedWindowIfNeeded()
            cacheSamples.append(Double(DispatchTime.now().uptimeNanoseconds - cacheStart) / 1_000_000)
        }
        report("frozen-256-siblings", snapshotSamples)
        report("closed-cache-256-windows", cacheSamples)
    }

    private func report(_ scenario: String, _ samples: [Double]) {
        let sorted = samples.sorted()
        print("MODEL_REFRESH_BENCHMARK \(scenario) median_ms=\(sorted[sorted.count / 2]) p95_ms=\(sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1])")
    }

    func testSessionContentComparisonBenchmark() throws {
        setUpWorkspacesForTests()
        for id in 1 ... 128 { TestWindow.new(id: UInt32(id), parent: focus.workspace.rootTilingContainer) }
        let before = RestartSessionSnapshot.capture(now: .distantPast)
        let after = RestartSessionSnapshot.capture(now: .distantPast)
        let previousJSON = try JSONEncoder.winMuxDefault.encode(before)
        var jsonSamples: [Double] = []
        var valueSamples: [Double] = []
        for _ in 0 ..< 30 {
            let jsonStart = DispatchTime.now().uptimeNanoseconds
            let sameJSON = try JSONEncoder.winMuxDefault.encode(after) == previousJSON
            jsonSamples.append(Double(DispatchTime.now().uptimeNanoseconds - jsonStart) / 1_000_000)
            XCTAssertTrue(sameJSON)
            let valueStart = DispatchTime.now().uptimeNanoseconds
            let sameValue = after.hasSameContent(as: before)
            valueSamples.append(Double(DispatchTime.now().uptimeNanoseconds - valueStart) / 1_000_000)
            XCTAssertTrue(sameValue)
        }
        report("session-128-windows-json", jsonSamples)
        report("session-128-windows-values", valueSamples)
    }
}

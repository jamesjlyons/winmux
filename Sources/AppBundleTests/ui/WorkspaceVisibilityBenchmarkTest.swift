@testable import AppBundle
import XCTest

@MainActor
final class WorkspaceVisibilityBenchmarkTest: XCTestCase {
    func testEmptyAndMinimizedWorkspaceVisibilityBenchmark() {
        setUpWorkspacesForTests()
        let projectCount = 4
        let groupsPerProject = 24
        for projectIndex in 0 ..< projectCount {
            let projectId = WorkspaceProjectId("visibility-\(projectIndex)")
            winMuxWorkspaceState.registerProject(.init(id: projectId, name: "Project \(projectIndex)", order: projectIndex + 1))
            for groupIndex in 0 ..< groupsPerProject {
                let workspace = Workspace.get(byName: "visibility-\(projectIndex)-\(groupIndex)")
                workspace.assignProject(projectId)
                workspace.markAsAutomaticallyNamed()
                if groupIndex.isMultiple(of: 4) {
                    let window = TestWindow.new(id: UInt32(projectIndex * 100 + groupIndex + 1), parent: workspace.rootTilingContainer)
                    window.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: workspace.name)
                    window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                }
            }
        }
        let ordered = orderedWorkspacesForPresentation()
        let expected = ordered.filter { isUserFacingWorkspace($0) }.map(\.id)
        var samples: [Double] = []
        for _ in 0 ..< 20 {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = userFacingWorkspaces(ordered)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertEqual(result.map(\.id), expected)
        }
        let sorted = samples.sorted()
        print("VISIBILITY_BENCHMARK groups=96 minimized=24 median_ms=\(sorted[10]) p95_ms=\(sorted[18])")
    }
}

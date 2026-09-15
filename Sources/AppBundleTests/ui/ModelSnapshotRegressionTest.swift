@testable import AppBundle
import Common
import XCTest

@MainActor
final class ModelSnapshotRegressionTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testBulkDisplayNamesMatchIndividualNamesThroughProjectAndLifecycleChanges() {
        let projectId = WorkspaceProjectId("snapshot-project")
        winMuxWorkspaceState.registerProject(.init(id: projectId, name: "Second", order: 1))
        let first = Workspace.get(byName: "10")
        let second = Workspace.get(byName: "20")
        let otherProject = Workspace.get(byName: "30")
        let explicit = Workspace.get(byName: "Explicit")
        for (index, workspace) in [first, second, otherProject, explicit].enumerated() {
            if workspace !== explicit { workspace.markAsAutomaticallyNamed() }
            TestWindow.new(id: UInt32(index + 1), parent: workspace.rootTilingContainer)
        }
        otherProject.assignProject(projectId)
        let minimized = TestWindow.new(id: 5, parent: Workspace.get(byName: "40").rootTilingContainer)
        let minimizedWorkspace = minimized.nodeWorkspace!
        minimizedWorkspace.markAsAutomaticallyNamed()
        minimized.layoutReason = .macos(prevParentKind: .tilingContainer, prevWorkspaceName: minimizedWorkspace.name)
        minimized.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)

        func assertParity() {
            let ordered = orderedWorkspacesForPresentation()
            let indices = automaticWorkspaceDisplayIndices(workspaces: ordered, focusedWorkspace: focus.workspace)
            for workspace in Workspace.all {
                XCTAssertEqual(workspaceDisplayName(workspace.name, automaticIndices: indices), workspaceDisplayName(workspace.name))
            }
            XCTAssertEqual(indices[otherProject.id], 1, "Numbering starts again in each project")
            XCTAssertNil(indices[explicit.id])
        }
        assertParity()
        winMuxWorkspaceState.projectsById[first.projectId]?.workspaceOrder.reverse()
        config.workspaceSidebar.workspaceLabels[first.name] = "  Writing  "
        assertParity()
        XCTAssertEqual(workspaceDisplayName(first.name), "Writing")
        second.lifecycle = .archived
        assertParity()
        minimized.unbindFromParent()
        assertParity()
    }

    func testTabSnapshotKeepsOrderAndLoadsColdTitlesInBackground() async {
        let root = focus.workspace.rootTilingContainer
        root.layout = .tabGroup
        TestWindow.new(id: 7, parent: root)
        let nested = TilingContainer(parent: root, adaptiveWeight: 1, .h, .tiles, index: INDEX_BIND_LAST)
        TestWindow.new(id: 8, parent: nested)
        let active = TestWindow.new(id: 9, parent: root)
        _ = TilingContainer(parent: root, adaptiveWeight: 1, .h, .tiles, index: INDEX_BIND_LAST)

        let cold = makeWindowTabChromeTabs(container: root, activeWindowId: active.windowId)
        XCTAssertEqual(cold.map(\.id), [7, 8, 9])
        XCTAssertTrue(cold.allSatisfy { $0.title == $0.appName })
        XCTAssertEqual(cold.filter(\.isActive).map(\.id), [9])
        await waitForBackgroundWindowTitlesForTests()
        let warm = makeWindowTabChromeTabs(container: root, activeWindowId: 7)
        XCTAssertEqual(warm.map(\.title), ["TestWindow(7)", "TestWindow(8)", "TestWindow(9)"])
        XCTAssertEqual(warm.filter(\.isActive).map(\.id), [7])
    }

    func testFrozenRecentOrderFollowsFocusRemovalAndReinsertion() {
        let root = focus.workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        let third = TestWindow.new(id: 3, parent: root)
        first.markAsMostRecentChild()
        XCTAssertEqual(root.childrenByMostRecentUse, [first, third, second])
        XCTAssertEqual(FrozenContainer(root).mostRecentChildIndices, [0, 2, 1])
        third.unbindFromParent()
        XCTAssertEqual(root.childrenByMostRecentUse, [first, second])
        third.bind(to: root, adaptiveWeight: 1, index: 0)
        XCTAssertEqual(root.childrenByMostRecentUse, [third, first, second])
        XCTAssertEqual(FrozenContainer(root).mostRecentChildIndices, [0, 1, 2])
    }

    func testClosedCacheRetainsOriginalSnapshotUntilANewWindowAppears() async throws {
        resetClosedWindowsCache()
        defer { resetClosedWindowsCache() }
        let workspace = focus.workspace
        workspace.rootTilingContainer.layout = .tabGroup
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        cacheClosedWindowIfNeeded()
        workspace.rootTilingContainer.layout = .tiles
        cacheClosedWindowIfNeeded()
        let restoredFirst = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: first)
        XCTAssertTrue(restoredFirst)
        XCTAssertEqual(workspace.rootTilingContainer.layout, .tabGroup)

        workspace.rootTilingContainer.layout = .tiles
        let added = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        cacheClosedWindowIfNeeded()
        workspace.rootTilingContainer.layout = .tabGroup
        let restoredAdded = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: added)
        XCTAssertTrue(restoredAdded)
        XCTAssertEqual(workspace.rootTilingContainer.layout, .tiles)
        XCTAssertEqual(workspace.rootTilingContainer.children.compactMap { ($0 as? Window)?.windowId }, [1, 2, 3])
    }
}

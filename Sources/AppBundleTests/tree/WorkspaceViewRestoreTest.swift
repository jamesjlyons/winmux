@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor
final class WorkspaceViewRestoreTest: XCTestCase {
    private let browser = BrowserWorkspaceController.shared

    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.newItemPlacement = .newView
    }

    override func tearDown() async throws {
        browser.restorePlacementSnapshot(.init(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        browser.usesSurfaceTree = false
        config.newItemPlacement = .tile
    }

    func testExplicitEmptyViewsSurviveOccupancyClosureAndBothRestartFormatsForEveryArrivalPolicy() throws {
        for policy in NewItemPlacement.allCases {
            setUpWorkspacesForTests()
            config.newItemPlacement = policy
            let view = createEmptyView(projectId: focus.workspace.projectId, monitor: mainMonitor)
            let renamed = createBlankWorkspace(projectId: view.projectId, monitor: mainMonitor)
            try renameWorkspaceForSidebar(workspaceName: renamed.name, displayName: "Research")
            let windows = [TestWindow.new(id: 407, parent: view.rootTilingContainer),
                           TestWindow.new(id: 408, parent: renamed.rootTilingContainer)]
            for window in windows { window.unbindFromParent() }
            Workspace.reconcileWorkspaceState()
            XCTAssertTrue(Workspace.existing(byName: view.name) === view)
            XCTAssertTrue(Workspace.existing(byName: renamed.name) === renamed)
            XCTAssertTrue(userFacingWorkspaces(Workspace.all).contains(view))
            XCTAssertTrue(userFacingWorkspaces(Workspace.all).contains(renamed))

            let frozen = try JSONDecoder().decode([FrozenWorkspace].self,
                from: JSONEncoder().encode([FrozenWorkspace(view), FrozenWorkspace(renamed)]))
            browser.usesSurfaceTree = true
            browser.reconcileSharedOrganization()
            let surfaces = try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self,
                from: JSONEncoder().encode(try XCTUnwrap(browser.capturePlacementSnapshot())))
            XCTAssertTrue(surfaces.savedViews.first { $0.workspaceName == view.name }?.retainsWhenEmpty == true)
            for restoreSurfaces in [true, false] {
                setUpWorkspacesForTests()
                config.newItemPlacement = policy
                if restoreSurfaces {
                    browser.restorePlacementSnapshot(surfaces)
                } else {
                    restoreRestartMetadata(.init(savedAt: .now, bootSession: currentBootSession(),
                        world: .init(workspaces: frozen, monitors: [], windowIds: []), windows: [], projects: [],
                        focusedWindowId: nil, focusedWorkspace: nil))
                }
                Workspace.reconcileWorkspaceState()
                for name in [view.name, renamed.name] {
                    let restored = try XCTUnwrap(Workspace.existing(byName: name))
                    XCTAssertTrue(restored.retainsEmptyView)
                    XCTAssertTrue(isUserFacingWorkspace(restored))
                    XCTAssertFalse(workspaceShouldRemoveEmptyView(restored))
                }
            }
        }
    }

    func testExplicitEmptyViewIsNotReusedByAnotherArrivalOrNewViewButton() {
        let source = focus.workspace
        _ = TestWindow.new(id: 409, parent: source.rootTilingContainer)
        let empty = createEmptyView(projectId: source.projectId, monitor: mainMonitor)
        let another = createEmptyView(projectId: source.projectId, monitor: mainMonitor)
        XCTAssertFalse(another === empty)
        let arrival = browser.newStandaloneWorkspace(in: source)
        XCTAssertFalse(arrival === empty)
        XCTAssertFalse(arrival === another)
        XCTAssertTrue(browser.newStandaloneWorkspace(in: empty) === empty, "The selected empty View accepts its first arrival")
        let named = Workspace.get(byName: "Selected named View")
        XCTAssertTrue(browser.newStandaloneWorkspace(in: named) === named)
    }

    func testLegacyNumericWorkspaceUsesWindowTitleAndPreservesCustomLabel() async throws {
        let workspace = Workspace.get(byName: "4")
        workspace.restoreNamingStyle(.explicit)
        let window = TestWindow.new(id: 401, parent: workspace.rootTilingContainer)
        _ = await getCachedWindowTitle(window)
        var models = await sidebarModels()
        XCTAssertEqual(models.first { $0.name == "4" }?.displayName, "TestWindow(401)")

        config.workspaceSidebar.workspaceLabels[workspace.name] = "My research"
        models = await sidebarModels()
        XCTAssertEqual(models.first { $0.name == "4" }?.displayName, "My research")

        config.workspaceSidebar.workspaceLabels[workspace.name] = "4"
        models = await sidebarModels()
        XCTAssertEqual(models.first { $0.name == "4" }?.displayName, "4", "An intentional numeric label is still supported")
    }

    func testEmptySurfaceRootsDoNotRecreateRecoveredOrNumberedViews() {
        var tree = SurfaceTree()
        for name in ["Recovered", "13", "14"] {
            let id = SurfaceID.nativeWindow(UUID())
            tree.reconcile([id], in: name)
            tree.remove(id)
            XCTAssertEqual(tree.roots[name], [])
        }
        browser.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        for name in ["Recovered", "13", "14"] { XCTAssertNil(Workspace.existing(byName: name)) }
    }

    func testLegacyEmptyNumberedAndRecoveredViewsArePruned() {
        _ = TestWindow.new(id: 402, parent: focus.workspace.rootTilingContainer)
        for name in ["Recovered", "13", "14"] {
            let workspace = Workspace.get(byName: name)
            workspace.restoreNamingStyle(.explicit)
            XCTAssertFalse(isUserFacingWorkspace(workspace))
        }
        Workspace.reconcileWorkspaceState()
        for name in ["Recovered", "13", "14"] { XCTAssertNil(Workspace.existing(byName: name)) }
    }

    func testPendingNamedSurfaceIsHiddenAndRetiredAfterDiscovery() async {
        let id = SurfaceID.nativeWindow(UUID())
        var tree = SurfaceTree(); tree.reconcile([id], in: "Old arrangement")
        browser.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        let workspace = Workspace.get(byName: "Old arrangement")
        XCTAssertFalse(isUserFacingWorkspace(workspace))
        XCTAssertFalse(userFacingWorkspaces(Workspace.all).contains(workspace))
        let models = await sidebarModels()
        XCTAssertFalse(models.contains { $0.name == workspace.name }, "The published sidebar must apply lifecycle visibility")
        browser.finishNativeRestoration()
        Workspace.reconcileWorkspaceState()
        XCTAssertNil(Workspace.existing(byName: workspace.name))
    }

    func testUsedNamedWorkspaceRemembersOccupancyAcrossRestart() throws {
        let workspace = Workspace.get(byName: "Old arrangement")
        let window = TestWindow.new(id: 403, parent: workspace.rootTilingContainer)
        window.unbindFromParent()
        let saved = try JSONDecoder().decode(FrozenWorkspace.self, from: JSONEncoder().encode(FrozenWorkspace(workspace)))
        removeWorkspaceFromRegistry(workspace)
        let snapshot = RestartSessionSnapshot(savedAt: .now, bootSession: currentBootSession(),
            world: .init(workspaces: [saved], monitors: [], windowIds: []), windows: [], projects: [],
            focusedWindowId: nil, focusedWorkspace: nil)
        restoreRestartMetadata(snapshot)
        Workspace.reconcileWorkspaceState()
        XCTAssertNil(Workspace.existing(byName: workspace.name))
        XCTAssertNotNil(Workspace.existing(byName: "setUpWorkspacesForTests"), "An intentionally unused named view survives")
    }

    func testOldSnapshotInfersOccupancyFromMissingNativeWindows() throws {
        let workspace = Workspace.get(byName: "Previous work")
        let window = TestWindow.new(id: 404, parent: workspace.rootTilingContainer)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(FrozenWorkspace(workspace))) as? [String: Any])
        json.removeValue(forKey: "hasContainedItems")
        let saved = try JSONDecoder().decode(FrozenWorkspace.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(saved.hasContainedItems)
        window.unbindFromParent()
        removeWorkspaceFromRegistry(workspace)
        let snapshot = RestartSessionSnapshot(savedAt: .now, bootSession: currentBootSession(),
            world: .init(workspaces: [saved], monitors: [], windowIds: [404]), windows: [], projects: [],
            focusedWindowId: nil, focusedWorkspace: nil)
        restoreRestartMetadata(snapshot)
        Workspace.reconcileWorkspaceState()
        XCTAssertNil(Workspace.existing(byName: workspace.name))
    }

    func testAutomaticBlankHasDescriptiveNameAndConfiguredNumericNamesRemainExplicit() async throws {
        let workspace = createBlankWorkspace(projectId: focus.workspace.projectId, monitor: mainMonitor)
        _ = workspace.focusWorkspace()
        let models = await sidebarModels()
        XCTAssertEqual(models.first { $0.name == workspace.name }?.displayName, "Empty View")
        config.newItemPlacement = .tile
        config.persistentWorkspaces = ["27"]
        let numeric = Workspace.get(byName: "27")
        numeric.restoreNamingStyle(.explicit)
        XCTAssertEqual(workspaceDisplayName(numeric.name), "27")
    }

    private func sidebarModels() async -> [WorkspaceSidebarWorkspaceViewModel] {
        await buildWorkspaceSidebarWorkspaceViewModels(currentFocus: focus,
            workspaceLabels: config.workspaceSidebar.workspaceLabels, availableMonitors: monitors)
    }
}

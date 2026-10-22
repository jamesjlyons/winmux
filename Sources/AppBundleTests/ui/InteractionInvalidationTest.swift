@testable import AppBundle
import AppKit
import Common
import WorkspaceCore
import XCTest

@MainActor
final class InteractionInvalidationTest: XCTestCase {
    override func setUp() async throws {
        await InteractionChromeScheduler.shared.flush()
        setUpWorkspacesForTests()
        TrayMenuModel.shared.isEnabled = true
    }

    override func tearDown() async throws {
        await InteractionChromeScheduler.shared.flush()
        await waitForBackgroundWindowTitlesForTests()
        appForTests = nil
    }

    func testNativeSidebarReusesUntouchedWorkspaceAndInvalidatesTitleAndMembership() async {
        let first = focus.workspace
        let second = Workspace.get(byName: "other")
        let one = TestWindow.new(id: 1, parent: first.rootTilingContainer)
        _ = TestWindow.new(id: 2, parent: second.rootTilingContainer)
        _ = await buildWorkspaceSidebarNativeItems(for: first, currentFocus: focus)
        _ = await buildWorkspaceSidebarNativeItems(for: second, currentFocus: focus)
        await waitForBackgroundWindowTitlesForTests()
        _ = await buildWorkspaceSidebarNativeItems(for: first, currentFocus: focus)
        _ = await buildWorkspaceSidebarNativeItems(for: second, currentFocus: focus)
        let builds = nativeSidebarBuildCount
        _ = await buildWorkspaceSidebarNativeItems(for: first, currentFocus: focus)
        _ = await buildWorkspaceSidebarNativeItems(for: second, currentFocus: focus)
        XCTAssertEqual(nativeSidebarBuildCount, builds)

        one.recordChange(.metadata)
        _ = await buildWorkspaceSidebarNativeItems(for: first, currentFocus: focus)
        _ = await buildWorkspaceSidebarNativeItems(for: second, currentFocus: focus)
        XCTAssertEqual(nativeSidebarBuildCount, builds + 1)

        one.bind(to: second.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let firstItems = await buildWorkspaceSidebarNativeItems(for: first, currentFocus: focus)
        let secondItems = await buildWorkspaceSidebarNativeItems(for: second, currentFocus: focus)
        XCTAssertTrue(firstItems.isEmpty)
        XCTAssertEqual(secondItems.flatMap(\.surfaceItems).count, 2)
    }

    func testCleanHiddenWorkspaceSurvivesUnrelatedSelectionButGeometryInvalidatesIt() {
        let hidden = Workspace.get(byName: "hidden")
        let window = TestWindow.new(id: 11, parent: hidden.rootTilingContainer)
        let visible = TestWindow.new(id: 12, parent: focus.workspace.rootTilingContainer)
        let cache = WorkspaceLayoutCache()
        let revision = WorkspaceLayoutRevision(hidden, includeBrowser: false)
        cache.record(hidden, revision: revision, token: cache.token())
        visible.markAsMostRecentChild()
        XCTAssertFalse(cache.needsLayout(hidden, revision: WorkspaceLayoutRevision(hidden, includeBrowser: false)))
        window.invalidateLastKnownNativeState()
        XCTAssertTrue(cache.needsLayout(hidden, revision: WorkspaceLayoutRevision(hidden, includeBrowser: false)))
    }

    func testAnimationOutputDoesNotInvalidateLayoutOrPersistTiledFrames() {
        let workspace = focus.workspace
        let window = TestWindow.new(id: 20, parent: workspace.rootTilingContainer)
        let layout = WorkspaceLayoutRevision(workspace)
        let session = RestartSessionRevision()
        window.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 10, topLeftY: 10, width: 800, height: 600)
        window.invalidateLastKnownNativeState(layoutChanged: false)
        XCTAssertEqual(WorkspaceLayoutRevision(workspace), layout)
        XCTAssertEqual(RestartSessionRevision(), session)
        window.invalidateLastKnownNativeState(includingSharedLayoutSize: true)
        XCTAssertNotEqual(WorkspaceLayoutRevision(workspace), layout)
    }

    func testExplicitFrameRepairInvalidatesAnOtherwiseCleanLayout() {
        let workspace = focus.workspace
        let window = TestWindow.new(id: 21, parent: workspace.rootTilingContainer)
        window.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 10, topLeftY: 10, width: 800, height: 600)
        let revision = WorkspaceLayoutRevision(workspace)
        window.lastAppliedLayoutPhysicalRect = nil
        XCTAssertNotEqual(WorkspaceLayoutRevision(workspace), revision)
    }

    func testSelectionDoesNotReplanAnotherHiddenBrowserWorkspace() {
        let controller = BrowserWorkspaceController()
        let first = focus.workspace
        let hidden = Workspace.get(byName: "hidden-browser")
        let a = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let b = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var tree = SurfaceTree()
        tree.reconcile([a], in: first.name)
        tree.reconcile([b], in: hidden.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        _ = controller.plannedLayout(in: first)
        let before = controller.plannedLayout(in: hidden)
        let builds = controller.layoutPlanBuildCount
        controller.recentSelections = [a]
        _ = controller.focusCoordinator.select(a)
        XCTAssertEqual(controller.plannedLayout(in: hidden), before)
        XCTAssertEqual(controller.layoutPlanBuildCount, builds)
        _ = controller.plannedLayout(in: first)
        XCTAssertEqual(controller.layoutPlanBuildCount, builds + 1)
    }

    func testSelectionDoesNotReplanWorkspaceWhoseRecentOrderIsUnchanged() {
        let controller = BrowserWorkspaceController()
        let first = focus.workspace
        let hidden = Workspace.get(byName: "hidden-recent")
        let a = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let b = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let c = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var tree = SurfaceTree()
        tree.reconcile([a, c], in: first.name)
        tree.reconcile([b], in: hidden.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        controller.recentSelections = [c, b, a]
        let hiddenRevision = controller.layoutSelectionRevision(in: hidden)
        let firstRevision = controller.layoutSelectionRevision(in: first)
        // Moving `a` to the front shifts `b` to a later index, but `b` is still
        // the most recent selection of its own workspace.
        controller.recentSelections = [a, c, b]
        XCTAssertEqual(controller.layoutSelectionRevision(in: hidden), hiddenRevision)
        XCTAssertNotEqual(controller.layoutSelectionRevision(in: first), firstRevision)
    }

    func testBrowserMetadataInventoryDoesNotReplanButHostStateDoes() {
        let controller = BrowserWorkspaceController()
        let workspace = focus.workspace
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let connection = UUID(), epoch = UUID()
        var tree = SurfaceTree()
        tree.reconcile([page], in: workspace.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [workspace.name], selected: nil, closedBrowserTabs: []))
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        func record(title: String, loading: Bool = false, minimized: Bool = false) -> BrowserTabRecord {
            .init(surfaceID: page, hostID: "metadata", title: title, selected: true, url: "https://example.test/" + title,
                  isLoading: loading, hostMinimized: minimized, blockedRequests: title.count)
        }
        controller.received(.init(revision: 1, full: true, tabs: [record(title: "a")]), epoch: epoch,
                            connection: connection, protocolVersion: 4)
        // The first plan lazily creates the root container; settle it first.
        _ = controller.plannedLayout(in: workspace)
        _ = controller.plannedLayout(in: workspace)
        let epochBefore = controller.layoutEpoch
        controller.received(.init(revision: 2, full: false, tabs: [record(title: "ab", loading: true)]), epoch: epoch,
                            connection: connection, protocolVersion: 4)
        XCTAssertEqual(controller.layoutEpoch, epochBefore)
        let builds = controller.layoutPlanBuildCount
        _ = controller.plannedLayout(in: workspace)
        XCTAssertEqual(controller.layoutPlanBuildCount, builds)

        controller.received(.init(revision: 3, full: false, tabs: [record(title: "ab", minimized: true)]), epoch: epoch,
                            connection: connection, protocolVersion: 4)
        XCTAssertNotEqual(controller.layoutEpoch, epochBefore)
        XCTAssertFalse(controller.plannedLayout(in: workspace).surfaces.contains { $0.surfaceID == page && $0.visible })
    }

    func testBrowserTitleInventoryDoesNotCheckpointButMembershipDoes() {
        let controller = BrowserWorkspaceController()
        let workspace = focus.workspace
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let connection = UUID(), epoch = UUID()
        var tree = SurfaceTree()
        tree.reconcile([page], in: workspace.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [workspace.name], selected: nil, closedBrowserTabs: []))
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        func record(_ id: SurfaceID, title: String) -> BrowserTabRecord {
            .init(surfaceID: id, hostID: "metadata", title: title, selected: true, url: "https://example.test/")
        }
        controller.received(.init(revision: 1, full: true, tabs: [record(page, title: "a")]), epoch: epoch,
                            connection: connection, protocolVersion: 4)
        let persisted = controller.persistenceRevision
        let interaction = controller.interactionRevision
        // A title change is presented, never checkpointed to disk.
        controller.received(.init(revision: 2, full: false, tabs: [record(page, title: "ab")]), epoch: epoch,
                            connection: connection, protocolVersion: 4)
        XCTAssertEqual(controller.persistenceRevision, persisted)
        XCTAssertNotEqual(controller.interactionRevision, interaction)
        let arrival = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        controller.received(.init(revision: 3, full: false, tabs: [record(arrival, title: "c")]), epoch: epoch,
                            connection: connection, protocolVersion: 4)
        XCTAssertNotEqual(controller.persistenceRevision, persisted)
    }

    func testRecoveryInvalidationCannotBeAcknowledgedByAnOlderPass() {
        let cache = WorkspaceLayoutCache()
        let workspace = focus.workspace
        let revision = WorkspaceLayoutRevision(workspace)
        let old = cache.token()
        cache.invalidate()
        cache.record(workspace, revision: revision, token: old)
        XCTAssertTrue(cache.needsLayout(workspace, revision: revision))
        cache.record(workspace, revision: revision, token: cache.token())
        XCTAssertFalse(cache.needsLayout(workspace, revision: revision))
        config.gaps.inner.horizontal = .constant(31)
        XCTAssertTrue(cache.needsLayout(workspace, revision: WorkspaceLayoutRevision(workspace)))
    }

    func testPersistenceRevisionTracksEditsButIgnoresTitleAndPresentation() {
        let workspace = focus.workspace
        let window = TestWindow.new(id: 30, parent: workspace.rootTilingContainer)
        let baseline = RestartSessionRevision()
        window.recordChange(.metadata)
        window.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 500, height: 400)
        XCTAssertEqual(RestartSessionRevision(), baseline)
        window.setWeight(.h, 2)
        XCTAssertNotEqual(RestartSessionRevision(), baseline)
        let resized = RestartSessionRevision()
        window.setWeight(.h, 2)
        XCTAssertEqual(RestartSessionRevision(), resized)
        workspace.retainsEmptyView.toggle()
        XCTAssertNotEqual(RestartSessionRevision(), resized)
    }

    func testMouseReleaseUsesClickedAndDraggedAppsWithoutGlobalDiscovery() {
        var scopes: [WindowRefreshScope] = []
        let recovery = MouseReleaseDiscovery(discover: { scopes.append($0) })
        recovery.mouseDown(targetPID: 42)
        recovery.mouseUp(dragOwner: 43)
        XCTAssertEqual(scopes, [.apps([42, 43])])
        recovery.cancel()
    }

    func testUnknownMouseReleasesCoalesceIntoOneRecovery() async {
        var scopes: [WindowRefreshScope] = []
        let recovery = MouseReleaseDiscovery(discover: { scopes.append($0) })
        for _ in 0..<100 { recovery.mouseUp() }
        XCTAssertTrue(scopes.isEmpty)
        await recovery.waitForRecoveryForTests()
        XCTAssertEqual(scopes, [.all])
    }

    func testHoverCoalescingFlushesLatestPositionBeforeButtonAction() {
        let coalescer = PointerActivityCoalescer()
        var positions: [Int] = []
        for i in 0..<100 { coalescer.submit { positions.append(i) } }
        coalescer.flush()
        positions.append(100) // button handler
        coalescer.flush()
        XCTAssertEqual(positions, [99, 100])
    }
}

@testable import AppBundle
import AppKit
import WorkspaceCore
import XCTest

@MainActor
final class NativeTabGroupingTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }
    override func tearDown() async throws { setUpWorkspacesForTests() }

    func testSwitchingNativeTabsRetainsSurfaceAndThreeSpaceOwnership() async throws {
        let spaces = ["native-a", "native-b", "native-c"].map { Workspace.get(byName: $0) }
        let window = TestWindow.new(id: 41, parent: spaces[0].rootTilingContainer)
        let originalSurface = window.surfaceID
        let group = UUID()
        var registry = NativeTabRegistry()
        let identities = Set([window])
        for step in 0..<180 {
            let space = spaces[step % spaces.count]
            window.bind(to: space.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
            registry.observe(group: group, selected: step % 2 == 0 ? 41 : 42, titles: ["shell", "server"])
            window.adoptNativeTabGroup(try XCTUnwrap(registry.groups[group]))
            XCTAssertEqual(window.surfaceID, originalSurface)
            XCTAssertTrue(window.nodeWorkspace === space)
            XCTAssertTrue(Window.get(bySurfaceID: originalSurface) === window)
            XCTAssertTrue(identities.contains(window), "Identity-based hashing must survive physical ID changes")
            XCTAssertEqual(spaces.flatMap(\.allLeafWindowsRecursive).count, 1)
        }
        let row = await makeWorkspaceSidebarWindowViewModel(for: window, workspaceName: window.nodeWorkspace!.name, currentFocus: focus)
        XCTAssertEqual(row.nativeTabBadge, "2 tabs")
        XCTAssertEqual(row.surfaceID, originalSurface)
        XCTAssertEqual(WorkspaceSidebarItemViewModel(kind: .window(row)).surfaceItems.first?.nativeTabBadge, "2 tabs")
    }

    func testTwoNativeGroupsNeverMergeEvenWithIdenticalTitles() throws {
        var registry = NativeTabRegistry()
        let first = UUID(), second = UUID()
        registry.observe(group: first, selected: 1, titles: ["shell", "shell"])
        registry.observe(group: second, selected: 3, titles: ["shell", "shell"])
        registry.observe(group: first, selected: 2, titles: ["shell", "shell"])
        registry.observe(group: second, selected: 4, titles: ["shell", "shell"])
        XCTAssertEqual(registry.selectedByMember, [1: 2, 2: 2, 3: 4, 4: 4])
    }

    func testMissingWindowDoesNotDetachAndConfirmedDetachReleasesOnlyThatMember() throws {
        var registry = NativeTabRegistry()
        let group = UUID()
        registry.observe(group: group, selected: 1, titles: ["one", "two"])
        registry.observe(group: group, selected: 2, titles: ["one", "two"])
        registry.retainAlive([1, 2, 99])
        XCTAssertEqual(registry.selectedByMember[1], 2)
        registry.observeStandalone(1)
        XCTAssertNil(registry.selectedByMember[1])
        XCTAssertEqual(registry.selectedByMember[2], 2)
        XCTAssertNil(registry.selectedByMember[99])
    }

    func testClosingSelectedTabKeepsGroupUntilFinalMemberCloses() throws {
        var registry = NativeTabRegistry()
        let group = UUID()
        registry.observe(group: group, selected: 1, titles: ["one", "two"])
        registry.observe(group: group, selected: 2, titles: ["one", "two"])
        registry.retainAlive([1])
        registry.observeStandalone(1)
        XCTAssertEqual(registry.groups[group]?.selectedWindowID, 1)
        XCTAssertEqual(registry.groups[group]?.memberWindowIDs, [1])
        registry.retainAlive([])
        XCTAssertTrue(registry.groups.isEmpty)
    }

    func testMovingTabBetweenNativeGroupsUpdatesMembershipWithoutCombiningGroups() {
        var registry = NativeTabRegistry()
        let a = UUID(), b = UUID()
        registry.observe(group: a, selected: 1, titles: ["one", "two"])
        registry.observe(group: a, selected: 2, titles: ["one", "two"])
        registry.observe(group: b, selected: 3, titles: ["three"])
        registry.observe(group: b, selected: 2, titles: ["three", "two"])
        registry.observe(group: a, selected: 1, titles: ["one"])
        XCTAssertEqual(registry.groups[a]?.memberWindowIDs, [1])
        XCTAssertEqual(registry.groups[b]?.memberWindowIDs, [2, 3])
    }

    func testNativeSelectionInvalidatesTitleAndPreservesLayoutSlot() async throws {
        let root = focus.workspace.rootTilingContainer
        let before = TestWindow.new(id: 5, parent: root)
        let window = TestWindow.new(id: 6, parent: root)
        let after = TestWindow.new(id: 7, parent: root)
        window.titleForTesting = "old"
        _ = await getCachedWindowTitle(window)
        window.titleForTesting = "selected"
        window.adoptNativeTabGroup(.init(id: UUID(), selectedWindowID: 8, memberWindowIDs: [6, 8], titles: ["old", "selected"]))
        XCTAssertNil(cachedWindowTitle(for: window))
        let title = await getCachedWindowTitle(window)
        XCTAssertEqual(title, "selected")
        XCTAssertEqual(root.children, [before, window, after])
    }
    func testNativePinKeepsOneBindingWhileSelectedTabChanges() throws {
        TestApp.shared.bundlePath = "/Test.app"
        let controller = BrowserWorkspaceController(); controller.usesSurfaceTree = true
        let window = TestWindow.new(id: 31, parent: focus.workspace.rootTilingContainer)
        controller.reconcileSharedOrganization()
        XCTAssertTrue(controller.pinSurface(window.surfaceID))
        let pin = try XCTUnwrap(controller.nativeAppSidebarPins.first)
        let destination = window.nodeWorkspace
        let group = UUID()
        for id: UInt32 in [32, 31, 33, 32] {
            window.adoptNativeTabGroup(.init(id: group, selectedWindowID: id, memberWindowIDs: [31, 32, 33], titles: ["shell", "logs", "server"]))
            controller.reconcileSharedOrganization()
            XCTAssertEqual(controller.nativeAppSidebarPins.count, 1)
            XCTAssertEqual(controller.nativeAppSidebarPins.first?.surfaceID, pin.surfaceID)
            XCTAssertTrue(window.nodeWorkspace === destination)
            XCTAssertNoThrow(try controller.capturePlacementSnapshot()?.validated())
        }
    }

    func testRestartMatchesNativeGroupAfterSelectionChangedWhileManagerWasClosed() async throws {
        let source = Workspace.get(byName: "Original native Space")
        let window = TestWindow.new(id: 41, parent: source.rootTilingContainer)
        window.adoptNativeTabGroup(.init(id: UUID(), selectedWindowID: 41, memberWindowIDs: [41, 42], titles: ["shell", "server"]))
        let surface = window.surfaceID
        let snapshot = RestartSessionSnapshot.capture()
        setUpWorkspacesForTests()
        let restored = TestWindow.new(id: 42, parent: focus.workspace.rootTilingContainer)
        restored.adoptNativeTabGroup(.init(id: UUID(), selectedWindowID: 42, memberWindowIDs: [42], titles: ["shell", "server"]))
        let restart = RestartSessionController()
        restart.prepare(snapshot)
        try await restart.restoreAfterDiscovery()
        XCTAssertEqual(restored.surfaceID, surface)
        XCTAssertEqual(restored.nodeWorkspace?.name, source.name)
    }

    func testRestartMatchesUniqueWholeGroupAndRejectsAmbiguousIdenticalGroups() async throws {
        for duplicate in [false, true] {
            setUpWorkspacesForTests()
            let source = Workspace.get(byName: "Original native Space")
            let original = TestWindow.new(id: 41, parent: source.rootTilingContainer)
            original.adoptNativeTabGroup(.init(id: UUID(), selectedWindowID: 41, memberWindowIDs: [41], titles: ["shell", "server"]))
            let surface = original.surfaceID
            var snapshot = RestartSessionSnapshot.capture()
            snapshot = .init(version: snapshot.version, savedAt: snapshot.savedAt, bootSession: "previous boot",
                             world: snapshot.world, windows: snapshot.windows, projects: snapshot.projects,
                             focusedWindowId: nil, focusedWorkspace: nil)
            setUpWorkspacesForTests()
            let restored = TestWindow.new(id: 52, parent: focus.workspace.rootTilingContainer)
            restored.adoptNativeTabGroup(.init(id: UUID(), selectedWindowID: 52, memberWindowIDs: [52], titles: ["server", "shell"]))
            if duplicate {
                let other = TestWindow.new(id: 53, parent: focus.workspace.rootTilingContainer)
                other.adoptNativeTabGroup(.init(id: UUID(), selectedWindowID: 53, memberWindowIDs: [53], titles: ["shell", "server"]))
            }
            let restart = RestartSessionController(isAppStillRunning: { _ in false })
            restart.prepare(snapshot)
            try await restart.restoreAfterDiscovery()
            XCTAssertEqual(restored.surfaceID == surface, !duplicate)
        }
    }

    func testQueuedOperationFollowsGroupWhenItsOriginalTabDetaches() throws {
        let group = UUID()
        var registry = NativeTabRegistry()
        registry.observe(group: group, selected: 1, titles: ["shell", "server"])
        let routing = NativeTabOperationRouting(); routing.publish(registry)
        let capturedGroup = routing.group(for: 1)
        registry.observe(group: group, selected: 2, titles: ["shell", "server"])
        registry.observeStandalone(1)
        XCTAssertEqual(NativeTabOperationRouting.target(window: 1, group: capturedGroup, in: registry), 2)
        registry.retainAlive([1])
        XCTAssertNil(NativeTabOperationRouting.target(window: 1, group: capturedGroup, in: registry), "A queued job cannot target a detached or reused window after its group closes")
    }

    func testIncompleteSelectionDoesNotRouteJobsToAnotherGroupsWindow() {
        var registry = NativeTabRegistry()
        let a = UUID(), b = UUID()
        registry.observe(group: a, selected: 1, titles: ["one", "two"])
        registry.observe(group: a, selected: 2, titles: ["one", "two"])
        registry.observe(group: b, selected: 3, titles: ["three"])
        registry.observe(group: b, selected: 2, titles: ["three", "two"])
        XCTAssertTrue(registry.hasUnresolvedSelection)
        XCTAssertNil(NativeTabOperationRouting.target(window: 2, group: a, in: registry))
        XCTAssertEqual(NativeTabOperationRouting.target(window: 3, group: b, in: registry), 2)
        registry.observe(group: a, selected: 1, titles: ["one"])
        XCTAssertFalse(registry.hasUnresolvedSelection)
        XCTAssertEqual(NativeTabOperationRouting.target(window: 2, group: a, in: registry), 1)
    }

    func testTransferPlansBothOwnersBeforeChangingPhysicalWindowIDs() throws {
        let root = focus.workspace.rootTilingContainer
        let first = TestWindow.new(id: 2, parent: root), second = TestWindow.new(id: 3, parent: root)
        let a = UUID(), b = UUID()
        first.adoptNativeTabGroup(.init(id: a, selectedWindowID: 2, memberWindowIDs: [1, 2], titles: ["shell", "shell"]))
        second.adoptNativeTabGroup(.init(id: b, selectedWindowID: 3, memberWindowIDs: [3], titles: ["shell"]))
        var registry = NativeTabRegistry()
        registry.observe(group: a, selected: 1, titles: ["shell"])
        registry.observe(group: b, selected: 3, titles: ["shell", "shell"])
        registry.observe(group: b, selected: 2, titles: ["shell", "shell"])
        let planned = nativeTabOwnerAssignments([first, second], registry: registry)
        XCTAssertEqual(planned.count, 2)
        XCTAssertTrue(planned.first { $0.0.id == a }?.1 === first)
        XCTAssertTrue(planned.first { $0.0.id == b }?.1 === second)
        for (group, owner) in planned { owner.adoptNativeTabGroup(group) }
        XCTAssertEqual(first.windowId, 1)
        XCTAssertEqual(second.windowId, 2)
        XCTAssertEqual(Set(root.allLeafWindowsRecursive.map(\.surfaceID)).count, 2)
    }

    func testDetachedTabInheritsSourceSpaceInsteadOfCurrentFocus() throws {
        let source = Workspace.get(byName: "Source Space")
        let sourceProject = createWorkspaceProject(); source.assignProject(sourceProject.id)
        let window = TestWindow.new(id: 2, parent: source.rootTilingContainer)
        let group = UUID()
        window.adoptNativeTabGroup(.init(id: group, selectedWindowID: 2, memberWindowIDs: [1, 2], titles: ["shell", "server"]))
        var registry = NativeTabRegistry()
        registry.observe(group: group, selected: 1, titles: ["shell", "server"])
        registry.observe(group: group, selected: 2, titles: ["shell", "server"])
        registry.observeStandalone(1)
        XCTAssertNotEqual(focus.workspace.projectId, source.projectId)
        XCTAssertEqual(detachedNativeTabDestinations([window], registry: registry), [1: source.name])
    }

}

@testable import AppBundle
import WorkspaceCore
import XCTest

@MainActor
final class SpacePinnedGroupTest: XCTestCase {
    override func setUp() async throws {
        BrowserWorkspaceController.shared.restorePlacementSnapshot(.init(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        BrowserWorkspaceController.shared.usesSurfaceTree = false
        setUpWorkspacesForTests()
    }

    override func tearDown() async throws {
        BrowserWorkspaceController.shared.restorePlacementSnapshot(.init(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        BrowserWorkspaceController.shared.usesSurfaceTree = false
    }

    func testLegacyPinsMigrateOncePerSpaceWithoutOpeningOrChangingOtherLayouts() throws {
        let regular = focus.workspace
        let otherGroup = Workspace.get(byName: "Docs")
        let otherSpace = createWorkspaceProject()
        let work = Workspace.get(byName: "Work"); work.assignProject(otherSpace.id)
        let profile = UUID(), live = SurfaceID.browserTab(profile: profile, tab: UUID())
        let sibling = SurfaceID.browserTab(profile: profile, tab: UUID())
        var tree = SurfaceTree(); tree.reconcile([live, sibling], in: regular.name)
        let pin = BrowserSidebarPin(profileID: profile, workspaceName: regular.name, title: "Docs", url: "https://example.com", surfaceID: live)
        let closed = BrowserSidebarPin(profileID: profile, workspaceName: otherGroup.name, title: "Mail", url: "https://example.com/mail")
        let isolated = BrowserSidebarPin(profileID: profile, workspaceName: work.name, title: "Work", url: "https://example.com/work")
        let controller = BrowserWorkspaceController()
        let legacy = SurfaceWorkspaceSnapshot(tree: tree, layoutWorkspaces: [], selected: live, closedBrowserTabs: [], browserPins: [pin, closed, isolated])
        controller.restorePlacementSnapshot(legacy)
        XCTAssertEqual(controller.pinnedDesktops.count, 3)
        XCTAssertEqual(Set(controller.pinShelves.first { $0.spaceID == regular.projectId.rawValue }!.desktopOrder), [pin.id, closed.id])
        XCTAssertEqual(controller.surfaceTree.roots[regular.name]?.flatMap(\.surfaces), [sibling])
        XCTAssertEqual(controller.surfaceTree.workspace(of: live), controller.pinnedDesktops.first { $0.id == pin.id }?.workspaceName)
        XCTAssertEqual(controller.pinShelves.first { $0.spaceID == otherSpace.id.rawValue }?.desktopOrder, [isolated.id])
        let saved = try XCTUnwrap(controller.capturePlacementSnapshot()).validated()
        controller.restorePlacementSnapshot(saved)
        XCTAssertEqual(controller.capturePlacementSnapshot(), saved, "A restart must not migrate again or reorder pins")
    }

    func testNewTabsUseLastRegularGroupAndPinnedGroupCannotBeRenamedOrDeleted() throws {
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID()
        controller.usesSurfaceTree = true
        let regular = focus.workspace, next = Workspace.get(byName: "Second")
        let group = controller.pinnedGroup(for: regular.projectId, source: regular)
        controller.rememberRegularWorkspace(next)
        XCTAssertEqual(controller.regularWorkspaceForNewItem(group), next)
        XCTAssertThrowsError(try renameWorkspaceForSidebar(workspaceName: group.name, displayName: "Renamed"))
        XCTAssertThrowsError(try deleteWorkspace(group))
        XCTAssertFalse(reorderWorkspace(group.name, relativeTo: regular.name, placement: .before))
        var reply: (@MainActor (BrowserActionReply, SurfaceID?) -> Void)?
        controller.connected(connection, processID: -1, sendNewTab: { _, callback in reply = callback }) { _, callback in callback(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: []), epoch: epoch, connection: connection, protocolVersion: 5)
        let created = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        XCTAssertEqual(controller.openBrowserTab(workspaceName: group.name), .issued)
        try XCTUnwrap(reply)(.issued, created)
        XCTAssertEqual(controller.workspaceName(for: created), next.name)
        let ownPins = try XCTUnwrap(controller.capturePlacementSnapshot()).pinnedGroups
        XCTAssertEqual(ownPins.first?.lastRegularWorkspaceName, next.name)
    }

    func testClosedPinOrderAndMovingBetweenSpacesSurviveRoundTrip() throws {
        let controller = BrowserWorkspaceController(), space = createWorkspaceProject()
        let group = controller.pinnedGroup(for: focus.workspace.projectId, source: focus.workspace)
        let pins = (1...3).map { BrowserSidebarPin(profileID: UUID(), workspaceName: group.name, title: "Page \($0)", url: "https://example.com/\($0)") }
        controller.browserSidebarPins = pins
        for pin in pins { controller.appendPinOrder(pin.id, workspace: group.name) }
        controller.migratePinnedDesktops()
        controller.reorderPin(pins[2].id, before: pins[0].id)
        XCTAssertEqual(controller.pinShelves.first?.desktopOrder, [pins[2].id, pins[0].id, pins[1].id])
        XCTAssertTrue(controller.movePin(pins[0].id, to: space.id))
        XCTAssertEqual(controller.pinShelves.first?.desktopOrder, [pins[2].id, pins[1].id])
        XCTAssertEqual(controller.pinShelves.first { $0.spaceID == space.id.rawValue }?.desktopOrder, [pins[0].id])
        XCTAssertEqual(controller.pinTilesByWorkspace().values.flatMap { $0 }.count, 3)
        controller.usesSurfaceTree = true
        let snapshot = try XCTUnwrap(controller.capturePlacementSnapshot()).validated()
        let restored = BrowserWorkspaceController(); restored.restorePlacementSnapshot(snapshot)
        XCTAssertEqual(restored.pinShelves, controller.pinShelves)
        XCTAssertEqual(restored.pinnedDesktops, controller.pinnedDesktops)

    }

    func testFirstPinnedGroupRemembersRegularGroupAlreadyActiveAtStartup() {
        let regular = Workspace.get(byName: "Second")
        XCTAssertTrue(regular.focusWorkspace())
        let controller = BrowserWorkspaceController()
        let group = controller.pinnedGroup(for: regular.projectId)
        XCTAssertEqual(controller.regularWorkspaceForNewItem(group), regular)
        XCTAssertEqual(controller.spacePinnedGroups.first?.lastRegularWorkspaceName, regular.name)
    }

    func testDifferentWindowsOfSameAppOwnIndependentDesktops() throws {
        let controller = BrowserWorkspaceController.shared
        controller.usesSurfaceTree = true
        let regular = focus.workspace
        TestApp.shared.bundlePath = "/Missing/Test.app"
        let first = TestWindow.new(id: 91, parent: regular.rootTilingContainer)
        let second = TestWindow.new(id: 92, parent: regular.rootTilingContainer)
        var tree = SurfaceTree(); tree.reconcile([first.surfaceID, second.surfaceID], in: regular.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        XCTAssertTrue(controller.pinSurface(first.surfaceID))
        let pin = try XCTUnwrap(controller.nativeAppSidebarPins.first)
        XCTAssertEqual(first.nodeWorkspace?.name, pin.workspaceName)
        XCTAssertTrue(controller.pinSurface(second.surfaceID))
        XCTAssertEqual(controller.nativeAppSidebarPins.count, 2)
        XCTAssertEqual(controller.nativeAppSidebarPins.first?.surfaceID, first.surfaceID)
        XCTAssertNotEqual(first.nodeWorkspace, second.nodeWorkspace)
        XCTAssertEqual(first.nodeWorkspace?.name, pin.workspaceName)
        let secondWorkspace = second.nodeWorkspace
        XCTAssertTrue(controller.unpin(pin.id))
        XCTAssertEqual(first.nodeWorkspace?.name, pin.workspaceName)
        XCTAssertFalse(try XCTUnwrap(first.nodeWorkspace).isPinnedGroup)
        XCTAssertEqual(second.nodeWorkspace, secondWorkspace)
        XCTAssertTrue(try XCTUnwrap(secondWorkspace).isPinnedGroup)
        XCTAssertFalse(controller.hasPins(in: pin.workspaceName))
        XCTAssertNoThrow(try controller.capturePlacementSnapshot()?.validated())
    }

    func testPinningDuringSidebarReadDoesNotLeaveDuplicateInRegularWorkspace() async throws {
        let controller = BrowserWorkspaceController.shared
        controller.usesSurfaceTree = true
        let regular = focus.workspace
        let oldPath = TestApp.shared.bundlePath
        TestApp.shared.bundlePath = "/Missing/Test.app"
        defer { TestApp.shared.bundlePath = oldPath }
        let window = TestWindow.new(id: 94, parent: regular.rootTilingContainer)
        let capturedRows = await buildWorkspaceSidebarNativeItems(for: regular, currentFocus: focus)
        XCTAssertEqual(controller.organizedRows(native: capturedRows, in: regular.name).flatMap(\.surfaceIDs), [window.surfaceID])
        XCTAssertTrue(controller.pinSurface(window.surfaceID))
        let pin = try XCTUnwrap(controller.nativeAppSidebarPins.first)

        XCTAssertTrue(controller.organizedRows(native: capturedRows, in: regular.name).isEmpty)
        XCTAssertEqual(controller.surfaceTree.workspace(of: window.surfaceID), pin.workspaceName)
        XCTAssertEqual(controller.pinTiles(in: pin.workspaceName).compactMap(\.surfaceID), [window.surfaceID])

        XCTAssertTrue(controller.unpin(pin.id, to: regular))
        XCTAssertEqual(controller.organizedRows(native: capturedRows, in: regular.name).flatMap(\.surfaceIDs), [window.surfaceID])
    }

    func testMissingAppRemainsVisibleAndCanBeUnpinnedWithoutLaunching() throws {
        let controller = BrowserWorkspaceController()
        controller.usesSurfaceTree = true
        let group = controller.pinnedGroup(for: focus.workspace.projectId)
        let app = NativeAppSidebarPin(workspaceName: group.name, bundleIdentifier: "dev.winmux.missing-test-app",
            bundlePath: "/Missing/Test.app", title: "Missing App")
        controller.nativeAppSidebarPins = [app]; controller.appendPinOrder(app.id, workspace: group.name)
        XCTAssertEqual(controller.selectPin(app.id), .unavailable)
        XCTAssertTrue(try XCTUnwrap(controller.pinTiles(in: group.name).first).isUnavailable)
        XCTAssertTrue(controller.pendingNativePinLaunches.isEmpty)
        XCTAssertNoThrow(try controller.capturePlacementSnapshot()?.validated())
        XCTAssertTrue(controller.unpin(app.id))
        XCTAssertTrue(controller.pinTiles(in: group.name).isEmpty)
    }

    func testEmptyPinnedGroupIsHiddenAndDoesNotChangeRegularNumbering() {
        let controller = BrowserWorkspaceController.shared
        controller.usesSurfaceTree = true
        let regular = focus.workspace
        regular.markAsAutomaticallyNamed()
        let original = workspaceDisplayName(regular.name)
        let group = controller.pinnedGroup(for: regular.projectId, source: regular)
        XCTAssertFalse(userFacingWorkspaces(Workspace.all, focusedWorkspace: regular).contains(group))
        let pin = BrowserSidebarPin(profileID: UUID(), workspaceName: group.name, title: "Docs", url: "https://example.com")
        controller.browserSidebarPins = [pin]; controller.appendPinOrder(pin.id, workspace: group.name)
        XCTAssertTrue(userFacingWorkspaces(Workspace.all, focusedWorkspace: regular).contains(group))
        XCTAssertEqual(workspaceDisplayName(regular.name), original)
        XCTAssertEqual(workspaceDisplayName(group.name), "Pinned")
    }
    func testPinWholeWorkspaceAndUnpinPreserveIdentityAndAllRoots() throws {
        let controller = BrowserWorkspaceController.shared, regular = focus.workspace
        TestApp.shared.bundlePath = "/Missing/Test.app"
        let a = TestWindow.new(id: 991, parent: regular.rootTilingContainer)
        let b = TestWindow.new(id: 992, parent: regular.rootTilingContainer)
        var tree = SurfaceTree(); tree.reconcile([a.surfaceID, b.surfaceID], in: regular.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [regular.name], selected: nil, closedBrowserTabs: []))
        XCTAssertTrue(controller.pinWorkspace(regular.name))
        let desktop = try XCTUnwrap(controller.pinnedDesktops.first)
        XCTAssertEqual(desktop.workspaceName, regular.name)
        XCTAssertEqual(desktop.kind, .group)
        XCTAssertEqual(controller.surfaceTree, tree)
        XCTAssertTrue(controller.unpin(desktop.id))
        XCTAssertFalse(regular.isPinnedGroup)
        XCTAssertEqual(controller.surfaceTree, tree)
        XCTAssertEqual(a.nodeWorkspace, regular); XCTAssertEqual(b.nodeWorkspace, regular)
        XCTAssertNoThrow(try controller.capturePlacementSnapshot()?.validated())
    }

}

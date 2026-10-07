@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor final class IncognitoSpacesTest: XCTestCase {
    let controller = BrowserWorkspaceController.shared
    let connection = UUID(), epoch = UUID(), profile = UUID()

    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.newItemPlacement = .newView
        controller.restorePlacementSnapshot(.init(tree: SurfaceTree(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        controller.connected(connection, processID: -1, send: { _, reply in reply(.issued) })
    }

    override func tearDown() async throws {
        controller.disconnected(connection)
        controller.restorePlacementSnapshot(.init(tree: SurfaceTree(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        controller.usesSurfaceTree = false
        config.newItemPlacement = .tile
    }

    private func page(_ profile: UUID? = nil) -> BrowserTabRecord {
        .init(surfaceID: .browserTab(profile: profile ?? self.profile, tab: UUID()), hostID: UUID().uuidString,
              title: "Private synthetic title", selected: true, privateBrowsing: true, url: "https://example.invalid/private")
    }

    private func receive(_ pages: [BrowserTabRecord], revision: UInt64) {
        controller.received(.init(revision: revision, full: true, tabs: pages), epoch: epoch, connection: connection, protocolVersion: 7)
        for name in Set(pages.compactMap { controller.workspaceName(for: $0.surfaceID) }) {
            _ = controller.organizedRows(native: [], in: name)
        }
    }

    func testTemporarySpaceContainsOnlyPrivateTabsAndDisappearsAfterLastClose() throws {
        let original = focus.workspace, first = page(), second = page()
        receive([first, second], revision: 1)
        let name = try XCTUnwrap(controller.workspaceName(for: first.surfaceID))
        let view = try XCTUnwrap(Workspace.existing(byName: name))
        XCTAssertTrue(view.isIncognito)
        XCTAssertNotEqual(view.projectId, original.projectId)
        XCTAssertEqual(workspaceProjectName(view.projectId), "Incognito")
        XCTAssertEqual(Workspace.existing(byName: try XCTUnwrap(controller.workspaceName(for: second.surfaceID)))?.projectId, view.projectId)
        XCTAssertFalse(controller.pinSurface(first.surfaceID))
        XCTAssertFalse(moveSurfaceToWorkspace(first.surfaceID, original, CmdIo(stdin: .emptyStdin), focusFollowsSurface: false, failIfNoop: false))
        XCTAssertTrue(view.focusWorkspace())
        receive([second], revision: 2)
        XCTAssertNotNil(winMuxWorkspaceState.projectsById[view.projectId])
        receive([], revision: 3)
        XCTAssertNil(winMuxWorkspaceState.projectsById[view.projectId])
        XCTAssertFalse(Workspace.all.contains(where: \.isIncognito))
        XCTAssertFalse(focus.workspace.isIncognito)
        XCTAssertTrue(controller.privateSurfaces.isEmpty)
        XCTAssertFalse(controller.closedBrowserTabs.contains(first.surfaceID))
        XCTAssertFalse(controller.closedBrowserTabs.contains(second.surfaceID))
    }

    func testPrivateStateNeverEntersRestartSnapshotIncludingMonitorMemory() throws {
        let tab = page()
        receive([tab], revision: 1)
        let view = try XCTUnwrap(Workspace.existing(byName: try XCTUnwrap(controller.workspaceName(for: tab.surfaceID))))
        XCTAssertTrue(view.focusWorkspace())
        let snapshot = RestartSessionSnapshot.capture()
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(snapshot.world.workspaces.contains { $0.name == view.name })
        XCTAssertFalse(snapshot.world.monitors.contains { $0.visibleWorkspace == view.name })
        for value in [tab.surfaceID.description, view.projectId.rawValue, tab.title, tab.url] {
            XCTAssertFalse(json.contains(value), value)
        }
        XCTAssertNoThrow(try snapshot.surfaces?.validated())
    }

    func testSeparatePrivateProfilesCannotMixAndRegularTabsStayOutside() throws {
        let a = page(), b = page(UUID())
        receive([a, b], revision: 1)
        let source = try XCTUnwrap(Workspace.existing(byName: try XCTUnwrap(controller.workspaceName(for: a.surfaceID))))
        let target = try XCTUnwrap(Workspace.existing(byName: try XCTUnwrap(controller.workspaceName(for: b.surfaceID))))
        XCTAssertNotEqual(source.projectId, target.projectId)
        XCTAssertFalse(controller.moveUsingDestinationProfile([a.surfaceID], to: target, commit: { XCTFail(); return true }) ?? true)
        XCTAssertTrue(source.focusWorkspace())
        let regular = BrowserTabRecord(surfaceID: .browserTab(profile: UUID(), tab: UUID()), hostID: "regular", title: "Regular", selected: true)
        receive([a, b, regular], revision: 2)
        let destination = try XCTUnwrap(Workspace.existing(byName: try XCTUnwrap(controller.workspaceName(for: regular.surfaceID))))
        XCTAssertFalse(destination.isIncognito)
        XCTAssertFalse(controller.canPlaceSurface(regular.surfaceID, in: source))
        XCTAssertTrue(windowMoveMenuDestinations().allSatisfy { !$0.id.isIncognito })
        XCTAssertEqual(windowMoveMenuDestinations(sourceSpace: source.projectId).map(\.id), [source.projectId])
    }

    func testReconnectRecreatesPrivateSpaceWithoutRecoveryOrPersistence() throws {
        let tab = page()
        receive([tab], revision: 1)
        controller.disconnected(connection)
        XCTAssertFalse(Workspace.all.contains(where: \.isIncognito))
        controller.connected(connection, processID: -1, send: { _, reply in reply(.issued) })
        receive([tab], revision: 1)
        XCTAssertTrue(Workspace.existing(byName: try XCTUnwrap(controller.workspaceName(for: tab.surfaceID)))?.isIncognito == true)
        XCTAssertNil(controller.capturePlacementSnapshot()?.tree.workspace(of: tab.surfaceID))
    }

    func testNewTabInsidePrivateSpaceUsesExactPrivateOwner() throws {
        let tab = page()
        receive([tab], revision: 1)
        controller.disconnected(connection)
        var request: BrowserNewTabRequest?
        controller.connected(connection, processID: -1, sendNewTab: { value, reply in request = value; reply(.unavailable, nil) }, send: { _, reply in reply(.issued) })
        receive([tab], revision: 1)
        let current = try XCTUnwrap(controller.workspaceName(for: tab.surfaceID))
        XCTAssertEqual(controller.openBrowserTab(workspaceName: current), .issued)
        XCTAssertEqual(request?.sourceSurfaceID, tab.surfaceID)
        XCTAssertNil(request?.workspaceProfile)
    }

    func testNativeDragAndDirectBindingCannotEnterPrivateSpace() throws {
        let original = focus.workspace, tab = page()
        receive([tab], revision: 1)
        let target = try XCTUnwrap(Workspace.existing(byName: try XCTUnwrap(controller.workspaceName(for: tab.surfaceID))))
        let window = TestWindow.new(id: 301, parent: original.rootTilingContainer)
        applySidebarWorkspaceMove(sourceNode: window, sourceWindow: window, targetWorkspace: target)
        XCTAssertTrue(window.nodeWorkspace === original)
        window.bind(to: target.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        XCTAssertTrue(window.nodeWorkspace === original)
        let arriving = TestWindow.new(id: 302, parent: target.rootTilingContainer)
        XCTAssertFalse(arriving.nodeWorkspace?.isIncognito ?? true)
        XCTAssertTrue(target.allLeafWindowsRecursive.isEmpty)
    }
}

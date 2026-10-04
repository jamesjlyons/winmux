@testable import AppBundle
import AppKit
import WorkspaceCore
import XCTest

@MainActor
final class BrowserSidebarPinsTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func record(_ id: SurfaceID, title: String = "Docs", url: String = "https://example.com/docs") -> BrowserTabRecord {
        .init(surfaceID: id, hostID: "host", title: title, selected: false, url: url)
    }

    private func controller(_ ids: [SurfaceID]) -> (BrowserWorkspaceController, UUID, UUID) {
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID()
        controller.usesSurfaceTree = true
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: ids.map { record($0) }),
                            epoch: epoch, connection: connection, protocolVersion: 5)
        return (controller, connection, epoch)
    }

    func testPinMovesIntoItsOwnGroupAndUnpinKeepsTheLivePage() throws {
        let regular = focus.workspace.name
        let profile = UUID(), pinID = SurfaceID.browserTab(profile: profile, tab: UUID())
        let ordinary = SurfaceID.browserTab(profile: profile, tab: UUID())
        let (controller, _, _) = controller([pinID, ordinary])
        _ = controller.organizedRows(native: [], in: regular)
        var tree = SurfaceTree(); tree.reconcile([pinID, ordinary], in: regular)
        tree.group(pinID, with: ordinary)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        XCTAssertTrue(controller.pinBrowserTab(pinID))
        XCTAssertFalse(controller.pinBrowserTab(pinID))
        let pin = try XCTUnwrap(controller.browserSidebarPins.first)
        let group = try XCTUnwrap(Workspace.existing(byName: pin.workspaceName))
        XCTAssertTrue(group.isPinnedGroup)
        XCTAssertEqual(controller.organizedRows(native: [], in: regular).flatMap(\.surfaceIDs), [ordinary])
        XCTAssertEqual(controller.surfaceTree.workspace(of: pinID), group.name)
        XCTAssertEqual(controller.pinTiles(in: group.name).map(\.id), [pin.id])
        XCTAssertNoThrow(try controller.capturePlacementSnapshot()?.validated())
        controller.unpinBrowserTab(pin.id)
        XCTAssertEqual(controller.workspaceName(for: pinID), regular)
        XCTAssertFalse(controller.hasPins(in: group.name))
        XCTAssertTrue(controller.isAvailable(pinID))
    }

    func testClosingPinPreservesItsOriginalURLProfileIconAndSearchIdentity() throws {
        let regular = focus.workspace.name
        let profile = UUID(), id = SurfaceID.browserTab(profile: profile, tab: UUID())
        let (controller, connection, epoch) = controller([id])
        _ = controller.organizedRows(native: [], in: regular)
        XCTAssertTrue(controller.pinBrowserTab(id))
        let group = try XCTUnwrap(controller.browserSidebarPins.first?.workspaceName)
        controller.browserSidebarPins[0].iconPNGBase64 = "cached-icon"
        controller.received(.init(revision: 2, full: false, tabs: [record(id, title: "Other", url: "https://example.com/other")]),
                            epoch: epoch, connection: connection, protocolVersion: 5)
        controller.received(.init(revision: 3, full: false, tabs: [], removed: [id]),
                            epoch: epoch, connection: connection, protocolVersion: 5)
        let saved = try XCTUnwrap(controller.capturePlacementSnapshot()).validated()
        XCTAssertEqual(saved.browserPins.first?.url, "https://example.com/docs")
        XCTAssertEqual(saved.browserPins.first?.title, "Docs")
        XCTAssertEqual(saved.browserPins.first?.profileID, profile)
        XCTAssertNil(saved.browserPins.first?.surfaceID)
        let restored = BrowserWorkspaceController()
        restored.restorePlacementSnapshot(saved)
        let pins = restored.pinTiles(in: group)
        let pin = try XCTUnwrap(pins.first)
        XCTAssertFalse(pin.isOpen)
        XCTAssertEqual(pin.iconPNGBase64, "cached-icon")
        XCTAssertTrue(restored.surfaceTree.roots.values.flatMap { $0.flatMap(\.surfaces) }.isEmpty)
        let workspace = WorkspaceSidebarWorkspaceViewModel(name: group, projectId: workspaceProjectDefaultId,
            displayName: "Pinned", sidebarLabel: "", isGeneratedName: false, monitorScopeId: "test", monitorName: "",
            isFocused: true, isVisible: true, items: [], isPinnedGroup: true, pins: pins)
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [workspace]), [.pinnedBrowserTab(pin.id)])
        let filtered = workspaceSidebarFilteredWorkspacesByProject([workspaceProjectDefaultId: [workspace]], projects: [], query: "example.com/docs")
        XCTAssertEqual(filtered[workspaceProjectDefaultId]?.first?.pins.map(\.id), [pin.id])
    }

    func testClosedPinOpensSavedURLInItsSpaceAndWaitsForInventoryBeforeAnotherOpen() throws {
        let profile = UUID(), newID = SurfaceID.browserTab(profile: profile, tab: UUID())
        let pin = BrowserSidebarPin(profileID: profile, workspaceName: "Saved", title: "Docs", url: "https://example.com/docs")
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID()
        controller.restorePlacementSnapshot(.init(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: [], browserPins: [pin]))
        var requests: [BrowserNewTabRequest] = []
        var creationReply: (@MainActor (BrowserActionReply, SurfaceID?) -> Void)?
        controller.connected(connection, processID: -1, sendNewTab: { request, reply in
            requests.append(request); creationReply = reply
        }) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: []), epoch: epoch, connection: connection, protocolVersion: 5)
        XCTAssertTrue(requests.isEmpty, "Restoration only displays saved shortcuts")
        XCTAssertEqual(controller.selectPinnedBrowserTab(pin.id), .issued)
        XCTAssertEqual(requests.first?.url, pin.url)
        XCTAssertEqual(requests.first?.profileID, profile)
        XCTAssertEqual(controller.selectPinnedBrowserTab(pin.id), .issued)
        XCTAssertEqual(requests.count, 1)
        try XCTUnwrap(creationReply)(.issued, newID)
        XCTAssertEqual(controller.workspaceName(for: newID), controller.browserSidebarPins.first?.workspaceName)
        XCTAssertEqual(controller.selectPinnedBrowserTab(pin.id), .issued)
        XCTAssertEqual(requests.count, 1, "A creation reply can precede authoritative inventory")
        controller.received(.init(revision: 2, full: false, tabs: [record(newID)]), epoch: epoch, connection: connection, protocolVersion: 5)
        XCTAssertEqual(controller.browserSidebarPins.first?.surfaceID, newID)
        XCTAssertTrue(controller.pendingSidebarPinOpenings.isEmpty)
        XCTAssertEqual(controller.selectPinnedBrowserTab(pin.id), .issued)
        XCTAssertEqual(requests.count, 1, "An open pin focuses its existing page")
    }

    func testFailedOpenCanRetryAndUnpinDuringCreationDoesNotRecreateShortcut() throws {
        let profile = UUID(), newID = SurfaceID.browserTab(profile: profile, tab: UUID())
        let pin = BrowserSidebarPin(profileID: profile, workspaceName: "Saved", title: "Docs", url: "https://example.com/docs")
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID()
        controller.restorePlacementSnapshot(.init(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: [], browserPins: [pin]))
        var replies: [@MainActor (BrowserActionReply, SurfaceID?) -> Void] = []
        controller.connected(connection, processID: -1, sendNewTab: { _, reply in replies.append(reply) }) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: []), epoch: epoch, connection: connection, protocolVersion: 5)
        XCTAssertEqual(controller.selectPinnedBrowserTab(pin.id), .issued)
        replies[0](.unavailable, nil)
        XCTAssertTrue(controller.pendingSidebarPinOpenings.isEmpty)
        XCTAssertEqual(controller.selectPinnedBrowserTab(pin.id), .issued)
        XCTAssertEqual(replies.count, 2)
        controller.unpinBrowserTab(pin.id)
        replies[1](.issued, newID)
        XCTAssertTrue(controller.browserSidebarPins.isEmpty)
    }

    func testRestoredMissingLivePinBecomesClosedShortcutWithoutGhostPane() throws {
        let profile = UUID(), oldID = SurfaceID.browserTab(profile: profile, tab: UUID())
        let other = SurfaceID.browserTab(profile: profile, tab: UUID())
        let pin = BrowserSidebarPin(profileID: profile, workspaceName: "Saved", title: "Docs", url: "https://example.com/docs", surfaceID: oldID)
        var tree = SurfaceTree(); tree.reconcile([oldID], in: "Saved")
        let controller = BrowserWorkspaceController(), connection = UUID()
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: ["Saved"], selected: nil, closedBrowserTabs: [], browserPins: [pin]))
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [record(other)]), epoch: UUID(), connection: connection, protocolVersion: 5)
        XCTAssertNil(controller.browserSidebarPins.first?.surfaceID)
        XCTAssertNil(controller.surfaceTree.workspace(of: oldID))
        XCTAssertEqual(controller.pinTiles(in: try XCTUnwrap(controller.browserSidebarPins.first?.workspaceName)).count, 1)
        XCTAssertNoThrow(try controller.capturePlacementSnapshot()?.validated())
    }

    func testOtherOwnerInventoryDoesNotCloseLivePinAndDisconnectDoesNotDuplicateIt() throws {
        let profile = UUID(), pinnedID = SurfaceID.browserTab(profile: profile, tab: UUID())
        let other = SurfaceID.browserTab(profile: profile, tab: UUID())
        let (controller, firstConnection, _) = controller([pinnedID])
        _ = controller.organizedRows(native: [], in: focus.workspace.name)
        XCTAssertTrue(controller.pinBrowserTab(pinnedID))
        let pin = try XCTUnwrap(controller.browserSidebarPins.first)
        let secondConnection = UUID()
        var creations = 0
        controller.connected(secondConnection, processID: -2, sendNewTab: { _, reply in
            creations += 1; reply(.issued, SurfaceID.browserTab(profile: profile, tab: UUID()))
        }) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [record(other)]), epoch: UUID(), connection: secondConnection, protocolVersion: 5)
        XCTAssertEqual(controller.browserSidebarPins.first?.surfaceID, pinnedID, "Another session's snapshot cannot remove a live owner's page")
        controller.disconnected(firstConnection)
        XCTAssertEqual(controller.selectPinnedBrowserTab(pin.id), .unavailable)
        XCTAssertEqual(creations, 0, "A lost connection is not a confirmed tab close")
    }

    func testUnpinDuringLostConnectionMovesReservedPageToRegularGroup() throws {
        let regular = focus.workspace.name
        let id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let (controller, connection, _) = controller([id])
        _ = controller.organizedRows(native: [], in: regular)
        XCTAssertTrue(controller.pinBrowserTab(id))
        let pin = try XCTUnwrap(controller.browserSidebarPins.first)
        controller.disconnected(connection)
        XCTAssertTrue(controller.unpin(pin.id))
        XCTAssertEqual(controller.workspaceName(for: id), regular)
        XCTAssertTrue(controller.browserSidebarPins.isEmpty)
        XCTAssertNoThrow(try controller.capturePlacementSnapshot()?.validated())
    }

    func testUnpinSelectedPageReturnsItsFocusToRegularGroup() throws {
        let regular = focus.workspace
        let id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let (controller, _, _) = controller([id])
        _ = controller.organizedRows(native: [], in: regular.name)
        XCTAssertTrue(controller.pinBrowserTab(id))
        let pin = try XCTUnwrap(controller.browserSidebarPins.first)
        XCTAssertEqual(controller.select(id), .issued)
        XCTAssertEqual(focus.workspace.name, pin.workspaceName)
        XCTAssertTrue(controller.unpin(pin.id))
        XCTAssertEqual(focus.workspace, regular)
        XCTAssertEqual(controller.focusCoordinator.target, id)
    }

    func testBrowserProcessRestartCanRetireTheOldPinReservation() throws {
        let profile = UUID(), oldID = SurfaceID.browserTab(profile: profile, tab: UUID())
        let restoredPage = SurfaceID.browserTab(profile: profile, tab: UUID())
        let (controller, oldConnection, _) = controller([oldID])
        _ = controller.organizedRows(native: [], in: focus.workspace.name)
        XCTAssertTrue(controller.pinBrowserTab(oldID))
        controller.disconnected(oldConnection)
        let newConnection = UUID()
        controller.connected(newConnection, processID: ProcessInfo.processInfo.processIdentifier) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [record(restoredPage)]), epoch: UUID(), connection: newConnection, protocolVersion: 5)
        XCTAssertNil(controller.browserSidebarPins.first?.surfaceID)
        XCTAssertTrue(controller.unresolvedSidebarPinOwners.isEmpty)
        XCTAssertNil(controller.surfaceTree.workspace(of: oldID))
        XCTAssertNoThrow(try controller.capturePlacementSnapshot()?.validated())
    }

    func testMovingPinDuringCreationUsesLatestSpaceWithoutOverridingNewFocus() throws {
        let profile = UUID(), newID = SurfaceID.browserTab(profile: profile, tab: UUID())
        let pin = BrowserSidebarPin(profileID: profile, workspaceName: "Saved", title: "Docs", url: "https://example.com/docs")
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID()
        controller.restorePlacementSnapshot(.init(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: [], browserPins: [pin]))
        var creationReply: (@MainActor (BrowserActionReply, SurfaceID?) -> Void)?
        controller.connected(connection, processID: -1, sendNewTab: { _, reply in creationReply = reply }) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: []), epoch: epoch, connection: connection, protocolVersion: 5)
        let native = TestWindow.new(id: 91, parent: focus.workspace.rootTilingContainer)
        let firstSpace = createWorkspaceProject(), secondSpace = createWorkspaceProject()
        XCTAssertEqual(controller.selectPinnedBrowserTab(pin.id), .issued)
        controller.movePin(pin.id, to: firstSpace.id)
        XCTAssertEqual(controller.select(native.surfaceID), .issued)
        try XCTUnwrap(creationReply)(.issued, newID)
        XCTAssertEqual(controller.workspaceName(for: newID), controller.pinnedGroup(for: firstSpace.id).name)
        XCTAssertEqual(controller.focusCoordinator.target, native.surfaceID)
        controller.movePin(pin.id, to: secondSpace.id)
        XCTAssertEqual(controller.workspaceName(for: newID), controller.pinnedGroup(for: secondSpace.id).name)
        controller.received(.init(revision: 2, full: false, tabs: [record(newID)]), epoch: epoch, connection: connection, protocolVersion: 5)
        XCTAssertEqual(controller.browserSidebarPins.first?.workspaceName, controller.pinnedGroup(for: secondSpace.id).name)
        XCTAssertEqual(controller.focusCoordinator.target, native.surfaceID)
        XCTAssertTrue(controller.pendingSidebarPinOpenings.isEmpty)
        XCTAssertNoThrow(try controller.capturePlacementSnapshot()?.validated())
    }

    func testDraggingLivePinIntoRegularGroupUnpinsWithoutClosing() throws {
        let id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let (controller, _, _) = controller([id])
        _ = controller.organizedRows(native: [], in: focus.workspace.name)
        XCTAssertTrue(controller.pinBrowserTab(id))
        let group = try XCTUnwrap(controller.browserSidebarPins.first?.workspaceName)
        _ = Workspace.get(byName: "Destination")
        controller.moveBrowserSurface(id, to: "Destination")
        controller.syncSidebarPins()
        XCTAssertTrue(controller.pinTiles(in: group).isEmpty)
        XCTAssertTrue(controller.browserSidebarPins.isEmpty)
        XCTAssertEqual(controller.workspaceName(for: id), "Destination")
        XCTAssertTrue(controller.isAvailable(id))
        XCTAssertNoThrow(try controller.capturePlacementSnapshot()?.validated())
    }
}

@testable import AppBundle
import Foundation
import Common
import WorkspaceCore
import XCTest

@MainActor final class BrowserNewTabTest: XCTestCase {
    func testCreationCapturesWorkspaceAndPlacesInventoryBeforeOrAfterReply() throws {
        for inventoryFirst in [true, false] {
            setUpWorkspacesForTests()
            let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID()
            let id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
            var callback: (@MainActor (BrowserActionReply, SurfaceID?) -> Void)?
            controller.connected(connection, processID: -1, sendNewTab: { _, reply in callback = reply }, send: { _, reply in reply(.issued) })
            controller.received(.init(revision: 1, full: true, tabs: []), epoch: epoch, connection: connection, protocolVersion: 5)
            let requestedWorkspace = focus.workspace.name
            XCTAssertEqual(controller.openBrowserTab(workspaceName: requestedWorkspace), .issued)
            let message = BrowserInventoryMessage(revision: 2, full: true, tabs: [.init(surfaceID: id, hostID: "host", title: "New", selected: true)])
            if inventoryFirst { controller.received(message, epoch: epoch, connection: connection, protocolVersion: 5) }
            callback?(.issued, id)
            if !inventoryFirst { controller.received(message, epoch: epoch, connection: connection, protocolVersion: 5) }
            XCTAssertEqual(controller.workspaceName(for: id), requestedWorkspace)
            XCTAssertEqual(controller.focusCoordinator.target, id)
            controller.disconnected(connection)
        }
    }

    func testCreationRecordsOpenerOnlyForTabContext() {
        for fromTab in [true, false] {
            setUpWorkspacesForTests()
            config.newItemPlacement = .tile
            let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID(), profile = UUID()
            controller.usesSurfaceTree = true
            let source = SurfaceID.browserTab(profile: profile, tab: UUID())
            let child = SurfaceID.browserTab(profile: profile, tab: UUID())
            var callback: (@MainActor (BrowserActionReply, SurfaceID?) -> Void)?
            controller.connected(connection, processID: -1, sendNewTab: { _, reply in callback = reply }, send: { _, reply in reply(.issued) })
            controller.received(.init(revision: 1, full: true, tabs: [.init(surfaceID: source, hostID: "host", title: "Source", selected: true)]), epoch: epoch, connection: connection, protocolVersion: 5)
            XCTAssertEqual(controller.select(source), .issued)
            let destination = focus.workspace.name
            XCTAssertEqual(controller.openBrowserTab(workspaceName: fromTab ? nil : destination), .issued)
            callback?(.issued, child)
            XCTAssertEqual(controller.tabOpeners[child], fromTab ? source : nil)
            controller.received(.init(revision: 2, full: true, tabs: [source, child].map {
                .init(surfaceID: $0, hostID: "host", title: "Page", selected: true)
            }), epoch: epoch, connection: connection, protocolVersion: 5)
            XCTAssertEqual(controller.focusCoordinator.target, child)
            XCTAssertEqual(controller.tabOpeners[child], fromTab ? source : nil)
            controller.disconnected(connection)
        }
    }

    func testNewRequestRetiresOlderReplyWaitingForInventory() {
        setUpWorkspacesForTests()
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID(), profile = UUID()
        let first = SurfaceID.browserTab(profile: profile, tab: UUID()), second = SurfaceID.browserTab(profile: profile, tab: UUID())
        var replies: [@MainActor (BrowserActionReply, SurfaceID?) -> Void] = []
        controller.connected(connection, processID: -1, sendNewTab: { _, reply in replies.append(reply) }, send: { _, reply in reply(.issued) })
        controller.received(.init(revision: 1, full: true, tabs: []), epoch: epoch, connection: connection, protocolVersion: 5)
        _ = controller.openBrowserTab()
        replies[0](.issued, first)
        _ = controller.openBrowserTab()
        controller.received(.init(revision: 2, full: true, tabs: [.init(surfaceID: first, hostID: "host", title: "", selected: true)]), epoch: epoch, connection: connection, protocolVersion: 5)
        XCTAssertNil(controller.focusCoordinator.target)
        replies[1](.issued, second)
        controller.received(.init(revision: 3, full: true, tabs: [first, second].map { .init(surfaceID: $0, hostID: "host", title: "", selected: false) }), epoch: epoch, connection: connection, protocolVersion: 5)
        XCTAssertEqual(controller.focusCoordinator.target, second)
        controller.disconnected(connection)
    }

    func testOlderCreationReplyDoesNotReplaceNewerSelection() {
        setUpWorkspacesForTests()
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID(), profile = UUID()
        let first = SurfaceID.browserTab(profile: profile, tab: UUID()), second = SurfaceID.browserTab(profile: profile, tab: UUID())
        var replies: [@MainActor (BrowserActionReply, SurfaceID?) -> Void] = []
        controller.connected(connection, processID: -1, sendNewTab: { _, reply in replies.append(reply) }, send: { _, reply in reply(.issued) })
        controller.received(.init(revision: 1, full: true, tabs: []), epoch: epoch, connection: connection, protocolVersion: 5)
        _ = controller.openBrowserTab(); _ = controller.openBrowserTab()
        controller.received(.init(revision: 2, full: true, tabs: [first, second].map { .init(surfaceID: $0, hostID: "host", title: "", selected: false) }), epoch: epoch, connection: connection, protocolVersion: 5)
        replies[1](.issued, second)
        replies[0](.issued, first)
        XCTAssertEqual(controller.focusCoordinator.target, second)
        controller.disconnected(connection)
    }
}

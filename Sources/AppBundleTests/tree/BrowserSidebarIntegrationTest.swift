@testable import AppBundle
import AppKit
import WorkspaceCore
import XCTest

@MainActor
final class BrowserSidebarIntegrationTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testBrowserRowsShareNativeSidebarAndSearchWithoutNativeBindings() async throws {
        let controller = BrowserWorkspaceController()
        let connection = UUID(), epoch = UUID()
        let id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var requests: [BrowserActionRequest] = []
        controller.connected(connection, processID: -1) { request, reply in requests.append(request); reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [record(id)]), epoch: epoch, connection: connection)
        let rows = controller.rows(in: focus.workspace.name)
        XCTAssertEqual(rows.map(\.id), [id.description])
        XCTAssertNil(Window.get(bySurfaceID: id))
        let native = TestWindow.new(id: 41, parent: focus.workspace.rootTilingContainer)
        let nativeRow = await makeWorkspaceSidebarWindowViewModel(for: native, workspaceName: focus.workspace.name, currentFocus: focus)
        let workspace = WorkspaceSidebarWorkspaceViewModel(name: focus.workspace.name, projectId: workspaceProjectDefaultId,
            displayName: "Test", sidebarLabel: "", isGeneratedName: false, monitorScopeId: "test", monitorName: "Test",
            isFocused: true, isVisible: true, items: [.init(kind: .window(nativeRow))] + rows)
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: [workspace]), [.surface(native.surfaceID), .surface(id)])
        let filtered = workspaceSidebarFilteredWorkspacesByProject([workspaceProjectDefaultId: [workspace]], projects: [], query: "Synthetic web")
        XCTAssertEqual(filtered[workspaceProjectDefaultId]?.first?.items.map(\.id), [id.description])
        XCTAssertEqual(controller.select(id), .issued)
        controller.close(id)
        XCTAssertEqual(requests.map(\.action), [.focus, .close])
        XCTAssertEqual(controller.rows(in: focus.workspace.name).count, 1, "Close acknowledgement isn't removal")
        controller.received(.init(revision: 2, full: false, tabs: [], removed: [id]), epoch: epoch, connection: connection)
        XCTAssertTrue(controller.rows(in: focus.workspace.name).isEmpty)
        XCTAssertEqual(controller.select(id), .unavailable)
    }

    func testNativeFocusFencesBrowserAndLateReplyCannotRefocusAnOlderNativeTarget() {
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID()
        let tab = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var requests: [BrowserActionRequest] = []
        var replies: [@MainActor (BrowserActionReply) -> Void] = []
        controller.connected(connection, processID: -1) { request, reply in requests.append(request); replies.append(reply) }
        controller.received(.init(revision: 1, full: true, tabs: [record(tab)]), epoch: epoch, connection: connection)
        let a = TestWindow.new(id: 41, parent: focus.workspace.rootTilingContainer)
        let b = TestWindow.new(id: 42, parent: focus.workspace.rootTilingContainer)
        XCTAssertEqual(controller.select(tab), .issued)
        XCTAssertEqual(controller.select(a.surfaceID), .issued)
        XCTAssertTrue(TestApp.shared.focusedWindow === a, "Native focus must not await the browser")
        XCTAssertEqual(controller.select(b.surfaceID), .issued)
        replies[1](.issued)
        replies[0](.issued)
        XCTAssertTrue(TestApp.shared.focusedWindow === b)
        XCTAssertEqual(requests.map(\.generation), [1, 2, 3])
        XCTAssertEqual(requests.map(\.action), [.focus, .cancelFocus, .cancelFocus])
        XCTAssertNil(controller.owner(of: tab)?.focusIntent)
    }

    func testDisconnectAndDuplicateOwnersCannotResurrectOrMisrouteRows() {
        let controller = BrowserWorkspaceController(), a = UUID(), b = UUID(), epoch = UUID()
        let tab = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let message = BrowserInventoryMessage(revision: 1, full: true, tabs: [record(tab)])
        controller.connected(a, processID: -1) { _, _ in XCTFail("Ambiguous target dispatched") }
        controller.connected(b, processID: -1) { _, _ in XCTFail("Ambiguous target dispatched") }
        controller.received(message, epoch: epoch, connection: a)
        controller.received(message, epoch: epoch, connection: b)
        XCTAssertEqual(controller.select(tab), .unavailable)
        XCTAssertTrue(controller.rows(in: focus.workspace.name).isEmpty)
        controller.disconnected(a)
        controller.disconnected(b)
        controller.received(.init(revision: 2, full: true, tabs: [record(tab)]), epoch: epoch, connection: a)
        XCTAssertTrue(controller.rows(in: focus.workspace.name).isEmpty)
    }

    func testMultipleBrowserFencesReaffirmOnlyTheCurrentOwner() {
        let controller = BrowserWorkspaceController()
        let ids = (0..<3).map { _ in SurfaceID.browserTab(profile: UUID(), tab: UUID()) }
        var requests: [(Int, BrowserActionRequest, @MainActor (BrowserActionReply) -> Void)] = []
        for index in ids.indices {
            let connection = UUID()
            controller.connected(connection, processID: -1) { request, reply in requests.append((index, request, reply)) }
            controller.received(.init(revision: 1, full: true, tabs: [record(ids[index])]), epoch: UUID(), connection: connection)
        }
        XCTAssertEqual(controller.select(ids[0]), .issued)
        let fences = requests.filter { $0.1.action == .cancelFocus }
        XCTAssertEqual(fences.count, 2)
        for fence in fences { fence.2(.issued) }
        XCTAssertEqual(requests.filter { $0.0 == 0 && $0.1.action == .focus }.count, 3)
        XCTAssertEqual(controller.focusCoordinator.target, ids[0])
        let native = TestWindow.new(id: 41, parent: focus.workspace.rootTilingContainer)
        XCTAssertEqual(controller.select(native.surfaceID), .issued)
        let count = requests.count
        fences[0].2(.issued)
        XCTAssertEqual(requests.count, count, "Old browser fence must not supersede a newer native selection")
    }

    func testAuthenticatedProcessRemainsExcludedAcrossTransientDisconnect() {
        let controller = BrowserWorkspaceController(), connection = UUID()
        let pid = ProcessInfo.processInfo.processIdentifier
        controller.connected(connection, processID: pid) { _, _ in }
        XCTAssertTrue(controller.excludesNativeDiscovery(processID: pid))
        controller.disconnected(connection)
        XCTAssertTrue(controller.excludesNativeDiscovery(processID: pid))
        XCTAssertFalse(controller.excludesNativeDiscovery(processID: -1))
    }

    private func record(_ id: SurfaceID) -> BrowserTabRecord {
        .init(surfaceID: id, hostID: "host:1", title: "Synthetic web tab", selected: true, hostWindowID: 91)
    }
}

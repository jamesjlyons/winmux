@testable import AppBundle
import AppKit
import WorkspaceCore
import XCTest

@MainActor
final class BrowserSidebarIntegrationTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testSidebarProjectionMatchesLiveRowsAndRefreshesOwnershipAndIcons() throws {
        let controller = BrowserWorkspaceController(), connection = UUID(), duplicate = UUID(), epoch = UUID()
        let first = SurfaceID.browserTab(profile: UUID(), tab: UUID()), second = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var tree = SurfaceTree()
        tree.reconcile([first], in: "one"); tree.reconcile([second], in: "two")
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        defer { controller.disconnected(connection); controller.disconnected(duplicate) }
        let icon = favicon(red: 255, blue: 0)
        let record = BrowserTabRecord(surfaceID: first, hostID: "first", title: "Website", selected: false, iconPNGBase64: icon)
        controller.received(.init(revision: 1, full: true, tabs: [record,
            .init(surfaceID: second, hostID: "second", title: "Other", selected: false)]), epoch: epoch, connection: connection)
        let before = controller.sidebarProjection()
        for name in ["one", "two"] {
            XCTAssertEqual(before.rowsByWorkspace[name], controller.rows(in: name))
            XCTAssertEqual(controller.organizedRows(native: [], in: name, projection: before),
                           controller.organizedRows(native: [], in: name))
        }
        XCTAssertEqual(controller.surfaceTree.workspace(of: first), "one")
        controller.connected(duplicate, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [record]), epoch: UUID(), connection: duplicate)
        XCTAssertNil(controller.sidebarProjection().rowsByWorkspace["one"], "Ambiguous owners must not produce actionable rows")
        XCTAssertEqual(controller.sidebarProjection().rowsByWorkspace["two"]?.count, 1)
        controller.disconnected(duplicate)
        controller.received(.init(revision: 2, full: false, tabs: [
            .init(surfaceID: first, hostID: "first", title: "Navigated", selected: false, iconPNGBase64: nil),
        ]), epoch: epoch, connection: connection)
        XCTAssertNil(controller.sidebarProjection().rowsByWorkspace["one"]?.first?.surfaceItems.first?.iconPNGBase64)
        XCTAssertEqual(before.rowsByWorkspace["one"]?.first?.surfaceItems.first?.iconPNGBase64, icon,
            "The projection is a per-refresh value, not a persistent cache with stale invalidation")
    }

    func testCurrentWebsiteFaviconReachesSharedRowsAndSearchAfterNavigation() throws {
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID()
        controller.usesSurfaceTree = true
        let id = SurfaceID.browserTab(profile: UUID(), tab: UUID()), workspace = focus.workspace.name
        let first = favicon(red: 255, blue: 0), second = favicon(red: 0, blue: 255)
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        defer { controller.disconnected(connection) }
        func receive(_ revision: UInt64, icon: String?) {
            controller.received(.init(revision: revision, full: true, tabs: [
                .init(surfaceID: id, hostID: "host", title: "Website", selected: true, iconPNGBase64: icon),
            ]), epoch: epoch, connection: connection)
        }
        receive(1, icon: first)
        let before = controller.organizedRows(native: [], in: workspace)
        XCTAssertEqual(before.flatMap(\.surfaceItems).first?.iconPNGBase64, first)
        receive(2, icon: second)
        let after = controller.organizedRows(native: [], in: workspace)
        XCTAssertNotEqual(before, after, "A favicon-only update must publish a changed sidebar snapshot")
        let model = WorkspaceSidebarWorkspaceViewModel(name: workspace, projectId: workspaceProjectDefaultId,
            displayName: "View", sidebarLabel: "", isGeneratedName: true, monitorScopeId: "test", monitorName: nil,
            isFocused: false, isVisible: true, items: after)
        let filtered = workspaceSidebarFilteredWorkspacesByProject([workspaceProjectDefaultId: [model]], projects: [], query: "Website")
        XCTAssertEqual(filtered[workspaceProjectDefaultId]?.first?.viewSurfaces.first?.iconPNGBase64, second)
        receive(3, icon: nil)
        XCTAssertNil(controller.organizedRows(native: [], in: workspace).flatMap(\.surfaceItems).first?.iconPNGBase64,
            "A page without an icon must not keep the previous website's icon")
    }

    func testOpenPinUsesCurrentWebsiteIconWhileClosedPinKeepsSavedIcon() throws {
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID(), profile = UUID()
        controller.usesSurfaceTree = true
        let id = SurfaceID.browserTab(profile: profile, tab: UUID())
        let saved = favicon(red: 255, blue: 0), current = favicon(red: 0, blue: 255)
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        defer { controller.disconnected(connection) }
        controller.received(.init(revision: 1, full: true, tabs: [
            .init(surfaceID: id, hostID: "host", title: "Pinned", selected: true, url: "https://example.com", iconPNGBase64: saved),
        ]), epoch: epoch, connection: connection)
        XCTAssertTrue(controller.pinBrowserTab(id))
        let pin = try XCTUnwrap(controller.browserSidebarPins.first)
        controller.received(.init(revision: 2, full: true, tabs: [
            .init(surfaceID: id, hostID: "host", title: "Another website", selected: true, url: "https://example.org", iconPNGBase64: current),
        ]), epoch: epoch, connection: connection)
        XCTAssertEqual(controller.pinTiles(in: pin.workspaceName).first?.iconPNGBase64, current)
        XCTAssertEqual(controller.browserSidebarPins.first?.iconPNGBase64, saved, "Navigation must preserve the saved launcher icon")
        controller.received(.init(revision: 3, full: false, tabs: [], removed: [id]), epoch: epoch, connection: connection)
        XCTAssertEqual(controller.pinTiles(in: pin.workspaceName).first?.iconPNGBase64, saved)
    }

    private func favicon(red: UInt8, blue: UInt8) -> String {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
        bitmap.bitmapData!.update(from: [red, 0, blue, 255], count: 4)
        return bitmap.representation(using: .png, properties: [:])!.base64EncodedString()
    }

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

    func testMixedOrganizationUsesLiveOwnersAndSurvivesDisconnect() async throws {
        let controller = BrowserWorkspaceController(), connection = UUID(), epoch = UUID()
        controller.usesSurfaceTree = true
        let tab = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [record(tab)]), epoch: epoch, connection: connection, protocolVersion: 3)
        let native = TestWindow.new(id: 41, parent: focus.workspace.rootTilingContainer)
        let nativeRow = WorkspaceSidebarItemViewModel(kind: .window(await makeWorkspaceSidebarWindowViewModel(
            for: native, workspaceName: focus.workspace.name, currentFocus: focus)))
        controller.reconcileSharedOrganization()
        XCTAssertEqual(controller.select(native.surfaceID), .issued)
        controller.organize(tab, groupWithSelection: true)
        var items = controller.organizedRows(native: [nativeRow], in: focus.workspace.name)
        XCTAssertEqual(items.count, 1)
        guard case .surfaceGroup(let group, _) = items[0].kind else { return XCTFail("No mixed group") }
        XCTAssertEqual(items[0].surfaceIDs, [native.surfaceID, tab])
        controller.disconnected(connection)
        items = controller.organizedRows(native: [nativeRow], in: focus.workspace.name)
        XCTAssertEqual(items.flatMap(\.surfaceIDs), [native.surfaceID])
        let reconnect = UUID()
        controller.connected(reconnect, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 2, full: true, tabs: [record(tab)]), epoch: UUID(), connection: reconnect, protocolVersion: 3)
        items = controller.organizedRows(native: [nativeRow], in: focus.workspace.name)
        XCTAssertEqual(items[0].id, "surface-group:\(group)")
        XCTAssertEqual(items[0].surfaceIDs, [native.surfaceID, tab])
        controller.close(tab)
        XCTAssertEqual(controller.surfaceTree.workspace(of: tab), focus.workspace.name, "Issued close cannot remove placement")
    }

    func testUnifiedSearchAndTypedDragIncludeBothKindsInsideGroups() {
        let a = SurfaceID.nativeWindow(UUID()), b = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let item = WorkspaceSidebarItemViewModel(kind: .surfaceGroup(UUID(), [
            .init(kind: .surface(.init(surfaceID: a, title: "Native fixture", appName: "Fixture", isFocused: false))),
            .init(kind: .surface(.init(surfaceID: b, title: "Synthetic browser", appName: "WinMux Browser", isFocused: true))),
        ]))
        let workspace = WorkspaceSidebarWorkspaceViewModel(name: "mixed", projectId: workspaceProjectDefaultId,
            displayName: "Mixed", sidebarLabel: "", isGeneratedName: false, monitorScopeId: "test", monitorName: nil,
            isFocused: true, isVisible: true, items: [item])
        let filtered = workspaceSidebarFilteredWorkspacesByProject([workspaceProjectDefaultId: [workspace]], projects: [], query: "browser")
        XCTAssertEqual(workspaceSidebarSearchSelections(workspaces: filtered[workspaceProjectDefaultId] ?? []), [.surface(b)])
        for id in [a, b] {
            XCTAssertEqual(WorkspaceSidebarDragPayload(encodedValue: WorkspaceSidebarDragPayload.surface(id).encodedValue), .surface(id))
        }
        XCTAssertNil(WorkspaceSidebarDragPayload(encodedValue: "surface:native:41"))
    }

    func testClosedOrReusedNativeLeafCannotBeReorganized() async {
        let controller = BrowserWorkspaceController()
        controller.usesSurfaceTree = true
        let native = TestWindow.new(id: 41, parent: focus.workspace.rootTilingContainer)
        let row = await makeWorkspaceSidebarWindowViewModel(for: native, workspaceName: focus.workspace.name, currentFocus: focus)
        _ = controller.organizedRows(native: [.init(kind: .window(row))], in: focus.workspace.name)
        native.unbindFromParent()
        _ = TestWindow.new(id: 41, parent: focus.workspace.rootTilingContainer)
        let before = controller.surfaceTree
        controller.organize(native.surfaceID, earlier: false)
        XCTAssertEqual(controller.surfaceTree, before)
    }
}

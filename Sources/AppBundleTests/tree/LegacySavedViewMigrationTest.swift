@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor final class LegacySavedViewMigrationTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testEntirelyClosedLegacyGroupMigratesInShelfOrderWithoutLaunching() throws {
        let controller = BrowserWorkspaceController(), source = focus.workspace
        let profile = UUID(), a = SurfaceID.browserTab(profile: profile, tab: UUID())
        let b = SurfaceID.browserTab(profile: profile, tab: UUID())
        var template = SurfaceTree()
        template.reconcile([a, b], in: source.name)
        XCTAssertTrue(template.group(b, with: a, layout: .vertical))
        let groupID = try XCTUnwrap(template.containingGroup(of: a))
        template.setWeights([a.description: 2, b.description: 3])
        template.select(b)
        let pins = (0..<4).map { BrowserSidebarPin(profileID: profile, workspaceName: source.name,
            title: "Page \($0)", url: "https://example.com/\($0)") }
        let saved = PinnedViewGroup(id: groupID, title: "Research", template: template,
            members: [a: pins[1].id, b: pins[2].id])
        var legacy = SpacePinnedGroup(spaceID: source.projectId.rawValue, workspaceName: source.name,
            pinOrder: pins.map(\.id))
        legacy.views = [saved]
        let snapshot = try SurfaceWorkspaceSnapshot(tree: .init(), layoutWorkspaces: [], selected: nil,
            closedBrowserTabs: [a, b], browserPins: pins, pinnedGroups: [legacy]).validated()
        let connection = UUID()
        controller.connected(connection, processID: -1, sendNewTab: { _, _ in XCTFail("Restoration cannot open pages") }, send: { _, _ in })

        controller.restorePlacementSnapshot(snapshot)

        let desktop = try XCTUnwrap(controller.pinnedViews.first { $0.id == groupID })
        XCTAssertEqual(controller.pinShelves.first?.desktopOrder, [pins[0].id, groupID, pins[3].id])
        XCTAssertEqual(desktop.memberIDs, [pins[1].id, pins[2].id])
        XCTAssertEqual(desktop.selectedMember, pins[2].id)
        XCTAssertEqual(desktop.layout, [.group(groupID, .vertical,
            [.member(pins[1].id, 2), .member(pins[2].id, 3)], pins[2].id, 1)])
        XCTAssertTrue(controller.spacePinnedGroups.allSatisfy { $0.views.isEmpty })
        XCTAssertTrue(controller.surfaceTree.roots[desktop.workspaceName]?.isEmpty == true)
        XCTAssertTrue(controller.browserSidebarPins.allSatisfy { $0.surfaceID == nil })
        let migrated = try XCTUnwrap(controller.capturePlacementSnapshot()).validated()
        controller.restorePlacementSnapshot(migrated)
        XCTAssertEqual(controller.capturePlacementSnapshot(), migrated)
        controller.disconnected(connection)
    }

    func testMixedLegacyGroupWaitsForNativeRestoreAndKeepsClosedBrowserSlot() async throws {
        let controller = BrowserWorkspaceController(), source = focus.workspace
        let native = TestWindow.new(id: 3301, parent: source.rootTilingContainer)
        let nativeRestart = RestartSessionSnapshot.capture()
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let profile: UUID
        if case .browserTab(let id, _) = page { profile = id } else { return XCTFail("Expected page") }
        var template = SurfaceTree()
        template.reconcile([native.surfaceID, page], in: source.name)
        XCTAssertTrue(template.group(page, with: native.surfaceID, layout: .horizontal))
        let id = try XCTUnwrap(template.containingGroup(of: page))
        let app = NativeAppSidebarPin(workspaceName: source.name, bundleIdentifier: native.app.rawAppBundleId!,
            bundlePath: "/Missing/Test.app", title: "Editor", surfaceID: native.surfaceID)
        let browser = BrowserSidebarPin(profileID: profile, workspaceName: source.name, title: "Reference", url: "https://example.com")
        var group = SpacePinnedGroup(spaceID: source.projectId.rawValue, workspaceName: source.name, pinOrder: [app.id, browser.id])
        group.views = [.init(id: id, title: "Research", template: template, members: [native.surfaceID: app.id, page: browser.id])]
        var live = template
        live.remove(page)
        let snapshot = try SurfaceWorkspaceSnapshot(tree: live, layoutWorkspaces: [source.name], selected: nil,
            closedBrowserTabs: [page], browserPins: [browser], appPins: [app], pinnedGroups: [group]).validated()

        RestartSessionController.shared.prepare(nativeRestart)
        controller.restorePlacementSnapshot(snapshot)
        XCTAssertTrue(controller.pinnedViews.isEmpty)
        XCTAssertEqual(controller.spacePinnedGroups.first?.views.map(\.id), [id])
        try await RestartSessionController.shared.restoreAfterDiscovery()
        controller.reconcileSharedOrganization()

        let desktop = try XCTUnwrap(controller.pinnedViews.first)
        XCTAssertEqual(native.nodeWorkspace?.name, desktop.workspaceName)
        XCTAssertEqual(controller.surfaceTree.workspace(of: native.surfaceID), desktop.workspaceName)
        XCTAssertEqual(desktop.memberIDs, [app.id, browser.id])
        XCTAssertEqual(desktop.layout.flatMap(\.members), desktop.memberIDs)
        XCTAssertNil(controller.browserSidebarPins.first?.surfaceID)
        XCTAssertEqual(controller.nativeAppSidebarPins.first?.surfaceID, native.surfaceID)
        XCTAssertNoThrow(try controller.capturePlacementSnapshot()?.validated())
    }
}

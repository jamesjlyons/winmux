@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor final class SavedViewPersistenceTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        TestApp.shared.bundlePath = "/Missing/Test.app"
    }
    override func tearDown() async throws { TestApp.shared.bundlePath = nil }

    func testViewAndMemberIdentitySurvivePinCloseUnpinAndRestart() throws {
        let controller = BrowserWorkspaceController(), workspace = focus.workspace
        controller.usesSurfaceTree = true
        let a = TestWindow.new(id: 3401, parent: workspace.rootTilingContainer)
        let b = TestWindow.new(id: 3402, parent: workspace.rootTilingContainer)
        controller.reconcileSharedOrganization()
        let original = try XCTUnwrap(controller.savedViews.first { $0.workspaceName == workspace.name })
        XCTAssertTrue(original.members.allSatisfy { $0.launch == nil })

        XCTAssertTrue(controller.pinWorkspace(workspace.name))
        let pinned = try XCTUnwrap(controller.pinnedViews.first)
        XCTAssertEqual(pinned.id, original.id)
        XCTAssertEqual(pinned.memberIDs, original.memberIDs)
        XCTAssertTrue(pinned.members.allSatisfy { $0.launch != nil })
        XCTAssertTrue(controller.legacyAppPins.isEmpty)
        b.unbindFromParent()
        controller.reconcileSharedOrganization()
        let closed = try XCTUnwrap(controller.capturePlacementSnapshot()).savedViews.first { $0.id == pinned.id }
        XCTAssertEqual(closed?.memberIDs, original.memberIDs)
        XCTAssertNil(closed?.members.last?.surfaceID)

        XCTAssertTrue(controller.unpin(pinned.id))
        let ordinary = try XCTUnwrap(controller.savedViews.first { $0.id == original.id })
        XCTAssertFalse(ordinary.isPinned)
        XCTAssertEqual(ordinary.members.map(\.surfaceID), [a.surfaceID])
        XCTAssertEqual(ordinary.memberIDs, [original.members[0].id])
        XCTAssertTrue(ordinary.members.allSatisfy { $0.launch == nil })
        let snapshot = try XCTUnwrap(controller.capturePlacementSnapshot()).validated()
        let decoded = try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
        let restored = BrowserWorkspaceController()
        restored.restorePlacementSnapshot(decoded)
        XCTAssertEqual(restored.capturePlacementSnapshot(), snapshot)
    }

    func testMovingAnOrdinaryMemberKeepsItsIDAndBothViewIDs() throws {
        let controller = BrowserWorkspaceController(), source = focus.workspace
        let destination = Workspace.get(byName: "Destination")
        controller.usesSurfaceTree = true
        let moved = TestWindow.new(id: 3403, parent: source.rootTilingContainer)
        _ = TestWindow.new(id: 3404, parent: destination.rootTilingContainer)
        controller.reconcileSharedOrganization()
        let before = Dictionary(uniqueKeysWithValues: controller.savedViews.map { ($0.workspaceName, $0.id) })
        let member = try XCTUnwrap(controller.savedMemberID(for: moved.surfaceID))

        XCTAssertTrue(controller.editOrganization(of: moved.surfaceID, movingTo: destination) { _ in true })
        controller.reconcileSharedOrganization()

        XCTAssertEqual(controller.savedMemberID(for: moved.surfaceID), member)
        XCTAssertEqual(controller.savedViews.first { $0.workspaceName == destination.name }?.id, before[destination.name])
        XCTAssertEqual(controller.savedViews.first { $0.workspaceName == source.name }?.id, before[source.name])
        XCTAssertNoThrow(try controller.capturePlacementSnapshot()?.validated())
    }

    func testV6StoresPinnedMembersOnceAndRetainsIntentionalEmptyViews() throws {
        let controller = BrowserWorkspaceController(), source = focus.workspace
        controller.usesSurfaceTree = true
        _ = TestWindow.new(id: 3405, parent: source.rootTilingContainer)
        let empty = Workspace.get(byName: "Future research")
        controller.reconcileSharedOrganization()
        XCTAssertTrue(controller.pinWorkspace(source.name))
        let snapshot = try XCTUnwrap(controller.capturePlacementSnapshot()).validated()
        let data = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["savedViews"])
        XCTAssertNil(json["browserPins"])
        XCTAssertNil(json["appPins"])
        XCTAssertNil(json["pinnedDesktops"])
        let emptyID = try XCTUnwrap(snapshot.savedViews.first { $0.workspaceName == empty.name }?.id)
        let name = empty.name
        setUpWorkspacesForTests()
        let restored = BrowserWorkspaceController()
        restored.restorePlacementSnapshot(try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: data))
        XCTAssertNotNil(Workspace.existing(byName: name))
        XCTAssertEqual(restored.savedViews.first { $0.workspaceName == name }?.id, emptyID)
        XCTAssertTrue(restored.savedViews.first { $0.workspaceName == name }?.members.isEmpty == true)
    }

    func testUnresolvedLegacyGroupRetainsItsOriginalReferencesUntilDiscovery() throws {
        let controller = BrowserWorkspaceController(), source = focus.workspace
        let native = SurfaceID.nativeWindow(UUID()), profile = UUID()
        let page = SurfaceID.browserTab(profile: profile, tab: UUID())
        var tree = SurfaceTree()
        tree.reconcile([native, page], in: source.name)
        XCTAssertTrue(tree.group(page, with: native, layout: .horizontal))
        let pin = BrowserSidebarPin(profileID: profile, workspaceName: source.name, title: "Reference",
            url: "https://example.com", surfaceID: page)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [source.name], selected: nil,
            closedBrowserTabs: [], browserPins: [pin]))

        let snapshot = try XCTUnwrap(controller.capturePlacementSnapshot()).validated()

        XCTAssertEqual(snapshot.tree, tree)
        XCTAssertEqual(snapshot.browserPins, [pin])
        XCTAssertFalse(snapshot.savedViews.contains { $0.workspaceName == source.name })
        XCTAssertEqual(try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }

    func testV6CheckpointPreservesV5BytesAndReadsSharedViews() throws {
        let controller = BrowserWorkspaceController(), source = focus.workspace
        controller.usesSurfaceTree = true
        _ = TestWindow.new(id: 3406, parent: source.rootTilingContainer)
        controller.reconcileSharedOrganization()
        XCTAssertTrue(controller.pinWorkspace(source.name))
        let current = try XCTUnwrap(controller.capturePlacementSnapshot()).validated()
        let legacy = SurfaceWorkspaceSnapshot(tree: current.tree, layoutWorkspaces: current.layoutWorkspaces,
            selected: current.selected, closedBrowserTabs: current.closedBrowserTabs,
            browserPins: current.browserPins, appPins: current.appPins, pinnedGroups: current.pinnedGroups,
            pinnedDesktops: current.pinnedDesktops, pinShelves: current.pinShelves)
        var fileSnapshot = RestartSessionSnapshot.capture()
        fileSnapshot.version = 5; fileSnapshot.surfaces = legacy
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = RestartSessionFile(url: directory.appendingPathComponent("session.json"))
        try file.write(fileSnapshot)
        let original = try Data(contentsOf: file.url)

        fileSnapshot.version = 6; fileSnapshot.surfaces = current
        try file.write(fileSnapshot)
        try file.write(fileSnapshot)

        XCTAssertEqual(try file.read()?.version, 6)
        XCTAssertEqual(try file.read()?.surfaces?.savedViews, current.savedViews)
        XCTAssertEqual(try Data(contentsOf: file.migrationBackupURL(version: 5)), original)
    }
}

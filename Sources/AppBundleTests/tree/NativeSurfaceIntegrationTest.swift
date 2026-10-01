@testable import AppBundle
import Common
import Foundation
import WorkspaceCore
import XCTest

@MainActor
final class NativeSurfaceIntegrationTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testSidebarIdentityAndAdapterFollowLiveWindow() async throws {
        let window = TestWindow.new(id: 41, parent: focus.workspace.rootTilingContainer)
        let view = await makeWorkspaceSidebarWindowViewModel(for: window, workspaceName: focus.workspace.name, currentFocus: focus)
        XCTAssertEqual(view.id, window.surfaceID)
        XCTAssertEqual(WorkspaceSidebarItemViewModel(kind: .window(view)).id, window.surfaceID.description)
        let adapter = NativeWindowSurfaceAdapter(surfaceID: view.surfaceID)
        XCTAssertEqual(adapter.requestFocus(), .issued)
        XCTAssertTrue(TestApp.shared.focusedWindow === window)
        XCTAssertTrue(Window.get(byId: 41) === window, "Numeric native CLI lookup remains available")
    }

    func testStaleSidebarItemCannotControlReusedNativeWindowID() {
        let old = TestWindow.new(id: 41, parent: focus.workspace.rootTilingContainer)
        let adapter = NativeWindowSurfaceAdapter(surfaceID: old.surfaceID)
        old.unbindFromParent()
        let replacement = TestWindow.new(id: 41, parent: focus.workspace.rootTilingContainer)
        XCTAssertNotEqual(old.surfaceID, replacement.surfaceID)
        XCTAssertEqual(adapter.requestFocus(), .unavailable)
        XCTAssertEqual(adapter.requestClose(), .unavailable)
        XCTAssertTrue(replacement.isBound)
        XCTAssertFalse(TestApp.shared.focusedWindow === replacement)
    }

    func testCloseRequestLeavesUnconfirmedWindowInModel() {
        let window = SaveConfirmationWindow(parent: focus.workspace.rootTilingContainer)
        XCTAssertEqual(NativeWindowSurfaceAdapter(surfaceID: window.surfaceID).requestClose(), .issued)
        XCTAssertEqual(window.closeRequests, 1)
        XCTAssertTrue(window.isBound)
        XCTAssertTrue(Window.get(bySurfaceID: window.surfaceID) === window)
    }

    func testSurfaceIdentitySurvivesRestartOnlyAfterNativeBindingMatches() async throws {
        let old = TestWindow.new(id: 41, parent: focus.workspace.rootTilingContainer)
        let originalID = old.surfaceID
        let snapshot = RestartSessionSnapshot.capture()
        setUpWorkspacesForTests()
        let restored = TestWindow.new(id: 41, parent: focus.workspace.rootTilingContainer)
        let temporaryID = restored.surfaceID
        let controller = RestartSessionController()
        controller.prepare(snapshot)
        try await controller.restoreAfterDiscovery()
        XCTAssertEqual(restored.surfaceID, originalID)
        XCTAssertNil(Window.get(bySurfaceID: temporaryID))
        XCTAssertTrue(Window.get(bySurfaceID: originalID) === restored)

        var changed = snapshot
        changed = RestartSessionSnapshot(savedAt: changed.savedAt, bootSession: "different-boot", world: changed.world,
                                        windows: changed.windows, projects: changed.projects,
                                        focusedWindowId: changed.focusedWindowId, focusedWorkspace: changed.focusedWorkspace)
        setUpWorkspacesForTests()
        let reused = TestWindow.new(id: 41, parent: focus.workspace.rootTilingContainer)
        controller.prepare(changed)
        try await controller.restoreAfterDiscovery()
        XCTAssertNotEqual(reused.surfaceID, originalID)
    }

    func testVersionTwoImportsAndNextCaptureWritesTypedIdentities() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let window = TestWindow.new(id: 41, parent: focus.workspace.rootTilingContainer)
        let snapshot = RestartSessionSnapshot.capture()
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.winMuxDefault.encode(snapshot)) as? [String: Any])
        old["version"] = 2
        var windows = try XCTUnwrap(old["windows"] as? [[String: Any]])
        for i in windows.indices { windows[i].removeValue(forKey: "surfaceID") }
        old["windows"] = windows
        let file = RestartSessionFile(url: folder.appendingPathComponent("session.json"))
        try JSONSerialization.data(withJSONObject: old).write(to: file.url)
        let imported = try XCTUnwrap(file.read())
        XCTAssertEqual(imported.version, 2)
        XCTAssertNil(imported.windows?.first?.surfaceID)
        try file.write(snapshot)
        XCTAssertEqual(try file.read()?.version, 3)
        XCTAssertEqual(try file.read()?.windows?.first?.surfaceID, window.surfaceID)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: file.backupURL)) as? NSDictionary, old as NSDictionary)
    }

    func testSurfaceRestorationRejectsBrowserAndDuplicateNativeIdentities() {
        let a = TestWindow.new(id: 41, parent: focus.workspace.rootTilingContainer)
        let b = TestWindow.new(id: 42, parent: focus.workspace.rootTilingContainer)
        XCTAssertFalse(b.restoreSurfaceID(a.surfaceID))
        XCTAssertFalse(b.restoreSurfaceID(.browserTab(profile: UUID(), tab: UUID())))
        XCTAssertNotEqual(a.surfaceID, b.surfaceID)
    }
}

private final class SaveConfirmationWindow: Window {
    var closeRequests = 0
    @MainActor init(parent: NonLeafTreeNodeObject) {
        super.init(id: 71, TestApp.shared, lastFloatingSize: nil, parent: parent, adaptiveWeight: 1, index: INDEX_BIND_LAST)
    }
    override func closeAxWindow() { closeRequests += 1 }
}

@testable import AppBundle
import Foundation
import WorkspaceCore
import XCTest

@MainActor
final class BrowserNativeManagementTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testIsolatedStateRequiresMarkerAndPreservesConfigurationOnRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try BrowserNativeState(directory: root)
        XCTAssertTrue(state.session.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"))
        XCTAssertLessThan(state.socket.utf8.count, 104)
        XCTAssertTrue(parseConfig(BrowserNativeState.initialConfiguration).errors.isEmpty)
        let customized = BrowserNativeState.initialConfiguration + "\n# Keep my isolated settings\n"
        try customized.write(to: state.config, atomically: true, encoding: .utf8)
        let reopened = try BrowserNativeState(directory: root)
        XCTAssertEqual(state.socket, reopened.socket)
        XCTAssertEqual(try String(contentsOf: reopened.config, encoding: .utf8), customized)
        try FileManager.default.removeItem(at: root.appendingPathComponent("winmux-browser-state-v1"))
        XCTAssertThrowsError(try BrowserNativeState(directory: root))
        XCTAssertEqual(try String(contentsOf: state.config, encoding: .utf8), customized)
    }

    func testStateRejectsSessionSymlinkAndLeaseRejectsConcurrentOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try BrowserNativeState(directory: root)
        try FileManager.default.createSymbolicLink(at: state.session, withDestinationURL: state.config)
        XCTAssertThrowsError(try BrowserNativeState(directory: root))
        let path = root.appendingPathComponent("owner.lock").path
        let lease = try NativeManagementLease(path: path)
        try withExtendedLifetime(lease) { XCTAssertThrowsError(try NativeManagementLease(path: path)) }
        XCTAssertFalse(lease.isRevoked)
        lease.revoke()
        XCTAssertTrue(lease.isRevoked)
    }

    func testManagedDefaultsHaveSharedShortcutsAndDoNotReplaceExistingSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try BrowserNativeState(directory: root, workspaceShortcuts: true)
        let config = try String(contentsOf: state.config, encoding: .utf8)
        XCTAssertTrue(parseConfig(config).errors.isEmpty)
        XCTAssertTrue(config.contains("alt-j = 'focus tab-next'"))
        XCTAssertTrue(config.contains("alt-space = 'layout horizontal vertical'"))
        _ = try BrowserNativeState(directory: root)
        XCTAssertEqual(try String(contentsOf: state.config, encoding: .utf8), config)
    }

    func testOwnershipPreflightReleasesItsLeaseAndDoesNotStealAnExistingLease() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try NativeManagementLease.checkAvailable(path: path)
        do {
            let owner = try NativeManagementLease(path: path)
            try withExtendedLifetime(owner) {
                XCTAssertThrowsError(try NativeManagementLease.checkAvailable(path: path))
                XCTAssertFalse(owner.isRevoked)
                XCTAssertThrowsError(try NativeManagementLease(path: path))
            }
        }
        try NativeManagementLease.checkAvailable(path: path)
    }

    func testFreshManagedDefaultsUseOriginalHierarchyAndCompactNeutralSidebar() throws {
        let parsed = parseConfig(BrowserNativeState.initialConfiguration)
        XCTAssertTrue(parsed.errors.isEmpty)
        XCTAssertTrue(parsed.config.persistentWorkspaces.isEmpty)
        XCTAssertTrue(parsed.config.workspaceSidebar.enabled)
        XCTAssertFalse(parsed.config.workspaceSidebar.alwaysExpanded)
        XCTAssertFalse(parsed.config.workspaceSidebar.autoHide)
        XCTAssertEqual(parsed.config.workspaceSidebar.chromeStyle, .solid)
        XCTAssertEqual(parsed.config.workspaceSidebar.solidChromeColor, .system)
        XCTAssertTrue(parsed.config.workspaceSidebar.projectLabels.isEmpty)
        XCTAssertTrue(parsed.config.workspaceSidebar.workspaceLabels.isEmpty)
    }

    func testViewsTrialStartsInViewsModeAndPreservesLaterPreferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try BrowserNativeState(directory: root, workspaceShortcuts: true, viewsTrial: true)
        let text = try String(contentsOf: state.config, encoding: .utf8)
        let parsed = parseConfig(text)
        XCTAssertTrue(parsed.errors.isEmpty)
        XCTAssertEqual(parsed.config.workspaceInteractionMode, .views)
        XCTAssertTrue(text.contains("alt-j = 'focus tab-next'"))
        let customized = text.replacingOccurrences(of: "workspace-interaction-mode = 'views'", with: "workspace-interaction-mode = 'tiling'")
        try customized.write(to: state.config, atomically: true, encoding: .utf8)
        _ = try BrowserNativeState(directory: root, workspaceShortcuts: true, viewsTrial: true)
        XCTAssertEqual(try String(contentsOf: state.config, encoding: .utf8), customized)
    }

    func testUnifiedAlphaMigratesExistingDefaultModeWithoutChangingOtherSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try BrowserNativeState(directory: root, workspaceShortcuts: true)
        let old = try String(contentsOf: state.config, encoding: .utf8) + "\n# Preserve custom shortcuts\n"
        try old.write(to: state.config, atomically: true, encoding: .utf8)
        _ = try BrowserNativeState(directory: root, viewsTrial: true)
        let migrated = try String(contentsOf: state.config, encoding: .utf8)
        XCTAssertEqual(migrated, "workspace-interaction-mode = 'views'\n" + old)
        XCTAssertEqual(parseConfig(migrated).config.workspaceInteractionMode, .views)
        _ = try BrowserNativeState(directory: root, viewsTrial: true)
        XCTAssertEqual(try String(contentsOf: state.config, encoding: .utf8), migrated)
    }

    func testStandaloneOwnershipRecognizesNativeAppButAllowsTransportHelper() {
        XCTAssertTrue(BrowserNativeManagement.isStandaloneManager(bundleID: "com.zimengxiong.winmux", executable: nil))
        XCTAssertTrue(BrowserNativeManagement.isStandaloneManager(bundleID: nil, executable: "WinMuxApp"))
        XCTAssertFalse(BrowserNativeManagement.isStandaloneManager(bundleID: "com.jameslyons.winmux.browser.alpha.workspace", executable: "WinMuxWorkspaceHelper"))
        XCTAssertFalse(BrowserNativeManagement.isStandaloneManager(bundleID: "com.jameslyons.winmux.browser.alpha", executable: "Chromium"))
    }

    func testNativeCommandAndEmptyWorkspaceFenceBrowserIntent() {
        let controller = BrowserWorkspaceController.shared, connection = UUID(), epoch = UUID()
        defer {
            controller.received(.init(revision: 2, full: true, tabs: []), epoch: epoch, connection: connection)
            controller.disconnected(connection)
        }
        let tab = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var requests: [BrowserActionRequest] = []
        var replies: [@MainActor (BrowserActionReply) -> Void] = []
        controller.connected(connection, processID: -1) { request, reply in requests.append(request); replies.append(reply) }
        controller.received(.init(revision: 1, full: true, tabs: [
            .init(surfaceID: tab, hostID: "host:1", title: "Synthetic", selected: true)
        ]), epoch: epoch, connection: connection)
        let native = TestWindow.new(id: 91, parent: focus.workspace.rootTilingContainer)
        XCTAssertTrue(native.focusWindow())
        XCTAssertEqual(controller.select(tab), .issued)
        XCTAssertTrue(native.focusWindow(), "Re-selecting the old native focus still supersedes a browser intent")
        XCTAssertEqual(controller.focusCoordinator.target, native.surfaceID)
        XCTAssertTrue(TestApp.shared.focusedWindow === native, "Same-leaf native command must not wait for a stalled browser")
        let empty = Workspace.get(byName: "Empty")
        XCTAssertTrue(empty.focusWorkspace())
        XCTAssertNil(controller.focusCoordinator.target)
        for reply in replies { reply(.issued) }
        XCTAssertTrue(focus.workspace === empty, "Old acknowledgements cannot leave the empty workspace")
        XCTAssertEqual(requests.map(\.action), [.cancelFocus, .focus, .cancelFocus, .cancelFocus])
    }
}

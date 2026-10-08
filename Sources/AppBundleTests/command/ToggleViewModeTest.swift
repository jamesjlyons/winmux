@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class ToggleViewModeTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testToastPlacementOnOffsetMonitor() {
        let visible = Rect(topLeftX: -1920, topLeftY: 100, width: 1920, height: 1000)
        let frame = ViewModeToastPanel.toastFrame(in: visible, screenTop: 1200)
        XCTAssertEqual(frame.midX, -960)
        XCTAssertEqual(frame.minY, 132)
    }

    func testToastIsNonactivatingAndReplacementResetsDismissal() async throws {
        _ = NSApplication.shared
        let panel = ViewModeToastPanel.shared
        let keyWindow = NSApp.keyWindow
        panel.show(mode: .newView, dismissAfter: .milliseconds(100))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        panel.show(mode: .tile, dismissAfter: .milliseconds(400))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(NSApp.keyWindow, keyWindow)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(panel.isVisible)
    }

    func testCommandAndDefaultShortcut() {
        XCTAssertTrue(parseCommand("toggle-view-mode").cmdOrNil is ToggleViewModeCommand)
        XCTAssertNotNil(parseCommand("toggle-view-mode extra").errorOrNil)
        let parsed = parseConfig(starterConfigText())
        XCTAssertTrue(parsed.errors.isEmpty)
        XCTAssertEqual(readModeBindingEntries(in: starterConfigText())["alt-shift-v"], "toggle-view-mode")
        XCTAssertTrue(buildShortcutSections().flatMap(\.actions).contains { $0.canonicalCommand == "toggle-view-mode" })
    }

    func testToggleFromEveryPlacementWithoutContent() async throws {
        for initial in NewItemPlacement.allCases {
            var current = initial
            var notifications: [NewItemPlacement] = []
            let controller = ViewModeToggleController(current: { current }, save: { current = $0 }, notify: { notifications.append($0) })
            try await controller.toggle()
            XCTAssertEqual(current, initial == .tile ? .newView : .tile)
            XCTAssertEqual(notifications, [current])
        }
    }

    func testOverlappingRequestsReadTheLastAppliedMode() async throws {
        var current = NewItemPlacement.newView
        var notifications: [NewItemPlacement] = []
        let controller = ViewModeToggleController(current: { current }, save: { mode in
            await Task.yield()
            current = mode
        }, notify: { notifications.append($0) })
        let first = Task { try await controller.toggle() }
        let second = Task { try await controller.toggle() }
        try await first.value
        try await second.value
        XCTAssertEqual(notifications, [.tile, .newView])
        XCTAssertEqual(current, .newView)
    }

    func testFailureDoesNotNotifyAndNextRequestCanSucceed() async throws {
        var current = NewItemPlacement.newView
        var fail = true
        var notifications: [NewItemPlacement] = []
        let controller = ViewModeToggleController(current: { current }, save: { mode in
            if fail { throw NSError(domain: "test", code: 1) }
            current = mode
        }, notify: { notifications.append($0) })
        do {
            try await controller.toggle()
            XCTFail("Expected save failure")
        } catch {}
        XCTAssertEqual(current, .newView)
        XCTAssertTrue(notifications.isEmpty)
        fail = false
        try await controller.toggle()
        XCTAssertEqual(notifications, [.tile])
    }

    func testSavedModeRoundTripPreservesCustomBindingsAndLegacySettings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("winmux.toml")
        let original = "automatically-tile-new-windows = false # keep\n[mode.main.binding]\nalt-shift-v = 'fullscreen'\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        for mode in [NewItemPlacement.tile, .newView] {
            try writeSettingsConfig(to: url, section: nil, key: "new-item-placement", renderedValue: "'\(mode.rawValue)'")
            let saved = try String(contentsOf: url, encoding: .utf8)
            let parsed = parseConfig(saved)
            XCTAssertTrue(parsed.errors.isEmpty)
            XCTAssertEqual(parsed.config.newItemPlacement, mode)
            XCTAssertTrue(saved.contains("automatically-tile-new-windows = false # keep"))
            XCTAssertEqual(readModeBindingEntries(in: saved)["alt-shift-v"], "fullscreen")
        }
        let before = try String(contentsOf: url, encoding: .utf8)
        XCTAssertThrowsError(try writeSettingsConfig(to: url, section: nil, key: "new-item-placement", renderedValue: "'invalid'"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), before)
        XCTAssertThrowsError(try writeSettingsConfig(to: folder, section: nil, key: "new-item-placement", renderedValue: "'tile'"))
    }
}

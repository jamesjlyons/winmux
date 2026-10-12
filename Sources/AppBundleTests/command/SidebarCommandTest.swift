@testable import AppBundle
import AppKit
import Common
import Foundation
import XCTest

@MainActor
final class SidebarCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testCommandsAndShortcutSettings() {
        let actions = buildShortcutSections().flatMap(\.actions)
        for action in SidebarCmdArgs.Action.allCases {
            let script = "sidebar \(action.rawValue)"
            let command = parseCommand(script).cmdOrNil as? SidebarCommand
            XCTAssertEqual(command?.args.action.val, action)
            XCTAssertEqual(command?.canSkipPostCommandRefresh, true)
            XCTAssertTrue(actions.contains { $0.canonicalCommand == script })
        }
        for script in ["sidebar", "sidebar invalid", "sidebar hide extra"] {
            XCTAssertNotNil(parseCommand(script).errorOrNil)
        }
        let text = starterConfigText()
        XCTAssertTrue(parseConfig(text).errors.isEmpty)
        let bindings = readModeBindingEntries(in: text)
        XCTAssertEqual(bindings["alt-ctrl-cmd-shift-s"], "sidebar cycle")
        XCTAssertEqual(bindings["alt-shift-s"], "sidebar toggle")
        XCTAssertEqual(bindings["alt-shift-e"], "sidebar toggle-expanded")
        XCTAssertEqual(bindings["ctrl-f"], "open-sidebar")
        XCTAssertEqual(Set(actions.map(\.id)).count, actions.count)
        XCTAssertEqual(Set(actions.map(\.canonicalCommand)).count, actions.count)
    }

    func testEveryActionFromEveryVisibility() {
        let expectations: [(SidebarCmdArgs.Action, [WorkspaceSidebarVisibility])] = [
            (.show, [.compact, .compact, .expanded]),
            (.hide, [.autoHide, .autoHide, .autoHide]),
            (.expand, [.expanded, .expanded, .expanded]),
            (.collapse, [.compact, .compact, .compact]),
            (.toggle, [.compact, .autoHide, .autoHide]),
            (.toggleExpanded, [.expanded, .expanded, .compact]),
            (.cycle, [.compact, .expanded, .autoHide]),
        ]
        for (action, expected) in expectations {
            for (current, next) in zip([WorkspaceSidebarVisibility.autoHide, .compact, .expanded], expected) {
                XCTAssertEqual(workspaceSidebarVisibility(after: action, current: current), next)
            }
        }
    }

    func testHyperShortcutRecorderRoundTrip() throws {
        let shortcut = try XCTUnwrap(masShortcut(from: "alt-ctrl-cmd-shift-s"))
        XCTAssertEqual(shortcut.modifierFlags, [.control, .option, .shift, .command])
        XCTAssertEqual(notation(from: shortcut), "alt-ctrl-cmd-shift-s")
    }

    func testOverlappingCyclesVisitEveryVisibilityAndWrap() async throws {
        var current = WorkspaceSidebarVisibility.autoHide
        var applied: [WorkspaceSidebarVisibility] = []
        let controller = SidebarVisibilityController(current: { current }, save: {
            await Task.yield()
            current = $0
        }, apply: { applied.append($0) })
        let requests = (0..<6).map { _ in Task { try await controller.perform(.cycle) } }
        for request in requests { try await request.value }
        XCTAssertEqual(applied, [.compact, .expanded, .autoHide, .compact, .expanded, .autoHide])
        XCTAssertEqual(current, .autoHide)
    }

    func testOverlappingTogglesUseLastSavedState() async throws {
        var current = WorkspaceSidebarVisibility.compact
        var applied: [WorkspaceSidebarVisibility] = []
        let controller = SidebarVisibilityController(current: { current }, save: {
            await Task.yield()
            current = $0
        }, apply: { applied.append($0) })
        let first = Task { try await controller.perform(.toggleExpanded) }
        let second = Task { try await controller.perform(.toggleExpanded) }
        try await first.value
        try await second.value
        XCTAssertEqual(applied, [.expanded, .compact])
        XCTAssertEqual(current, .compact)
    }

    func testNoopStillClosesHoverPresentationWithoutSaving() async throws {
        var saves = 0
        var applied: [WorkspaceSidebarVisibility] = []
        let controller = SidebarVisibilityController(current: { .autoHide }, save: { _ in saves += 1 }, apply: { applied.append($0) })
        try await controller.perform(.hide)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(applied, [.autoHide])
    }

    func testSaveFailureDoesNotApplyAndQueueRecovers() async throws {
        var current = WorkspaceSidebarVisibility.compact
        var shouldFail = true
        var applied: [WorkspaceSidebarVisibility] = []
        let controller = SidebarVisibilityController(current: { current }, save: {
            if shouldFail { throw NSError(domain: "test", code: 1) }
            current = $0
        }, apply: { applied.append($0) })
        do {
            try await controller.perform(.hide)
            XCTFail("Expected save failure")
        } catch {}
        XCTAssertEqual(current, .compact)
        XCTAssertTrue(applied.isEmpty)
        shouldFail = false
        try await controller.perform(.expand)
        XCTAssertEqual(applied, [.expanded])
    }

    func testPersistencePreservesCustomBindingsAndSidebarWidth() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("winmux.toml")
        let original = "[workspace-sidebar]\nwidth = 310 # keep\n[mode.main.binding]\nalt-shift-s = 'fullscreen'\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        for visibility in WorkspaceSidebarVisibility.allCases {
            try writeSettingsConfig(to: url, section: "workspace-sidebar", key: "visibility", renderedValue: "'\(visibility.rawValue)'")
            let saved = try String(contentsOf: url, encoding: .utf8)
            let parsed = parseConfig(saved)
            XCTAssertTrue(parsed.errors.isEmpty)
            XCTAssertEqual(parsed.config.workspaceSidebar.visibility, visibility)
            XCTAssertTrue(saved.contains("width = 310 # keep"))
            XCTAssertEqual(readModeBindingEntries(in: saved)["alt-shift-s"], "fullscreen")
        }
    }
}

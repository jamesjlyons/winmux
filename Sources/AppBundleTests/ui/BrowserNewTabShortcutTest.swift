@testable import AppBundle
import Common
import XCTest

@MainActor final class BrowserNewTabShortcutTest: XCTestCase {
    func testOldConfigsReceiveDefaultWhileExplicitConflictsWin() {
        let (old, errors) = parseConfig("[mode.main.binding]\nalt-j = 'focus down'\n")
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(browserNewTabBinding(in: old)?.descriptionWithKeyCode, "alt-cmd-t")
        let (conflict, _) = parseConfig("[mode.main.binding]\nalt-cmd-t = 'focus down'\n")
        XCTAssertNil(browserNewTabBinding(in: conflict))
        let (rebound, _) = parseConfig("[mode.main.binding]\nalt-cmd-n = 'browser-new-tab'\n")
        XCTAssertNil(browserNewTabBinding(in: rebound))
    }

    func testRuntimeGateAddsBrowserDefaultOnlyForBrowserManagementAndPreservesExplicitBindings() {
        let previous = config
        defer { config = previous }
        config = parseConfig("[mode.main.binding]\nalt-j = 'focus down'\n").config
        XCTAssertNil(effectiveHotkeyBindings(for: mainModeId, includesBrowserShortcut: false)["alt-cmd-t"])
        XCTAssertNotNil(effectiveHotkeyBindings(for: mainModeId, includesBrowserShortcut: true)["alt-cmd-t"])
        XCTAssertNil(effectiveHotkeyBindings(for: "service", includesBrowserShortcut: true)["alt-cmd-t"])

        config = parseConfig("[mode.main.binding]\nalt-cmd-t = 'browser-new-tab'\n").config
        let explicit = effectiveHotkeyBindings(for: mainModeId, includesBrowserShortcut: false)["alt-cmd-t"]
        XCTAssertTrue(explicit?.commands.contains { $0 is BrowserNewTabCommand } == true)

        config = parseConfig("[mode.main.binding]\nalt-cmd-t = 'focus right'\n").config
        let conflict = effectiveHotkeyBindings(for: mainModeId, includesBrowserShortcut: true)["alt-cmd-t"]
        XCTAssertTrue(conflict?.commands.contains { $0 is FocusCommand } == true)
    }

    func testClearAndRebindPersistAcrossParseWithoutChangingOtherBindings() {
        let original = "config-version = 2\n[mode.main.binding]\nalt-j = 'focus down'\n"
        let cleared = updateBrowserNewTabShortcutConfig(in: original, notation: "")
        let (disabled, errors) = parseConfig(cleared)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertNil(browserNewTabBinding(in: disabled))
        let rebound = updateBrowserNewTabShortcutConfig(in: cleared, notation: "alt-cmd-n")
        let (configured, errors2) = parseConfig(rebound)
        XCTAssertTrue(errors2.isEmpty)
        XCTAssertEqual(browserNewTabBinding(in: configured)?.descriptionWithKeyCode, "alt-cmd-n")
        XCTAssertTrue(rebound.contains("alt-j = 'focus down'"))
        XCTAssertEqual(rebound.components(separatedBy: "browser-new-tab-shortcut").count, 2)
    }

    func testBrowserRecorderSavePreservesOtherBindingsAndDoesNotAddGroupShortcuts() throws {
        let original = "shortcuts-preset = 'none'\n[mode.main.binding]\nalt-j = 'focus down'\nalt-k = 'focus up'\n"
        let previousConfig = config
        let model = ShortcutSettingsModel.shared
        defer { config = previousConfig; model.reload() }
        config = parseConfig(original).config
        model.reload()
        let previous = model.assignments
        var updated = previous
        updated["browser-new-tab"] = "ctrl-cmd-n"
        let edits = try model.bindingConfigEdits(for: updated, previousAssignments: previous, browserShortcutEdit: true)
        let modeText = updateModeBindingConfig(in: original, managedCommands: edits.managedCommands, assignments: edits.assignments)
        let saved = updateBrowserNewTabShortcutConfig(in: modeText, notation: "ctrl-cmd-n")
        XCTAssertEqual(readModeBindingEntries(in: saved), ["alt-j": "focus down", "alt-k": "focus up"])
        XCTAssertFalse(saved.contains("workspace 1"))
        XCTAssertEqual(browserNewTabBinding(in: parseConfig(saved).config)?.descriptionWithKeyCode, "ctrl-cmd-n")
    }

    func testBrowserRecorderReassignmentRemovesOnlyTheDirectlyConflictingAction() throws {
        let original = "shortcuts-preset = 'none'\n[mode.main.binding]\nalt-j = 'focus down'\nalt-k = 'focus up'\n"
        let previousConfig = config
        let model = ShortcutSettingsModel.shared
        defer { config = previousConfig; model.reload() }
        config = parseConfig(original).config
        model.reload()
        let previous = model.assignments
        var updated = previous
        updated["browser-new-tab"] = "alt-j"
        updated["focus-down"] = nil
        let edits = try model.bindingConfigEdits(for: updated, previousAssignments: previous, browserShortcutEdit: true)
        let modeText = updateModeBindingConfig(in: original, managedCommands: edits.managedCommands, assignments: edits.assignments)
        let saved = updateBrowserNewTabShortcutConfig(in: modeText, notation: "alt-j")
        XCTAssertEqual(readModeBindingEntries(in: saved), ["alt-k": "focus up"])
        XCTAssertEqual(browserNewTabBinding(in: parseConfig(saved).config)?.descriptionWithKeyCode, "alt-j")
    }
}

@testable import AppBundle
import AppKit
import SwiftUI
import XCTest

@MainActor
final class SettingsInputTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testTypingOnlySavesOnEnterAndDoesNotSaveAgainForUnchangedValue() async throws {
        let state = InputState()
        let window = host(NumberInput(state: state))
        defer { window.close() }
        try await settle(window)
        let field = try XCTUnwrap(descendants(of: window.contentView!, as: NSTextField.self).first { $0.isEditable })
        let editor = try edit(field, in: window)

        for text in ["", "3", "32", "320"] {
            replace(editor, with: text)
            try await settle(window)
            XCTAssertEqual(state.value, 240)
            XCTAssertTrue(state.saved.isEmpty, "Typing \(text) must not save")
        }

        editor.insertNewline(nil)
        try await settle(window)
        XCTAssertEqual(state.value, 320)
        XCTAssertEqual(state.saved, [320])
        XCTAssertTrue(window.firstResponder === editor)

        editor.insertNewline(nil)
        try await settle(window)
        XCTAssertEqual(state.saved, [320])
    }

    func testInvalidDraftsDoNotApplyAndCanBeCorrected() async throws {
        let state = InputState()
        let window = host(NumberInput(state: state))
        defer { window.close() }
        try await settle(window)
        let field = try XCTUnwrap(descendants(of: window.contentView!, as: NSTextField.self).first { $0.isEditable })
        let editor = try edit(field, in: window)

        for text in ["", "-", "abc", "1.5", "119", "481", "9999999999999999999999"] {
            replace(editor, with: text)
            editor.insertNewline(nil)
            try await settle(window)
            XCTAssertEqual(state.value, 240, "Invalid draft: \(text)")
            XCTAssertTrue(state.saved.isEmpty)
            XCTAssertEqual(editor.string, text)
        }

        for value in [120, 480] {
            replace(editor, with: String(value))
            editor.insertNewline(nil)
            try await settle(window)
            XCTAssertEqual(state.value, value)
        }
        XCTAssertEqual(state.saved, [120, 480])
    }

    func testLeavingFieldDoesNotApplyAndReloadPreservesDraft() async throws {
        let state = InputState()
        let window = host(NumberInput(state: state))
        defer { window.close() }
        try await settle(window)
        let field = try XCTUnwrap(descendants(of: window.contentView!, as: NSTextField.self).first { $0.isEditable })
        let editor = try edit(field, in: window)
        replace(editor, with: "320")
        try await settle(window)
        window.makeFirstResponder(nil)
        try await settle(window)
        XCTAssertEqual(state.value, 240)
        XCTAssertTrue(state.saved.isEmpty)

        state.value = 280
        try await settle(window)
        XCTAssertEqual(field.stringValue, "320", "Reloading config must preserve an unsubmitted draft")
        XCTAssertTrue(state.saved.isEmpty)

        let resumedEditor = try edit(field, in: window)
        resumedEditor.insertNewline(nil)
        try await settle(window)
        XCTAssertEqual(state.value, 320)
        XCTAssertEqual(state.saved, [320])
        window.makeFirstResponder(nil)
        state.value = 300
        try await settle(window)
        XCTAssertEqual(field.stringValue, "300", "Untouched fields should reflect config reloads")
        XCTAssertEqual(state.saved, [320])
    }

    func testAppearanceReloadKeepsScrollViewFocusAndDraft() async throws {
        let model = ShortcutSettingsModel.shared
        let window = host(ShortcutAppearanceSettingsView(model: model))
        defer { window.close() }
        try await settle(window)
        let content = try XCTUnwrap(window.contentView)
        let scroll = try XCTUnwrap(descendants(of: content, as: NSScrollView.self).first)
        let field = try XCTUnwrap(descendants(of: content, as: NSTextField.self).last { $0.isEditable })
        let editor = try edit(field, in: window)
        replace(editor, with: "37")
        try await settle(window)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(window)
        let origin = scroll.contentView.bounds.origin
        XCTAssertGreaterThan(origin.y, 0)

        model.reload()
        try await settle(window)

        XCTAssertTrue(descendants(of: content, as: NSScrollView.self).first === scroll)
        XCTAssertTrue(descendants(of: content, as: NSTextField.self).contains { $0 === field })
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.string, "37")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y, accuracy: 1)
    }

    func testRefreshingToggleFromConfigDoesNotSaveItAgain() async throws {
        let state = InputState()
        let window = host(ToggleInput(state: state))
        defer { window.close() }
        try await settle(window)

        state.enabled = true
        try await settle(window)
        XCTAssertTrue(state.savedToggles.isEmpty)
        state.enabled = false
        try await settle(window)
        XCTAssertTrue(state.savedToggles.isEmpty)
    }

    private func host(_ view: some View) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 540, height: 500),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        return window
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func edit(_ field: NSTextField, in window: NSWindow) throws -> NSTextView {
        XCTAssertTrue(window.makeFirstResponder(field))
        return try XCTUnwrap(field.currentEditor() as? NSTextView)
    }

    private func replace(_ editor: NSTextView, with text: String) {
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { child in
            (child as? T).map { [$0] } ?? []
        } + view.subviews.flatMap { descendants(of: $0, as: type) }
    }
}

@MainActor
private final class InputState: ObservableObject {
    @Published var value = 240
    @Published var enabled = false
    var saved: [Int] = []
    var savedToggles: [Bool] = []
}

private struct ToggleInput: View {
    @ObservedObject var state: InputState

    var body: some View {
        SettingsToggle("Enabled", isOn: $state.enabled) {
            state.savedToggles.append(state.enabled)
        }
    }
}

private struct NumberInput: View {
    @ObservedObject var state: InputState

    var body: some View {
        SettingsStepper("Width", value: $state.value, range: 120...480, help: "Width") {
            state.saved.append(state.value)
        }
    }
}

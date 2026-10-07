@testable import AppBundle
import AppKit
import WorkspaceCore
import XCTest

@MainActor
final class BrowserToolbarControlsTest: XCTestCase {
    private let extensionID = String(repeating: "a", count: 32)

    private func item() -> BrowserToolbarItem {
        var result = BrowserToolbarItem(surfaceID: .browserTab(profile: UUID(), tab: UUID()),
            frame: .init(x: 0, y: 0, width: 900, height: 36), url: "https://example.com/path?q=1",
            canGoBack: true, canGoForward: false, isLoading: false, isFocused: true)
        result.supportsToolbarActions = true
        result.pinnedExtensions = [.init(id: extensionID, title: "Test extension")]
        return result
    }

    private func button(_ identifier: String, in toolbar: BrowserToolbarView) throws -> NSButton {
        try XCTUnwrap(toolbar.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == identifier })
    }

    func testPinnedExtensionInvokesItsOwnActionAndUnpinsThroughOwner() throws {
        let toolbar = BrowserToolbarView()
        let state = item()
        toolbar.update(state, preserveAddress: false)
        var actions: [BrowserToolbarAction] = []
        toolbar.onAction = { actions.append($0) }
        let pin = try button("winmux.browser.extension." + extensionID, in: toolbar)
        pin.performClick(nil)
        let unpin = try XCTUnwrap(pin.menu?.items.first { $0.title == "Unpin from Toolbar" })
        XCTAssertTrue(toolbar.validateMenuItem(unpin))
        NSApp.sendAction(try XCTUnwrap(unpin.action), to: unpin.target, from: unpin)
        XCTAssertEqual(actions, [.extensionAction(extensionID), .unpinExtension(extensionID)])
        toolbar.update(state, preserveAddress: false)
        XCTAssertTrue(try button("winmux.browser.extension." + extensionID, in: toolbar) === pin)
        var removed = state
        removed.pinnedExtensions = []
        toolbar.update(removed, preserveAddress: false)
        XCTAssertNil(pin.superview)
    }

    func testPolicyAndIncognitoPinsCannotBeUnpinned() throws {
        let toolbar = BrowserToolbarView()
        var state = item()
        state.pinnedExtensions = [.init(id: extensionID, title: "Managed extension", canUnpin: false)]
        toolbar.update(state, preserveAddress: false)
        let pin = try button("winmux.browser.extension." + extensionID, in: toolbar)
        XCTAssertFalse(pin.menu?.items.contains { $0.title == "Unpin from Toolbar" } ?? true)
    }

    func testDedicatedExtensionsAndDownloadsDispatchAndReflectActivity() throws {
        let toolbar = BrowserToolbarView()
        var state = item()
        state.activeDownloads = 2
        toolbar.update(state, preserveAddress: false)
        var actions: [BrowserToolbarAction] = []
        toolbar.onAction = { actions.append($0) }
        try button("winmux.browser.extensions", in: toolbar).performClick(nil)
        let downloads = try button("winmux.browser.downloads", in: toolbar)
        XCTAssertEqual(downloads.toolTip, "Downloads — 2 in progress")
        downloads.performClick(nil)
        XCTAssertEqual(actions, [.extensions, .downloads])
    }

    func testGripStaysInRightCornerAndPinsOverflowWithoutOverlappingAddress() throws {
        let toolbar = BrowserToolbarView()
        var state = item()
        state.pinnedExtensions = (0..<8).map { .init(id: String(repeating: String(UnicodeScalar(97 + $0)!), count: 32), title: "Extension \($0)") }
        toolbar.update(state, preserveAddress: false)
        let grip = try XCTUnwrap(toolbar.subviews.first { $0.accessibilityIdentifier() == "winmux.browser.move" })
        for width: CGFloat in [164, 240, 420, 700, 1400] {
            toolbar.frame = .init(x: 0, y: 0, width: width, height: 36)
            toolbar.layout()
            XCTAssertEqual(grip.frame.maxX, width - 5)
            XCTAssertEqual(grip.frame.width, 24)
            let controls = toolbar.subviews.filter { !$0.isHidden && !($0 is BrowserChromeBackgroundView) }
            for (index, view) in controls.enumerated() {
                XCTAssertTrue(toolbar.bounds.contains(view.frame))
                for other in controls.dropFirst(index + 1) { XCTAssertFalse(view.frame.intersects(other.frame)) }
            }
            XCTAssertTrue(toolbar.menu?.items.contains { $0.title == "Downloads" } == true)
            XCTAssertTrue(toolbar.menu?.items.contains { $0.title == "Extensions" } == true)
        }
        XCTAssertGreaterThan(toolbar.address.superview!.frame.width, 540, "Wide headers give their spare width to the URL")
    }

    func testAddressDraftSurvivesUpdatesAndEscapeRestoresCommittedURL() {
        let toolbar = BrowserToolbarView()
        let state = item()
        toolbar.update(state, preserveAddress: false)
        toolbar.address.stringValue = "edited query"
        toolbar.update(state, preserveAddress: true)
        XCTAssertEqual(toolbar.address.stringValue, "edited query")
        var cancelled = false
        toolbar.onCancelAddress = { cancelled = true }
        XCTAssertTrue(toolbar.control(toolbar.address, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(cancelled)
        toolbar.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification))
        XCTAssertEqual(toolbar.address.stringValue, state.url)
    }

    func testAddressReturnSubmitsQueryAndEditingShortcutsUseFieldEditor() throws {
        let toolbar = BrowserToolbarView()
        let editor = NSTextView()
        editor.string = "  a search query  "
        var actions: [BrowserToolbarAction] = []
        toolbar.onAction = { actions.append($0) }
        XCTAssertTrue(toolbar.control(toolbar.address, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(actions, [.navigate("a search query")])
        for (key, selector) in [("a", "selectAll:"), ("c", "copy:"), ("v", "paste:"), ("x", "cut:"), ("z", "undo:")] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                timestamp: 0, windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: 0))
            XCTAssertEqual(BrowserToolbarAddressField.editingAction(for: event), Selector(selector))
        }
    }

    func testCommandLReselectsDraftAndEscapeReturnsToPage() throws {
        _ = NSApplication.shared
        let state = item()
        let panel = BrowserToolbarPanel(surfaceID: state.surfaceID)
        defer { panel.dismiss(); panel.close() }
        panel.update(state)
        var actions: [BrowserToolbarAction] = []
        panel.onAction = { actions.append($0) }
        let commandL = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "l", charactersIgnoringModifiers: "l",
            isARepeat: false, keyCode: 37))
        XCTAssertTrue(panel.performKeyEquivalent(with: commandL))
        let editor = try XCTUnwrap(panel.toolbarView.address.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: state.url.utf16.count))
        editor.insertText("replacement query", replacementRange: editor.selectedRange())
        editor.breakUndoCoalescing()
        let undo = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z",
            isARepeat: false, keyCode: 6))
        XCTAssertTrue(panel.performKeyEquivalent(with: undo))
        XCTAssertEqual(editor.string, state.url)
        let redo = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "Z", charactersIgnoringModifiers: "z",
            isARepeat: false, keyCode: 6))
        XCTAssertTrue(panel.performKeyEquivalent(with: redo))
        XCTAssertEqual(editor.string, "replacement query")
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertTrue(panel.performKeyEquivalent(with: commandL))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertTrue(panel.toolbarView.control(panel.toolbarView.address, textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(panel.toolbarView.address.stringValue, state.url)
        XCTAssertFalse(panel.isEditingAddress)
        XCTAssertEqual(actions, [.focusPage])
    }
}

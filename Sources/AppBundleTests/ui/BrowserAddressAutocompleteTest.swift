@testable import AppBundle
import AppKit
import WorkspaceCore
import XCTest

@MainActor
final class BrowserAddressAutocompleteTest: XCTestCase {
    private let profile = UUID()
    private var surface: SurfaceID { .browserTab(profile: profile, tab: UUID()) }
    private let history = [
        BrowserHistoryEntry(url: "https://github.com/", title: "GitHub", visitCount: 12, lastVisit: 100),
        BrowserHistoryEntry(url: "https://github.com/jameslyons/winmux/issues", title: "Issues · WinMux", visitCount: 4, lastVisit: 200),
        BrowserHistoryEntry(url: "https://example.com/guide", title: "GitHub setup guide", visitCount: 20, lastVisit: 300),
    ]

    func testRanksHostAndURLPrefixesAheadOfTitleAndKeepsSearchChoice() throws {
        let rows = BrowserAddressSuggestions.make(query: "git", history: history, tabs: [], surfaceID: surface, isPrivate: false)
        XCTAssertEqual(rows.first?.url, "https://github.com/")
        XCTAssertEqual(rows.first?.completion(for: "git"), "github.com")
        XCTAssertEqual(rows[1].kind, .search)
        XCTAssertEqual(URLComponents(string: rows[1].url)?.queryItems?.first?.value, "git")
        XCTAssertEqual(rows.last?.title, "GitHub setup guide")
        let titles = BrowserAddressSuggestions.make(query: "setup guide", history: history, tabs: [], surfaceID: surface, isPrivate: false)
        XCTAssertEqual(titles.first?.kind, .search)
        XCTAssertEqual(titles.last?.url, "https://example.com/guide")
        XCTAssertNil(titles.last?.completion(for: "setup guide"))
    }

    func testCompletionPreservesSchemesCasePathsAndUnicode() {
        let row = BrowserAddressSuggestion(kind: .history, title: "", url: "http://www.example.com/Path?q=1")
        XCTAssertEqual(row.completion(for: "exa"), "example.com/Path?q=1")
        XCTAssertEqual(row.completion(for: "EXA"), "EXAmple.com/Path?q=1")
        XCTAssertEqual(row.completion(for: "http://www.ex"), "http://www.example.com/Path?q=1")
        XCTAssertNil(row.completion(for: "ample"))
        XCTAssertNil(row.completion(for: "example query"))
        let unicode = BrowserAddressSuggestion(kind: .history, title: "", url: "https://example.com/🌎/guide")
        XCTAssertEqual(unicode.completion(for: "example.com/🌎"), "example.com/🌎/guide")
    }

    func testDeduplicatesTabsAndHistoryAndIsolatesProfilesAndPrivatePages() {
        let current = surface, other = surface
        let tabs = [
            BrowserTabRecord(surfaceID: other, hostID: "1", title: "GitHub", selected: false, url: history[0].url),
            BrowserTabRecord(surfaceID: .browserTab(profile: UUID(), tab: UUID()), hostID: "2", title: "Other profile", selected: false, url: "https://github.com/other"),
            BrowserTabRecord(surfaceID: surface, hostID: "3", title: "Private", selected: false, privateBrowsing: true, url: "https://github.com/private"),
        ]
        let rows = BrowserAddressSuggestions.make(query: "git", history: history, tabs: tabs, surfaceID: current, isPrivate: false)
        XCTAssertEqual(rows.filter { $0.url == history[0].url }.count, 1)
        XCTAssertEqual(rows.first?.tabID, other)
        XCTAssertFalse(rows.contains { $0.title == "Private" || $0.title == "Other profile" })
        let privateRows = BrowserAddressSuggestions.make(query: "git", history: history, tabs: tabs, surfaceID: current, isPrivate: true)
        XCTAssertEqual(privateRows.count, 2)
        XCTAssertTrue(privateRows.contains { $0.title == "Private" })
        XCTAssertFalse(privateRows.contains { $0.kind == .history })
    }

    func testUnmatchedURLSearchAndEmptyQueryAreBounded() {
        let direct = BrowserAddressSuggestions.make(query: "localhost:3000/test", history: [], tabs: [], surfaceID: surface, isPrivate: false)
        XCTAssertEqual(direct.first?.url, "http://localhost:3000/test")
        XCTAssertEqual(direct.last?.kind, .search)
        let recent = BrowserAddressSuggestions.make(query: "", history: history, tabs: [], surfaceID: surface, isPrivate: false, limit: 2)
        XCTAssertEqual(recent.count, 2)
        XCTAssertFalse(recent.contains { $0.kind == .search })
        XCTAssertTrue(BrowserAddressSuggestions.make(query: "javascript:alert(1)", history: history, tabs: [], surfaceID: surface, isPrivate: false).isEmpty)
    }

    func testStaleRepliesDismissalKeyboardAndInlineSelection() async throws {
        let field = NSTextField(), editor = NSTextView()
        let autocomplete = BrowserAddressAutocomplete(field: field)
        var replies: [String: ([BrowserAddressSuggestion]) -> Void] = [:]
        let first = expectation(description: "first query"), second = expectation(description: "second query")
        autocomplete.provider = { query, reply in
            replies[query] = reply
            (query == "g" ? first : second).fulfill()
        }
        editor.string = "g"; editor.setSelectedRange(.init(location: 1, length: 0))
        autocomplete.request(query: "g", editor: editor, allowInline: true)
        await fulfillment(of: [first], timeout: 2)
        editor.string = "git"; editor.setSelectedRange(.init(location: 3, length: 0))
        autocomplete.request(query: "git", editor: editor, allowInline: true)
        await fulfillment(of: [second], timeout: 2)
        let rows = BrowserAddressSuggestions.make(query: "git", history: history, tabs: [], surfaceID: surface, isPrivate: false)
        replies["g"]?(rows)
        XCTAssertEqual(editor.string, "git")
        XCTAssertTrue(autocomplete.suggestions.isEmpty)
        replies["git"]?(rows)
        XCTAssertEqual(editor.string, "github.com")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 7))
        XCTAssertTrue(autocomplete.command(#selector(NSResponder.moveDown(_:)), editor: editor))
        XCTAssertEqual(editor.string, "git")
        var navigated: String?
        autocomplete.onNavigate = { navigated = $0 }
        XCTAssertTrue(autocomplete.command(#selector(NSResponder.insertNewline(_:)), editor: editor))
        XCTAssertEqual(navigated, rows[1].url)
        replies["git"]?(rows)
        XCTAssertTrue(autocomplete.suggestions.isEmpty, "A submitted or dismissed draft cannot reopen")
    }

    func testDeletionDoesNotReinsertSuffixAndTabSwitchDispatchesOnce() async throws {
        let field = NSTextField(), editor = NSTextView()
        let autocomplete = BrowserAddressAutocomplete(field: field)
        let target = surface
        let rows = [BrowserAddressSuggestion(kind: .history, title: "GitHub", url: "https://github.com/", tabID: target),
                    BrowserAddressSuggestion(kind: .search, title: "git — Kagi Search", url: "https://kagi.com/search?q=git")]
        let received = expectation(description: "results")
        autocomplete.provider = { _, reply in reply(rows); received.fulfill() }
        editor.string = "git"; editor.setSelectedRange(.init(location: 3, length: 0))
        autocomplete.request(query: "git", editor: editor, allowInline: false)
        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(editor.string, "git")
        XCTAssertEqual(autocomplete.selectedIndex, 1)
        XCTAssertTrue(autocomplete.command(#selector(NSResponder.moveUp(_:)), editor: editor))
        var switches: [SurfaceID] = []
        autocomplete.onSwitchTab = { switches.append($0) }
        XCTAssertTrue(autocomplete.command(#selector(NSResponder.insertTab(_:)), editor: editor))
        autocomplete.activate(0, switchTab: true)
        XCTAssertEqual(switches, [target])
    }

    func testNativePopupRetainsEditorRendersBothAppearancesAndDismissesWithToolbar() async throws {
        _ = NSApplication.shared
        let id = surface
        let panel = BrowserToolbarPanel(surfaceID: id)
        defer { panel.dismiss(); panel.close() }
        var state = BrowserToolbarItem(surfaceID: id, frame: .init(x: 100, y: 500, width: 1100, height: 36),
            url: "https://example.com/", canGoBack: true, canGoForward: false, isLoading: false, isFocused: true)
        let other = BrowserTabRecord(surfaceID: surface, hostID: "other", title: "Issues · WinMux", selected: false, url: history[1].url)
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            state.chromeAppearance = appearance
            panel.update(state)
            let received = expectation(description: "native query")
            panel.toolbarView.autocomplete.provider = { [self] query, reply in
                reply(BrowserAddressSuggestions.make(query: query, history: history, tabs: [other], surfaceID: id, isPrivate: false))
                received.fulfill()
            }
            XCTAssertTrue(panel.focusAddress())
            let editor = try XCTUnwrap(panel.toolbarView.address.currentEditor() as? NSTextView)
            editor.insertText("git", replacementRange: editor.selectedRange())
            await fulfillment(of: [received], timeout: 2)
            XCTAssertEqual(editor.string, "github.com")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 7))
            XCTAssertTrue(panel.isKeyWindow)
            let popup = try XCTUnwrap(panel.childWindows?.first { $0.accessibilityIdentifier() == "winmux.browser.address.suggestions" })
            XCTAssertFalse(popup.canBecomeKey)
            XCTAssertLessThanOrEqual(popup.frame.maxY, panel.frame.minY + 10)
            let content = try XCTUnwrap(popup.contentView)
            content.layoutSubtreeIfNeeded()
            if let directory = ProcessInfo.processInfo.environment["WINMUX_AUTOCOMPLETE_PROOF_DIRECTORY"] {
                let url = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent(appearance == .aqua ? "light.png" : "dark.png"))
            }
            // The suffix and typed prefix can both be undone without appending
            // stale characters to the previously committed URL.
            editor.undoManager?.undo()
            XCTAssertEqual(editor.string, "git")
            editor.undoManager?.undo()
            XCTAssertEqual(editor.string, state.url)
            panel.dismiss()
            XCTAssertFalse(popup.isVisible)
            XCTAssertFalse(panel.toolbarView.autocomplete.isVisible)
            XCTAssertNil(popup.parent)
        }
    }

    func testFocusingAddressShowsHistoryWithoutChoosingItAndLosingFocusDismisses() async throws {
        _ = NSApplication.shared
        let id = surface
        let panel = BrowserToolbarPanel(surfaceID: id)
        defer { panel.dismiss(); panel.close() }
        let url = "https://example.com/"
        panel.update(.init(surfaceID: id, frame: .init(x: 100, y: 500, width: 700, height: 36),
            url: url, canGoBack: false, canGoForward: false, isLoading: false, isFocused: true))
        let received = expectation(description: "history on focus")
        panel.toolbarView.autocomplete.provider = { [self] query, reply in
            XCTAssertEqual(query, "")
            reply(BrowserAddressSuggestions.make(query: query, history: history, tabs: [], surfaceID: id, isPrivate: false))
            received.fulfill()
        }
        XCTAssertTrue(panel.focusAddress())
        await fulfillment(of: [received], timeout: 2)
        XCTAssertTrue(panel.toolbarView.autocomplete.isVisible)
        XCTAssertEqual(panel.toolbarView.autocomplete.selectedIndex, -1)
        XCTAssertEqual(panel.toolbarView.address.currentEditor()?.string, url)
        panel.resignKey()
        XCTAssertFalse(panel.toolbarView.autocomplete.isVisible)
    }
}

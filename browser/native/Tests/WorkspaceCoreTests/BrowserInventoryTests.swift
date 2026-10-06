import Foundation
import WorkspaceCore
import XCTest

final class BrowserInventoryTests: XCTestCase {
    func testHostWindowBindingMustBeConsistentWithinConnection() {
        var inventory = BrowserInventory()
        let a = SurfaceID.browserTab(profile: UUID(), tab: UUID()), b = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let first = BrowserTabRecord(surfaceID: a, hostID: "host:1", title: "", selected: true, hostWindowID: 42)
        XCTAssertTrue(inventory.apply(.init(revision: 1, full: true, tabs: [first])))
        for invalid in [
            BrowserTabRecord(surfaceID: b, hostID: "host:1", title: "", selected: false, hostWindowID: 43),
            BrowserTabRecord(surfaceID: b, hostID: "host:2", title: "", selected: false, hostWindowID: 42),
            BrowserTabRecord(surfaceID: b, hostID: "host:2", title: "", selected: false, hostWindowID: 0),
        ] {
            XCTAssertFalse(inventory.apply(.init(revision: 2, full: false, tabs: [invalid])))
            XCTAssertEqual(inventory.tabs, [a: first])
        }
    }
    func testNavigationStateRoundTripsAndLegacyInventoryDefaults() throws {
        let id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        let record = BrowserTabRecord(surfaceID: id, hostID: "host:1", title: "Page", selected: true,
                                      url: "https://example.test/path", canGoBack: true,
                                      canGoForward: true, isLoading: true, hostManaged: true, hostMinimized: true, hostFullscreen: true, hostZoomed: true, focused: true)
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(BrowserTabRecord.self, from: data), record)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["url", "can_go_back", "can_go_forward", "is_loading", "host_managed", "host_minimized", "host_fullscreen", "host_zoomed", "focused"] {
            legacy.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(BrowserTabRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.url, "")
        XCTAssertFalse(decoded.canGoBack || decoded.canGoForward || decoded.isLoading || decoded.hostManaged || decoded.hostMinimized || decoded.hostFullscreen || decoded.hostZoomed || decoded.focused)
        var inventory = BrowserInventory()
        XCTAssertTrue(inventory.apply(.init(revision: 1, full: true, tabs: [record])))
        let oversized = BrowserTabRecord(surfaceID: id, hostID: "host:1", title: "Page", selected: true,
                                         url: String(repeating: "x", count: 16_385))
        XCTAssertFalse(inventory.apply(.init(revision: 2, full: false, tabs: [oversized])))
        XCTAssertEqual(inventory.tabs[id], record)
    }

    private func tab(id: SurfaceID = .browserTab(profile: UUID(), tab: UUID()), title: String = "Synthetic tab", privateBrowsing: Bool = false) -> BrowserTabRecord {
        BrowserTabRecord(surfaceID: id, hostID: "host:1", title: title, selected: true, privateBrowsing: privateBrowsing)
    }

    func testFullThenDeltasAndRemovalAreAuthoritative() throws {
        var inventory = BrowserInventory()
        let a = tab(), b = tab()
        let full = BrowserInventoryMessage(revision: 4, full: true, tabs: [a, b])
        let decoded = try JSONDecoder().decode(BrowserInventoryMessage.self, from: JSONEncoder().encode(full))
        XCTAssertTrue(inventory.apply(decoded))
        XCTAssertTrue(inventory.apply(.init(revision: 5, full: false, tabs: [tab(id: a.surfaceID, title: "Changed")], removed: [b.surfaceID])))
        XCTAssertEqual(inventory.tabs.count, 1)
        XCTAssertEqual(inventory.tabs[a.surfaceID]?.title, "Changed")
        XCTAssertTrue(inventory.apply(.init(revision: 7, full: true, tabs: [b])))
        XCTAssertEqual(inventory.tabs, [b.surfaceID: b])
    }

    func testStaleMissingAndOutOfOrderUpdatesCannotPartiallyMutateState() {
        var inventory = BrowserInventory()
        let a = tab(), b = tab()
        XCTAssertFalse(inventory.apply(.init(revision: 1, full: false, tabs: [a])))
        XCTAssertTrue(inventory.apply(.init(revision: 1, full: true, tabs: [a])))
        XCTAssertFalse(inventory.apply(.init(revision: 1, full: true, tabs: [b])))
        XCTAssertFalse(inventory.apply(.init(revision: 3, full: false, tabs: [b])))
        XCTAssertFalse(inventory.apply(.init(revision: 2, full: false, tabs: [], removed: [a.surfaceID, b.surfaceID])))
        XCTAssertEqual(inventory.revision, 1)
        XCTAssertEqual(inventory.tabs, [a.surfaceID: a])
    }

    func testPrivateRecordsRemainConnectionScopedAndFlagged() {
        var inventory = BrowserInventory()
        let page = tab(privateBrowsing: true)
        XCTAssertTrue(inventory.apply(.init(revision: 1, full: true, tabs: [page])))
        XCTAssertEqual(inventory.tabs[page.surfaceID]?.privateBrowsing, true)
        XCTAssertFalse(inventory.apply(.init(revision: 2, full: true, tabs: [tab(id: page.surfaceID)])))
        XCTAssertTrue(inventory.apply(.init(revision: 2, full: false, tabs: [], removed: [page.surfaceID])))
        XCTAssertTrue(inventory.tabs.isEmpty)
    }

    func testNativeDuplicateAndConflictingRecordsAreRejected() {
        var inventory = BrowserInventory()
        let a = tab()
        for message in [
            BrowserInventoryMessage(revision: 1, full: true, tabs: [tab(id: .nativeWindow(UUID()))]),
            .init(revision: 1, full: true, tabs: [a, a]),
            .init(revision: 1, full: true, tabs: [a], removed: [a.surfaceID]),
            .init(revision: 1, full: true, tabs: [tab(title: String(repeating: "x", count: 4097))]),
        ] { XCTAssertFalse(inventory.apply(message)) }
        XCTAssertTrue(inventory.tabs.isEmpty)
    }
}

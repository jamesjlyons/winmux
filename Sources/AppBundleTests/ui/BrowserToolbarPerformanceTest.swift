@testable import AppBundle
import AppKit
import WorkspaceCore
import XCTest

@MainActor
final class BrowserToolbarPerformanceTest: XCTestCase {
    private func item(_ id: SurfaceID) -> BrowserToolbarItem {
        .init(surfaceID: id, frame: .init(x: 0, y: 0, width: 500, height: 28),
              url: "https://example.com", canGoBack: false, canGoForward: false,
              isLoading: false, isFocused: false)
    }

    func testSwitchingGroupsHidesAndReusesControlsThenEvictsClosedPages() throws {
        _ = NSApplication.shared
        let id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var liveIDs: Set<SurfaceID> = [id]
        let controller = BrowserToolbarController(isAvailable: { liveIDs.contains($0) })
        defer { controller.hideAll() }
        controller.update(items: [item(id)]) { _, _ in }
        let panel = try XCTUnwrap(controller.panels[id])
        for _ in 0 ..< 10 {
            controller.update(items: []) { _, _ in }
            XCTAssertFalse(panel.isVisible, "Departing controls must disappear in the same update")
            XCTAssertTrue(controller.presentationItems.isEmpty)
            XCTAssertTrue(controller.accessibilityWindows.isEmpty)
            controller.update(items: [item(id)]) { _, _ in }
            XCTAssertTrue(controller.panels[id] === panel)
        }
        liveIDs.remove(id)
        controller.update(items: []) { _, _ in }
        XCTAssertNil(controller.panels[id])
    }

    func testHiddenToolbarCacheIsBounded() {
        _ = NSApplication.shared
        let controller = BrowserToolbarController(isAvailable: { _ in true })
        defer { controller.hideAll() }
        let ids = (0 ... BrowserToolbarController.hiddenPanelLimit).map { _ in
            SurfaceID.browserTab(profile: UUID(), tab: UUID())
        }
        for id in ids { controller.update(items: [item(id)]) { _, _ in } }
        controller.update(items: []) { _, _ in }
        XCTAssertEqual(controller.panels.count, BrowserToolbarController.hiddenPanelLimit)
        XCTAssertNil(controller.panels[ids[0]], "Evict the least recently visible page")
        XCTAssertNotNil(controller.panels[ids.last!])
    }

    func testUnchangedToolbarDoesNotRecreateSymbolsOrRequestLayout() throws {
        _ = NSApplication.shared
        let toolbar = BrowserToolbarView()
        let host = NSWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 28),
                            styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = toolbar
        defer { host.close() }
        let id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        toolbar.update(item(id), preserveAddress: false)
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertFalse(toolbar.needsLayout, "Settle the initial view hierarchy before measuring a repeated update")
        let reload = try XCTUnwrap(toolbar.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == "Reload page" })
        let image = reload.image
        toolbar.update(item(id), preserveAddress: false)
        XCTAssertTrue(reload.image === image)
        XCTAssertFalse(toolbar.needsLayout)
        XCTAssertEqual(toolbar.address.stringValue, "https://example.com")
        toolbar.address.stringValue = "unsubmitted draft"
        toolbar.update(item(id), preserveAddress: false)
        XCTAssertEqual(toolbar.address.stringValue, "https://example.com",
                       "A cached toolbar must discard unfinished editing when it returns")
    }

    func testPinFaviconIsReusedAndInvalidImagesAreIgnored() throws {
        let cache = WorkspaceSidebarPinImageCache()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let encoded = data.base64EncodedString()
        let first = try XCTUnwrap(cache.image(for: encoded))
        XCTAssertTrue(cache.image(for: encoded) === first)
        XCTAssertNil(cache.image(for: "invalid base64"))
    }
}

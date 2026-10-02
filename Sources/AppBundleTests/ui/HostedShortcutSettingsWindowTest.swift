@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class HostedShortcutSettingsWindowTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testHostedSettingsReusesTheOriginalSettingsWindowAfterClose() {
        _ = NSApplication.shared
        let presenter = HostedShortcutSettingsWindow()
        let window = presenter.windowForPresentation()
        defer { window.close() }
        XCTAssertEqual(window.identifier?.rawValue, shortcutSettingsWindowId)
        XCTAssertNotNil(window.contentView)
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertFalse(window.styleMask.contains(.resizable))
        window.close()
        XCTAssertTrue(presenter.windowForPresentation() === window)
    }

    func testHelperAndOriginalSettingsRequestsUseTheSameRequestModel() {
        let model = ShortcutSettingsModel.shared
        let previous = model.openRequestId
        requestShortcutSettingsWindow()
        XCTAssertEqual(model.openRequestId, previous + 1)
    }
}

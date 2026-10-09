@testable import AppBundle
import AppKit
import XCTest

final class DeviceHubWindowTypeTest: XCTestCase {
    func testStandardDeviceHubWindowWithFullscreenButtonFloats() {
        // Attributes observed from Device Hub's device display. Without its
        // bundle rule, these are the attributes of an ordinary tiled window.
        let button = DeviceHubAXFixture(attributes: [kAXEnabledAttribute: true])
        let window = DeviceHubAXFixture(attributes: [
            kAXSubroleAttribute: kAXStandardWindowSubrole,
            kAXCloseButtonAttribute: button,
            kAXMinimizeButtonAttribute: button,
            kAXFullScreenButtonAttribute: button,
            kAXMainAttribute: true,
            kAXFocusedAttribute: true,
        ])
        let app = DeviceHubAXFixture(attributes: [:])
        XCTAssertEqual(KnownBundleId(rawValue: "com.apple.dt.Devices"), .deviceHub)
        XCTAssertEqual(window.getWindowType(axApp: app, .deviceHub, .regular, .normalWindow), .dialog)
        XCTAssertEqual(window.getWindowType(axApp: app, nil, .regular, .normalWindow), .window)
    }
}

private struct DeviceHubAXFixture: AxUiElementMock {
    let attributes: [String: Any]
    func get<Attr: ReadableAttr>(_ attr: Attr) -> Attr.T? { attributes[attr.key] as? Attr.T }
    func containingWindowId() -> CGWindowID? { nil }
}

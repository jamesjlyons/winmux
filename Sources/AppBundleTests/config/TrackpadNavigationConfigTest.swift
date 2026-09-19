@testable import AppBundle
import Common
import XCTest

@MainActor
final class TrackpadNavigationConfigTest: XCTestCase {
    func testDefaultsAndTOMLRoundTrip() {
        XCTAssertEqual(parseConfig("").config.trackpadNavigation, TrackpadNavigationConfig())
        let parsed = parseConfig("""
            [trackpad-navigation]
            enabled = true
            reverse-direction = true
            """)
        XCTAssertTrue(parsed.errors.isEmpty)
        XCTAssertEqual(parsed.config.trackpadNavigation, TrackpadNavigationConfig(enabled: true, reverseDirection: true))
    }

    func testRejectsWrongTypesAndUnknownKeys() {
        for value in ["enabled = 'true'", "reverse-direction = 1", "fingers = 4"] {
            XCTAssertFalse(parseConfig("[trackpad-navigation]\n\(value)").errors.isEmpty)
        }
    }

    func testSettingsEditsPreserveExistingConfiguration() {
        var text = "tab-group-padding = 35\n[workspace-sidebar]\nenabled = true\n"
        for enabled in [true, false] {
            text = updateSettingsScalarConfig(in: text, section: "trackpad-navigation", key: "enabled",
                renderedValue: enabled ? "true" : "false")
            let parsed = parseConfig(text)
            XCTAssertTrue(parsed.errors.isEmpty)
            XCTAssertEqual(parsed.config.trackpadNavigation.enabled, enabled)
            XCTAssertEqual(parsed.config.tabGroupPadding, 35)
            XCTAssertTrue(parsed.config.workspaceSidebar.enabled)
        }
    }

    func testConfigCommandReportsBooleanValues() async throws {
        let previous = config
        defer { config = previous }
        config.trackpadNavigation = TrackpadNavigationConfig(enabled: true, reverseDirection: false)
        guard case .cmd(let command) = parseCommand("config --get trackpad-navigation --json") else {
            return XCTFail("Could not parse config command")
        }
        let result = try await command.run(.defaultEnv, .emptyStdin)
        XCTAssertEqual(result.exitCode, 0)
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.joined(separator: "\n").utf8)) as? [String: Bool]
        XCTAssertEqual(object, ["enabled": true, "reverse-direction": false])
    }
}

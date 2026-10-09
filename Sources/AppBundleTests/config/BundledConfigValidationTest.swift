@testable import AppBundle
import Foundation
import XCTest

@MainActor
final class BundledConfigValidationTest: XCTestCase {
    func testShippedDefaultConfigurationIsAccepted() throws {
        try validateBundledDefaultConfig(at: getDefaultConfigUrlFromProject())
    }

    func testIncompatibleConfigurationThrowsInsteadOfInitializingGlobalConfig() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
        defer { try? FileManager.default.removeItem(at: file) }
        try "[workspace-sidebar]\nunknown-bundled-option = 0\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try validateBundledDefaultConfig(at: file)) { error in
            XCTAssertTrue(error.localizedDescription.contains("workspace-sidebar.unknown-bundled-option: Unknown key"))
        }
    }

    func testMissingFileThrowsInsteadOfFallingBackToRepositoryConfiguration() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
        XCTAssertThrowsError(try validateBundledDefaultConfig(at: file))
    }

    func testMalformedTomlThrowsWithoutLoadingGlobalDefaultConfiguration() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
        defer { try? FileManager.default.removeItem(at: file) }
        try "[workspace-sidebar".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try validateBundledDefaultConfig(at: file))
    }
}

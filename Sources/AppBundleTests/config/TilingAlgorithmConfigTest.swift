@testable import AppBundle
import XCTest

@MainActor
final class TilingAlgorithmConfigTest: XCTestCase {
    func testDefaultsAndSettingsRoundTrip() {
        XCTAssertEqual(parseConfig("").config.tilingAlgorithm, .adaptive)
        XCTAssertEqual(defaultConfig.tilingAlgorithm, .adaptive)
        for algorithm in TilingAlgorithm.allCases {
            let original = "new-item-placement = 'tile' # keep this\n"
            let updated = updateSettingsScalarConfig(in: original, section: nil,
                key: "tiling-algorithm", renderedValue: "'\(algorithm.rawValue)'")
            let parsed = parseConfig(updated)
            XCTAssertTrue(parsed.errors.isEmpty, "\(parsed.errors)")
            XCTAssertEqual(parsed.config.tilingAlgorithm, algorithm)
            XCTAssertEqual(parsed.config.newItemPlacement, .tile)
            XCTAssertTrue(updated.contains(original))
        }
    }

    func testInvalidAlgorithmsAreRejected() {
        for value in ["'unknown'", "true", "1"] {
            XCTAssertFalse(parseConfig("tiling-algorithm = \(value)").errors.isEmpty)
        }
    }
}

@testable import AppBundle
import XCTest

@MainActor
final class NewItemPlacementConfigTest: XCTestCase {
    func testModernPoliciesOverrideEveryLegacyCombinationInEitherKeyOrder() {
        for mode in ["views", "tiling"] {
            for tile in [true, false] {
                for stack in [true, false] {
                    let legacy = "workspace-interaction-mode = '\(mode)'\nautomatically-tile-new-windows = \(tile)\nauto-add-new-windows-to-tab-group = \(stack)"
                    let expected: NewItemPlacement = mode == "views" ? .newView : !tile ? .floatNative : stack ? .stackNative : .tile
                    let parsed = parseConfig(legacy)
                    XCTAssertTrue(parsed.errors.isEmpty)
                    XCTAssertEqual(parsed.config.newItemPlacement, expected)
                    for policy in NewItemPlacement.allCases {
                        let modern = "new-item-placement = '\(policy.rawValue)'"
                        for text in [modern + "\n" + legacy, legacy + "\n" + modern] {
                            let parsed = parseConfig(text)
                            XCTAssertTrue(parsed.errors.isEmpty)
                            XCTAssertEqual(parsed.config.newItemPlacement, policy)
                        }
                    }
                }
            }
        }
    }

    func testLegacyDefaultsApplyOnlyWhenAnArrivalKeyIsExplicit() {
        for (text, expected) in [
            ("", NewItemPlacement.newView),
            ("workspace-interaction-mode = 'tiling'", .tile),
            ("automatically-tile-new-windows = true", .tile),
            ("automatically-tile-new-windows = false", .floatNative),
            ("auto-add-new-windows-to-tab-group = true", .stackNative),
            ("auto-add-new-windows-to-tab-group = false", .tile),
        ] {
            let parsed = parseConfig(text)
            XCTAssertTrue(parsed.errors.isEmpty)
            XCTAssertEqual(parsed.config.newItemPlacement, expected)
        }
    }

    func testModernPolicyDoesNotHideInvalidLegacyValues() {
        for text in ["new-item-placement = 'invalid'", "new-item-placement = false",
                     "workspace-interaction-mode = 'unknown'", "automatically-tile-new-windows = 'false'",
                     "auto-add-new-windows-to-tab-group = 1"] {
            XCTAssertFalse(parseConfig(text).errors.isEmpty)
            if !text.hasPrefix("new-item-placement") {
                XCTAssertFalse(parseConfig("new-item-placement = 'new-view'\n" + text).errors.isEmpty)
            }
        }
    }

    func testSettingsOverridePreservesLegacyLinesAndTheirComments() {
        let old = "automatically-tile-new-windows = false # existing preference\nauto-add-new-windows-to-tab-group = true\n"
        for policy in NewItemPlacement.allCases {
            let updated = updateSettingsScalarConfig(in: old, section: nil, key: "new-item-placement", renderedValue: "'\(policy.rawValue)'")
            XCTAssertTrue(updated.contains(old))
            let parsed = parseConfig(updated)
            XCTAssertTrue(parsed.errors.isEmpty)
            XCTAssertEqual(parsed.config.newItemPlacement, policy)
        }
    }
}

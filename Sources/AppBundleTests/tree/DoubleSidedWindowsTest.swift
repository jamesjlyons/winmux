@testable import AppBundle
import XCTest

@MainActor
final class DoubleSidedWindowsTest: XCTestCase {
    func testLegacyFlipPreferenceUsesOrdinaryTabsWithoutChangingSelection() {
        setUpWorkspacesForTests()
        let saved = UserDefaults.standard.object(forKey: "doubleSidedWindows")
        defer { UserDefaults.standard.set(saved, forKey: "doubleSidedWindows") }
        UserDefaults.standard.set(true, forKey: "doubleSidedWindows")
        config.windowTabs.enabled = true
        let group = Workspace.get(byName: "pair").rootTilingContainer
        group.layout = .tabGroup
        let front = TestWindow.new(id: 1, parent: group)
        _ = TestWindow.new(id: 2, parent: group)
        front.markAsMostRecentChild()
        XCTAssertTrue(group.showsWindowTabs)
        XCTAssertTrue(group.tabActiveWindow === front)
        XCTAssertEqual(group.children.count, 2)
        front.isFullscreen = true
        XCTAssertFalse(group.showsWindowTabs)
        front.isFullscreen = false
        config.windowTabs.enabled = false
        XCTAssertFalse(group.showsWindowTabs)
    }
}

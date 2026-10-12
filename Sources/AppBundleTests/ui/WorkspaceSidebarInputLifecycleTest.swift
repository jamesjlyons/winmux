import AppKit
@testable import AppBundle
import XCTest

@MainActor
final class WorkspaceSidebarInputLifecycleTest: XCTestCase {
    func testSearchNeedsNoPointerExitMonitorsAndRenameReusesItsMonitors() {
        let panel = WorkspaceSidebarPanel.shared
        let oldPolicy = panel.inlineTextEditingCancelsOnPointerExit
        defer {
            panel.removeInlineTextEditingEventMonitors()
            panel.inlineTextEditingCancelsOnPointerExit = oldPolicy
        }
        panel.inlineTextEditingCancelsOnPointerExit = false
        for _ in 0 ..< 100 { panel.installInlineTextEditingEventMonitors() }
        XCTAssertTrue(panel.inlineTextEditingEventMonitors.isEmpty)

        panel.inlineTextEditingCancelsOnPointerExit = true
        panel.installInlineTextEditingEventMonitors()
        let monitors = panel.inlineTextEditingEventMonitors.map { ObjectIdentifier($0 as AnyObject) }
        XCTAssertFalse(monitors.isEmpty)
        for _ in 0 ..< 100 { panel.installInlineTextEditingEventMonitors() }
        XCTAssertEqual(panel.inlineTextEditingEventMonitors.map { ObjectIdentifier($0 as AnyObject) }, monitors)

        panel.inlineTextEditingCancelsOnPointerExit = false
        panel.installInlineTextEditingEventMonitors()
        XCTAssertTrue(panel.inlineTextEditingEventMonitors.isEmpty)
    }

    func testSearchHandoffUpdatesHandlersWithoutRestartingFocusOrInputSession() {
        let panel = WorkspaceSidebarPanel.shared
        let previousActivePanel = WorkspaceSidebarPanel.activeInlineTextEditingPanel
        let originalWidth = panel.viewModel.workspaceSidebarVisibleWidth
        let keyWindow = NSApp?.keyWindow
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        defer {
            panel.endInlineTextEditing()
            WorkspaceSidebarPanel.activeInlineTextEditingPanel = previousActivePanel
        }
        // The command has already opened and armed input; SwiftUI now adopts it.
        panel.inlineTextEditingActive = true
        WorkspaceSidebarPanel.activeInlineTextEditingPanel = panel
        panel.inlineTextEditingStartedAt = startedAt
        var oldHandlerCalls = 0
        panel.inlineTextEditingKeyDown = { _ in oldHandlerCalls += 1 }
        var received: [String] = []
        panel.beginInlineTextEditing(locksExpansion: false, cancelsOnPointerExit: false, onKeyDown: {
            if case .text(let text) = $0 { received.append(text) }
        })
        XCTAssertTrue(panel.handleInlineTextEditingKey(.text("a")))
        XCTAssertEqual(received, ["a"])
        XCTAssertEqual(oldHandlerCalls, 0)
        XCTAssertEqual(panel.inlineTextEditingStartedAt, startedAt)
        XCTAssertEqual(panel.viewModel.workspaceSidebarVisibleWidth, originalWidth)
        XCTAssertEqual(NSApp?.keyWindow, keyWindow)
        XCTAssertTrue(panel.inlineTextEditingEventMonitors.isEmpty)
        XCTAssertFalse(panel.inlineTextEditingLocksExpansion)
    }

    func testCommandUnlockHonorsGraceAndDistanceThenReleasesSearchLock() {
        let panel = WorkspaceSidebarPanel.shared
        let oldLock = panel.commandExpansionLocksCollapse
        let oldInlineLock = panel.inlineTextEditingLocksExpansion
        let oldNextLock = panel.shouldLockNextSidebarSearchExpansion
        defer {
            clearWorkspaceSidebarCommandMouseUnlock(panel)
            panel.commandExpansionLocksCollapse = oldLock
            panel.inlineTextEditingLocksExpansion = oldInlineLock
            panel.shouldLockNextSidebarSearchExpansion = oldNextLock
        }
        panel.commandExpansionLocksCollapse = true
        panel.inlineTextEditingLocksExpansion = true
        panel.shouldLockNextSidebarSearchExpansion = true
        panel.commandMouseUnlockPoint = CGPoint(x: 10, y: 10)
        panel.commandMouseUnlockAfter = 100
        panel.unlockCommandSidebarExpansionIfMouseMoved(to: CGPoint(x: 20, y: 10), timestamp: 99)
        XCTAssertTrue(panel.commandExpansionLocksCollapse)
        panel.unlockCommandSidebarExpansionIfMouseMoved(to: CGPoint(x: 10.5, y: 10), timestamp: 100)
        XCTAssertTrue(panel.commandExpansionLocksCollapse)
        panel.unlockCommandSidebarExpansionIfMouseMoved(to: CGPoint(x: 20, y: 10), timestamp: 100)
        XCTAssertFalse(panel.commandExpansionLocksCollapse)
        XCTAssertFalse(panel.inlineTextEditingLocksExpansion)
        XCTAssertFalse(panel.shouldLockNextSidebarSearchExpansion)
        XCTAssertNil(panel.commandMouseUnlockPoint)
    }

    func testRapidCommandRearmingLeavesOnlyTheCurrentUnlockState() {
        let panel = WorkspaceSidebarPanel.shared
        defer { clearWorkspaceSidebarCommandMouseUnlock(panel) }
        for _ in 0 ..< 100 {
            armWorkspaceSidebarCommandMouseUnlock(panel)
            clearWorkspaceSidebarCommandMouseUnlock(panel)
        }
        XCTAssertNil(panel.commandMouseUnlockPoint)
        XCTAssertEqual(panel.commandMouseUnlockAfter, 0)
        armWorkspaceSidebarCommandMouseUnlock(panel)
        XCTAssertNotNil(panel.commandMouseUnlockPoint)
        XCTAssertGreaterThan(panel.commandMouseUnlockAfter, ProcessInfo.processInfo.systemUptime)
    }
}

@testable import AppBundle
import AppKit
import SwiftUI
import WorkspaceCore
import XCTest

@MainActor
final class WorkspaceSidebarVerticalAlignmentTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testViewRowsKeepTheirPositionsAcrossCollapseAndIntermediateWidths() async throws {
        for pinCount in [0, 5] {
            let snapshot = fixture(pinCount: pinCount)
            let expanded = try await frames(snapshot, width: 240)
            for width: CGFloat in [40, 100, 180, 240] {
                let actual = try await frames(snapshot, width: width)
                for name in ["first", "arrangement", "last", "blank"] {
                    let before = try XCTUnwrap(expanded[name])
                    let after = try XCTUnwrap(actual[name])
                    XCTAssertEqual(after.minY, before.minY, accuracy: 0.5, "\(name), \(pinCount) pins, width \(width)")
                    XCTAssertEqual(after.height, before.height, accuracy: 0.5, "\(name), width \(width)")
                }
                if pinCount > 0 {
                    XCTAssertEqual(try XCTUnwrap(actual["pins"]).height, try XCTUnwrap(expanded["pins"]).height, accuracy: 0.5)
                }
                XCTAssertEqual(try XCTUnwrap(actual["create"]).height, try XCTUnwrap(expanded["create"]).height, accuracy: 0.5)
                XCTAssertEqual(try XCTUnwrap(actual["firstViewport"]).height, try XCTUnwrap(expanded["firstViewport"]).height, accuracy: 0.5)
            }
        }
    }

    func testFilteredDisplayAndClockKeepTheSameVerticalFootprint() async throws {
        var snapshot = fixture(pinCount: 3)
        snapshot.selectedMonitorScopeId = "display"
        snapshot.configuration.showsClock = true
        snapshot.configuration.showsSeconds = true
        snapshot.configuration.showsDate = true
        snapshot.configuration.showsWeekday = true
        for menuBarStyle in [false, true] {
            snapshot.configuration.menuBarStyle = menuBarStyle
            let expanded = try await frames(snapshot, width: 240)
            let compact = try await frames(snapshot, width: 40)
            for name in ["first", "arrangement", "last"] {
                XCTAssertEqual(try XCTUnwrap(compact[name]).minY, try XCTUnwrap(expanded[name]).minY, accuracy: 0.5)
            }
            XCTAssertEqual(try XCTUnwrap(compact["firstViewport"]).height, try XCTUnwrap(expanded["firstViewport"]).height, accuracy: 0.5)
        }
    }

    private func frames(_ snapshot: WorkspaceSidebarSnapshot, width: CGFloat) async throws -> [String: CGRect] {
        var snapshot = snapshot
        snapshot.visibleWidth = width
        var result: [String: CGRect] = [:]
        let view = WorkspaceSidebarView(snapshot: snapshot, actions: .init(setDropTargets: { targets in
            for target in targets {
                switch target.kind {
                case .workspace(let name):
                    result[name] = target.frame
                    if name == "first", let clip = target.clipFrame { result["firstViewport"] = clip }
                case .newWorkspace: result["create"] = target.frame
                default: break
                }
            }
        })).transaction { $0.disablesAnimations = true }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: 800),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertNotNil(result["first"])
        return result
    }

    private func fixture(pinCount: Int) -> WorkspaceSidebarSnapshot {
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.configuration.collapsedWidth = 40
        snapshot.configuration.expandedWidth = 240
        snapshot.configuration.showsBrowserControls = true
        snapshot.configuration.chromeStyle = .solid
        snapshot.targetMonitorScopeId = "display"
        snapshot.focusedMonitorScopeId = "display"
        snapshot.projects = (0..<6).map { index in
            .init(id: index == 0 ? workspaceProjectDefaultId : WorkspaceProjectId("space-\(index)"),
                displayName: "Space \(index)", colorHex: nil)
        }
        func item(_ name: String) -> WorkspaceSidebarItemViewModel {
            .init(kind: .surface(.init(surfaceID: .nativeWindow(UUID()), title: name, appName: "Notes",
                isFocused: false, appBundleId: "com.apple.Notes")))
        }
        func workspace(_ name: String, _ items: [WorkspaceSidebarItemViewModel]) -> WorkspaceSidebarWorkspaceViewModel {
            .init(name: name, projectId: workspaceProjectDefaultId, displayName: name, sidebarLabel: "",
                isGeneratedName: true, monitorScopeId: "display", monitorName: nil, isFocused: name == "first",
                isVisible: name == "first", items: items, isViewMode: true)
        }
        var pins = workspace("pins", [])
        pins.isPinnedGroup = true
        pins.pins = (0..<pinCount).map { index in
            .init(id: UUID(), workspaceName: "pins", title: "Pin \(index)", bundleIdentifier: "com.apple.Notes",
                bundlePath: nil, iconPNGBase64: nil, surfaceID: nil, isFocused: false, isOpen: false,
                isLoading: false, isUnavailable: false, isBrowser: false)
        }
        snapshot.workspaces = [pins, workspace("first", [item("First tab")]),
            workspace("arrangement", [item("Split"), .init(kind: .surfaceGroup(UUID(), [item("One"), item("Two")]))]),
            workspace("last", [item("Last tab")]), workspace("blank", [])]
        return snapshot
    }
}

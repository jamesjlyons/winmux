@testable import AppBundle
import Foundation
import WorkspaceCore
import XCTest

final class WorkspaceSidebarSearchFeedbackTest: XCTestCase {
    func testTitleHighlightsEveryOccurrenceWithoutChangingSpelling() {
        XCTAssertEqual(highlights("Fish shell · FISH notes · fish", "fish"), ["Fish", "FISH", "fish"])
        XCTAssertEqual(highlights("Release checklist", "  release\nCHECK  "), ["Release", "check"])
        XCTAssertEqual(highlights("Release checklist", "safari"), [])
        XCTAssertEqual(highlights("Release checklist", " \n "), [])
    }

    func testOverlappingMatchesMergeAndUnicodeRangesStayInOriginalTitle() {
        XCTAssertEqual(highlights("Banana", "ana nana ana"), ["anana"])
        XCTAssertEqual(highlights("👩🏽‍💻 Cafe\u{301} notes — CAFÉ", "café"), ["Cafe\u{301}", "CAFÉ"])
        XCTAssertEqual(highlights("日本語の資料 · 日本語", "日本語"), ["日本語", "日本語"])
    }

    func testFilteringRetainsOrderContextFocusAndRestoresCompleteTree() {
        let surfaces = ["Fish shell", "Release notes", "Fish documentation"].enumerated().map { index, title in
            WorkspaceSidebarItemViewModel(kind: .surface(.init(surfaceID: .nativeWindow(UUID()), title: title,
                appName: "Terminal", isFocused: index == 1)))
        }
        let group = WorkspaceSidebarItemViewModel(kind: .surfaceGroup(UUID(), surfaces))
        let workspace = WorkspaceSidebarWorkspaceViewModel(name: "website", projectId: workspaceProjectDefaultId,
            displayName: "Website", sidebarLabel: "", isGeneratedName: false, monitorScopeId: "display",
            monitorName: nil, isFocused: true, isVisible: true, items: [group])
        let original = [workspaceProjectDefaultId: [workspace]]
        let filtered = workspaceSidebarFilteredWorkspacesByProject(original, projects: [], query: "fish")
        let result = filtered[workspaceProjectDefaultId]!.first!
        XCTAssertEqual(result.id, workspace.id)
        XCTAssertEqual(result.displayName, "Website")
        XCTAssertEqual(result.viewSurfaceCount, 3, "A filtered arrangement keeps its total count and hierarchy")
        XCTAssertFalse(result.isSingleWindowView)
        guard case .surfaceGroup(let id, let children) = result.items[0].kind,
              case .surfaceGroup(let originalID, _) = group.kind else { return XCTFail("Lost stack context") }
        XCTAssertEqual(id, originalID)
        XCTAssertEqual(children.map(\.id), [surfaces[0].id, surfaces[2].id])
        XCTAssertTrue(result.viewSurfaces.allSatisfy { !$0.isFocused }, "A match must not become the active window")
        XCTAssertTrue(workspace.viewSurfaces[1].isFocused)
        let restored = workspaceSidebarFilteredWorkspacesByProject(original, projects: [], query: "")
        XCTAssertEqual(restored[workspaceProjectDefaultId]![0].items[0].tabLayoutIdentity, group.tabLayoutIdentity)
        XCTAssertTrue(restored[workspaceProjectDefaultId]![0].viewSurfaces[1].isFocused)
        let collapsed: Set<String> = [workspace.name]
        XCTAssertTrue(workspaceSidebarPageSelectionOrder(workspaces: [workspace], allowsActivation: true,
            collapsedWorkspaceNames: collapsed).isEmpty)
        XCTAssertEqual(workspaceSidebarPageSelectionOrder(workspaces: [result], allowsActivation: true,
            collapsedWorkspaceNames: collapsed, isSearchFiltering: true),
            result.viewSurfaces.map { .surface($0.surfaceID) })
        XCTAssertTrue(workspaceSidebarPageSelectionOrder(workspaces: restored[workspaceProjectDefaultId]!,
            allowsActivation: true, collapsedWorkspaceNames: collapsed).isEmpty,
            "Clearing a filter restores the collapsed arrangement's navigation order")
    }

    func testNearbySelectionTravelsButLongAndClippedJumpsFade() {
        let viewport = CGRect(x: 0, y: 100, width: 240, height: 400)
        let first = target("a", y: 110)
        let next = target("b", y: 180)
        XCTAssertEqual(WorkspaceSidebarSelectionMotion.resolve(from: first, to: next, viewport: viewport, reduceMotion: false), .travel)
        XCTAssertEqual(WorkspaceSidebarSelectionMotion.resolve(from: first, to: target("c", y: 420), viewport: viewport, reduceMotion: false), .fade)
        XCTAssertEqual(WorkspaceSidebarSelectionMotion.resolve(from: target("a", y: 85), to: next, viewport: viewport, reduceMotion: false), .fade)
        XCTAssertEqual(WorkspaceSidebarSelectionMotion.resolve(from: target("a", y: 420), to: target("b", y: 480), viewport: viewport, reduceMotion: false), .fade)
        XCTAssertEqual(WorkspaceSidebarSelectionMotion.resolve(from: nil, to: next, viewport: viewport, reduceMotion: false), .fade)
    }

    func testLegacyStackLayoutIdentityTracksOnlyDisplayedTabs() {
        let tabs = (0..<3).map { index in
            WorkspaceSidebarWindowViewModel(windowId: UInt32(index + 1), workspaceName: "website",
                appName: "Safari", appBundleId: nil, appBundlePath: nil, title: "Tab \(index)",
                isFocused: index == 0, surfaceID: .nativeWindow(UUID()))
        }
        var group = WorkspaceSidebarTabGroupViewModel(representativeWindowId: 1, workspaceName: "website",
            title: "Website", windowCount: 3, isFocused: true, tabs: tabs)
        let complete = WorkspaceSidebarItemViewModel(kind: .tabGroup(group)).tabLayoutIdentity
        group.searchVisibleTabs = [tabs[2]]
        let filtered = WorkspaceSidebarItemViewModel(kind: .tabGroup(group)).tabLayoutIdentity
        XCTAssertNotEqual(filtered, complete, "Filtering a stack must trigger layout animation")
        XCTAssertEqual(filtered, [group.id, tabs[2].surfaceID.description])
        XCTAssertEqual(group.tabs, tabs, "Filtering must keep the complete stack available for restoration")
    }

    func testReflowAndReducedMotionNeverStartAnotherSelectionSpring() {
        let first = target("a", y: 0)
        let moved = target("a", y: 140)
        XCTAssertEqual(WorkspaceSidebarSelectionMotion.resolve(from: first, to: moved, viewport: nil, reduceMotion: false), .immediate)
        for next in [target("b", y: 40), target("b", y: 400), nil] {
            XCTAssertEqual(WorkspaceSidebarSelectionMotion.resolve(from: first, to: next, viewport: nil, reduceMotion: true), .immediate)
        }
    }

    private func highlights(_ title: String, _ query: String) -> [String] {
        workspaceSidebarSearchMatchRanges(in: title, query: query).map { String(title[$0]) }
    }

    private func target(_ id: String, y: CGFloat) -> WorkspaceSidebarSelectionTarget {
        .init(id: id, bounds: .init(x: 10, y: y, width: 220, height: 32), isFocused: true)
    }
}

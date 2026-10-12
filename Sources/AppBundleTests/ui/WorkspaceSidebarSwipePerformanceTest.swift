@testable import AppBundle
import AppKit
import SwiftUI
import WorkspaceCore
import XCTest

@MainActor
final class WorkspaceSidebarSwipePerformanceTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testCrowdedPageOnlyMountsNearbyRowsAndCanScrollToLastRow() async throws {
        let snapshot = fixture(count: 200)
        let host = NSHostingView(rootView: page(snapshot).transaction { $0.disablesAnimations = true })
        let window = makeWindow(host)
        defer { window.contentView = nil }
        try await layout(host)

        let initialRows = anchors(in: window)
        XCTAssertFalse(initialRows.isEmpty)
        XCTAssertLessThan(initialRows.count, 100, "Offscreen rows should not be mounted when a Space enters the pager")
        print("SIDEBAR_SWIPE_MOUNT_BENCHMARK total=200 mounted=\(initialRows.count)")

        let scroll = try XCTUnwrap(descendant(NSScrollView.self, in: host))
        let document = try XCTUnwrap(scroll.documentView)
        scroll.contentView.scroll(to: .init(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await layout(host)
        let lastID = snapshot.workspaces.last!.viewSurfaces[0].surfaceID
        XCTAssertTrue(anchors(in: window).contains { $0.surface?.surfaceID == lastID }, "Lazy rows must appear when scrolled into view")
    }

    func testContinuousSwipeMovesPageWithoutRebuildingItsContents() async throws {
        let position = WorkspaceSidebarProjectSwipePosition()
        let snapshot = fixture(count: 200)
        var evaluations = 0
        let content = SidebarSwipeContentProbe(onBody: { evaluations += 1 }, content: page(snapshot))
            .modifier(WorkspaceSidebarProjectSwipeOffset(position: position,
                displayIndex: 0, projectCount: 2, pageWidth: 280))
            .transaction { $0.disablesAnimations = true }
        let host = NSHostingView(rootView: content)
        let window = makeWindow(host)
        defer { window.contentView = nil }
        try await layout(host)
        let initialEvaluations = evaluations
        let first = try XCTUnwrap(anchors(in: window).first)
        let originalX = first.convert(.zero, to: host).x

        for step in 1...20 {
            position.move(to: -CGFloat(step) * 5)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
        }
        try await layout(host)
        XCTAssertEqual(first.convert(.zero, to: host).x, originalX - 100, accuracy: 0.5)
        XCTAssertEqual(evaluations, initialEvaluations, "Continuous travel must only invalidate the offset modifier")
        print("SIDEBAR_SWIPE_CONTENT_BENCHMARK updates=20 contentRebuilds=\(evaluations - initialEvaluations)")

        position.move(to: 0)
        try await layout(host)
        XCTAssertEqual(first.convert(.zero, to: host).x, originalX, accuracy: 0.5)
    }

    func testCrowdedArrangementOnlyMountsNearbyChildren() async throws {
        var snapshot = fixture(count: 200)
        var arrangement = snapshot.workspaces[0]
        arrangement.items = [.init(kind: .surfaceGroup(UUID(), snapshot.workspaces.flatMap(\.items)))]
        snapshot.workspaces = [arrangement]
        let host = NSHostingView(rootView: page(snapshot).transaction { $0.disablesAnimations = true })
        let window = makeWindow(host)
        defer { window.contentView = nil }
        try await layout(host)
        let mounted = anchors(in: window).count
        XCTAssertGreaterThan(mounted, 0)
        XCTAssertLessThan(mounted, 100, "A single large arrangement also needs lazy children")
        print("SIDEBAR_SWIPE_ARRANGEMENT_BENCHMARK total=200 mounted=\(mounted)")
    }

    func testLazySelectionSurvivesScrollingButPrunesRemovedRows() async throws {
        let order = workspaceSidebarPageSelectionOrder(workspaces: fixture(count: 200).workspaces,
            allowsActivation: true, collapsedWorkspaceNames: [])
        var context = TabSelectionContext()
        let host = NSHostingView(rootView: SidebarLazySelectionFixture(order: order, visible: Array(order.prefix(10))) { context = $0 })
        let window = makeWindow(host)
        defer { window.contentView = nil }
        try await layout(host)
        XCTAssertEqual(context.order, order)
        let model = try XCTUnwrap(context.model)
        model.state.click(order[0], order: context.order, shift: false, command: false)
        model.state.click(order[199], order: context.order, shift: true, command: false)

        host.rootView = SidebarLazySelectionFixture(order: order, visible: Array(order.suffix(10))) { context = $0 }
        try await layout(host)
        XCTAssertTrue(context.model === model)
        XCTAssertEqual(model.state.selected.count, 200, "Unmounting offscreen rows must preserve a range selection")

        let remaining = Array(order.suffix(10))
        host.rootView = SidebarLazySelectionFixture(order: remaining, visible: remaining) { context = $0 }
        try await layout(host)
        XCTAssertEqual(model.state.selected, Set(remaining))
    }

    func testCollapsedArrangementsExcludeHiddenRowsFromSelection() {
        let snapshot = fixture(count: 3)
        var arrangement = snapshot.workspaces[0]
        var floating = snapshot.workspaces[2].viewSurfaces[0]
        floating.isFloating = true
        arrangement.items += snapshot.workspaces[1].items + [.init(kind: .surface(floating))]
        let visible = workspaceSidebarPageSelectionOrder(workspaces: [arrangement], allowsActivation: true,
            collapsedWorkspaceNames: [arrangement.name])
        XCTAssertEqual(visible, [.surface(floating.surfaceID)])
        let searched = workspaceSidebarPageSelectionOrder(workspaces: [arrangement], allowsActivation: true,
            collapsedWorkspaceNames: [arrangement.name], isSearchFiltering: true)
        XCTAssertEqual(searched, arrangement.viewSurfaces.map { .surface($0.surfaceID) })
    }

    private func page(_ snapshot: WorkspaceSidebarSnapshot) -> some View {
        WorkspaceSidebarView(snapshot: snapshot)
    }

    private func makeWindow(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 280, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        return window
    }

    private func layout(_ host: NSView) async throws {
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func anchors(in window: NSWindow) -> [WorkspaceSidebarTabRowAnchorView] {
        WorkspaceSidebarTabRowAnchorView.live.allObjects.filter { $0.window === window }
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }

    private func fixture(count: Int) -> WorkspaceSidebarSnapshot {
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.visibleWidth = 280
        snapshot.configuration.collapsedWidth = 40
        snapshot.configuration.expandedWidth = 280
        snapshot.configuration.chromeStyle = .solid
        snapshot.targetMonitorScopeId = "swipe-test"
        snapshot.focusedMonitorScopeId = "swipe-test"
        snapshot.workspaces = (0..<count).map { index in
            .init(name: "row-\(index)", projectId: snapshot.activeProjectId, displayName: "Tab \(index)",
                sidebarLabel: "", isGeneratedName: true, monitorScopeId: "swipe-test", monitorName: nil,
                isFocused: index == 0, isVisible: index == 0,
                items: [.init(kind: .surface(.init(surfaceID: .nativeWindow(UUID()), title: "Tab \(index)",
                    appName: "Test", isFocused: index == 0)))])
        }
        return snapshot
    }
}

private struct SidebarSwipeContentProbe<Content: View>: View {
    let onBody: () -> Void
    let content: Content

    var body: some View {
        onBody()
        return content
    }
}

private struct SidebarLazySelectionFixture: View {
    let order: [SurfacePane]
    let visible: [SurfacePane]
    let onContext: (TabSelectionContext) -> Void

    var body: some View {
        VStack {
            ForEach(visible, id: \.self) { pane in Text("Row").tabSelectionItem(pane) }
        }
        .background(SidebarSelectionContextProbe(onContext: onContext))
        .tabSelectionRoot(scope: "lazy-test", order: order)
    }
}

private struct SidebarSelectionContextProbe: View {
    @Environment(\.tabSelection) private var selection
    let onContext: (TabSelectionContext) -> Void

    var body: some View {
        onContext(selection)
        return Color.clear
    }
}

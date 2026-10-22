@testable import AppBundle
import AppKit
import SwiftUI
import WorkspaceCore
import XCTest

/// Drives a Space swipe through the sidebar's own handlers and counts how often
/// the sidebar body is evaluated. The strip must move through the offset modifier
/// alone: locking the direction, crossing the switch threshold, releasing and the
/// settling spring may not rebuild the pages.
@MainActor
final class WorkspaceSidebarSwipeSettleTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        WorkspaceSidebarViewTestHooks.swipeDriver = nil
        WorkspaceSidebarViewTestHooks.forcesAdjacentPageMounting = nil
    }

    override func tearDown() async throws {
        WorkspaceSidebarViewTestHooks.forcesAdjacentPageMounting = nil
    }

    func testNavigatingSwipeOnlyInvalidatesTheSidebarWhenItLocksAndWhenItRetires() async throws {
        let snapshot = fixture(projects: 3, rows: 30)
        let host = NSHostingView(rootView: page(snapshot))
        let window = makeWindow(host)
        defer { window.contentView = nil }
        try await layout(host)
        let driver = try XCTUnwrap(WorkspaceSidebarViewTestHooks.swipeDriver)

        let beforeLock = WorkspaceSidebarViewTestHooks.bodyEvaluations
        driver.changed(-6, 0)
        try await layout(host)
        let afterLock = WorkspaceSidebarViewTestHooks.bodyEvaluations
        XCTAssertLessThanOrEqual(afterLock - beforeLock, 1, "Locking records the start Space once")

        for translation in stride(from: -14, through: -90, by: -8) {
            driver.changed(CGFloat(translation), 0)
            host.layoutSubtreeIfNeeded()
        }
        try await layout(host)
        XCTAssertEqual(WorkspaceSidebarViewTestHooks.bodyEvaluations, afterLock,
                       "Travel and the switch threshold must only move the offset modifier")

        driver.ended(-90, 0)
        try await layout(host)
        XCTAssertEqual(WorkspaceSidebarViewTestHooks.bodyEvaluations, afterLock,
                       "Release starts the settling spring without rebuilding the pages")

        try await Task.sleep(for: .milliseconds(550))
        try await layout(host)
        XCTAssertEqual(WorkspaceSidebarViewTestHooks.bodyEvaluations, afterLock,
                       "The outgoing page stays mounted until the selection arrives")

        var selected = snapshot
        selected.activeProjectId = snapshot.projects[2].id
        host.rootView = page(selected)
        try await layout(host)
        let retired = WorkspaceSidebarViewTestHooks.bodyEvaluations - afterLock
        XCTAssertGreaterThanOrEqual(retired, 1)
        XCTAssertLessThanOrEqual(retired, 2, "The new snapshot and the retirement are the only evaluations")
        print("SIDEBAR_SWIPE_SETTLE_BENCHMARK lock=\(afterLock - beforeLock) travelAndRelease=0 retire=\(retired)")
    }

    func testSnapBackRetiresWithASingleEvaluation() async throws {
        let snapshot = fixture(projects: 3, rows: 30)
        let host = NSHostingView(rootView: page(snapshot))
        let window = makeWindow(host)
        defer { window.contentView = nil }
        try await layout(host)
        let driver = try XCTUnwrap(WorkspaceSidebarViewTestHooks.swipeDriver)

        driver.changed(-6, 0)
        driver.changed(-20, 0)
        try await layout(host)
        let afterLock = WorkspaceSidebarViewTestHooks.bodyEvaluations
        driver.ended(-20, 0)
        try await layout(host)
        XCTAssertEqual(WorkspaceSidebarViewTestHooks.bodyEvaluations, afterLock)
        try await Task.sleep(for: .milliseconds(550))
        try await layout(host)
        XCTAssertLessThanOrEqual(WorkspaceSidebarViewTestHooks.bodyEvaluations - afterLock, 1,
                                 "Snapping back retires the gesture once, after the spring")
    }

    func testAdjacentPagesAreMountedWhilePointerRestsOverSidebar() async throws {
        let snapshot = fixture(projects: 3, rows: 30)
        let host = NSHostingView(rootView: page(snapshot))
        let window = makeWindow(host)
        defer { window.contentView = nil }
        try await layout(host)
        XCTAssertEqual(mountedProjects(in: window), ["p1"], "Away from the pointer only the displayed Space is built")

        WorkspaceSidebarViewTestHooks.forcesAdjacentPageMounting = true
        host.rootView = page(snapshot)
        try await layout(host)
        XCTAssertEqual(mountedProjects(in: window), ["p0", "p1", "p2"], "Both neighbours are built before a swipe can start")
        let mountedRows = anchors(in: window).count
        XCTAssertLessThan(mountedRows, 90, "Neighbour pages still mount only their visible rows")
        print("SIDEBAR_SWIPE_NEIGHBOUR_BENCHMARK projects=3 rowsPerProject=30 mountedRows=\(mountedRows)")

        // A swipe that locks while the neighbours are mounted builds nothing new.
        let driver = try XCTUnwrap(WorkspaceSidebarViewTestHooks.swipeDriver)
        let before = WorkspaceSidebarViewTestHooks.bodyEvaluations
        driver.changed(-6, 0)
        driver.changed(-60, 0)
        try await layout(host)
        XCTAssertLessThanOrEqual(WorkspaceSidebarViewTestHooks.bodyEvaluations - before, 1)
        XCTAssertEqual(mountedProjects(in: window), ["p0", "p1", "p2"])
    }

    func testSnapshotUpdateCostWithNeighboursMounted() async throws {
        WorkspaceSidebarViewTestHooks.forcesAdjacentPageMounting = true
        var results: [Int: Double] = [:]
        for projects in [1, 3] {
            let base = fixture(projects: projects, rows: 30)
            let host = NSHostingView(rootView: page(base))
            let window = makeWindow(host)
            defer { window.contentView = nil }
            try await layout(host)
            var samples: [Double] = []
            var updateSamples: [Double] = []
            var unchangedSamples: [Double] = []
            for step in 0 ..< 20 {
                var updated = base
                let active = updated.workspaces.firstIndex { $0.projectId == base.activeProjectId }!
                updated.workspaces[active].items = [.init(kind: .surface(.init(surfaceID: .nativeWindow(UUID()),
                    title: "Changed tab \(step)", appName: "Test", isFocused: true)))]
                let start = ProcessInfo.processInfo.systemUptime
                host.rootView = page(updated)
                let afterUpdate = ProcessInfo.processInfo.systemUptime
                host.layoutSubtreeIfNeeded()
                samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                updateSamples.append((afterUpdate - start) * 1000)
                let unchangedStart = ProcessInfo.processInfo.systemUptime
                host.rootView = page(updated)
                host.layoutSubtreeIfNeeded()
                unchangedSamples.append((ProcessInfo.processInfo.systemUptime - unchangedStart) * 1000)
            }
            results[projects] = samples.sorted()[samples.count / 2]
            print("SIDEBAR_SWIPE_UPDATE_DETAIL projects=\(projects) medianTotalMs=\(results[projects]!) medianRootUpdateMs=\(updateSamples.sorted()[10]) medianUnchangedMs=\(unchangedSamples.sorted()[10])")
        }
        print("SIDEBAR_SWIPE_UPDATE_BENCHMARK medianMs projects1=\(results[1]!) projects3=\(results[3]!)")
    }

    private func page(_ snapshot: WorkspaceSidebarSnapshot) -> some View {
        WorkspaceSidebarView(snapshot: snapshot).transaction { $0.disablesAnimations = true }
    }

    private func makeWindow(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 280, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        return window
    }

    private func layout(_ host: NSView) async throws {
        for _ in 0 ..< 4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func mountedProjects(in window: NSWindow) -> Set<Substring> {
        Set(anchors(in: window).compactMap { $0.surface?.title.split(separator: " ").first })
    }

    private func anchors(in window: NSWindow) -> [WorkspaceSidebarTabRowAnchorView] {
        WorkspaceSidebarTabRowAnchorView.live.allObjects.filter { $0.window === window }
    }

    private func fixture(projects projectCount: Int, rows: Int) -> WorkspaceSidebarSnapshot {
        var snapshot = WorkspaceSidebarSnapshot.empty
        snapshot.visibleWidth = 280
        snapshot.configuration.collapsedWidth = 40
        snapshot.configuration.expandedWidth = 280
        snapshot.configuration.chromeStyle = .solid
        snapshot.targetMonitorScopeId = "settle-test"
        snapshot.focusedMonitorScopeId = "settle-test"
        snapshot.projects = (0 ..< projectCount).map {
            WorkspaceSidebarProjectViewModel(id: WorkspaceProjectId(rawValue: "p\($0)"), displayName: "Space \($0)", colorHex: nil)
        }
        snapshot.activeProjectId = snapshot.projects[projectCount / 2].id
        snapshot.workspaces = snapshot.projects.flatMap { project in
            (0 ..< rows).map { index in
                WorkspaceSidebarWorkspaceViewModel(
                    name: "\(project.id.rawValue)-row-\(index)", projectId: project.id, displayName: "Tab \(index)",
                    sidebarLabel: "", isGeneratedName: true, monitorScopeId: "settle-test", monitorName: nil,
                    isFocused: index == 0, isVisible: index == 0,
                    items: [.init(kind: .surface(.init(surfaceID: .nativeWindow(UUID()), title: "\(project.id.rawValue) tab \(index)",
                        appName: "Test", isFocused: index == 0)))],
                )
            }
        }
        return snapshot
    }
}

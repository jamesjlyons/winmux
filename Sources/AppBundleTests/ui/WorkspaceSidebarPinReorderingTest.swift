import AppKit
@testable import AppBundle
import SwiftUI
import XCTest

final class WorkspaceSidebarPinReorderingTest: XCTestCase {
    private let ids = (0..<5).map { _ in UUID() }
    private var tiles: [WorkspaceSidebarPinReorderItem] {
        ids.enumerated().map { index, id in
            .init(id: id, frame: CGRect(x: 2 + (index % 3) * 58, y: 2 + (index / 3) * 46, width: 52, height: 40))
        }
    }
    private let shelf = CGRect(x: 0, y: 0, width: 174, height: 90)

    func testFullTileHalvesChooseBeforeAndAfter() {
        XCTAssertEqual(target(x: 80, y: 20), .init(id: ids[1], placement: .before, isVertical: false))
        XCTAssertEqual(target(x: 100, y: 20), .init(id: ids[1], placement: .after, isVertical: false))
    }

    func testGapsAndEmptyLastRowStillOfferInsertion() {
        XCTAssertEqual(target(x: 56, y: 20), .init(id: ids[0], placement: .after, isVertical: false))
        XCTAssertEqual(target(x: 58, y: 20), .init(id: ids[1], placement: .before, isVertical: false))
        XCTAssertEqual(target(x: 160, y: 60), .init(id: ids[4], placement: .after, isVertical: false))
        XCTAssertEqual(target(x: 10, y: 89), .init(id: ids[4], placement: .after, isVertical: false))
    }

    func testWrappedRowsFollowReadingOrder() {
        XCTAssertEqual(target(x: 140, y: 43), .init(id: ids[2], placement: .before, isVertical: false))
        XCTAssertEqual(target(x: 10, y: 47), .init(id: ids[3], placement: .before, isVertical: false))
        XCTAssertEqual(target(x: 10, y: 1), .init(id: ids[0], placement: .before, isVertical: false))
    }

    func testCompactSingleColumnUsesTopAndBottomHalves() {
        let items = ids.prefix(2).enumerated().map { index, id in
            WorkspaceSidebarPinReorderItem(id: id, frame: CGRect(x: 2, y: 2 + index * 46, width: 32, height: 40))
        }
        let compactShelf = CGRect(x: 0, y: 0, width: 36, height: 90)
        XCTAssertEqual(workspaceSidebarPinReorderTarget(at: CGPoint(x: 18, y: 55), items: items, shelf: compactShelf),
                       .init(id: ids[1], placement: .before, isVertical: true))
        XCTAssertEqual(workspaceSidebarPinReorderTarget(at: CGPoint(x: 18, y: 80), items: items, shelf: compactShelf),
                       .init(id: ids[1], placement: .after, isVertical: true))
    }

    func testSingleTileInWideShelfStillUsesHorizontalInsertion() {
        XCTAssertEqual(workspaceSidebarPinReorderTarget(at: CGPoint(x: 160, y: 20), items: [tiles[0]], shelf: shelf),
                       .init(id: ids[0], placement: .after, isVertical: false))
    }

    func testOnlyVisibleTilesParticipateAndOutsideDropsAreIgnored() {
        let clippedShelf = CGRect(x: 0, y: 46, width: 174, height: 44)
        XCTAssertEqual(workspaceSidebarPinReorderTarget(at: CGPoint(x: 10, y: 47), items: tiles, shelf: clippedShelf),
                       .init(id: ids[3], placement: .before, isVertical: false))
        XCTAssertNil(target(x: -1, y: 20))
        XCTAssertNil(target(x: 20, y: 91))
        XCTAssertNil(workspaceSidebarPinReorderTarget(at: CGPoint(x: 20, y: 20), items: [], shelf: shelf))
    }

    @MainActor
    func testInsertionMarkerDoesNotShiftTileHitTargets() async throws {
        var workspace = WorkspaceSidebarWorkspaceViewModel(name: "pin-proof", projectId: workspaceProjectDefaultId,
            displayName: "Pinned", sidebarLabel: "", isGeneratedName: false, monitorScopeId: "proof", monitorName: nil,
            isFocused: false, isVisible: true, items: [], isPinnedGroup: true)
        workspace.pins = ids.enumerated().map { index, id in
            .init(id: id, workspaceName: workspace.name, title: "Pin \(index + 1)", bundleIdentifier: "com.apple.Safari",
                  bundlePath: nil, iconPNGBase64: nil, surfaceID: nil, isFocused: false, isOpen: false,
                  isLoading: false, isUnavailable: false, isBrowser: index.isMultiple(of: 2))
        }
        for compact in [false, true] {
            let width: CGFloat = compact ? 36 : 174
            func grid(_ target: WorkspaceSidebarPinReorderTarget?) -> some View {
                WorkspaceSidebarPinGrid(workspace: workspace, projects: [], isCompact: compact,
                    availableWidth: width, showsDropWell: false, actions: .init(), expandedAvailableWidth: 174,
                    reorderTarget: target)
                    .frame(width: width, height: 100, alignment: .top)
                    .coordinateSpace(name: "workspaceSidebarContent")
            }
            let marker = WorkspaceSidebarPinReorderTarget(id: ids[1], placement: .after, isVertical: compact)
            let baseline = try await frames(of: grid(nil), width: width)
            let insertion = try await frames(of: grid(marker), width: width)
            XCTAssertTrue(insertion.contains { $0.kind == .pin(ids[1]) })
            XCTAssertEqual(insertion, baseline, "An insertion marker must not move the drag hit targets")

            if let directory = ProcessInfo.processInfo.environment["WINMUX_PIN_REORDER_PROOF_DIRECTORY"] {
                let output = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                for light in [true, false] {
                    let scene = grid(marker).padding(12).background(Color(nsColor: .windowBackgroundColor))
                    try renderMarketingView(scene,
                        to: output.appendingPathComponent("\(compact ? "compact" : "expanded")-\(light ? "light" : "dark").png"),
                        size: .init(width: width + 24, height: 124), colorScheme: light ? .light : .dark)
                }
            }
        }
    }

    func testCollapsedShelfCountsPinsBelowTheViewport() {
        XCTAssertEqual(workspaceSidebarHiddenPinCount(pinCount: 5, visibleRows: 2, scrolledBy: 0, rowHeight: 46), 3)
        XCTAssertEqual(workspaceSidebarHiddenPinCount(pinCount: 5, visibleRows: 2, scrolledBy: 46, rowHeight: 46), 2)
        // A sub-point scroll remainder still counts the row as passed.
        XCTAssertEqual(workspaceSidebarHiddenPinCount(pinCount: 5, visibleRows: 2, scrolledBy: 137.5, rowHeight: 46), 0)
        XCTAssertEqual(workspaceSidebarHiddenPinCount(pinCount: 2, visibleRows: 2, scrolledBy: 0, rowHeight: 46), 0)
        // Elastic overscroll above the top never inflates the count.
        XCTAssertEqual(workspaceSidebarHiddenPinCount(pinCount: 5, visibleRows: 2, scrolledBy: -20, rowHeight: 46), 3)
    }

    @MainActor
    private func frames(of view: some View, width: CGFloat) async throws -> [WorkspaceSidebarDropTargetFrame] {
        var result: [WorkspaceSidebarDropTargetFrame] = []
        let host = NSHostingView(rootView: view.onPreferenceChange(WorkspaceSidebarDropTargetPreferenceKey.self) { result = $0 })
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertFalse(result.isEmpty)
        return result
    }

    private func target(x: CGFloat, y: CGFloat) -> WorkspaceSidebarPinReorderTarget? {
        workspaceSidebarPinReorderTarget(at: CGPoint(x: x, y: y), items: tiles, shelf: shelf)
    }
}

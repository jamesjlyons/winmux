@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor
final class SurfaceClosureFocusTest: XCTestCase {
    private var controller: BrowserWorkspaceController!
    private var connection: UUID!
    private var epoch: UUID!
    private var pages: [SurfaceID] = []
    private var revision: UInt64 = 0

    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.newItemPlacement = .tile
        controller = BrowserWorkspaceController(foregroundProcessID: { -1 })
        controller.usesSurfaceTree = true
        connection = UUID(); epoch = UUID(); revision = 0
        let profile = UUID()
        pages = (0..<4).map { _ in .browserTab(profile: profile, tab: UUID()) }
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        inventory(pages)
        setOrder(pages, in: focus.workspace.name)
    }

    override func tearDown() async throws { controller.disconnected(connection) }

    func testBrowserCloseSelectsNextRowInsteadOfVisitHistoryOrEngineFallback() {
        let first = pages[0], second = pages[1], third = pages[2], adjacent = pages[3]
        for id in [second, first, third] { XCTAssertEqual(controller.select(id), .issued) }
        controller.cancelPendingBrowserFocusHold()

        inventory([first, second, adjacent], focused: adjacent)
        XCTAssertEqual(controller.focusCoordinator.target, adjacent)
        inventory([second, adjacent], focused: second)
        XCTAssertEqual(controller.focusCoordinator.target, adjacent)
    }

    func testOrdinaryBrowserCloseDoesNotReturnToPreviouslyVisitedNativeApp() {
        config.newItemPlacement = .newView
        let previous = Workspace.get(byName: "Previous app")
        let native = TestWindow.new(id: 811, parent: previous.rootTilingContainer)
        XCTAssertEqual(controller.select(native.surfaceID), .issued)
        XCTAssertEqual(controller.select(pages[0]), .issued)

        inventory(Array(pages.dropFirst()), focused: pages[1])
        XCTAssertEqual(controller.focusCoordinator.target, pages[1])
        XCTAssertNotEqual(focus.workspace, previous)
    }

    func testNativeClosureUsesOrderBeforeProvisionalFocus() {
        let nativeWorkspace = Workspace.get(byName: "Native view")
        let native = TestWindow.new(id: 812, parent: nativeWorkspace.rootTilingContainer)
        let provisional = TestWindow.new(id: 813, parent: nativeWorkspace.rootTilingContainer)
        XCTAssertEqual(controller.select(pages[2]), .issued)
        XCTAssertEqual(controller.select(native.surfaceID), .issued)
        setOrder([native.surfaceID, provisional.surfaceID], in: nativeWorkspace.name)
        let snapshot = controller.captureClosureFocus()
        // AX can report the app's own replacement before destruction is seen.
        controller.nativeSelectionChanged(provisional.surfaceID)
        native.unbindFromParent()

        XCTAssertTrue(controller.restoreFocusAfterClosing([native.surfaceID], snapshot: snapshot, workspace: nativeWorkspace))
        XCTAssertEqual(controller.focusCoordinator.target, provisional.surfaceID)
    }

    func testClosingBackgroundBrowserTabPreservesSelectionAndHistory() {
        XCTAssertEqual(controller.select(pages[1]), .issued)
        XCTAssertEqual(controller.select(pages[2]), .issued)
        inventory(Array(pages.dropFirst()))
        XCTAssertEqual(controller.focusCoordinator.target, pages[2])
        XCTAssertEqual(Array(controller.recentSelections.prefix(2)), [pages[2], pages[1]])
    }

    func testClosingBackgroundNativeWindowDoesNotRestoreAnOlderSelection() {
        let native = TestWindow.new(id: 814, parent: focus.workspace.rootTilingContainer)
        XCTAssertEqual(controller.select(native.surfaceID), .issued)
        XCTAssertEqual(controller.select(pages[1]), .issued)
        let snapshot = controller.captureClosureFocus()
        native.unbindFromParent()
        XCTAssertFalse(controller.restoreFocusAfterClosing([native.surfaceID], snapshot: snapshot, workspace: focus.workspace))
        XCTAssertEqual(controller.focusCoordinator.target, pages[1])
    }

    func testCloseRequestWaitsForRemovalAndRespectsInterveningSelection() {
        XCTAssertEqual(controller.select(pages[0]), .issued)
        XCTAssertEqual(controller.select(pages[1]), .issued)
        XCTAssertEqual(controller.close(pages[1]), .issued)
        XCTAssertEqual(controller.focusCoordinator.target, pages[1], "A close request may still be cancelled")
        XCTAssertEqual(controller.select(pages[2]), .issued)
        inventory([pages[0], pages[2], pages[3]])
        XCTAssertEqual(controller.focusCoordinator.target, pages[2])
    }

    func testNextRowSkipsMissingMinimizedAndArchivedSurfaces() {
        let native = TestWindow.new(id: 815, parent: focus.workspace.rootTilingContainer)
        let hidden = TestWindow.new(id: 816, parent: focus.workspace.rootTilingContainer)
        let archived = Workspace.get(byName: "Archived")
        let archivedWindow = TestWindow.new(id: 817, parent: archived.rootTilingContainer)
        for id in [pages[0], native.surfaceID, hidden.surfaceID, archivedWindow.surfaceID, pages[1]] {
            XCTAssertEqual(controller.select(id), .issued)
        }
        setOrder([pages[1], native.surfaceID, hidden.surfaceID, pages[0], pages[2], pages[3]], in: controller.workspaceName(for: pages[1])!)
        setOrder([archivedWindow.surfaceID], in: archived.name)
        native.unbindFromParent()
        hidden.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
        archived.lifecycle = .archived
        inventory([pages[0], pages[2], pages[3]])
        XCTAssertEqual(controller.focusCoordinator.target, pages[0])
    }

    func testBatchRemovalSkipsEveryClosedTabAndLastCloseClearsTarget() {
        for id in pages { XCTAssertEqual(controller.select(id), .issued) }
        inventory([pages[0]])
        XCTAssertEqual(controller.focusCoordinator.target, pages[0])
        inventory([])
        XCTAssertNil(controller.focusCoordinator.target)
        XCTAssertTrue(controller.recentSelections.isEmpty)
    }

    func testClosingChildReturnsToActualOpenerDespiteInterveningVisits() {
        controller.tabOpeners[pages[2]] = pages[0]
        for id in [pages[0], pages[1], pages[2]] { XCTAssertEqual(controller.select(id), .issued) }
        inventory([pages[0], pages[1], pages[3]], focused: pages[3])
        XCTAssertEqual(controller.focusCoordinator.target, pages[0])
        XCTAssertNil(controller.tabOpeners[pages[2]])
    }

    func testInventoryOpenerReturnsToSourceAcrossViews() {
        let sourceWorkspace = Workspace.get(byName: "Source")
        controller.placements[pages[0]] = sourceWorkspace.name
        controller.reconcileSharedOrganization()
        inventory(pages, openers: [pages[2]: pages[0]])
        for id in [pages[0], pages[1], pages[2]] { XCTAssertEqual(controller.select(id), .issued) }
        inventory([pages[0], pages[1], pages[3]])
        XCTAssertEqual(controller.focusCoordinator.target, pages[0])
        XCTAssertEqual(focus.workspace, sourceWorkspace)
    }

    func testMissingOpenerFallsBackToNextRow() {
        controller.tabOpeners[pages[1]] = pages[0]
        XCTAssertEqual(controller.select(pages[1]), .issued)
        inventory([pages[2], pages[3]])
        XCTAssertEqual(controller.focusCoordinator.target, pages[2])
        XCTAssertTrue(controller.tabOpeners.isEmpty)
    }

    func testOpenerInAnotherSpaceCannotWinOverNextRow() {
        let current = focus.workspace
        let other = createBlankWorkspace(projectId: createWorkspaceProject().id, monitor: mainMonitor)
        controller.placements[pages[0]] = other.name
        controller.reconcileSharedOrganization()
        controller.tabOpeners[pages[1]] = pages[0]
        XCTAssertEqual(controller.select(pages[1]), .issued)

        inventory([pages[0], pages[2], pages[3]], focused: pages[0])

        XCTAssertEqual(controller.focusCoordinator.target, pages[2])
        XCTAssertEqual(focus.workspace.projectId, current.projectId)
        // A later owner report of its fallback must not undo our replacement.
        controller.cancelPendingBrowserFocusHold()
        inventory([pages[0], pages[2], pages[3]], focused: pages[0])
        XCTAssertEqual(focus.workspace.projectId, current.projectId)
    }

    func testCandidateMovedToAnotherSpaceAfterSnapshotIsSkipped() {
        XCTAssertEqual(controller.select(pages[1]), .issued)
        let current = focus.workspace
        let snapshot = controller.captureClosureFocus()
        let other = createBlankWorkspace(projectId: createWorkspaceProject().id, monitor: mainMonitor)
        controller.placements[pages[2]] = other.name
        controller.reconcileSharedOrganization()

        XCTAssertTrue(controller.restoreFocusAfterClosing([pages[1]], snapshot: snapshot, workspace: current))
        XCTAssertEqual(controller.focusCoordinator.target, pages[3])
        XCTAssertEqual(focus.workspace.projectId, current.projectId)
    }

    func testDelayedClosureSnapshotCannotUndoExplicitSpaceSwitch() {
        XCTAssertEqual(controller.select(pages[1]), .issued)
        let current = focus.workspace
        let snapshot = controller.captureClosureFocus()
        let other = createBlankWorkspace(projectId: createWorkspaceProject().id, monitor: mainMonitor)
        controller.placements[pages[3]] = other.name
        controller.reconcileSharedOrganization()
        XCTAssertEqual(controller.select(pages[3]), .issued)

        XCTAssertFalse(controller.restoreFocusAfterClosing([pages[1]], snapshot: snapshot, workspace: current))
        XCTAssertEqual(controller.focusCoordinator.target, pages[3])
        XCTAssertEqual(focus.workspace.projectId, other.projectId)
    }

    func testToolbarMinimizeWaitsForInventoryThenSelectsSameSpaceNeighbor() {
        let current = focus.workspace
        let other = createBlankWorkspace(projectId: createWorkspaceProject().id, monitor: mainMonitor)
        controller.placements[pages[0]] = other.name
        controller.reconcileSharedOrganization()
        controller.tabOpeners[pages[1]] = pages[0]
        XCTAssertEqual(controller.select(pages[1]), .issued)
        controller.performToolbarAction(.minimize, for: pages[1])
        XCTAssertNil(controller.focusCoordinator.target)

        inventory(pages, focused: pages[0], minimized: [pages[1]])

        XCTAssertEqual(controller.focusCoordinator.target, pages[2])
        XCTAssertEqual(focus.workspace.projectId, current.projectId)
        XCTAssertEqual(controller.tabOpeners[pages[1]], pages[0], "Minimization preserves opener metadata")
        XCTAssertNotNil(controller.workspaceName(for: pages[1]))
    }

    func testExternalMinimizeSelectsNeighborAndBackgroundMinimizeKeepsFocus() {
        XCTAssertEqual(controller.select(pages[1]), .issued)
        inventory(pages, focused: pages[3], minimized: [pages[1]])
        XCTAssertEqual(controller.focusCoordinator.target, pages[2])
        inventory(pages, minimized: [pages[0], pages[1]])
        XCTAssertEqual(controller.focusCoordinator.target, pages[2])
    }

    func testPendingMinimizeDoesNotReplaceNewerSelection() {
        XCTAssertEqual(controller.select(pages[1]), .issued)
        controller.performToolbarAction(.minimize, for: pages[1])
        let other = createBlankWorkspace(projectId: createWorkspaceProject().id, monitor: mainMonitor)
        controller.placements[pages[3]] = other.name
        controller.reconcileSharedOrganization()
        XCTAssertEqual(controller.select(pages[3]), .issued)

        inventory(pages, minimized: [pages[1]])

        XCTAssertEqual(controller.focusCoordinator.target, pages[3])
        XCTAssertEqual(focus.workspace.projectId, other.projectId)
        XCTAssertNil(controller.pendingMinimizeFocus)
    }

    func testMinimizingOnlyItemKeepsSpaceEmptyWithoutReturningToOpener() {
        inventory([pages[0], pages[1]])
        let current = focus.workspace
        let other = createBlankWorkspace(projectId: createWorkspaceProject().id, monitor: mainMonitor)
        controller.placements[pages[0]] = other.name
        controller.reconcileSharedOrganization()
        controller.tabOpeners[pages[1]] = pages[0]
        XCTAssertEqual(controller.select(pages[1]), .issued)
        inventory([pages[0], pages[1]], focused: pages[0], minimized: [pages[1]])

        XCTAssertNil(controller.focusCoordinator.target)
        XCTAssertEqual(focus.workspace.projectId, current.projectId)
    }

    func testBottomRowSelectsNearestSurvivingRowAbove() {
        for id in [pages[2], pages[0], pages[3]] { XCTAssertEqual(controller.select(id), .issued) }
        inventory(Array(pages.dropLast()))
        XCTAssertEqual(controller.focusCoordinator.target, pages[2])
    }

    func testBatchRemovalSelectsFirstSurvivingRowBelow() {
        XCTAssertEqual(controller.select(pages[1]), .issued)
        inventory([pages[0], pages[3]])
        XCTAssertEqual(controller.focusCoordinator.target, pages[3])
    }

    func testOrdinaryCloseContinuesIntoNextViewBelow() {
        let next = Workspace.get(byName: "Next view")
        controller.placements[pages[2]] = next.name
        controller.placements[pages[3]] = next.name
        controller.reconcileSharedOrganization()
        setOrder([pages[2], pages[3]], in: next.name)
        for id in [pages[0], pages[3], pages[1]] { XCTAssertEqual(controller.select(id), .issued) }
        inventory([pages[0], pages[2], pages[3]])
        XCTAssertEqual(controller.focusCoordinator.target, pages[2])
        XCTAssertEqual(focus.workspace, next)
    }

    func testOrdinaryCloseUsesReorderedRows() {
        setOrder([pages[2], pages[0], pages[3], pages[1]], in: focus.workspace.name)
        for id in [pages[2], pages[1], pages[0]] { XCTAssertEqual(controller.select(id), .issued) }
        inventory([pages[1], pages[2], pages[3]])
        XCTAssertEqual(controller.focusCoordinator.target, pages[3])
    }

    private func setOrder(_ ids: [SurfaceID], in workspace: String) {
        controller.surfaceTree.reconcile(ids, in: workspace)
        for id in ids { XCTAssertTrue(controller.surfaceTree.moveToRoot(id, in: workspace)) }
    }

    private func inventory(_ ids: [SurfaceID], focused: SurfaceID? = nil, openers: [SurfaceID: SurfaceID] = [:], minimized: Set<SurfaceID> = []) {
        revision += 1
        controller.received(.init(revision: revision, full: true, tabs: ids.map {
            var record = BrowserTabRecord(surfaceID: $0, hostID: $0.description, title: "Page", selected: true,
                                          hostMinimized: minimized.contains($0), focused: $0 == focused)
            record.openerSurfaceID = openers[$0]
            return record
        }), epoch: epoch, connection: connection, protocolVersion: 4)
    }
}

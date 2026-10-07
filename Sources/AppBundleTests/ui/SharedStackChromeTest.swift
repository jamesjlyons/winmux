@testable import AppBundle
import AppKit
import WorkspaceCore
import XCTest

@MainActor final class SharedStackChromeTest: XCTestCase {
    let controller = BrowserWorkspaceController.shared
    var connection = UUID()
    var page = SurfaceID.browserTab(profile: UUID(), tab: UUID())
    var group = UUID()
    var first: TestWindow!
    var second: TestWindow!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 1600, height: 1000)
        let monitor = TestMonitor(monitorAppKitNsScreenScreensId: 1, name: "Main", rect: rect, visibleRect: rect, isMain: true)
        setMonitorsForTests([monitor])
        XCTAssertTrue(monitor.setActiveWorkspace(focus.workspace))
        config.windowTabs.enabled = true
        connection = UUID(); page = .browserTab(profile: UUID(), tab: UUID()); group = UUID()
        let root = focus.workspace.rootTilingContainer
        root.layout = .tabGroup
        first = TestWindow.new(id: 7101, parent: root)
        second = TestWindow.new(id: 7102, parent: root)
        var tree = SurfaceTree(); tree.reconcile([first.surfaceID, page, second.surfaceID], in: focus.workspace.name)
        XCTAssertTrue(tree.importOrganization([.group(group, [.surface(first.surfaceID), .surface(page)]), .surface(second.surfaceID)],
            in: focus.workspace.name, layouts: [group: .stack], activeSurfaces: [group: page], weights: [:]))
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [focus.workspace.name], selected: nil, closedBrowserTabs: []))
        controller.connected(connection, processID: -1) { _, reply in reply(.issued) }
        controller.received(.init(revision: 1, full: true, tabs: [.init(surfaceID: page, hostID: "stack-page",
            title: "Reference page", selected: true, hostWindowID: 98001, hostManaged: true)]),
            epoch: UUID(), connection: connection, protocolVersion: 4)
        XCTAssertEqual(controller.select(page), .issued)
    }

    override func tearDown() async throws {
        WindowTabStripPanelController.shared.hideAll()
        controller.disconnected(connection)
        controller.nativeSelectionChanged(nil)
        controller.restorePlacementSnapshot(.init(tree: .init(), layoutWorkspaces: [], selected: nil, closedBrowserTabs: []))
        controller.usesSurfaceTree = false
    }

    func testProjectionUsesSharedStackAndRealHostOrderingWithoutChangingEitherTree() async throws {
        let tree = controller.surfaceTree, root = focus.workspace.rootTilingContainer
        let nativeOrder = root.children.map(ObjectIdentifier.init)
        let strips = await buildWindowTabStripViewModelsFromChromeItems()
        XCTAssertEqual(strips.count, 1)
        let strip = try XCTUnwrap(strips.first)
        XCTAssertEqual(strip.id, .shared(group))
        XCTAssertEqual(strip.activeWindowId, 98001)
        XCTAssertNil(Window.get(byId: 98001))
        let stack = try XCTUnwrap(strip.sharedStack)
        XCTAssertEqual(stack.tabs.map(\.id), [.surface(first.surfaceID), .surface(page)])
        XCTAssertEqual(stack.tabs.first(where: \.isActive)?.title, "Reference page")
        XCTAssertEqual(stack.tabs.filter(\.isFocused).map(\.surface), [page])
        XCTAssertEqual(strip.frame.height, resolvedWindowTabBarHeight())
        let native = try XCTUnwrap(controller.plannedSurfaces(in: focus.workspace).first { $0.surfaceID == first.surfaceID })
        XCTAssertEqual(CGFloat(native.frame.y), mainMonitor.height - strip.frame.minY)
        XCTAssertEqual(CGFloat(native.frame.x), strip.groupFrame.minX + windowTabGroupShellHorizontalInset())
        XCTAssertEqual(controller.surfaceTree, tree)
        XCTAssertEqual(root.children.map(ObjectIdentifier.init), nativeOrder)
        let repeated = await buildWindowTabStripViewModelsFromChromeItems()
        XCTAssertEqual(repeated, strips)
        XCTAssertEqual(controller.surfaceTree, tree)
    }

    func testSelectionReorderAndDetachChangeSharedModelAndRetainNativeBindings() async throws {
        let root = first.parent
        XCTAssertEqual(controller.select(first.surfaceID), .issued)
        XCTAssertTrue(reorderSharedStackTab(.surface(page), stack: group, to: 0))
        let strips = await buildSharedStackChrome()
        let stack = try XCTUnwrap(strips.first?.sharedStack)
        XCTAssertEqual(stack.tabs.map(\.surface), [page, first.surfaceID])
        XCTAssertEqual(stack.tabs.first(where: \.isActive)?.surface, first.surfaceID)
        XCTAssertEqual(controller.surfaceTree.activeSurfaces[group], first.surfaceID)
        XCTAssertTrue(first.parent === root && second.parent === root)
        XCTAssertTrue(separateSharedStackTab(.surface(page)))
        XCTAssertNil(controller.surfaceTree.group(group))
        let remaining = await buildSharedStackChrome()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(Set(controller.surfaceTree.roots[focus.workspace.name]?.flatMap(\.surfaces) ?? []),
                       [first.surfaceID, second.surfaceID, page])
    }

    func testDisabledTabsAndHiddenWorkspaceHaveNoStripOrReservedHeader() async throws {
        let workspace = focus.workspace
        let stackFrame = try XCTUnwrap(controller.plannedLayout(in: workspace).frames[.group(group)])
        config.windowTabs.enabled = false
        let disabled = await buildSharedStackChrome()
        XCTAssertTrue(disabled.isEmpty)
        XCTAssertTrue(controller.plannedLayout(in: workspace).stacks.isEmpty)
        XCTAssertEqual(controller.plannedSurfaces(in: workspace).first?.frame, stackFrame)
        config.windowTabs.enabled = true
        XCTAssertTrue(Workspace.get(byName: "hidden-stack").focusWorkspace())
        let hidden = await buildSharedStackChrome()
        XCTAssertTrue(hidden.isEmpty)
        XCTAssertTrue(controller.plannedLayout(in: workspace).stacks.allSatisfy { !$0.visible })
    }

    func testNestedArrangementIsOneTabAndPanelRetainsSharedIdentity() async throws {
        let split = UUID()
        XCTAssertTrue(controller.editOrganization(in: [focus.workspace.name]) {
            $0.arrange([.group(group, [.surface(page), .group(split, [.surface(first.surfaceID), .surface(second.surfaceID)])])],
                in: focus.workspace.name, layouts: [group: .stack, split: .horizontal],
                activeSurfaces: [group: first.surfaceID, split: first.surfaceID], weights: [:])
        })
        XCTAssertEqual(controller.select(first.surfaceID), .issued)
        let strips = await buildSharedStackChrome()
        let stack = try XCTUnwrap(strips.first?.sharedStack)
        XCTAssertEqual(stack.tabs.map(\.id), [.surface(page), .group(split)])
        XCTAssertTrue(stack.tabs[1].isActive)
        XCTAssertTrue(stack.tabs[1].title.contains("2 items"))
        let panels = WindowTabStripPanelController.shared, identity = WindowTabStripIdentity.shared(group)
        let panel = panels.stripPanel(for: identity)
        panels.removeStalePanels(activeIds: [])
        XCTAssertTrue(panels.stripPanels[identity] === panel)
        XCTAssertTrue(separateSharedStackTab(.group(split)))
        panels.removeStalePanels(activeIds: [])
        XCTAssertNil(panels.stripPanels[identity])
        XCTAssertEqual(controller.surfaceTree.group(split)?.surfaces, [first.surfaceID, second.surfaceID])
    }

    func testWholeStackDropPreservesMembersAndRejectsStaleGeometry() throws {
        let target = try XCTUnwrap(controller.plannedSurfaces(in: focus.workspace).first { $0.surfaceID == second.surfaceID })
        let rect = Rect(topLeftX: CGFloat(target.frame.x), topLeftY: CGFloat(target.frame.y),
                        width: CGFloat(target.frame.width), height: CGFloat(target.frame.height))
        let zone = try XCTUnwrap(WindowIntentZoneBuilder.zones(in: rect).first { $0.zone == .bottom })
        let drop = try XCTUnwrap(resolveSharedStackDrop(.group(group), pointer: zone.frame.center))
        let members = controller.surfaceTree.group(group)
        XCTAssertTrue(commitSharedStackDrop(drop, pointer: zone.frame.center))
        XCTAssertEqual(controller.surfaceTree.group(group), members)
        XCTAssertEqual(controller.surfaceTree.activeSurfaces[group], page)
        let after = controller.surfaceTree
        XCTAssertFalse(commitSharedStackDrop(drop, pointer: zone.frame.center))
        XCTAssertEqual(controller.surfaceTree, after)
    }

    func testUnavailableOwnerCannotReorderOrDetachButOtherTabsStayUsable() async throws {
        controller.disconnected(connection)
        let before = controller.surfaceTree
        XCTAssertFalse(reorderSharedStackTab(.surface(page), stack: group, to: 0))
        XCTAssertFalse(separateSharedStackTab(.surface(page)))
        let strips = await buildSharedStackChrome()
        let stack = try XCTUnwrap(strips.first?.sharedStack)
        XCTAssertEqual(stack.tabs.count, 2)
        XCTAssertFalse(try XCTUnwrap(stack.tabs.first { $0.surface == page }).isAvailable)
        XCTAssertTrue(try XCTUnwrap(stack.tabs.first { $0.surface == first.surfaceID }).isAvailable)
        XCTAssertEqual(controller.surfaceTree, before)
    }

    func testTemporaryNativeAbsenceCollapsesOnlyProjectionAndReturnsSameHeader() async throws {
        let before = controller.surfaceTree
        first.nativeIsMacosMinimized = true
        // Native observations enter the shared projection through the cached
        // state, the same boundary used by refresh sessions.
        first.recordObservedNativeState(fullscreen: false, minimized: true, token: first.nativeStateObservationToken())
        let hidden = await buildSharedStackChrome()
        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(controller.surfaceTree, before)
        first.nativeIsMacosMinimized = false
        first.recordObservedNativeState(fullscreen: false, minimized: false, token: first.nativeStateObservationToken())
        let restored = await buildSharedStackChrome()
        XCTAssertEqual(restored.first?.id, .shared(group))
        XCTAssertEqual(controller.surfaceTree, before)
    }

    func testNoAvailableOwnerDoesNotLeaveAnOrphanedStrip() async {
        controller.disconnected(connection)
        Window.resetSurfaceRegistryForTests()
        let strips = await buildSharedStackChrome()
        XCTAssertTrue(strips.isEmpty)
    }

    func testMidGestureLayoutChangeCannotRestartDragAgainstNewArrangement() {
        let drag = SharedStackDragController.shared
        drag.update(.surface(page), selecting: page)
        XCTAssertTrue(reorderSharedStackTab(.surface(page), stack: group, to: 0))
        let after = controller.surfaceTree
        drag.update(.surface(page), selecting: page)
        drag.update(.surface(page), selecting: page)
        drag.finish()
        XCTAssertEqual(controller.surfaceTree, after)
        XCTAssertNil(drag.pane)
    }

    func testReorderRejectsAChangedTabOrder() {
        let oldOrder: [SurfacePane] = [.surface(first.surfaceID), .surface(page)]
        XCTAssertTrue(reorderSharedStackTab(.surface(page), stack: group, to: 0, expectedOrder: oldOrder))
        let changed = controller.surfaceTree
        XCTAssertFalse(reorderSharedStackTab(.surface(first.surfaceID), stack: group, to: 0, expectedOrder: oldOrder))
        XCTAssertEqual(controller.surfaceTree, changed)
    }

    func testStackGestureExposesTypedSidebarSubjectAndReleasesExpansionLock() {
        let drag = SharedStackDragController.shared
        let pointer = CGPoint(x: -10000, y: -10000)
        resetWorkspaceSidebarItemDrag()
        drag.update(.group(group), selecting: page, at: pointer)
        XCTAssertEqual(currentWorkspaceSidebarSurfaceDragSubject(), .group(group))
        XCTAssertTrue(isWorkspaceSidebarItemDragActive())
        XCTAssertEqual(getCurrentMouseManipulationKind(), .none)
        drag.notePointerEvent(type: .rightMouseDown, at: pointer)
        XCTAssertNil(currentWorkspaceSidebarSurfaceDragSubject())
        XCTAssertFalse(isWorkspaceSidebarItemDragActive())
        XCTAssertNil(TrayMenuModel.shared.workspaceSidebarDropPreview)
    }

    func testGlobalMouseReleaseCommitsCompleteStackWhenSwiftUIGestureEndsOutsidePanel() throws {
        let placement = try XCTUnwrap(controller.plannedSurfaces(in: focus.workspace).first { $0.surfaceID == second.surfaceID })
        let rect = Rect(topLeftX: CGFloat(placement.frame.x), topLeftY: CGFloat(placement.frame.y),
                        width: CGFloat(placement.frame.width), height: CGFloat(placement.frame.height))
        let pointer = try XCTUnwrap(WindowIntentZoneBuilder.zones(in: rect).first { $0.zone == .bottom }).frame.center
        let before = controller.surfaceTree
        let drag = SharedStackDragController.shared
        drag.update(.group(group), selecting: page, at: pointer)
        drag.notePointerEvent(type: .leftMouseUp, at: pointer)
        XCTAssertNil(drag.pane)
        XCTAssertFalse(isWorkspaceSidebarItemDragActive())
        XCTAssertNotEqual(controller.surfaceTree, before)
        XCTAssertEqual(controller.surfaceTree.group(group), before.group(group))
        XCTAssertEqual(controller.focusCoordinator.target, page)
        let committed = controller.surfaceTree
        drag.finish(at: pointer)
        XCTAssertEqual(controller.surfaceTree, committed, "The delayed SwiftUI callback must not commit twice")
    }

    func testNativeOrBrowserFrameDropRecognizesSharedStackHeader() throws {
        let header = try XCTUnwrap(controller.plannedLayout(in: focus.workspace).stacks.first?.headerFrame)
        let point = CGPoint(x: header.x + header.width / 2, y: header.y + header.height / 2)
        let drop = try XCTUnwrap(resolveBrowserSurfaceDrop(source: second.surfaceID, pointer: point))
        XCTAssertEqual(drop.targetStack, group)
        XCTAssertEqual(drop.zone, .tab)
        XCTAssertTrue(commitBrowserSurfaceDrop(drop))
        XCTAssertEqual(controller.surfaceTree.group(group)?.surfaces, [first.surfaceID, page, second.surfaceID])
        XCTAssertEqual(controller.surfaceTree.activeSurfaces[group], second.surfaceID)
    }

    func testWholeArrangementDropOntoHeaderJoinsItsExistingStack() throws {
        let third = TestWindow.new(id: 7103, parent: focus.workspace.rootTilingContainer)
        controller.reconcileSharedOrganization()
        XCTAssertTrue(controller.editOrganization(of: third.surfaceID) { $0.group(third.surfaceID, with: second.surfaceID) })
        let target = try XCTUnwrap(controller.surfaceTree.stack(containing: second.surfaceID))
        let header = try XCTUnwrap(controller.plannedLayout(in: focus.workspace).stacks.first { $0.groupID == target }?.headerFrame)
        let point = CGPoint(x: header.x + header.width / 2, y: header.y + header.height / 2)
        let before = controller.surfaceTree.group(group)
        let drop = try XCTUnwrap(resolveSharedStackDrop(.group(group), pointer: point))
        XCTAssertEqual(drop.destination.targetStack, target)
        XCTAssertTrue(commitSharedStackDrop(drop, pointer: point))
        XCTAssertEqual(controller.surfaceTree.group(group), before)
        XCTAssertEqual(controller.surfaceTree.group(target)?.surfaces, [second.surfaceID, third.surfaceID, first.surfaceID, page])
    }

    func testOuterHeaderDoesNotInsertIntoItsSelectedNestedStack() throws {
        let outer = UUID()
        let third = TestWindow.new(id: 7103, parent: focus.workspace.rootTilingContainer)
        controller.reconcileSharedOrganization()
        let inner = try XCTUnwrap(controller.surfaceTree.group(group))
        XCTAssertTrue(controller.editOrganization(in: [focus.workspace.name]) {
            $0.arrange([.group(outer, [inner, .surface(second.surfaceID)])], in: focus.workspace.name,
                layouts: [outer: .stack], activeSurfaces: [outer: page], weights: [:])
        })
        let header = try XCTUnwrap(controller.plannedLayout(in: focus.workspace).stacks.first { $0.groupID == outer }?.headerFrame)
        let point = CGPoint(x: header.x + header.width / 2, y: header.y + header.height / 2)
        let drop = try XCTUnwrap(resolveBrowserSurfaceDrop(source: third.surfaceID, pointer: point))
        XCTAssertEqual(drop.targetStack, outer)
        XCTAssertTrue(commitBrowserSurfaceDrop(drop))
        XCTAssertEqual(controller.surfaceTree.group(group), inner)
        XCTAssertEqual(controller.surfaceTree.group(outer), .group(outer, [inner, .surface(second.surfaceID), .surface(third.surfaceID)]))
    }
}

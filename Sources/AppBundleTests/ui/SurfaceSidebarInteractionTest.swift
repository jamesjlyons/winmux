@testable import AppBundle
import SwiftUI
import WorkspaceCore
import XCTest

@MainActor
final class SurfaceSidebarInteractionTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testMoveMenusKeepNativeAndBrowserOwnerIdentitiesAndTargetScope() {
        let native = SurfaceID.nativeWindow(UUID())
        let browser = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var sent: [WorkspaceSidebarAction] = []
        let actions = WorkspaceSidebarActions(send: { sent.append($0) })
        for id in [native, browser] {
            let menu = SurfaceMoveMenu(subject: .surface(id), workspaceName: "source",
                                       targetMonitorScopeId: "display-two", actions: actions)
            menu.move(to: "source")
            menu.move(to: "destination")
            menu.moveToNewGroup(in: "research")
        }
        XCTAssertEqual(sent, [
            .moveSurface(native, toWorkspace: "destination"),
            .moveSurfaceToNewWorkspace(native, projectId: "research", monitorScopeId: "display-two"),
            .moveSurface(browser, toWorkspace: "destination"),
            .moveSurfaceToNewWorkspace(browser, projectId: "research", monitorScopeId: "display-two"),
        ])
    }

    func testStackMenuMovesWholeSubtreeRatherThanItsRepresentative() {
        let group = UUID()
        var sent: [WorkspaceSidebarAction] = []
        let menu = SurfaceMoveMenu(subject: .group(group), workspaceName: "source",
            targetMonitorScopeId: "display-two", actions: .init(send: { sent.append($0) }))
        menu.move(to: "source")
        menu.move(to: "destination")
        menu.moveToNewGroup(in: "research")
        XCTAssertEqual(sent, [
            .moveSurfaceGroup(group, toWorkspace: "destination"),
            .moveSurfaceGroupToNewWorkspace(group, projectId: "research", monitorScopeId: "display-two"),
        ])
    }

    func testSharedActivationHonorsEditingDragAndOtherDisplayGuards() {
        let id = SurfaceID.browserTab(profile: UUID(), tab: UUID())
        var sent: [WorkspaceSidebarAction] = []
        var override: String? = nil
        let binding = Binding<String?>(get: { override }, set: { override = $0 })
        let actions = WorkspaceSidebarActions(send: { sent.append($0) })
        section(actions: actions, override: binding, allowsActivation: false).activateSharedSurface(id)
        section(actions: actions, override: binding, editingName: "editing").activateSharedSurface(id)
        beginWorkspaceSidebarItemDrag()
        section(actions: actions, override: binding).activateSharedSurface(id)
        endWorkspaceSidebarItemDrag()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertNil(override)

        section(actions: actions, override: binding, inUseElsewhere: true).activateSharedSurface(id)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(override, "source")
        section(actions: actions, override: binding).activateSharedSurface(id)
        XCTAssertNil(override)
        XCTAssertEqual(sent, [.selectSurface(id)])
    }

    func testSharedStackIconMetadataPreservesNestedOwnerOrder() {
        let native = WorkspaceSidebarSurfaceItem(surfaceID: .nativeWindow(UUID()), title: "Editor", appName: "Editor",
            isFocused: false, appBundleId: "test.editor", appBundlePath: "/Applications/Test Editor.app")
        let browser = WorkspaceSidebarSurfaceItem(surfaceID: .browserTab(profile: UUID(), tab: UUID()), title: "Reference",
            appName: "WinMux Browser", isFocused: true, appBundleId: "com.jameslyons.winmux.browser.alpha")
        let item = WorkspaceSidebarItemViewModel(kind: .surfaceGroup(UUID(), [
            .init(kind: .surface(native)),
            .init(kind: .surfaceGroup(UUID(), [.init(kind: .surface(browser))])),
        ]))
        XCTAssertEqual(item.surfaceItems, [native, browser])
        XCTAssertEqual(item.surfaceItems.map(\.appBundleId), ["test.editor", "com.jameslyons.winmux.browser.alpha"])
        XCTAssertEqual(item.surfaceItems.map(\.appBundlePath), ["/Applications/Test Editor.app", nil])
        XCTAssertFalse(native.isBrowser)
        XCTAssertTrue(browser.isBrowser)
    }

    func testSearchFilteredStackRetainsFullCountIconsAndSavedRepresentative() throws {
        let id = UUID()
        let active = WorkspaceSidebarSurfaceItem(surfaceID: .browserTab(profile: UUID(), tab: UUID()),
            title: "Active reference", appName: "Browser", isFocused: false,
            appBundleId: "com.jameslyons.winmux.browser.alpha")
        let match = WorkspaceSidebarSurfaceItem(surfaceID: .nativeWindow(UUID()), title: "Search match", appName: "Editor",
            isFocused: false, appBundleId: "test.editor")
        let complete = WorkspaceSidebarItemViewModel(kind: .surfaceGroup(id, [
            .init(kind: .surface(active)), .init(kind: .surface(match)),
        ]))
        let filtered = WorkspaceSidebarItemViewModel(kind: .surfaceGroup(id, [.init(kind: .surface(match))]))
        let items = try XCTUnwrap(complete.surfaceGroup(matching: id)).surfaceItems
        XCTAssertEqual(filtered.surfaceItems.count, 1)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.appBundleId), ["com.jameslyons.winmux.browser.alpha", "test.editor"])
        XCTAssertEqual(workspaceSidebarSurfaceStackRepresentative(items, activeSurfaceID: active.surfaceID)?.surfaceID, active.surfaceID)
    }

    private func section(actions: WorkspaceSidebarActions, override: Binding<String?>,
                         allowsActivation: Bool = true, editingName: String? = nil,
                         inUseElsewhere: Bool = false) -> WorkspaceSidebarWorkspaceSection {
        WorkspaceSidebarWorkspaceSection(
            workspace: .init(name: "source", projectId: workspaceProjectDefaultId, displayName: "Source",
                sidebarLabel: "", isGeneratedName: false, monitorScopeId: workspaceSidebarDefaultScopeId,
                monitorName: nil, isFocused: true, isVisible: true, items: []),
            targetMonitorScopeId: "display-two", dragPreview: nil, expansionProgress: 1, layout: .empty,
            emitsDropTarget: false, isFromOtherDisplay: false, isInUseOnOtherDisplay: inUseElsewhere,
            isOnFocusedMonitor: true, allowsWorkspaceActivation: allowsActivation, isPinnedActiveWorkspace: false,
            isActiveOnTargetMonitor: true, projectContextLabel: nil, projectContextColor: nil,
            renamingWorkspaceName: .constant(editingName), renamingWorkspaceText: .constant(""),
            onBeginRenameWorkspace: {}, onCommitRenameWorkspace: {}, onCancelRenameWorkspace: {},
            selectedSearchTarget: nil, isSearchFiltering: false, activeInUseOverrideWorkspaceName: override,
            actions: actions
        )
    }
}

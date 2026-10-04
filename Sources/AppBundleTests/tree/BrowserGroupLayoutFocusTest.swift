@testable import AppBundle
import WorkspaceCore
import XCTest

@MainActor
final class BrowserGroupLayoutFocusTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testLateLayoutReplyCannotActivatePageFromHiddenGroup() throws {
        try checkLayoutReplyAfterGroupChange(hideSource: true)
    }

    func testLayoutReplyReaffirmsPageInVisibleGroup() throws {
        try checkLayoutReplyAfterGroupChange(hideSource: false)
    }

    private func checkLayoutReplyAfterGroupChange(hideSource: Bool) throws {
        let previousLease = BrowserNativeManagement.lease
        let previousEnabled = TrayMenuModel.shared.isEnabled
        let leasePath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        BrowserNativeManagement.lease = try NativeManagementLease(path: leasePath)
        TrayMenuModel.shared.isEnabled = true
        defer {
            BrowserNativeManagement.lease = previousLease
            TrayMenuModel.shared.isEnabled = previousEnabled
            try? FileManager.default.removeItem(atPath: leasePath)
        }

        let controller = BrowserWorkspaceController(), source = focus.workspace
        let page = SurfaceID.browserTab(profile: UUID(), tab: UUID()), connection = UUID()
        var tree = SurfaceTree(); tree.reconcile([page], in: source.name)
        controller.restorePlacementSnapshot(.init(tree: tree, layoutWorkspaces: [source.name], selected: nil, closedBrowserTabs: []))
        var actions: [BrowserSurfaceAction] = []
        var layoutReplies: [@MainActor (BrowserActionReply) -> Void] = []
        controller.connected(connection, processID: -1, sendLayout: { _, reply in layoutReplies.append(reply) }) { request, reply in
            actions.append(request.action); reply(.issued)
        }
        controller.received(.init(revision: 1, full: true, tabs: [
            .init(surfaceID: page, hostID: "layout-reply", title: "Page", selected: true),
        ]), epoch: UUID(), connection: connection, protocolVersion: 4)
        XCTAssertEqual(controller.select(page), .issued)
        controller.publishBrowserLayouts()
        XCTAssertEqual(layoutReplies.count, 1)

        if hideSource { XCTAssertTrue(Workspace.get(byName: "Destination").focusWorkspace()) }
        // This owner's selection still names its old page, as it can during an
        // asynchronous group transition. The reply must respect live visibility.
        XCTAssertEqual(controller.focusCoordinator.target, page)
        layoutReplies[0](.issued)
        XCTAssertEqual(actions.filter { $0 == .focus }.count, hideSource ? 1 : 2)
    }
}

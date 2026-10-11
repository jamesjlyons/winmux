import Foundation

/// A model built across suspension may only publish for the inputs it read.
struct ChromePublicationRevision: Equatable {
    let workspaces: [ObjectIdentifier: TreeRevisions]
    let viewports: [MonitorViewportId: WorkspaceId?]
    let monitorFrames: [Rect]
    let configuration: UInt64
    let browser: UInt64
    let browserFocus: UInt64
    let focusedWorkspace: WorkspaceId
    let focusedWindow: UInt32?
    let enabled: Bool
    let suppressed: Bool

    @MainActor init() {
        workspaces = Dictionary(uniqueKeysWithValues: Workspace.all.map { (ObjectIdentifier($0), $0.revisions) })
        viewports = winMuxWorkspaceState.monitorViewportsById.mapValues(\.activeWorkspaceId)
        monitorFrames = monitors.flatMap { [$0.rect, $0.visibleRect] }
        configuration = configurationRevision
        browser = BrowserWorkspaceController.shared.interactionRevision
        browserFocus = BrowserWorkspaceController.shared.focusCoordinator.generation
        focusedWorkspace = focus.workspace.id
        focusedWindow = focus.windowOrNil?.windowId
        enabled = TrayMenuModel.shared.isEnabled
        suppressed = shouldSuppressChromeForNativeFullscreenContent
    }
}

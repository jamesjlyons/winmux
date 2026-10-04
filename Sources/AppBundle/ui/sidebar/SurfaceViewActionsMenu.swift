import SwiftUI
import WorkspaceCore

struct SurfaceViewActionsMenu: View {
    let surface: SurfaceID
    let actions: WorkspaceSidebarActions

    private var targets: [WorkspaceSidebarSurfaceItem] {
        let controller = BrowserWorkspaceController.shared
        guard let name = controller.workspaceName(for: surface), let source = Workspace.existing(byName: name) else { return [] }
        let workspaces = TrayMenuModel.shared.workspaceSidebarWorkspaces.filter {
            $0.projectId == source.projectId && $0.isPinnedGroup == source.isPinnedGroup
        }
        return workspaces.flatMap { workspace in
            workspace.items.flatMap(\.surfaceItems) + workspace.pins.compactMap { pin in
                pin.surfaceID.map { .init(surfaceID: $0, title: pin.title, appName: pin.title,
                    isFocused: pin.isFocused, appBundleId: pin.bundleIdentifier, appBundlePath: pin.bundlePath) }
            }
        }.filter { $0.surfaceID != surface && controller.canMoveSurface($0.surfaceID) }
    }

    var body: some View {
        Menu("Combine with…") {
            ForEach(targets, id: \.surfaceID) { target in
                Menu(target.title) {
                    action("Stack", target: target.surfaceID, layout: .stack)
                    action("Split Left", target: target.surfaceID, layout: .horizontal, before: true)
                    action("Split Right", target: target.surfaceID, layout: .horizontal)
                    action("Split Above", target: target.surfaceID, layout: .vertical, before: true)
                    action("Split Below", target: target.surfaceID, layout: .vertical)
                }
            }
        }.disabled(targets.isEmpty)
        Button("Separate into Own View") { actions.send(.separateView(surface)) }
            .disabled(!BrowserWorkspaceController.shared.canSeparateView(surface))
    }

    private func action(_ title: String, target: SurfaceID, layout: SurfaceContainerLayout, before: Bool = false) -> some View {
        Button(title) { actions.send(.combineViews(surface, with: target, layout: layout, before: before)) }
    }
}

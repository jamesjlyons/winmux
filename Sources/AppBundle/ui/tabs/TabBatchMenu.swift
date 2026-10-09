import SwiftUI
import WorkspaceCore

enum TabBatchAction: Equatable {
    case group(SurfaceContainerLayout)
    case move(String)
    case newView(WorkspaceProjectId, monitorScopeID: String)
    case separate
    case close
}

struct TabBatchMenu: View {
    let panes: [SurfacePane]
    let workspaceName: String
    let monitorScopeID: String?
    let actions: WorkspaceSidebarActions

    var body: some View {
        Text("\(panes.count) Selected Tabs")
        Divider()
        Button("Group Selected Tabs") { send(.group(.stack)) }
            .disabled(!canGroupSelectedTabs(panes))
        Menu("Split Selected Tabs") {
            Button("Side by Side") { send(.group(.horizontal)) }
            Button("Above and Below") { send(.group(.vertical)) }
        }.disabled(!canGroupSelectedTabs(panes))
        Menu("Move Selected Tabs to") {
            ForEach(windowMoveMenuDestinations(sourceSpace: Workspace.existing(byName: workspaceName)?.projectId)) { space in
                Menu(space.title) {
                    ForEach(space.groups) { group in
                        Button(group.title) { send(.move(group.id)) }
                            .disabled(!canMoveSelectedTabs(panes, to: group.id))
                    }
                    Divider()
                    Button("New View") {
                        send(.newView(space.id, monitorScopeID: monitorScopeID ?? TrayMenuModel.shared.workspaceSidebarFocusedMonitorScopeId))
                    }.disabled(!canMoveSelectedTabs(panes, toProject: space.id))
                }
            }
        }
        Button("Remove Selected Tabs from Stack") { send(.separate) }
            .disabled(!canSeparateSelectedTabs(panes))
        Divider()
        Button("Close \(panes.count) Selected Tabs", role: .destructive) { send(.close) }
    }

    func send(_ action: TabBatchAction) { actions.send(.batchTabs(panes, action)) }
}

private struct TabSelectionMenu<Single: View>: ViewModifier {
    let pane: SurfacePane?
    let workspaceName: String
    let monitorScopeID: String?
    let actions: WorkspaceSidebarActions
    let single: () -> Single
    @Environment(\.tabSelection) private var selection

    func body(content: Content) -> some View {
        content.contextMenu {
            Group {
                if let pane, selection.targets(for: pane).count > 1 {
                    TabBatchMenu(panes: selection.targets(for: pane), workspaceName: workspaceName,
                        monitorScopeID: monitorScopeID, actions: actions)
                } else { single() }
            }
            .onAppear {
                if let pane { selection.model?.state.contextClick(pane, order: selection.order) }
            }
        }
    }
}

extension View {
    func tabSelectionMenu<Single: View>(for pane: SurfacePane?, workspace: String, monitor: String? = nil,
                                       actions: WorkspaceSidebarActions, @ViewBuilder single: @escaping () -> Single) -> some View {
        modifier(TabSelectionMenu(pane: pane, workspaceName: workspace, monitorScopeID: monitor, actions: actions, single: single))
    }
}

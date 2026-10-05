import SwiftUI
import WorkspaceCore

struct WorkspaceSidebarPinnedBrowserTabRow: View {
    let tab: WorkspaceSidebarPinnedBrowserTabViewModel
    let workspaceName: String
    let selectedSearchTarget: WorkspaceSidebarSearchSelection?
    let isSearchFiltering: Bool
    let actions: WorkspaceSidebarActions
    let onActivate: @MainActor (UUID) -> Void
    @State private var isHovered = false

    var body: some View {
        Button { onActivate(tab.id) } label: {
            WorkspaceSidebarWindowRow(title: tab.title, badge: nil, isFocused: tab.isFocused,
                suppressFocusedStyle: isSearchFiltering, rowHeight: workspaceSidebarWorkspaceRowHeight,
                isHovered: isHovered || selectedSearchTarget == .pinnedBrowserTab(tab.id), style: .window,
                appBundleIds: [], appBundlePaths: [], favicons: [tab.pin.iconPNGBase64], fallbackSystemImage: "pin.fill")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pinned browser tab: \(tab.title)\(tab.isOpen ? "" : ", closed")")
        .help(tab.pin.url)
        .contextMenu {
            Button("Unpin Tab") { actions.send(.unpinBrowserTab(tab.id)) }
            Menu("Move to") {
                ForEach(windowMoveMenuDestinations()) { space in
                    Menu(space.title) {
                        ForEach(space.groups) { group in
                            Button(group.title) { actions.send(.movePinnedBrowserTab(tab.id, toWorkspace: group.id)) }
                                .disabled(group.id == workspaceName)
                        }
                    }
                }
            }
            if tab.isOpen, let surfaceID = tab.pin.surfaceID {
                Divider()
                Button("Close Tab") { actions.send(.closeSurface(surfaceID)) }
            }
        }
        .onHover { isHovered = $0 }
    }
}

import SwiftUI

struct WorkspaceSidebarContextMenu: View {
    let configuration: WorkspaceSidebarConfiguration
    let actions: WorkspaceSidebarActions

    var body: some View {
        if configuration.showsBrowserControls {
            Button("New Tab") { actions.send(.newBrowserTab(workspaceName: nil)) }
            Divider()
        }
        Picker("Sidebar visibility", selection: Binding(
            get: { configuration.visibility },
            set: { actions.send(.setVisibility($0)) }
        )) {
            ForEach(WorkspaceSidebarVisibility.allCases, id: \.self) { visibility in
                Text(visibility.title).tag(visibility)
            }
        }
        .pickerStyle(.inline)
    }
}

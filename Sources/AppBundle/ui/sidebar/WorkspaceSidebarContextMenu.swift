import SwiftUI

struct WorkspaceSidebarContextMenu: View {
    let configuration: WorkspaceSidebarConfiguration
    let actions: WorkspaceSidebarActions

    var body: some View {
        Toggle("Compact Mode", isOn: Binding(
            get: { configuration.isCompactMode },
            set: { actions.send(.setCompactMode($0)) },
        ))
        Toggle("Auto-hide", isOn: Binding(
            get: { configuration.autoHide },
            set: { actions.send(.setAutoHide($0)) },
        ))
        .disabled(!configuration.isCompactMode)
    }
}

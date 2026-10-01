struct WorkspaceSidebarItemViewModel: Hashable, Identifiable {
    let kind: WorkspaceSidebarItemKind

    var id: String {
        switch kind {
            case .browserTab(let tab):
                tab.surfaceID.description
            case .window(let window):
                window.surfaceID.description
            case .tabGroup(let group):
                group.id
        }
    }
}

enum WorkspaceSidebarItemKind: Hashable {
    case browserTab(WorkspaceSidebarBrowserTabViewModel)
    case window(WorkspaceSidebarWindowViewModel)
    case tabGroup(WorkspaceSidebarTabGroupViewModel)
}

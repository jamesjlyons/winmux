import Foundation
import WorkspaceCore

struct WorkspaceSidebarItemViewModel: Hashable, Identifiable, Sendable {
    let kind: WorkspaceSidebarItemKind

    var id: String {
        switch kind {
            case .pinnedBrowserTab(let tab): "browser-pin:\(tab.id.uuidString.lowercased())"
            case .surface(let item): item.surfaceID.description
            case .surfaceGroup(let id, _): "surface-group:\(id)"
            case .browserTab(let tab):
                tab.surfaceID.description
            case .window(let window):
                window.surfaceID.description
            case .tabGroup(let group):
                group.id
        }
    }
}

indirect enum WorkspaceSidebarItemKind: Hashable, Sendable {
    case surface(WorkspaceSidebarSurfaceItem)
    case surfaceGroup(UUID, [WorkspaceSidebarItemViewModel])
    case browserTab(WorkspaceSidebarBrowserTabViewModel)
    case pinnedBrowserTab(WorkspaceSidebarPinnedBrowserTabViewModel)
    case window(WorkspaceSidebarWindowViewModel)
    case tabGroup(WorkspaceSidebarTabGroupViewModel)
}

struct WorkspaceSidebarSurfaceItem: Hashable, Sendable {
    let surfaceID: SurfaceID
    let title: String
    let appName: String
    let isFocused: Bool
    let appBundleId: String?
    let appBundlePath: String?

    init(surfaceID: SurfaceID, title: String, appName: String, isFocused: Bool,
         appBundleId: String? = nil, appBundlePath: String? = nil) {
        self.surfaceID = surfaceID
        self.title = title
        self.appName = appName
        self.isFocused = isFocused
        self.appBundleId = appBundleId
        self.appBundlePath = appBundlePath
    }

    var isBrowser: Bool {
        if case .browserTab = surfaceID { return true }
        return false
    }
}

extension WorkspaceSidebarItemViewModel {
    var surfaceIDs: [SurfaceID] {
        switch kind {
        case .pinnedBrowserTab(let tab): tab.isOpen ? tab.pin.surfaceID.map { [$0] } ?? [] : []
        case .surface(let item): [item.surfaceID]
        case .surfaceGroup(_, let children): children.flatMap(\.surfaceIDs)
        case .browserTab(let tab): [tab.surfaceID]
        case .window(let window): [window.surfaceID]
        case .tabGroup(let group): group.tabs.map(\.surfaceID)
        }
    }
}

extension WorkspaceSidebarItemViewModel {
    var surfaceItems: [WorkspaceSidebarSurfaceItem] {
        switch kind {
        case .pinnedBrowserTab: []
        case .surface(let item): [item]
        case .surfaceGroup(_, let children): children.flatMap(\.surfaceItems)
        case .browserTab(let tab):
            [.init(surfaceID: tab.surfaceID, title: tab.title, appName: "WinMux Browser", isFocused: tab.isFocused,
                   appBundleId: "com.jameslyons.winmux.browser.alpha")]
        case .window(let window):
            [.init(surfaceID: window.surfaceID, title: window.title ?? window.appName, appName: window.appName,
                   isFocused: window.isFocused, appBundleId: window.appBundleId, appBundlePath: window.appBundlePath)]
        case .tabGroup(let group):
            group.tabs.map { window in
                .init(surfaceID: window.surfaceID, title: window.title ?? window.appName, appName: window.appName,
                      isFocused: window.isFocused, appBundleId: window.appBundleId, appBundlePath: window.appBundlePath)
            }
        }
    }
}

extension WorkspaceSidebarItemViewModel {
    /// Search keeps only matching children; stack headers still describe and
    /// activate the complete saved subtree from the unfiltered snapshot.
    func surfaceGroup(matching groupId: UUID) -> WorkspaceSidebarItemViewModel? {
        guard case .surfaceGroup(let id, let children) = kind else { return nil }
        if id == groupId { return self }
        return children.lazy.compactMap { $0.surfaceGroup(matching: groupId) }.first
    }
}

func workspaceSidebarSurfaceStackRepresentative(
    _ surfaces: [WorkspaceSidebarSurfaceItem], activeSurfaceID: SurfaceID?
) -> WorkspaceSidebarSurfaceItem? {
    activeSurfaceID.flatMap { selected in surfaces.first(where: { $0.surfaceID == selected }) }
        ?? surfaces.first(where: \.isFocused) ?? surfaces.first
}

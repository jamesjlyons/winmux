import AppKit
import SwiftUI
import WorkspaceCore

/// Renders production navigation without starting a window manager or touching user windows.
@MainActor
public func renderWorkspaceTopBarProof(in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for scheme in [ColorScheme.light, .dark] {
        let suffix = scheme == .light ? "light" : "dark"
        for width: CGFloat in [1440, 900, 480, 320] {
            let snapshot = topBarProofSnapshot()
            let view = WorkspaceTopBarView(snapshot: snapshot, actions: .init())
            try renderMarketingView(view, to: directory.appendingPathComponent("top-tabs-\(Int(width))-\(suffix).png"),
                size: .init(width: width, height: workspaceTopBarHeight), colorScheme: scheme)
        }
        for query in ["", "terminal", "does not exist"] {
            let view = WorkspaceTopViewsMenu(snapshot: topBarProofSnapshot(), actions: .init(), query: query)
                .background(Color(nsColor: .windowBackgroundColor))
            try renderMarketingView(view,
                to: directory.appendingPathComponent("views-\(query.isEmpty ? "all" : query == "terminal" ? "search" : "empty")-\(suffix).png"),
                size: .init(width: 320, height: 490), colorScheme: scheme)
        }
    }
}

@MainActor
private func topBarProofSnapshot() -> WorkspaceSidebarSnapshot {
    var snapshot = MarketingFixtures.sidebarSnapshot
    snapshot.configuration.placement = .top
    snapshot.configuration.chromeStyle = .solid
    snapshot.configuration.solidChromeColor = .system
    snapshot.configuration.showsBrowserControls = true
    snapshot.projects[0] = .init(id: snapshot.activeProjectId, displayName: "Tap Five", colorHex: "#7C6CF2")
    func surface(_ title: String, app: String, bundle: String, focused: Bool = false) -> WorkspaceSidebarItemViewModel {
        .init(kind: .surface(.init(surfaceID: .nativeWindow(UUID()), title: title, appName: app,
            isFocused: focused, appBundleId: bundle)))
    }
    func view(_ name: String, _ title: String, items: [WorkspaceSidebarItemViewModel], focused: Bool = false) -> WorkspaceSidebarWorkspaceViewModel {
        .init(name: name, projectId: snapshot.activeProjectId, displayName: title, sidebarLabel: "", isGeneratedName: false,
            monitorScopeId: snapshot.targetMonitorScopeId, monitorName: nil, isFocused: focused, isVisible: focused, items: items)
    }
    var pins = view("pins", "Pinned", items: [])
    pins.isPinnedGroup = true
    pins.pins = [
        .init(id: UUID(), workspaceName: "pins", title: "Mail", bundleIdentifier: "com.apple.mail", bundlePath: nil,
            iconPNGBase64: nil, surfaceID: nil, isFocused: false, isOpen: false, isLoading: false, isUnavailable: false, isBrowser: false),
        .init(id: UUID(), workspaceName: "pins", title: "Music", bundleIdentifier: "com.apple.Music", bundlePath: nil,
            iconPNGBase64: nil, surfaceID: nil, isFocused: false, isOpen: false, isLoading: false, isUnavailable: false, isBrowser: false),
    ]
    snapshot.workspaces = [pins,
        view("notes", "Project notes", items: [surface("Project notes", app: "Notes", bundle: "com.apple.Notes")]),
        view("website", "Website reference", items: [surface("Website reference", app: "Safari", bundle: "com.apple.Safari")]),
        view("build", "WinMux", items: [surface("Implementation", app: "Xcode", bundle: "com.apple.dt.Xcode", focused: true),
            surface("Terminal", app: "Terminal", bundle: "com.apple.Terminal")], focused: true),
        view("files", "Project files", items: [surface("Project files", app: "Finder", bundle: "com.apple.finder")]),
        view("docs", "API documentation and interface references", items: [surface("API documentation", app: "Safari", bundle: "com.apple.Safari")]),
    ]
    return snapshot
}

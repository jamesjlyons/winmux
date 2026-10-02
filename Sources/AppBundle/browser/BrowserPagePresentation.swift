import AppKit
import Common
import Foundation
import WorkspaceCore

/// Each page keeps its own native host even when several pages share a WinMux
/// stack. Group membership never transfers WebContents between native windows.
@MainActor
func browserHostPlacements(_ placements: [SurfacePlacement], hasNativeToolbar: Bool) -> [BrowserHostPlacement] {
    if !hasNativeToolbar {
        // Protocol 3 peers still expose conventional Chromium controls. Preserve
        // their one-host-per-container wire contract until both sides support 4.
        let groups = Dictionary(grouping: placements) { placement -> String in
            guard case .browserTab(let profile, _) = placement.surfaceID else { return "" }
            return "\(placement.containerID):\(profile)"
        }
        return groups.keys.sorted().filter { !$0.isEmpty }.compactMap { key in
            guard let items = groups[key], let first = items.first else { return nil }
            let visible = items.first { $0.visible }
            return .init(containerID: first.containerID, surfaces: items.map(\.surfaceID),
                         selected: visible?.surfaceID, frame: first.frame, visible: visible != nil)
        }
    }
    return placements.sorted { $0.surfaceID.description < $1.surfaceID.description }.compactMap { placement in
        guard case .browserTab = placement.surfaceID else { return nil }
        var frame = placement.frame
        if hasNativeToolbar {
            let height = Int(BrowserToolbarController.height)
            guard frame.height > height else { return nil }
            frame.y += height
            frame.height -= height
        }
        return .init(containerID: placement.containerID, surfaces: [placement.surfaceID],
                     selected: placement.visible ? placement.surfaceID : nil, frame: frame, visible: placement.visible, nativeControls: true)
    }
}

/// Keep omnibox normalization separate from dispatch so arbitrary pasted text
/// never becomes an executable URL scheme.
func browserNavigationURL(_ text: String) -> String? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 8192 else { return nil }
    let allowed = Set(["https", "http", "chrome", "chrome-extension", "about", "file"])
    if let components = URLComponents(string: value), let scheme = components.scheme?.lowercased(), allowed.contains(scheme) {
        guard !["http", "https"].contains(scheme) || components.host?.isEmpty == false else { return nil }
        return components.url?.absoluteString
    }
    // Reject explicit active/custom schemes, but allow localhost:port addresses.
    let hostLike = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
    let localHost = hostLike == "localhost" || hostLike.hasPrefix("localhost:") || hostLike.hasPrefix("[")
    if !value.contains(where: { $0.isWhitespace }), localHost || hostLike.contains(".") {
        if let url = URL(string: (localHost ? "http://" : "https://") + value), url.host?.isEmpty == false {
            return url.absoluteString
        }
    }
    if let scheme = URLComponents(string: value)?.scheme, !scheme.isEmpty { return nil }
    var search = URLComponents(string: "https://www.google.com/search")!
    search.queryItems = [URLQueryItem(name: "q", value: value)]
    return search.url?.absoluteString
}

extension BrowserWorkspaceController {
    func updateBrowserToolbars(_ placements: [SurfacePlacement]) {
        guard !isUnitTest else { return }
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        let items = placements.compactMap { placement -> BrowserToolbarItem? in
            guard placement.visible, let session = owner(of: placement.surfaceID), session.supportsBrowserControls,
                  let record = session.inventory.tabs[placement.surfaceID], record.hostManaged else { return nil }
            let frame = NSRect(x: CGFloat(placement.frame.x),
                               y: screenTop - CGFloat(placement.frame.y) - BrowserToolbarController.height,
                               width: CGFloat(placement.frame.width), height: BrowserToolbarController.height)
            return BrowserToolbarItem(surfaceID: placement.surfaceID, frame: frame, url: record.url,
                                      canGoBack: record.canGoBack, canGoForward: record.canGoForward,
                                      isLoading: record.isLoading, isFocused: focusCoordinator.target == placement.surfaceID,
                                      hostWindowID: record.hostWindowID)
        }
        BrowserToolbarController.shared.update(items: items) { [weak self] id, action in
            self?.performToolbarAction(action, for: id)
        }
    }

    func performToolbarAction(_ action: BrowserToolbarAction, for id: SurfaceID) {
        if action == .focusPage { _ = select(id); return }
        if action == .close { _ = close(id); return }
        guard let session = owner(of: id), session.supportsBrowserControls else { return }
        let request: BrowserSurfaceAction
        var url: String?
        switch action {
        case .back: request = .back
        case .forward: request = .forward
        case .reload: request = .reload
        case .stop: request = .stop
        case .extensions: request = .extensions
        case .newTab: request = .newTab
        case .resize(let width, let height):
            guard let name = workspaceName(for: id), let workspace = Workspace.existing(byName: name) else { return }
            var resized = false
            if width != 0 { resized = resizeSurface(id, in: workspace, dimension: .width, amount: Double(width)) }
            if height != 0 { resized = resizeSurface(id, in: workspace, dimension: .height, amount: Double(height)) || resized }
            if !resized && (width != 0 || height != 0) {
                BrowserToolbarController.shared.showFailure(for: id, message: "This page has no resizable split in that direction.")
            }
            return
        case .resizeWidth(let delta), .resizeHeight(let delta):
            guard let name = workspaceName(for: id), let workspace = Workspace.existing(byName: name) else { return }
            let dimension: SurfaceResizeDimension = if case .resizeWidth = action { .width } else { .height }
            if !resizeSurface(id, in: workspace, dimension: dimension, amount: Double(delta)) {
                BrowserToolbarController.shared.showFailure(for: id, message: "This page has no resizable split in that direction.")
            }
            return
        case .navigate(let text):
            guard let normalized = browserNavigationURL(text) else {
                BrowserToolbarController.shared.showFailure(for: id, message: "Enter a web address or search terms.")
                return
            }
            request = .navigate
            url = normalized
        case .focusPage, .close: return
        }
        // Buttons and address submission target their own page, including a
        // visible page that was not the previously focused workspace surface.
        _ = select(id)
        if request == .newTab || request == .extensions || request == .manageExtensions {
            // These commands can create and activate a different page. Do not
            // let the source page's short focus hold override that new window.
            cancelPendingBrowserFocusHold()
        }
        _ = session.request(request, surfaceID: id, url: url) { reply in
            guard reply == .issued else {
                BrowserToolbarController.shared.showFailure(for: id, message: "Browser action could not be completed (\(reply.rawValue)).")
                return
            }
        }
    }
}


extension BrowserWorkspaceController {
    @discardableResult
    func resizeSurface(_ id: SurfaceID, in workspace: Workspace, dimension: SurfaceResizeDimension,
                       amount: Double, absolute: Bool = false) -> Bool {
        let rect = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        let frame = SurfaceFrame(x: Int(rect.topLeftX.rounded()), y: Int(rect.topLeftY.rounded()),
                                 width: Int(rect.width.rounded()), height: Int(rect.height.rounded()))
        let minima = minimumSizes(in: workspace)
        return editOrganization(of: id) {
            $0.resize(id, dimension: dimension, amount: amount, absolute: absolute, frame: frame, minimumSizes: minima)
        }
    }
}

import AppKit
import Common
import Foundation
import WorkspaceCore

/// Each page keeps its own native host even when several pages share a WinMux
/// stack. Group membership never transfers WebContents between native windows.
@MainActor
func browserHostPlacements(_ placements: [SurfacePlacement], hasNativeToolbar: Bool,
                           bodyFrameOverrides: [SurfaceID: SurfaceFrame] = [:]) -> [BrowserHostPlacement] {
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
        guard let geometry = BrowserPageChromeGeometry(frame: placement.frame) else { return nil }
        return .init(containerID: placement.containerID, surfaces: [placement.surfaceID],
                     selected: placement.visible ? placement.surfaceID : nil,
                     frame: bodyFrameOverrides[placement.surfaceID] ?? geometry.bodyFrame,
                     visible: placement.visible, nativeControls: true)
    }
}

/// Keep omnibox normalization separate from dispatch so arbitrary pasted text
/// never becomes an executable URL scheme.
func browserNavigationURL(_ text: String, allowSearch: Bool = true) -> String? {
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
    guard allowSearch else { return nil }
    var search = URLComponents(string: "https://kagi.com/search")!
    search.queryItems = [URLQueryItem(name: "q", value: value)]
    return search.url?.absoluteString
}

extension BrowserWorkspaceController {
    func updateBrowserToolbars(_ placements: [SurfacePlacement]) {
        guard !isUnitTest else { return }
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        let items = placements.compactMap { placement -> BrowserToolbarItem? in
            guard placement.visible, let session = owner(of: placement.surfaceID), session.supportsBrowserControls,
                  let record = session.inventory.tabs[placement.surfaceID], record.hostManaged,
                  !record.hostMinimized, !record.hostFullscreen, !record.hostZoomed,
                  let hostWindowID = record.hostWindowID,
                  let geometry = BrowserPageChromeGeometry(frame: placement.frame) else { return nil }
            return BrowserToolbarItem(surfaceID: placement.surfaceID,
                                      frame: BrowserPageChromeGeometry.appKitRect(geometry.headerFrame, screenTop: screenTop),
                                      url: record.url, canGoBack: record.canGoBack, canGoForward: record.canGoForward,
                                      isLoading: record.isLoading, isFocused: focusCoordinator.target == placement.surfaceID,
                                      supportsPrivacy: session.supportsPrivacy, keepActive: record.keepActive,
                                      blockingEnabled: record.blockingEnabled, blockedRequests: record.blockedRequests,
                                      hostWindowID: hostWindowID,
                                      pageFrame: BrowserPageChromeGeometry.appKitRect(geometry.pageFrame, screenTop: screenTop),
                                      bodyFrame: BrowserPageChromeGeometry.appKitRect(geometry.bodyFrame, screenTop: screenTop),
                                      chromeColor: record.privateBrowsing ? NSColor(srgbRed: 0.19, green: 0.14, blue: 0.27, alpha: 1) : (config.workspaceSidebar.chromeStyle == .solid &&
                                          config.workspaceSidebar.solidChromeColor != .system
                                          ? config.workspaceSidebar.resolvedSolidChromeNSColor : nil),
                                      chromeAppearance: record.privateBrowsing ? .darkAqua : config.workspaceSidebar.chromeAppearance,
                                      isPrivate: record.privateBrowsing, pinnedExtensions: record.pinnedExtensions,
                                      activeDownloads: record.activeDownloads, supportsToolbarActions: session.supportsToolbarActions)
        }
        BrowserToolbarController.shared.update(items: items) { [weak self] id, action in
            self?.performToolbarAction(action, for: id)
        }
        focusCreatedBrowserTabAddress()
    }

    func performToolbarAction(_ action: BrowserToolbarAction, for id: SurfaceID) {
        if case .switchToTab(let target) = action {
            guard let current = owner(of: id)?.inventory.tabs[id],
                  let destination = owner(of: target)?.inventory.tabs[target],
                  target.browserProfileID == id.browserProfileID,
                  destination.privateBrowsing == current.privateBrowsing else { return }
            _ = select(target)
            return
        }
        if action == .focusPage { _ = select(id); return }
        if action == .close { _ = close(id); return }
        if action == .newTab, owner(of: id)?.supportsTabCreation == true {
            _ = openBrowserTab(sourceSurfaceID: id)
            return
        }
        guard let session = owner(of: id), session.supportsBrowserControls else { return }
        let request: BrowserSurfaceAction
        var url: String?
        switch action {
        case .back: request = .back
        case .forward: request = .forward
        case .reload: request = .reload
        case .stop: request = .stop
        case .extensions: request = .extensions
        case .manageExtensions: request = .manageExtensions
        case .extensionAction(let id): request = .extensionAction; url = id
        case .unpinExtension(let id): request = .unpinExtension; url = id
        case .downloads:
            if session.supportsToolbarActions { request = .downloads }
            else { request = .newTab; url = "chrome://downloads/" }
        case .newTab: request = .newTab
        case .minimize: request = .minimize
        case .fullscreen: request = .fullscreen
        case .zoom: request = .zoom
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
        case .privacySettings:
            presentPrivacySettings(for: id)
            return
        case .toggleKeepActive:
            guard session.supportsPrivacy, let record = session.inventory.tabs[id] else { return }
            request = .keepActive; url = record.keepActive ? "false" : "true"
        case .toggleSiteBlocking:
            guard session.supportsPrivacy, let record = session.inventory.tabs[id] else { return }
            request = .siteBlocking; url = record.blockingEnabled ? "false" : "true"
        case .navigate(let text):
            guard let normalized = browserNavigationURL(text) else {
                BrowserToolbarController.shared.showFailure(for: id, message: "Enter a web address or search terms.")
                return
            }
            if session.supportsPrivacy && browserNavigationURL(text, allowSearch: false) == nil {
                request = .search; url = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                request = .navigate; url = normalized
            }
        case .focusPage, .close, .switchToTab: return
        }
        // Buttons and address submission target their own page, including a
        // visible page that was not the previously focused workspace surface.
        if request == .minimize {
            // Minimizing a passive pane must not activate it first. Retire any
            // outstanding focus intent that could restore this window later.
            if focusCoordinator.target == id { nativeSelectionChanged(nil) }
            cancelPendingBrowserFocusHold()
        } else {
            _ = select(id)
        }
        if request == .fullscreen || request == .zoom { cancelPendingBrowserFocusHold() }
        if request == .newTab || request == .extensions || request == .manageExtensions || request == .downloads || request == .extensionAction {
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
    /// A native frame gesture commits all changed edges together. The shared
    /// tree supplies proportions; neither owner mutates native layout weights.
    @discardableResult
    func resizeObservedSurface(_ id: SurfaceID, from original: CGRect, to observed: CGRect) -> Bool {
        guard [original.minX, original.minY, original.width, original.height,
               observed.minX, observed.minY, observed.width, observed.height].allSatisfy(\.isFinite),
              original.width > 0, original.height > 0, observed.width > 0, observed.height > 0,
              abs(original.width - observed.width) > 1 || abs(original.height - observed.height) > 1,
              let name = workspaceName(for: id), let workspace = Workspace.existing(byName: name) else { return false }
        let rect = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        let frame = SurfaceFrame(x: Int(rect.topLeftX.rounded()), y: Int(rect.topLeftY.rounded()),
                                 width: Int(rect.width.rounded()), height: Int(rect.height.rounded()))
        let minima = minimumSizes(in: workspace)
        var candidate = liveLayoutTree(in: workspace), resized = false
        let edges: [(SurfaceDirection, Double)] = [
            (.left, original.minX - observed.minX), (.right, observed.maxX - original.maxX),
            (.up, original.minY - observed.minY), (.down, observed.maxY - original.maxY),
        ]
        for (edge, delta) in edges where abs(delta) > 1 {
            resized = candidate.resize(id, dimension: edge.isHorizontal ? .width : .height, amount: delta,
                frame: frame, minimumSizes: minima, rootPresentation: rootPresentation(in: workspace), edge: edge) || resized
        }
        guard resized else { return false }
        return editOrganization(of: id) { durable in
            durable.setWeights(candidate.weights)
            return true
        }
    }

    @discardableResult
    func resizeSurface(_ id: SurfaceID, in workspace: Workspace, dimension: SurfaceResizeDimension,
                       amount: Double, absolute: Bool = false) -> Bool {
        let rect = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        let frame = SurfaceFrame(x: Int(rect.topLeftX.rounded()), y: Int(rect.topLeftY.rounded()),
                                 width: Int(rect.width.rounded()), height: Int(rect.height.rounded()))
        let minima = minimumSizes(in: workspace)
        var livePlan = liveLayoutTree(in: workspace)
        guard livePlan.workspace(of: id) == workspace.name,
              livePlan.resize(id, dimension: dimension, amount: amount, absolute: absolute, frame: frame, minimumSizes: minima,
                              rootPresentation: rootPresentation(in: workspace)) else { return false }
        return editOrganization(of: id) { durable in
            // Removing reservations only collapses containers; every remaining
            // weight key still belongs to the saved tree. Preserve its complete
            // membership and container metadata while updating visible weights.
            durable.setWeights(livePlan.weights)
            return true
        }
    }
}

import AppKit
import WorkspaceCore

/// Native controls occupy the strip above each visible Chromium page. Frames are
/// AppKit screen coordinates; the layout owner reserves this space from the page.
struct BrowserToolbarItem {
    let surfaceID: SurfaceID
    let frame: CGRect
    let url: String
    let canGoBack: Bool
    let canGoForward: Bool
    let isLoading: Bool
    let isFocused: Bool
    var controlsEnabled = true
    var hostWindowID: UInt32? = nil
}

enum BrowserToolbarAction: Equatable {
    case back, forward, reload, stop, extensions, newTab, close, focusPage
    case navigate(String)
    case resizeWidth(Int), resizeHeight(Int)
    case resize(width: Int, height: Int)
}

@MainActor
final class BrowserToolbarController {
    static let shared = BrowserToolbarController()
    nonisolated static let height: CGFloat = 38
    private var panels: [SurfaceID: BrowserToolbarPanel] = [:]
    private lazy var keyboard = BrowserToolbarKeyboard(
        canFocus: { [weak self] in
            guard let self, BrowserWorkspaceController.shared.ownsForegroundBrowser,
                  let id = self.editingSurfaceID ?? BrowserWorkspaceController.shared.focusCoordinator.target,
                  self.panels[id] != nil else { return false }
            // An explicit user binding takes precedence over the browser default.
            if let mode = activeMode.flatMap({ config.modes[$0] }),
               mode.bindings.values.contains(where: { $0.keyCode == .l && $0.modifiers == .command }) { return false }
            return true
        },
        focus: { [weak self] in
            guard let self,
                  let id = self.editingSurfaceID ?? BrowserWorkspaceController.shared.focusCoordinator.target else { return }
            self.focusAddress(for: id)
        })

    /// Keep layout acknowledgements from taking focus away from native address
    /// entry or keyboard/VoiceOver operation of the resize grip.
    var focusedControlSurfaceID: SurfaceID? {
        panels.first { $0.value.isKeyWindow }?.key
    }

    var editingSurfaceID: SurfaceID? {
        panels.first { $0.value.isEditingAddress }?.key
    }

    func update(items: [BrowserToolbarItem], onAction: @escaping (SurfaceID, BrowserToolbarAction) -> Void) {
        let visible = Set(items.map(\.surfaceID))
        for id in Array(panels.keys) where !visible.contains(id) {
            panels.removeValue(forKey: id)?.dismiss()
        }
        for item in items {
            let panel = panels[item.surfaceID] ?? BrowserToolbarPanel(surfaceID: item.surfaceID)
            panels[item.surfaceID] = panel
            panel.onAction = { action in onAction(item.surfaceID, action) }
            panel.update(item)
        }
        if panels.isEmpty { keyboard.stop() } else { keyboard.refresh() }
    }

    @discardableResult
    func focusAddress(for id: SurfaceID) -> Bool {
        guard let panel = panels[id], panel.isVisible else { return false }
        for other in panels.values where other !== panel { other.endAddressEditing() }
        return panel.focusAddress()
    }

    func showFailure(for id: SurfaceID, message: String) {
        panels[id]?.showFailure(message)
    }

    func hideAll() {
        keyboard.stop()
        for panel in panels.values { panel.dismiss() }
        panels.removeAll()
    }
}

import AppKit
import WorkspaceCore

/// Native controls occupy the strip above each visible Chromium page. Frames are
/// AppKit screen coordinates; the layout owner reserves this space from the page.
struct BrowserToolbarItem {
    let surfaceID: SurfaceID
    var frame: CGRect
    let url: String
    let canGoBack: Bool
    let canGoForward: Bool
    let isLoading: Bool
    let isFocused: Bool
    var controlsEnabled = true
    var hostWindowID: UInt32? = nil
    var pageFrame: CGRect? = nil
    var bodyFrame: CGRect? = nil
    /// Nil uses the native titlebar material; explicit solid colors stay opaque.
    var chromeColor: NSColor? = nil
    /// Nil follows the system. Explicit chrome colors can choose readable controls.
    var chromeAppearance: NSAppearance.Name? = nil
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
    nonisolated static let height = CGFloat(BrowserPageChromeGeometry.headerHeight)
    private var panels: [SurfaceID: BrowserToolbarPanel] = [:]
    private var plannedItems: [SurfaceID: BrowserToolbarItem] = [:]
    private var displayedItems: [SurfaceID: BrowserToolbarItem] = [:]

    /// Read at AX query time; the decorative page backing is never exposed here.
    var accessibilityWindows: [NSWindow] {
        panels.values.filter { $0.isVisible && $0.isAccessibilityElement() }
            .sorted { $0.windowNumber < $1.windowNumber }
    }

    /// Current presentation, including a temporary move or observed host frame.
    var presentationItems: [BrowserToolbarItem] {
        displayedItems.values.sorted { $0.surfaceID.description < $1.surfaceID.description }
    }
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
        },
        onActivation: { [weak self] in
            self?.panels.values.forEach { $0.invalidateHostStacking() }
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
        plannedItems = Dictionary(uniqueKeysWithValues: items.map { ($0.surfaceID, $0) })
        for id in Array(panels.keys) where !visible.contains(id) {
            panels.removeValue(forKey: id)?.dismiss()
            displayedItems.removeValue(forKey: id)
        }
        for plannedItem in items {
            let item = BrowserWindowDragController.shared.presentationItem(plannedItem)
            let panel = panels[item.surfaceID] ?? BrowserToolbarPanel(surfaceID: item.surfaceID)
            panels[item.surfaceID] = panel
            panel.onAction = { action in onAction(item.surfaceID, action) }
            panel.onDrag = { phase, point in
                let drag = BrowserWindowDragController.shared
                switch phase {
                case .began: drag.beginHeaderDrag(surfaceID: item.surfaceID, at: point)
                case .changed: drag.updateHeaderDrag(at: point)
                case .ended: drag.finishHeaderDrag(at: point)
                case .cancelled: drag.cancel()
                }
            }
            displayedItems[item.surfaceID] = item
            panel.update(item)
        }
        if panels.isEmpty { keyboard.stop() } else { keyboard.refresh() }
    }

    /// The native host reports its actual body in global top-left coordinates.
    /// Keep all three page pieces together without moving unrelated windows.
    func applyDragFrame(for id: SurfaceID, bodyFrame: CGRect) {
        guard let planned = plannedItems[id], let panel = panels[id] else { return }
        let item = planned.replacingBodyFrame(bodyFrame, screenTop: NSScreen.screens.first?.frame.maxY ?? 0)
        displayedItems[id] = item
        panel.update(item)
    }

    func restorePlannedFrame(for id: SurfaceID) {
        guard let item = plannedItems[id], let panel = panels[id] else { return }
        displayedItems[id] = item
        panel.update(item)
    }

    func restorePlannedFrames() {
        for id in plannedItems.keys { restorePlannedFrame(for: id) }
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
        BrowserWindowDragController.shared.cancel()
        for panel in panels.values { panel.dismiss() }
        panels.removeAll()
        plannedItems.removeAll()
        displayedItems.removeAll()
    }
}


extension BrowserToolbarItem {
    /// Preserve the measured header/frame insets when the Chromium body moves or
    /// changes size. Conversion also handles displays above or left of primary.
    func replacingBodyFrame(_ globalFrame: CGRect, screenTop: CGFloat) -> BrowserToolbarItem {
        guard let oldBody = bodyFrame, globalFrame.width > 0, globalFrame.height > 0,
              [globalFrame.minX, globalFrame.minY, globalFrame.width, globalFrame.height].allSatisfy(\.isFinite)
        else { return self }
        let body = CGRect(x: globalFrame.minX, y: screenTop - globalFrame.maxY,
                          width: globalFrame.width, height: globalFrame.height)
        var item = self
        item.frame = CGRect(x: body.minX + frame.minX - oldBody.minX,
                            y: body.maxY + frame.minY - oldBody.maxY,
                            width: body.width + frame.width - oldBody.width, height: frame.height)
        if let pageFrame {
            item.pageFrame = CGRect(x: body.minX + pageFrame.minX - oldBody.minX,
                                    y: body.minY + pageFrame.minY - oldBody.minY,
                                    width: body.width + pageFrame.width - oldBody.width,
                                    height: body.height + pageFrame.height - oldBody.height)
        }
        item.bodyFrame = body
        return item
    }
}

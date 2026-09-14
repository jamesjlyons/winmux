import AppKit
import SwiftUI

/// A small AppKit drag surface keeps the pointer's screen coordinate stable as SwiftUI relayouts.
struct WorkspaceSidebarResizeHandle: NSViewRepresentable {
    let monitorScopeId: String

    func makeNSView(context: Context) -> SidebarResizeView { SidebarResizeView() }
    func updateNSView(_ view: SidebarResizeView, context: Context) { view.monitorScopeId = monitorScopeId }
    static func dismantleNSView(_ view: SidebarResizeView, coordinator: ()) { view.finish(cancelled: true) }
}

final class SidebarResizeView: NSView {
    var monitorScopeId = ""
    private var startX: CGFloat?
    private var startWidth = 0
    private var multiplier: CGFloat = 1
    private var hovered = false
    private weak var previousResponder: NSResponder?
    private weak var resizingPanel: WorkspaceSidebarPanel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize sidebar")
    }
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard hovered || startX != nil else { return }
        NSColor.labelColor.withAlphaComponent(0.32).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 1, y: bounds.midY - 24, width: 2, height: 48), xRadius: 1, yRadius: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel = WorkspaceSidebarPanel.panel(for: monitorScopeId) else { return }
        resizingPanel = panel
        startWidth = config.workspaceSidebar.width
        multiplier = panel.viewModel.workspaceSidebarVisibleWidth > CGFloat(startWidth) + 0.5 ? 2 : 1
        startX = panel.convertPoint(toScreen: event.locationInWindow).x
        panel.isResizingSidebar = true
        panel.cancelExpansionWork()
        previousResponder = window?.firstResponder === self ? window?.contentView : window?.firstResponder
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            updateWidth(CGFloat(WorkspaceSidebarConfig().width))
            finish(cancelled: false)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startX, let panel = resizingPanel else { return }
        let x = panel.convertPoint(toScreen: event.locationInWindow).x
        updateWidth(CGFloat(startWidth) + (x - startX) / multiplier)
    }
    override func mouseUp(with event: NSEvent) { finish(cancelled: false) }
    override func cancelOperation(_ sender: Any?) { finish(cancelled: true) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(cancelled: true) } else { super.keyDown(with: event) }
    }

    private func updateWidth(_ proposed: CGFloat) {
        guard let panel = resizingPanel else { return }
        let available = (panel.screen?.frame.width ?? 960) / multiplier
        let width = clampedWorkspaceSidebarWidth(proposed, collapsedWidth: config.workspaceSidebar.collapsedWidth, availableWidth: available)
        applyWorkspaceSidebarPreviewWidth(width)
    }

    func finish(cancelled: Bool) {
        guard startX != nil else { return }
        startX = nil
        let width = config.workspaceSidebar.width
        if cancelled { applyWorkspaceSidebarPreviewWidth(startWidth) }
        resizingPanel?.isResizingSidebar = false
        resizingPanel?.scheduleHoverRecheckSoon()
        resizingPanel = nil
        if window?.firstResponder === self { window?.makeFirstResponder(previousResponder) }
        needsDisplay = true
        guard !cancelled, width != startWidth else { return }
        let previousWidth = startWidth
        Task { @MainActor in
            do {
                let url = try persistWorkspaceSidebarWidth(width)
                guard try await reloadConfig(forceConfigUrl: url) else {
                    throw NSError(domain: "WinMux", code: 1, userInfo: [NSLocalizedDescriptionKey: "Saved sidebar width, but could not reload the config."])
                }
            } catch {
                applyWorkspaceSidebarPreviewWidth(previousWidth)
                MessageModel.shared.message = Message(description: "Sidebar Resize", body: error.localizedDescription)
            }
        }
    }
}

@MainActor
private func applyWorkspaceSidebarPreviewWidth(_ width: Int) {
    let previousWidth = config.workspaceSidebar.width
    guard previousWidth != width else { return }
    config.workspaceSidebar.width = width
    for panel in WorkspaceSidebarPanel.visiblePanels where panel.viewModel.isWorkspaceSidebarExpanded {
        let isSplit = panel.viewModel.workspaceSidebarVisibleWidth > CGFloat(previousWidth) + 0.5
        panel.viewModel.workspaceSidebarVisibleWidth = CGFloat(width) * (isSplit ? 2 : 1)
        if panel.persistentExpansionWidth != nil { panel.persistentExpansionWidth = CGFloat(width) }
    }
    WorkspaceSidebarPanel.refreshAll()
    if config.workspaceSidebar.alwaysExpanded { scheduleRefreshSession(.configAutoReload) }
}

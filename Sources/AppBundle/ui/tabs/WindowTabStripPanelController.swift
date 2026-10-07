import AppKit
import WorkspaceCore

@MainActor
final class WindowTabStripPanelController {
    static let shared = WindowTabStripPanelController()

    enum MouseInteractionChromeMode: Equatable {
        case frameOnly
        case hidden
    }

    var visualPanels: [WindowTabStripIdentity: WindowTabGroupVisualPanel] = [:]
    var stripPanels: [WindowTabStripIdentity: WindowTabStripPanel] = [:]
    var transientResizeTabGroupId: WindowTabStripIdentity? = nil
    var transientResizeTabGroupStrip: WindowTabStripViewModel? = nil
    var mouseInteractionChromeMode: MouseInteractionChromeMode? = nil
    var hiddenPassiveTabGroupChromeIds: Set<WindowTabStripIdentity> = []

    private init() {}
}

extension WindowTabStripPanelController {
    func visualPanel(for id: WindowTabStripIdentity) -> WindowTabGroupVisualPanel {
        let panel = visualPanels[id] ?? WindowTabGroupVisualPanel(id: id)
        visualPanels[id] = panel
        return panel
    }

    func stripPanel(for id: WindowTabStripIdentity) -> WindowTabStripPanel {
        let panel = stripPanels[id] ?? WindowTabStripPanel(id: id)
        stripPanels[id] = panel
        return panel
    }

    func orderOutPanels(id: WindowTabStripIdentity) {
        orderOutIfVisible(visualPanels[id])
        orderOutIfVisible(stripPanels[id])
    }

    func removeStalePanels(activeIds: Set<WindowTabStripIdentity>) {
        // A group on a hidden workspace is still alive. Keep its AppKit windows and
        // SwiftUI hosts warm so switching back only restores their ordering. Previously
        // every workspace switch destroyed both panels and rebuilt their view trees.
        let owner = BrowserWorkspaceController.shared
        let nativeIds = Workspace.all.filter { !owner.usesSurfaceTree || !owner.hasMixedLayout(in: $0) }.flatMap {
            $0.rootTilingContainer.allTabbedContainersRecursive.map { WindowTabStripIdentity.native(ObjectIdentifier($0)) }
        }
        func sharedIDs(_ nodes: [SurfaceTreeNode]) -> [WindowTabStripIdentity] {
            nodes.flatMap { node -> [WindowTabStripIdentity] in
                guard case .group(let id, let children) = node else { return [] }
                let own: [WindowTabStripIdentity] = (owner.surfaceTree.layouts[id] ?? .stack) == .stack ? [.shared(id)] : []
                return own + sharedIDs(children)
            }
        }
        let sharedIds = owner.usesSurfaceTree ? sharedIDs(owner.surfaceTree.roots.values.flatMap { $0 }) : []
        let liveIds = Set(nativeIds + sharedIds)
        for staleId in visualPanels.keys where !activeIds.contains(staleId) {
            orderOutIfVisible(visualPanels[staleId])
            if !liveIds.contains(staleId) {
                visualPanels.removeValue(forKey: staleId)
            }
        }
        for staleId in stripPanels.keys where !activeIds.contains(staleId) {
            orderOutIfVisible(stripPanels[staleId])
            if !liveIds.contains(staleId) {
                stripPanels.removeValue(forKey: staleId)
            }
        }
    }

    func orderOutIfVisible(_ panel: NSPanelHud?) {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
    }
}

extension WindowTabStripPanelController {
    func refresh() {
        guard TrayMenuModel.shared.isEnabled, config.windowTabs.enabled else {
            hideAll()
            return
        }

        let strips = windowTabStripsWithTransientResizeApplied(TrayMenuModel.shared.windowTabStrips)
        let activeIds = Set(strips.map(\.id))
        if let mouseInteractionChromeMode {
            refreshSuppressedChrome(mode: mouseInteractionChromeMode, strips: strips, activeIds: activeIds)
            return
        }
        refreshInteractiveChrome(strips: strips, activeIds: activeIds)
    }

    func windowTabStripsWithTransientResizeApplied(_ strips: [WindowTabStripViewModel]) -> [WindowTabStripViewModel] {
        guard let transientResizeTabGroupStrip else { return strips }
        return strips.map { strip in
            strip.id == transientResizeTabGroupStrip.id ? transientResizeTabGroupStrip : strip
        }
    }

    func refreshInteractiveChrome(strips: [WindowTabStripViewModel], activeIds: Set<WindowTabStripIdentity>) {
        removeStalePanels(activeIds: activeIds)
        for strip in strips {
            guard !hiddenPassiveTabGroupChromeIds.contains(strip.id) else {
                orderOutPanels(id: strip.id)
                continue
            }
            visualPanel(for: strip.id).update(with: strip)
            stripPanel(for: strip.id).update(with: strip)
        }
    }

    func refreshSuppressedChrome(
        mode: MouseInteractionChromeMode,
        strips: [WindowTabStripViewModel],
        activeIds: Set<WindowTabStripIdentity>,
    ) {
        switch mode {
            case .frameOnly:
                refreshFrameOnlyChrome(strips: strips, activeIds: activeIds)
            case .hidden:
                refreshHiddenChrome(activeIds: activeIds)
        }
    }

    func refreshFrameOnlyChrome(strips: [WindowTabStripViewModel], activeIds: Set<WindowTabStripIdentity>) {
        removeStalePanels(activeIds: activeIds)
        for strip in strips {
            guard !hiddenPassiveTabGroupChromeIds.contains(strip.id) else {
                orderOutPanels(id: strip.id)
                continue
            }
            visualPanel(for: strip.id).update(with: strip)
            orderOutIfVisible(stripPanels[strip.id])
        }
    }
}

extension WindowTabStripPanelController {
    @discardableResult
    func updateResizingTabGroupChrome(window: Window, activeWindowRect: Rect) -> Bool {
        guard let transientStrip = resizingTabGroupStrip(window: window, activeWindowRect: activeWindowRect) else {
            transientResizeTabGroupId = nil
            transientResizeTabGroupStrip = nil
            return false
        }

        transientResizeTabGroupId = transientStrip.id
        transientResizeTabGroupStrip = transientStrip
        if hiddenPassiveTabGroupChromeIds.contains(transientStrip.id) {
            orderOutPanels(id: transientStrip.id)
            return true
        }
        visualPanel(for: transientStrip.id).update(with: transientStrip)
        updateInteractivePanelForResizingStrip(transientStrip)
        return true
    }

    func clearTransientResizeChrome() {
        guard transientResizeTabGroupId != nil || transientResizeTabGroupStrip != nil else { return }
        transientResizeTabGroupId = nil
        transientResizeTabGroupStrip = nil
    }

    func updateInteractivePanelForResizingStrip(_ strip: WindowTabStripViewModel) {
        if mouseInteractionChromeMode != nil {
            orderOutIfVisible(stripPanels[strip.id])
        } else {
            stripPanel(for: strip.id).update(with: strip)
        }
    }

    func resizingTabGroupStrip(window: Window, activeWindowRect: Rect) -> WindowTabStripViewModel? {
        guard TrayMenuModel.shared.isEnabled,
              config.windowTabs.enabled,
              let tabGroup = window.nearestWindowTabGroup,
              tabGroup.usesWindowTabBehavior,
              tabGroup.tabActiveWindow == window
        else { return nil }
        let id = WindowTabStripIdentity.native(ObjectIdentifier(tabGroup))
        guard let baseStrip = TrayMenuModel.shared.windowTabStrips.first(where: { $0.id == id }) else { return nil }
        return resizingTabGroupStrip(baseStrip: baseStrip, activeWindowRect: activeWindowRect)
    }

    func resizingTabGroupStrip(baseStrip: WindowTabStripViewModel, activeWindowRect: Rect) -> WindowTabStripViewModel {
        let groupFrameRect = windowTabGroupFrameRect(forActiveWindowContentRect: activeWindowRect)
        let tabBarRect = windowTabBarRect(forGroupFrameRect: groupFrameRect)
        return WindowTabStripViewModel(
            id: baseStrip.id,
            workspaceName: baseStrip.workspaceName,
            frame: tabBarRect.toAppKitScreenRect.alignedToBackingPixels(),
            groupFrame: groupFrameRect.toAppKitScreenRect.alignedToBackingPixels(),
            activeWindowId: baseStrip.activeWindowId,
            activeWindowCornerRadius: baseStrip.activeWindowCornerRadius,
            tabs: baseStrip.tabs,
            occludingFloatingWindowFrames: baseStrip.occludingFloatingWindowFrames,
            sharedStack: baseStrip.sharedStack,
        )
    }
}

extension WindowTabStripPanelController {
    func hideChromeDuringMouseInteraction(showFrameOnly: Bool = true) {
        guard TrayMenuModel.shared.isEnabled, config.windowTabs.enabled else { return }
        let nextMode: MouseInteractionChromeMode = showFrameOnly ? .frameOnly : .hidden
        guard mouseInteractionChromeMode != nextMode || transientResizeTabGroupId != nil else { return }
        mouseInteractionChromeMode = nextMode
        transientResizeTabGroupId = nil
        transientResizeTabGroupStrip = nil
        refresh()
    }

    func showChromeDuringMouseInteraction() {
        guard mouseInteractionChromeMode != nil || !hiddenPassiveTabGroupChromeIds.isEmpty else { return }
        mouseInteractionChromeMode = nil
        hiddenPassiveTabGroupChromeIds.removeAll()
        refresh()
    }

    func refreshHiddenChrome(activeIds: Set<WindowTabStripIdentity>) {
        for panel in visualPanels.values {
            orderOutIfVisible(panel)
        }
        for panel in stripPanels.values {
            orderOutIfVisible(panel)
        }
        removeStalePanels(activeIds: activeIds)
    }

    @discardableResult
    func clearMouseInteractionChromeSuppressionIfInactive() -> Bool {
        guard currentlyManipulatedWithMouseWindowId == nil,
              mouseInteractionChromeMode != nil
        else { return false }
        mouseInteractionChromeMode = nil
        return true
    }
}

extension WindowTabStripPanelController {
    func updateMousePolicies(at screenPoint: CGPoint) {
        for panel in stripPanels.values where panel.isVisible {
            panel.updateMousePolicy(at: screenPoint)
        }
    }

    func setHiddenPassiveTabGroupChrome(_ nativeIds: Set<ObjectIdentifier>) {
        let ids = Set(nativeIds.map(WindowTabStripIdentity.native))
        guard hiddenPassiveTabGroupChromeIds != ids else { return }
        hiddenPassiveTabGroupChromeIds = ids
        refresh()
    }

    func clearHiddenPassiveTabGroupChrome() {
        guard !hiddenPassiveTabGroupChromeIds.isEmpty else { return }
        hiddenPassiveTabGroupChromeIds.removeAll()
        refresh()
    }

    func hideAll() {
        SharedStackDragController.shared.cancel()
        transientResizeTabGroupId = nil
        transientResizeTabGroupStrip = nil
        mouseInteractionChromeMode = nil
        hiddenPassiveTabGroupChromeIds.removeAll()
        for panel in visualPanels.values {
            panel.orderOut(nil)
        }
        for panel in stripPanels.values {
            panel.orderOut(nil)
        }
        visualPanels.removeAll()
        stripPanels.removeAll()
    }

    func setIgnoresMouseEvents(_ ignoresMouseEvents: Bool) {
        for panel in stripPanels.values {
            panel.setExternalIgnoresMouseEvents(ignoresMouseEvents)
        }
    }
}

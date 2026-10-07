import AppKit
import Common
import SwiftUI

@MainActor
final class WindowTabGroupVisualPanel: NSPanelHud {
    let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    var currentContent: WindowTabGroupVisualContent?
    var currentPanelFrame: CGRect?
    var currentOrderingWindowId: UInt32?

    init(id: WindowTabStripIdentity) {
        super.init()
        identifier = NSUserInterfaceItemIdentifier(windowTabVisualPanelPrefix + String(id.hashValue))
        hasShadow = false
        isFloatingPanel = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        backgroundColor = .clear
        ignoresMouseEvents = true
        applyWinMuxLayer(.windowChrome)
        contentView = hostingView
        hostingView.frame = contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(with strip: WindowTabStripViewModel) {
        let displayStrip = strip.alignedForWindowTabChrome()
        let panelFrame = displayStrip.groupFrame
        let nextContent = WindowTabGroupVisualContent(strip: displayStrip)
        guard shouldUpdate(content: nextContent, frame: panelFrame, orderingWindowId: displayStrip.activeWindowId) else { return }
        if currentContent != nextContent {
            hostingView.rootView = AnyView(WindowTabGroupVisualView(
                strip: displayStrip,
            ))
            currentContent = nextContent
        }
        currentPanelFrame = panelFrame
        currentOrderingWindowId = displayStrip.activeWindowId
        debugFocusLog("WindowTabGroupVisualPanel.update id=\(String(describing: identifier?.rawValue)) frame=\(panelFrame)")
        setWindowTabChromePanelFrame(panelFrame, on: self)
        ignoresMouseEvents = true
        applyWindowTabVisualStackingPolicy(for: displayStrip, to: self)
    }

    private func shouldUpdate(content: WindowTabGroupVisualContent, frame: CGRect, orderingWindowId: UInt32?) -> Bool {
        if currentContent == content, currentPanelFrame == frame, currentOrderingWindowId == orderingWindowId, isVisible {
            ignoresMouseEvents = true
            return false
        }
        return true
    }
}

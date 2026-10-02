import AppKit
import WorkspaceCore

/// The backing belongs to the same page presentation as its header and content.
/// It never receives input; Chromium continues to receive every page interaction.
@MainActor
final class BrowserPageChromePanel: NSPanelHud {
    let chromeView = BrowserPageChromeView()
    private var currentHostWindowID: UInt32?
    private var wasFocused = false

    init(surfaceID: SurfaceID) {
        super.init()
        identifier = .init("winmux-browser-page-chrome-" + surfaceID.description)
        isFloatingPanel = false
        isMovable = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        ignoresMouseEvents = true
        // Chromium's native content window already supplies a shadow. Adding a
        // second panel shadow would make the two pieces look like stacked cards.
        hasShadow = false
        applyWinMuxLayer(.windowChrome)
        contentView = chromeView
        chromeView.autoresizingMask = [.width, .height]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(_ item: BrowserToolbarItem) {
        guard let pageFrame = item.pageFrame, let host = item.hostWindowID else {
            dismiss()
            return
        }
        if appearance?.name != item.chromeAppearance {
            appearance = item.chromeAppearance.flatMap { NSAppearance(named: $0) }
        }
        chromeView.update(item)
        if frame != pageFrame { setWindowTabChromePanelFrame(pageFrame, on: self) }
        if !isVisible || host != currentHostWindowID || (item.isFocused && !wasFocused) {
            order(.below, relativeTo: Int(host))
        }
        currentHostWindowID = host
        wasFocused = item.isFocused
    }

    func invalidateHostStacking() {
        currentHostWindowID = nil
    }

    func dismiss() {
        orderOut(nil)
        currentHostWindowID = nil
        wasFocused = false
    }
}

/// A full backing fills the native page's rounded corners without guessing its
/// OS-dependent radius. The opaque Chromium body covers the middle; the exposed
/// edges and native controls share one material and one continuous outer stroke.
@MainActor
final class BrowserPageChromeView: NSView {
    private var color = mattePanelNSColor
    private var focused = false
    private var headerHeight = CGFloat(BrowserPageChromeGeometry.headerHeight)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    func update(_ item: BrowserToolbarItem) {
        color = item.chromeColor ?? mattePanelNSColor
        focused = item.isFocused
        headerHeight = item.frame.height
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: BrowserPageChromeGeometry.cornerRadius,
                                   yRadius: BrowserPageChromeGeometry.cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        color.setFill()
        bounds.fill()
        let header = NSRect(x: 0, y: bounds.maxY - headerHeight, width: bounds.width, height: headerHeight)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSRect(x: CGFloat(BrowserPageChromeGeometry.shellInset), y: header.minY,
               width: max(0, bounds.width - CGFloat(BrowserPageChromeGeometry.shellInset * 2)), height: 0.5).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.labelColor.withAlphaComponent(focused ? 0.18 : 0.09).setStroke()
        outline.lineWidth = 0.5
        outline.stroke()
    }
}

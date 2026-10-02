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
        // Managed tiles share a quiet, flat frame without stacked window shadows.
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
/// OS-dependent radius. The Chromium body covers the middle; the exposed edges
/// and native controls share the system material and a faint outer stroke.
@MainActor
final class BrowserPageChromeView: NSView {
    private let background = BrowserChromeBackgroundView(headerOnly: false)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        addSubview(background)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    func update(_ item: BrowserToolbarItem) {
        background.update(item)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        background.frame = bounds
    }
}

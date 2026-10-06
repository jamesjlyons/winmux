import AppKit

/// Native page controls over the same system material as the page frame.
@MainActor
final class BrowserToolbarView: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    let address = BrowserToolbarAddressField(string: "")
    var onAction: ((BrowserToolbarAction) -> Void)?
    var onCancelAddress: (() -> Void)?
    var onDrag: ((BrowserToolbarDragPhase, CGPoint) -> Void)?
    private var dragGesture = BrowserToolbarDragGesture()
    private let chromeBackground = BrowserChromeBackgroundView(headerOnly: true)
    private var close: NSButton?
    private var minimize: NSButton?
    private var zoom: NSButton?
    var windowButtons: [NSButton] { [close, minimize, zoom].compactMap { $0 } }
    private let back = BrowserToolbarButton()
    private let forward = BrowserToolbarButton()
    private let reload = BrowserToolbarButton()
    private let more = BrowserToolbarButton()
    private let moveGrip = BrowserToolbarMoveGrip()
    private let addressWell = BrowserToolbarAddressWell()
    private var isLoading = false
    private var controlsEnabled = true
    private var canGoBack = false
    private var canGoForward = false
    private var currentControlState: ControlState?

    private struct ControlState: Equatable {
        let url: String
        let isLoading: Bool
        let controlsEnabled: Bool
        let canGoBack: Bool
        let canGoForward: Bool
        let isFocused: Bool
        let preserveAddress: Bool
        let isPrivate: Bool
    }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Web page controls")
        setAccessibilityIdentifier("winmux.browser.toolbar")
        addSubview(chromeBackground)
        configure(back, symbol: "chevron.left", label: "Back", action: #selector(goBack))
        configure(forward, symbol: "chevron.right", label: "Forward", action: #selector(goForward))
        configure(reload, symbol: "arrow.clockwise", label: "Reload page", action: #selector(reloadOrStop))
        configure(more, symbol: "ellipsis", label: "Web window actions", action: #selector(showActions))

        address.placeholderString = "Search or enter address"
        address.setAccessibilityLabel("Page address")
        address.setAccessibilityIdentifier("winmux.browser.address")
        address.font = .systemFont(ofSize: 11)
        address.textColor = .secondaryLabelColor
        address.controlSize = .small
        address.isBezeled = false
        address.drawsBackground = false
        address.focusRingType = .none
        address.lineBreakMode = .byTruncatingMiddle
        address.usesSingleLineMode = true
        address.cell?.isScrollable = true
        address.cell?.wraps = false
        address.delegate = self
        addressWell.field = address
        addressWell.addSubview(address)

        moveGrip.onDrag = { [weak self] phase, point in self?.onDrag?(phase, point) }
        moveGrip.onClick = { [weak self] in self?.onAction?(.focusPage) }
        for view in [back, forward, reload, addressWell, more, moveGrip] {
            addSubview(view)
        }
        menu = makeWindowMenu()
        moveGrip.menu = menu
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        chromeBackground.frame = bounds
        // Keep navigation and address entry usable in narrow splits. Every hidden
        // action remains available through the window actions menu.
        back.isHidden = bounds.width < 280
        forward.isHidden = bounds.width < 380
        reload.isHidden = bounds.width < 224
        more.isHidden = bounds.width < 200
        moveGrip.isHidden = false
        let controlHeight: CGFloat = 22
        let y = (bounds.height - controlHeight) / 2
        // AppKit owns titlebar placement, spacing, hover and Liquid Glass.
        // Only measure the controls here; never reparent or reposition them.
        let lightsRight = windowButtons.map { convert($0.bounds, from: $0).maxX }.max() ?? 0
        var left: CGFloat = max(10, lightsRight + 8)
        for button in [back, forward, reload] where !button.isHidden {
            button.frame = .init(x: left, y: y, width: 22, height: controlHeight)
            left += 22
        }
        left += 2
        var right = bounds.maxX - 5
        if !more.isHidden {
            more.frame = .init(x: right - 22, y: y, width: 22, height: controlHeight)
            right -= 24
        }
        // Reserve a full-height drag target beside the URL. Keep a compact grip
        // in minimum-width panes and give spare space to dragging on wide pages.
        let availableWidth = max(0, right - left)
        let gripWidth = min(56, max(24, availableWidth - 52 - 4))
        let addressWidth = min(540, max(0, availableWidth - gripWidth - 4))
        addressWell.frame = .init(x: left, y: y, width: addressWidth, height: controlHeight)
        let gripLeft = addressWell.frame.maxX + 4
        moveGrip.frame = .init(x: gripLeft, y: 0, width: max(0, right - gripLeft), height: bounds.height)
        addressWell.needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        for view in subviews { view.needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        dragGesture.begin(at: browserToolbarDragPoint(event, in: self))
    }

    override func mouseDragged(with event: NSEvent) {
        for update in dragGesture.update(at: browserToolbarDragPoint(event, in: self)) {
            onDrag?(update.phase, update.point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragGesture.origin != nil else { return }
        let point = browserToolbarDragPoint(event, in: self)
        if dragGesture.end() { onDrag?(.ended, point) }
        else { onAction?(.focusPage) }
    }

    func cancelDrag() {
        if dragGesture.end() { onDrag?(.cancelled, .zero) }
        moveGrip.cancelDrag()
    }

    override func cancelOperation(_ sender: Any?) { cancelDrag() }

    func update(_ item: BrowserToolbarItem, preserveAddress: Bool) {
        // A managed page's backing already draws the entire frame, including
        // the header. Drawing it again here doubles the material and corner
        // outline, and puts a straight separator across the native page curve.
        let hidesHeaderBackground = item.pageFrame != nil && item.hostWindowID != nil
        if chromeBackground.isHidden != hidesHeaderBackground { chromeBackground.isHidden = hidesHeaderBackground }
        chromeBackground.update(item)
        // Editing can begin and end between model updates (for example when
        // leaving a group). Restore the committed URL even if model state is equal.
        if !preserveAddress, address.stringValue != item.url { address.stringValue = item.url }
        let state = ControlState(url: item.url, isLoading: item.isLoading,
            controlsEnabled: item.controlsEnabled, canGoBack: item.canGoBack,
            canGoForward: item.canGoForward, isFocused: item.isFocused, preserveAddress: preserveAddress, isPrivate: item.isPrivate)
        guard currentControlState != state else { return }
        let previous = currentControlState
        currentControlState = state
        if previous?.isPrivate != item.isPrivate {
            let label = item.isPrivate ? "Incognito · Temporary — private page actions" : "Web window actions"
            more.image = NSImage(systemSymbolName: item.isPrivate ? "eye.slash.fill" : "ellipsis", accessibilityDescription: label)
            more.toolTip = label
            more.setAccessibilityLabel(label)
            setAccessibilityLabel(item.isPrivate ? "Private web page controls" : "Web page controls")
        }
        minimize?.isEnabled = item.controlsEnabled
        zoom?.isEnabled = item.controlsEnabled
        if previous?.isFocused != item.isFocused {
            for button in windowButtons { button.needsDisplay = true }
        }
        isLoading = item.isLoading
        controlsEnabled = item.controlsEnabled
        canGoBack = item.canGoBack
        canGoForward = item.canGoForward
        back.isEnabled = item.controlsEnabled && item.canGoBack
        forward.isEnabled = item.controlsEnabled && item.canGoForward
        reload.isEnabled = item.controlsEnabled
        address.isEnabled = item.controlsEnabled
        addressWell.isEditing = preserveAddress
        if previous?.isLoading != item.isLoading {
            let label = item.isLoading ? "Stop loading" : "Reload page"
            reload.image = NSImage(systemSymbolName: item.isLoading ? "xmark" : "arrow.clockwise", accessibilityDescription: label)
            reload.toolTip = label
            reload.setAccessibilityLabel(label)
        }
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
    }

    func installWindowButtons(from window: NSWindow) {
        close = window.standardWindowButton(.closeButton)
        minimize = window.standardWindowButton(.miniaturizeButton)
        zoom = window.standardWindowButton(.zoomButton)
        if let close { configureWindowButton(close, label: "Close web window", identifier: "close", action: #selector(closePage)) }
        if let minimize { configureWindowButton(minimize, label: "Minimize web window", identifier: "minimize", action: #selector(minimizePage)) }
        if let zoom { configureWindowButton(zoom, label: "Enter Full Screen", identifier: "fullscreen", action: #selector(zoomPage)) }
        needsLayout = true
    }

    private func configureWindowButton(_ button: NSButton, label: String, identifier: String, action: Selector) {
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier("winmux.browser." + identifier)
    }

    private func makeWindowMenu() -> NSMenu {
        let result = NSMenu(title: "Web window")
        for (title, action) in [
            ("Back", #selector(goBack)), ("Forward", #selector(goForward)),
            ("Reload page", #selector(reloadOrStop)), ("Extensions", #selector(openExtensions)),
            ("New web window", #selector(openNewTab)),
            ("Minimize", #selector(minimizePage)), ("Enter Full Screen", #selector(zoomPage)),
            ("Make Wider", #selector(makeWider)), ("Make Narrower", #selector(makeNarrower)),
            ("Make Taller", #selector(makeTaller)), ("Make Shorter", #selector(makeShorter)),
            ("Close web window", #selector(closePage)),
        ] {
            if action == #selector(makeWider) || action == #selector(closePage) { result.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            result.addItem(item)
        }
        return result
    }

    @objc private func showActions() {
        guard let menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: more.bounds.minX, y: more.bounds.minY), in: more)
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack): return controlsEnabled && canGoBack
        case #selector(goForward): return controlsEnabled && canGoForward
        case #selector(reloadOrStop):
            menuItem.title = isLoading ? "Stop loading" : "Reload page"
            return controlsEnabled
        case #selector(openExtensions), #selector(openNewTab), #selector(minimizePage), #selector(zoomPage): return controlsEnabled
        default: return true
        }
    }

    @objc private func goBack() { onAction?(.back) }
    @objc private func goForward() { onAction?(.forward) }
    @objc private func reloadOrStop() { onAction?(isLoading ? .stop : .reload) }
    @objc private func openExtensions() { onAction?(.extensions) }
    @objc private func openNewTab() { onAction?(.newTab) }
    @objc private func closePage() { onAction?(.close) }
    @objc private func minimizePage() { onAction?(.minimize) }
    @objc private func zoomPage() { onAction?(NSApp.currentEvent?.modifierFlags.contains(.option) == true ? .zoom : .fullscreen) }
    @objc private func makeWider() { onAction?(.resizeWidth(40)) }
    @objc private func makeNarrower() { onAction?(.resizeWidth(-40)) }
    @objc private func makeTaller() { onAction?(.resizeHeight(40)) }
    @objc private func makeShorter() { onAction?(.resizeHeight(-40)) }

    func controlTextDidBeginEditing(_ notification: Notification) {
        addressWell.isEditing = true
        address.textColor = .labelColor
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        addressWell.isEditing = false
        address.textColor = .secondaryLabelColor
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let input = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty else { NSSound.beep(); return true }
            onAction?(.navigate(input))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancelAddress?()
            return true
        default: return false
        }
    }
}

/// Native buttons retain page focus; the address well explicitly enters editing.
private final class BrowserToolbarButton: NSButton {
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if isHovered && isEnabled {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }
}

private final class BrowserToolbarAddressWell: NSView {
    weak var field: NSTextField?
    var isEditing = false { didSet { if oldValue != isEditing { needsDisplay = true } } }
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func layout() {
        super.layout()
        field?.frame = .init(x: 6, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 12), height: 16)
    }
    override func mouseDown(with event: NSEvent) {
        guard let field, field.isEnabled else { return }
        window?.makeKey()
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard isEditing || isHovered else { return }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 4, yRadius: 4)
        let fill = isEditing ? NSColor.textBackgroundColor : NSColor.labelColor.withAlphaComponent(0.045)
        fill.setFill()
        shape.fill()
        if isEditing {
            NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.75).setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
        }
    }
}

final class BrowserToolbarAddressField: NSTextField {
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

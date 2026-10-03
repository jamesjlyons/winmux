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
    private let close = BrowserToolbarView.windowButton(.closeButton)
    private let minimize = BrowserToolbarView.windowButton(.miniaturizeButton)
    private let zoom = BrowserToolbarView.windowButton(.zoomButton)
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

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Web page controls")
        setAccessibilityIdentifier("winmux.browser.toolbar")
        addSubview(chromeBackground)
        configureWindowButton(close, label: "Close web window", identifier: "close", action: #selector(closePage))
        configureWindowButton(minimize, label: "Minimize web window", identifier: "minimize", action: #selector(minimizePage))
        configureWindowButton(zoom, label: "Enter Full Screen", identifier: "fullscreen", action: #selector(zoomPage))
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
        for view in [close, minimize, zoom, back, forward, reload, addressWell, more, moveGrip] {
            addSubview(view)
        }
        menu = makeWindowMenu()
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
        reload.isHidden = bounds.width < 200
        moveGrip.isHidden = bounds.width < 240
        let controlHeight: CGFloat = 22
        let y = (bounds.height - controlHeight) / 2
        var left: CGFloat = 10
        for button in [close, minimize, zoom] {
            button.setFrameOrigin(.init(x: left, y: (bounds.height - button.frame.height) / 2))
            left += button.frame.width + 6
        }
        left += 2
        for button in [back, forward, reload] where !button.isHidden {
            button.frame = .init(x: left, y: y, width: 22, height: controlHeight)
            left += 22
        }
        left += 2
        var right = bounds.maxX - 5
        for view in [moveGrip, more] where !view.isHidden {
            let width: CGFloat = view === moveGrip ? 20 : 22
            right -= width
            view.frame = .init(x: right, y: y, width: width, height: controlHeight)
            right -= 1
        }
        addressWell.frame = .init(x: left, y: y, width: max(0, right - left - 2), height: controlHeight)
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
        chromeBackground.isHidden = item.pageFrame != nil && item.hostWindowID != nil
        chromeBackground.update(item)
        minimize.isEnabled = item.controlsEnabled
        zoom.isEnabled = item.controlsEnabled
        for button in [close, minimize, zoom] { button.needsDisplay = true }
        isLoading = item.isLoading
        controlsEnabled = item.controlsEnabled
        canGoBack = item.canGoBack
        canGoForward = item.canGoForward
        back.isEnabled = item.controlsEnabled && item.canGoBack
        forward.isEnabled = item.controlsEnabled && item.canGoForward
        reload.isEnabled = item.controlsEnabled
        address.isEnabled = item.controlsEnabled
        addressWell.isEditing = preserveAddress
        if !preserveAddress { address.stringValue = item.url }
        let label = item.isLoading ? "Stop loading" : "Reload page"
        reload.image = NSImage(systemSymbolName: item.isLoading ? "xmark" : "arrow.clockwise", accessibilityDescription: label)
        reload.toolTip = label
        reload.setAccessibilityLabel(label)
        needsLayout = true
        needsDisplay = true
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.symbolConfiguration = .init(pointSize: 10, weight: .regular)
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

    private static func windowButton(_ type: NSWindow.ButtonType) -> NSButton {
        guard let button = NSWindow.standardWindowButton(type, for: [.titled, .closable, .miniaturizable, .resizable]) else {
            preconditionFailure("AppKit did not provide a standard window control")
        }
        return button
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
    var isEditing = false { didSet { needsDisplay = true } }
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

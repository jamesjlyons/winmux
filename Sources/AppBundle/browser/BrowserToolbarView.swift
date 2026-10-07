import AppKit
import WorkspaceCore

/// Native page controls over the same system material as the page frame.
@MainActor
final class BrowserToolbarView: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    let address = BrowserToolbarAddressField(string: "")
    lazy var autocomplete: BrowserAddressAutocomplete = {
        let result = BrowserAddressAutocomplete(field: address)
        result.onNavigate = { [weak self] in self?.onAction?(.navigate($0)) }
        result.onSwitchTab = { [weak self] in self?.onAction?(.switchToTab($0)) }
        return result
    }()
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
    private let extensions = BrowserToolbarButton()
    private let downloads = BrowserToolbarButton()
    private var pinnedExtensions: [BrowserPinnedExtension] = []
    private var extensionButtons: [String: BrowserToolbarButton] = [:]
    private var activeDownloads = 0
    private var committedURL = ""
    private let moveGrip = BrowserToolbarMoveGrip()
    private let addressWell = BrowserToolbarAddressWell()
    private var supportsPrivacy = false
    private var keepActive = false
    private var blockingEnabled = true
    private var blockedRequests = 0
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
        configure(extensions, symbol: "puzzlepiece.extension", label: "Extensions", action: #selector(openExtensions))
        extensions.setAccessibilityIdentifier("winmux.browser.extensions")
        configure(downloads, symbol: "arrow.down.circle", label: "Downloads", action: #selector(openDownloads))
        downloads.setAccessibilityIdentifier("winmux.browser.downloads")
        moveGrip.setAccessibilityIdentifier("winmux.browser.move")
        configure(more, symbol: "ellipsis", label: "Web window actions", action: #selector(showActions))

        address.placeholderString = "Search or enter address"
        address.setAccessibilityLabel("Page address")
        address.setAccessibilityIdentifier("winmux.browser.address")
        address.font = .systemFont(ofSize: 12)
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
        address.onFocus = { [weak self] in self?.autocomplete.beginEditing() }
        addressWell.field = address
        addressWell.addSubview(address)

        moveGrip.onDrag = { [weak self] phase, point in self?.onDrag?(phase, point) }
        moveGrip.onClick = { [weak self] in self?.onAction?(.focusPage) }
        for view in [back, forward, reload, addressWell, extensions, downloads, more, moveGrip] {
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
        // The grip owns a fixed corner target. Extra width belongs to the URL,
        // so the icon never drifts toward the middle of a wide header.
        moveGrip.frame = .init(x: right - 24, y: 0, width: 24, height: bounds.height)
        right -= 28
        extensions.isHidden = bounds.width < 420
        downloads.isHidden = bounds.width < 460
        for button in [more, downloads, extensions] where !button.isHidden {
            button.frame = .init(x: right - 22, y: y, width: 22, height: controlHeight)
            right -= 26
        }
        let visiblePinCount = min(pinnedExtensions.count, max(0, Int((right - left - 144) / 26)))
        for (index, item) in pinnedExtensions.enumerated().reversed() {
            guard let button = extensionButtons[item.id] else { continue }
            button.isHidden = index >= visiblePinCount
            if !button.isHidden {
                button.frame = .init(x: right - 22, y: y, width: 22, height: controlHeight)
                right -= 26
            }
        }
        addressWell.frame = .init(x: left, y: (bounds.height - ChromeControlToken.addressHeight) / 2,
                                 width: max(0, right - left), height: ChromeControlToken.addressHeight)
        addressWell.needsLayout = true
        autocomplete.reposition()
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
        committedURL = item.url
        updatePinnedExtensions(item.supportsToolbarActions ? item.pinnedExtensions : [], enabled: item.controlsEnabled)
        if activeDownloads != item.activeDownloads {
            activeDownloads = item.activeDownloads
            let label = activeDownloads == 0 ? "Downloads" : "Downloads — \(activeDownloads) in progress"
            downloads.image = NSImage(systemSymbolName: activeDownloads > 0 ? "arrow.down.circle.fill" : "arrow.down.circle", accessibilityDescription: label)
            downloads.toolTip = label
            downloads.setAccessibilityLabel(label)
            downloads.contentTintColor = activeDownloads > 0 ? .labelColor : .secondaryLabelColor
        }
        extensions.isEnabled = item.controlsEnabled
        downloads.isEnabled = item.controlsEnabled
        supportsPrivacy = item.supportsPrivacy
        keepActive = item.keepActive
        blockingEnabled = item.blockingEnabled
        blockedRequests = item.blockedRequests
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
            ("Downloads", #selector(openDownloads)), ("Manage Extensions…", #selector(manageExtensions)),
            ("New web window", #selector(openNewTab)),
            ("Keep Active", #selector(toggleKeepActive)),
            ("Block Ads and Trackers on This Site", #selector(toggleSiteBlocking)),
            ("Privacy Settings…", #selector(openPrivacySettings)),
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
        case #selector(toggleKeepActive):
            menuItem.state = keepActive ? .on : .off
            return controlsEnabled && supportsPrivacy
        case #selector(toggleSiteBlocking):
            menuItem.state = blockingEnabled ? .on : .off
            menuItem.title = "Block Ads and Trackers on This Site (\(blockedRequests) blocked)"
            return controlsEnabled && supportsPrivacy
        case #selector(openPrivacySettings): return controlsEnabled && supportsPrivacy
        case #selector(goBack): return controlsEnabled && canGoBack
        case #selector(goForward): return controlsEnabled && canGoForward
        case #selector(reloadOrStop):
            menuItem.title = isLoading ? "Stop loading" : "Reload page"
            return controlsEnabled
        case #selector(openExtensions), #selector(openDownloads), #selector(manageExtensions), #selector(openNewTab), #selector(minimizePage), #selector(zoomPage): return controlsEnabled
        case #selector(unpinExtension(_:)):
            return controlsEnabled && pinnedExtensions.contains { $0.id == menuItem.representedObject as? String && $0.canUnpin }
        default: return true
        }
    }

    @objc private func goBack() { onAction?(.back) }
    @objc private func goForward() { onAction?(.forward) }
    @objc private func reloadOrStop() { onAction?(isLoading ? .stop : .reload) }
    @objc private func openExtensions() { onAction?(.extensions) }
    @objc private func openDownloads() { onAction?(.downloads) }
    @objc private func manageExtensions() { onAction?(.manageExtensions) }
    @objc private func invokeExtension(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onAction?(.extensionAction(id)) }
    }
    @objc private func unpinExtension(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onAction?(.unpinExtension(id)) }
    }

    private func updatePinnedExtensions(_ items: [BrowserPinnedExtension], enabled: Bool) {
        defer {
            for item in items { extensionButtons[item.id]?.isEnabled = enabled && item.isEnabled }
        }
        guard pinnedExtensions != items else { return }
        let live = Set(items.map(\.id))
        for id in Array(extensionButtons.keys) where !live.contains(id) {
            extensionButtons.removeValue(forKey: id)?.removeFromSuperview()
        }
        for item in items {
            let button = extensionButtons[item.id] ?? BrowserToolbarButton()
            if extensionButtons[item.id] == nil {
                configure(button, symbol: "puzzlepiece.extension", label: item.title, action: #selector(invokeExtension(_:)))
                button.identifier = .init(item.id)
                button.setAccessibilityIdentifier("winmux.browser.extension." + item.id)
                addSubview(button)
                extensionButtons[item.id] = button
            }
            button.image = item.iconPNGBase64.flatMap { BrowserToolbarIconCache.shared.image(for: $0) }
                ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: item.title)
            button.toolTip = item.title
            button.setAccessibilityLabel(item.title)
            let context = NSMenu()
            if item.canUnpin {
                let unpin = NSMenuItem(title: "Unpin from Toolbar", action: #selector(unpinExtension(_:)), keyEquivalent: "")
                unpin.target = self; unpin.representedObject = item.id
                context.addItem(unpin)
            }
            let manage = NSMenuItem(title: "Manage Extensions…", action: #selector(manageExtensions), keyEquivalent: "")
            manage.target = self; context.addItem(manage)
            button.menu = context
        }
        pinnedExtensions = items
        needsLayout = true
    }
    @objc private func toggleKeepActive() { onAction?(.toggleKeepActive) }
    @objc private func toggleSiteBlocking() { onAction?(.toggleSiteBlocking) }
    @objc private func openPrivacySettings() { onAction?(.privacySettings) }
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
        (address.currentEditor() as? NSTextView)?.allowsUndo = true
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        autocomplete.dismiss()
        addressWell.isEditing = false
        address.textColor = .secondaryLabelColor
        address.stringValue = committedURL
    }

    func controlTextDidChange(_ notification: Notification) { autocomplete.textChanged() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        if autocomplete.command(commandSelector, editor: textView) { return true }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let input = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty else { NSSound.beep(); return true }
            onAction?(.navigate(input))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            autocomplete.dismiss()
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
            NSColor.labelColor.withAlphaComponent(ChromeControlToken.hoverOpacity).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
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
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                                xRadius: ChromeControlToken.controlRadius, yRadius: ChromeControlToken.controlRadius)
        let fill = isEditing ? NSColor.textBackgroundColor : NSColor.labelColor.withAlphaComponent(isHovered ? 0.08 : 0.045)
        fill.setFill()
        shape.fill()
        if isEditing {
            NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.75).setStroke()
            shape.lineWidth = ChromeControlToken.focusRingWidth
            shape.stroke()
        } else {
            NSColor.labelColor.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.55 : 0.07).setStroke()
            shape.lineWidth = 0.5
            shape.stroke()
        }
    }
}

final class BrowserToolbarAddressField: NSTextField {
    var onFocus: (() -> Void)?
    override func selectText(_ sender: Any?) {
        super.selectText(sender)
        onFocus?()
    }
    override func mouseDown(with event: NSEvent) {
        let wasEditing = currentEditor() != nil
        super.mouseDown(with: event)
        if !wasEditing, event.clickCount == 1 { selectText(nil) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let editor = currentEditor() as? NSTextView,
           Self.performEditingShortcut(with: event, in: editor, sender: self) { return true }
        return super.performKeyEquivalent(with: event)
    }

    static func performEditingShortcut(with event: NSEvent, in editor: NSTextView, sender: Any?) -> Bool {
        guard let action = editingAction(for: event) else { return false }
        // NSTextView does not implement undo:/redo:. Its undo manager owns
        // those commands; sending the selectors directly raises an exception.
        if action == Selector("undo:") {
            if let manager = editor.undoManager, manager.canUndo { manager.undo() }
            return true
        }
        if action == Selector("redo:") {
            if let manager = editor.undoManager, manager.canRedo { manager.redo() }
            return true
        }
        return NSApp.sendAction(action, to: editor, from: sender)
    }

    static func editingAction(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard flags == .command || flags == [.command, .shift] else { return nil }
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags.contains(.shift) { return key == "z" ? Selector("redo:") : nil }
        switch key {
        case "a": return #selector(NSText.selectAll(_:))
        case "c": return #selector(NSText.copy(_:))
        case "v": return #selector(NSText.paste(_:))
        case "x": return #selector(NSText.cut(_:))
        case "z": return Selector("undo:")
        default: return nil
        }
    }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

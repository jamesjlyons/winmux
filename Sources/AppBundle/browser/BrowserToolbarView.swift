import AppKit

@MainActor
final class BrowserToolbarView: NSView, NSTextFieldDelegate {
    let address = BrowserToolbarAddressField(string: "")
    var onAction: ((BrowserToolbarAction) -> Void)?
    var onCancelAddress: (() -> Void)?
    private let back = BrowserToolbarButton()
    private let forward = BrowserToolbarButton()
    private let reload = BrowserToolbarButton()
    private let extensions = BrowserToolbarButton()
    private let newTab = BrowserToolbarButton()
    private let close = BrowserToolbarButton()
    private let resizeGrip = BrowserToolbarResizeGrip()
    private var isLoading = false
    private var focused = false

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
        configure(back, symbol: "chevron.left", label: "Back", action: #selector(goBack))
        configure(forward, symbol: "chevron.right", label: "Forward", action: #selector(goForward))
        configure(reload, symbol: "arrow.clockwise", label: "Reload page", action: #selector(reloadOrStop))
        configure(extensions, symbol: "puzzlepiece.extension", label: "Extensions", action: #selector(openExtensions))
        configure(newTab, symbol: "plus", label: "New web window", action: #selector(openNewTab))
        configure(close, symbol: "xmark", label: "Close web window", action: #selector(closePage))

        address.placeholderString = "Enter URL or search"
        address.setAccessibilityLabel("Page address")
        address.setAccessibilityIdentifier("winmux.browser.address")
        address.font = .systemFont(ofSize: 12)
        address.controlSize = .small
        address.isBezeled = true
        address.bezelStyle = .roundedBezel
        address.drawsBackground = true
        address.backgroundColor = .controlBackgroundColor
        address.lineBreakMode = .byTruncatingMiddle
        address.usesSingleLineMode = true
        address.cell?.isScrollable = true
        address.cell?.wraps = false
        address.delegate = self
        address.translatesAutoresizingMaskIntoConstraints = false
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        resizeGrip.onResize = { [weak self] width, height in
            self?.onAction?(.resize(width: width, height: height))
        }
        resizeGrip.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [back, forward, reload, address, extensions, newTab, close, resizeGrip])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let resizeMenu = NSMenu(title: "Web window")
        for (title, action) in [
            ("Make Wider", #selector(makeWider)), ("Make Narrower", #selector(makeNarrower)),
            ("Make Taller", #selector(makeTaller)), ("Make Shorter", #selector(makeShorter)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            resizeMenu.addItem(item)
        }
        menu = resizeMenu
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            address.heightAnchor.constraint(equalToConstant: 26),
            address.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            resizeGrip.widthAnchor.constraint(equalToConstant: 20),
            resizeGrip.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        (focused ? NSColor.controlAccentColor.withAlphaComponent(0.65) : NSColor.separatorColor).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    func update(_ item: BrowserToolbarItem, preserveAddress: Bool) {
        isLoading = item.isLoading
        focused = item.isFocused
        back.isEnabled = item.controlsEnabled && item.canGoBack
        forward.isEnabled = item.controlsEnabled && item.canGoForward
        reload.isEnabled = item.controlsEnabled
        extensions.isEnabled = item.controlsEnabled
        newTab.isEnabled = item.controlsEnabled
        address.isEnabled = item.controlsEnabled
        if !preserveAddress { address.stringValue = item.url }
        let label = item.isLoading ? "Stop loading" : "Reload page"
        reload.image = NSImage(systemSymbolName: item.isLoading ? "xmark" : "arrow.clockwise", accessibilityDescription: label)
        reload.toolTip = label
        reload.setAccessibilityLabel(label)
        needsDisplay = true
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    @objc private func goBack() { onAction?(.back) }
    @objc private func goForward() { onAction?(.forward) }
    @objc private func reloadOrStop() { onAction?(isLoading ? .stop : .reload) }
    @objc private func openExtensions() { onAction?(.extensions) }
    @objc private func openNewTab() { onAction?(.newTab) }
    @objc private func closePage() { onAction?(.close) }
    @objc private func makeWider() { onAction?(.resizeWidth(40)) }
    @objc private func makeNarrower() { onAction?(.resizeWidth(-40)) }
    @objc private func makeTaller() { onAction?(.resizeHeight(40)) }
    @objc private func makeShorter() { onAction?(.resizeHeight(-40)) }

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
        default:
            return false
        }
    }
}

/// Navigation buttons act without taking the page's keyboard focus. Address entry
/// opts into key focus, so typing and standard text shortcuts use AppKit's editor.
private final class BrowserToolbarButton: NSButton {
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class BrowserToolbarAddressField: NSTextField {
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

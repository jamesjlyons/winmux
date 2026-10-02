import AppKit
import WorkspaceCore

@MainActor
final class BrowserToolbarPanel: NSPanelHud {
    let toolbarView = BrowserToolbarView()
    var onAction: ((BrowserToolbarAction) -> Void)?
    private var currentURL = ""
    private var currentHostWindowID: UInt32?
    private var wasFocused = false
    private var failurePopover: NSPopover?
    var isEditingAddress: Bool { isKeyWindow && toolbarView.address.currentEditor() != nil }

    init(surfaceID: SurfaceID) {
        super.init()
        identifier = .init("winmux-browser-toolbar-" + surfaceID.description)
        title = "Web page controls"
        hasShadow = false
        isFloatingPanel = false
        isExcludedFromWindowsMenu = true
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        applyWinMuxLayer(.windowChrome)
        contentView = toolbarView
        toolbarView.autoresizingMask = [.width, .height]
        toolbarView.onAction = { [weak self] action in
            guard let self else { return }
            self.failurePopover?.close()
            self.endAddressEditing()
            self.onAction?(action)
        }
        toolbarView.onCancelAddress = { [weak self] in
            guard let self else { return }
            self.toolbarView.address.stringValue = self.currentURL
            self.endAddressEditing()
            self.onAction?(.focusPage)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func update(_ item: BrowserToolbarItem) {
        currentURL = item.url
        toolbarView.update(item, preserveAddress: isEditingAddress)
        if frame != item.frame { setWindowTabChromePanelFrame(item.frame, on: self) }
        // Updating a background page's loading state must not raise its chrome
        // over a different app. Reorder only when focus or its native host changes.
        if !isVisible || item.hostWindowID != currentHostWindowID || (item.isFocused && !wasFocused) {
            if let host = item.hostWindowID { order(.above, relativeTo: Int(host)) }
            else { orderFrontRegardless() }
        }
        currentHostWindowID = item.hostWindowID
        wasFocused = item.isFocused
    }

    @discardableResult
    func focusAddress() -> Bool {
        guard toolbarView.address.isEnabled else { return false }
        failurePopover?.close()
        makeKeyAndOrderFront(nil)
        guard makeFirstResponder(toolbarView.address) else { return false }
        toolbarView.address.selectText(nil)
        return isEditingAddress
    }

    func endAddressEditing() {
        guard isEditingAddress else { return }
        makeFirstResponder(nil)
        resignKey()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "l" {
            return focusAddress()
        }
        return super.performKeyEquivalent(with: event)
    }

    func showFailure(_ message: String) {
        guard isVisible else { return }
        failurePopover?.close()
        let text = NSTextField(wrappingLabelWithString: message)
        text.font = .systemFont(ofSize: 12)
        text.translatesAutoresizingMaskIntoConstraints = false
        let content = NSViewController()
        content.view = NSView(frame: .init(x: 0, y: 0, width: 300, height: 72))
        content.view.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: content.view.leadingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: content.view.trailingAnchor, constant: -12),
            text.topAnchor.constraint(equalTo: content.view.topAnchor, constant: 12),
            text.bottomAnchor.constraint(lessThanOrEqualTo: content.view.bottomAnchor, constant: -12),
        ])
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        popover.contentSize = .init(width: 300, height: max(72, text.sizeThatFits(.init(width: 276, height: 200)).height + 24))
        failurePopover = popover
        popover.show(relativeTo: toolbarView.address.bounds, of: toolbarView.address, preferredEdge: .minY)
    }

    func dismiss() {
        failurePopover?.close()
        endAddressEditing()
        orderOut(nil)
    }
}

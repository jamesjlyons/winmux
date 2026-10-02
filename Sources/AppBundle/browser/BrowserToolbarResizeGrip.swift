import AppKit

/// A drag changes the shared layout through the controller only after release.
/// Positive deltas grow the page: right increases width, down increases height.
@MainActor
final class BrowserToolbarResizeGrip: NSView {
    var onResize: ((Int, Int) -> Void)?
    private var dragOrigin: NSPoint?

    init() {
        super.init(frame: .zero)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
        ])
        toolTip = "Drag to resize web window"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Resize web window")
        setAccessibilityHelp("Drag right or down to enlarge. Use arrow keys or the resize actions to adjust the size.")
        setAccessibilityCustomActions([
            .init(name: "Make wider", target: self, selector: #selector(makeWider)),
            .init(name: "Make narrower", target: self, selector: #selector(makeNarrower)),
            .init(name: "Make taller", target: self, selector: #selector(makeTaller)),
            .init(name: "Make shorter", target: self, selector: #selector(makeShorter)),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var needsPanelToBecomeKey: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = screenPoint(for: event)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        // AppKit tracks the gesture even when the pointer leaves the thin bar.
        // The page remains stable until the user's chosen size is committed.
    }

    override func mouseUp(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        dragOrigin = nil
        needsDisplay = true
        let destination = screenPoint(for: event)
        let width = Int((destination.x - origin.x).rounded())
        let height = Int((origin.y - destination.y).rounded())
        guard abs(width) > 2 || abs(height) > 2 else { return }
        onResize?(width, height)
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeKey()
        return window?.makeFirstResponder(self) ?? false
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onResize?(-40, 0)
        case 124: onResize?(40, 0)
        case 125: onResize?(0, 40)
        case 126: onResize?(0, -40)
        default: super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        if dragOrigin != nil {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        guard window?.firstResponder === self else { return }
        NSColor.keyboardFocusIndicatorColor.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).stroke()
    }

    @objc private func makeWider() -> Bool { onResize?(40, 0); return true }
    @objc private func makeNarrower() -> Bool { onResize?(-40, 0); return true }
    @objc private func makeTaller() -> Bool { onResize?(0, 40); return true }
    @objc private func makeShorter() -> Bool { onResize?(0, -40); return true }
}

import AppKit

/// A drag changes the shared layout through the controller only after release.
/// Positive deltas grow the page: right increases width, down increases height.
@MainActor
final class BrowserToolbarResizeGrip: NSView {
    var onResize: ((Int, Int) -> Void)?
    private var dragOrigin: NSPoint?
    private let icon = NSImageView()
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.alphaValue = 0.45
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 8),
            icon.heightAnchor.constraint(equalToConstant: 10),
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
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
        icon.alphaValue = isHovered || dragOrigin != nil || window?.firstResponder === self ? 1 : 0.45
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


/// Drag phases use the same normalized top-left screen coordinates as Winmux's
/// surface planner. Controls and address selection never enter this gesture.
enum BrowserToolbarDragPhase: Equatable {
    case began, changed, ended, cancelled
}

struct BrowserToolbarDragUpdate: Equatable {
    let phase: BrowserToolbarDragPhase
    let point: CGPoint
}

struct BrowserToolbarDragGesture {
    private(set) var origin: CGPoint?
    private var didBegin = false

    mutating func begin(at point: CGPoint) {
        origin = point
        didBegin = false
    }

    mutating func update(at point: CGPoint) -> [BrowserToolbarDragUpdate] {
        guard let origin else { return [] }
        if !didBegin {
            guard hypot(point.x - origin.x, point.y - origin.y) >= 4 else { return [] }
            didBegin = true
            return [.init(phase: .began, point: origin), .init(phase: .changed, point: point)]
        }
        return [.init(phase: .changed, point: point)]
    }

    /// True only for an actual drag; a click keeps its normal focus behavior.
    mutating func end() -> Bool {
        defer { origin = nil; didBegin = false }
        return didBegin
    }
}

@MainActor
func browserToolbarDragPoint(_ event: NSEvent, in view: NSView) -> CGPoint {
    normalizeAppKitScreenPoint(view.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation)
}

/// The page's trailing handle moves the whole Winmux surface. Resizing remains
/// available through the accessible window-actions menu.
@MainActor
final class BrowserToolbarMoveGrip: NSView {
    var onDrag: ((BrowserToolbarDragPhase, CGPoint) -> Void)?
    var onClick: (() -> Void)?
    private var dragGesture = BrowserToolbarDragGesture()
    private let icon = NSImageView()
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor
        icon.alphaValue = 0.45
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
        ])
        toolTip = "Drag to move or organize web window"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Move web window")
        setAccessibilityHelp("Drag the web window into a split, stack, or workspace.")
    }

    required init?(coder: NSCoder) { nil }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        dragGesture.begin(at: browserToolbarDragPoint(event, in: self))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        for update in dragGesture.update(at: browserToolbarDragPoint(event, in: self)) {
            NSCursor.closedHand.set()
            onDrag?(update.phase, update.point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragGesture.origin != nil else { return }
        let point = browserToolbarDragPoint(event, in: self)
        if dragGesture.end() { onDrag?(.ended, point) }
        else { onClick?() }
        NSCursor.openHand.set()
        needsDisplay = true
    }

    func cancelDrag() {
        if dragGesture.end() { onDrag?(.cancelled, .zero) }
        needsDisplay = true
    }

    override func cancelOperation(_ sender: Any?) { cancelDrag() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        icon.alphaValue = isHovered || dragGesture.origin != nil ? 1 : 0.45
    }
}

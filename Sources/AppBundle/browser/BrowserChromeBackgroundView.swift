import AppKit

/// Native titlebar material and a quiet outline, shared by the page and header.
/// Decorative views never intercept the toolbar's controls or drag gestures.
@MainActor
final class BrowserChromeBackgroundView: NSView {
    private let material = BrowserChromeMaterialView()
    private let outline: BrowserChromeOutlineView

    init(headerOnly: Bool) {
        outline = BrowserChromeOutlineView(headerOnly: headerOnly)
        super.init(frame: .zero)
        setAccessibilityElement(false)
        material.material = .titlebar
        // Each piece lives in a separate helper panel. Sample within that window
        // so a temporarily reordered app does not show through the page frame.
        material.blendingMode = .withinWindow
        material.state = .inactive
        material.setAccessibilityElement(false)
        material.autoresizingMask = [.width, .height]
        outline.autoresizingMask = [.width, .height]
        let radius = CGFloat(BrowserPageChromeGeometry.cornerRadius)
        let mask = NSImage(size: .init(width: radius * 2 + 1, height: headerOnly ? radius + 1 : radius * 2 + 1),
                           flipped: false) { rect in
            NSColor.white.setFill()
            browserChromeShape(in: rect, headerOnly: headerOnly).fill()
            return true
        }
        mask.capInsets = .init(top: radius, left: radius, bottom: headerOnly ? 0 : radius, right: radius)
        mask.resizingMode = .stretch
        material.maskImage = mask
        addSubview(material)
        addSubview(outline)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ item: BrowserToolbarItem) {
        material.isHidden = item.chromeColor != nil
        // The nonactivating helper panel is never the browser's key window.
        material.state = item.isFocused ? .active : .inactive
        outline.color = item.chromeColor
        outline.focused = item.isFocused
        outline.needsDisplay = true
    }

    override func layout() {
        super.layout()
        material.frame = bounds
        outline.frame = bounds
    }
}

@MainActor
private final class BrowserChromeMaterialView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class BrowserChromeOutlineView: NSView {
    let headerOnly: Bool
    var color: NSColor?
    var focused = false

    init(headerOnly: Bool) {
        self.headerOnly = headerOnly
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let shape = browserChromeShape(in: bounds.insetBy(dx: 0.5, dy: 0.5), headerOnly: headerOnly)
        if let color {
            color.withAlphaComponent(1).setFill()
            shape.fill()
        }
        NSColor.labelColor.withAlphaComponent(focused ? 0.08 : 0.04).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
        if headerOnly {
            NSColor.separatorColor.withAlphaComponent(0.35).setFill()
            let inset = CGFloat(BrowserPageChromeGeometry.shellInset)
            NSRect(x: inset, y: bounds.minY, width: max(0, bounds.width - inset * 2), height: 0.5).fill()
        }
    }
}

@MainActor
private func browserChromeShape(in rect: NSRect, headerOnly: Bool) -> NSBezierPath {
    let radius = min(CGFloat(BrowserPageChromeGeometry.cornerRadius), rect.width / 2, rect.height)
    if !headerOnly { return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius) }
    let shape = NSBezierPath()
    shape.move(to: .init(x: rect.minX, y: rect.minY))
    shape.line(to: .init(x: rect.minX, y: rect.maxY - radius))
    shape.appendArc(withCenter: .init(x: rect.minX + radius, y: rect.maxY - radius),
                    radius: radius, startAngle: 180, endAngle: 90, clockwise: true)
    shape.line(to: .init(x: rect.maxX - radius, y: rect.maxY))
    shape.appendArc(withCenter: .init(x: rect.maxX - radius, y: rect.maxY - radius),
                    radius: radius, startAngle: 90, endAngle: 0, clockwise: true)
    shape.line(to: .init(x: rect.maxX, y: rect.minY))
    return shape
}

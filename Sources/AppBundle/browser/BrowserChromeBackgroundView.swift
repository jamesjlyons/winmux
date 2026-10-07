import AppKit

/// One native glass surface and a quiet outline, shared by the page and header.
/// Decorative views never intercept the toolbar's controls or drag gestures.
@MainActor
final class BrowserChromeBackgroundView: NSView {
    private let material = BrowserChromeMaterialView()
    private var glass: NSView?
    private let headerOnly: Bool
    private let outline: BrowserChromeOutlineView
    private var currentColor: NSColor?
    private var currentFocus: Bool?

    init(headerOnly: Bool) {
        self.headerOnly = headerOnly
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
        if #available(macOS 26.0, *) {
            let effect = BrowserChromeGlassView()
            effect.style = .regular
            effect.cornerRadius = radius
            effect.setAccessibilityElement(false)
            glass = effect
            addSubview(effect)
            wantsLayer = true
            layer?.mask = CAShapeLayer()
        }
        addSubview(outline)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ item: BrowserToolbarItem) {
        guard currentColor != item.chromeColor || currentFocus != item.isFocused else { return }
        currentColor = item.chromeColor
        currentFocus = item.isFocused
        updateMaterial()
    }

    @objc private func accessibilityChanged() { updateMaterial() }

    private func updateMaterial() {
        let opaque = currentColor ?? (NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? ChromePalette.background : nil)
        material.isHidden = opaque != nil || glass != nil
        glass?.isHidden = opaque != nil
        // The nonactivating helper panel is never the browser's key window.
        material.state = currentFocus == true ? .active : .inactive
        outline.color = opaque
        outline.focused = currentFocus == true
        outline.highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        outline.needsDisplay = true
    }

    override func layout() {
        super.layout()
        material.frame = bounds
        if #available(macOS 26.0, *), let glass {
            let extensionHeight = headerOnly ? BrowserPageChromeGeometry.cornerRadius : 0
            glass.frame = .init(x: 0, y: -extensionHeight, width: bounds.width, height: bounds.height + extensionHeight)
            (layer?.mask as? CAShapeLayer)?.path = browserChromeShape(in: bounds, headerOnly: headerOnly).cgPath
        }
        outline.frame = bounds
    }
}

@available(macOS 26.0, *)
@MainActor
private final class BrowserChromeGlassView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
    var highContrast = false

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
        NSColor.labelColor.withAlphaComponent(highContrast ? 0.55 : focused ? GlassToken.borderOpacity : 0.05).setStroke()
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

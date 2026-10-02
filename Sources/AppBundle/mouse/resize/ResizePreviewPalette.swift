import AppKit

/// Resolve semantic colors each time layers are updated under their view's
/// effective appearance; caching CGColor here would freeze the first theme.
enum ResizePreviewPalette {
    static var fill: CGColor { mattePanelNSColor.cgColor }
    static var stroke: CGColor { NSColor.labelColor.withAlphaComponent(0.09).cgColor }
    static var tabGroupBar: CGColor { NSColor.labelColor.withAlphaComponent(0.055).cgColor }
    static var fallbackIconFill: CGColor { NSColor.labelColor.withAlphaComponent(0.12).cgColor }
    static var sourceFrameFill: CGColor { mattePanelNSColor.cgColor }
    static var sourceFrameStroke: CGColor { NSColor.labelColor.withAlphaComponent(0.09).cgColor }
    static var sourceMockTabFill: CGColor { NSColor.labelColor.withAlphaComponent(0.085).cgColor }
    static var sourceMockTabStroke: CGColor { NSColor.labelColor.withAlphaComponent(0.075).cgColor }
}

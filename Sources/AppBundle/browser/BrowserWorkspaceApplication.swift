import AppKit

/// AppKit omits some nonactivating panels from its default application window
/// list. Browser headers are interactive windows, so include them dynamically
/// without replacing AppKit's windows or changing which application is active.
@MainActor
public final class BrowserWorkspaceApplication: NSApplication {
    public override func accessibilityWindows() -> [Any]? {
        browserAccessibilityWindows(
            inherited: super.accessibilityWindows(),
            toolbarWindows: BrowserToolbarController.shared.accessibilityWindows)
    }
}

@MainActor
func browserAccessibilityWindows(inherited: [Any]?, toolbarWindows: [NSWindow]) -> [Any] {
    var result = inherited ?? []
    for toolbar in toolbarWindows where toolbar.isVisible && toolbar.isAccessibilityElement() {
        guard !result.contains(where: { ($0 as? NSWindow) === toolbar }) else { continue }
        result.append(toolbar)
    }
    return result
}

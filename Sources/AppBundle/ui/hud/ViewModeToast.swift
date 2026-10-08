import AppKit
import SwiftUI

@MainActor
final class ViewModeToastPanel: NSPanelHud {
    static let shared = ViewModeToastPanel()
    private var dismissal: Task<Void, Never>?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private override init() {
        super.init()
        applyWinMuxLayer(.overlay)
        ignoresMouseEvents = true
        hasShadow = false
    }

    static func toastFrame(in visible: Rect, screenTop: CGFloat) -> NSRect {
        NSRect(x: visible.topLeftX + (visible.width - 348) / 2,
               y: screenTop - visible.maxY + 32, width: 348, height: 88)
    }

    func show(mode: NewItemPlacement, dismissAfter: Duration = .seconds(2)) {
        dismissal?.cancel()
        contentView = NSHostingView(rootView: ViewModeToast(mode: mode))
        let visible = focus.workspace.workspaceMonitor.visibleRect
        let frame = Self.toastFrame(in: visible, screenTop: NSScreen.screens.first?.frame.maxY ?? 0)
        setFrame(frame, display: true)
        orderFrontRegardless()
        // No movement animation: immediate feedback also respects Reduce Motion.
        dismissal = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: dismissAfter) } catch { return }
            self?.orderOut(nil)
        }
    }
}

struct ViewModeToast: View {
    let mode: NewItemPlacement
    var surfaceStyle: ChromeStyle = .liquidGlass

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: mode == .newView ? "rectangle" : "rectangle.split.2x1")
                .font(.system(size: 23, weight: .medium))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(mode == .newView ? "Full view mode" : "Tiling mode")
                    .font(.system(size: 14, weight: .semibold))
                Text(mode == .newView ? "New items open in separate views" : "New items tile in the current view")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(width: 340, height: 80)
        .background(GlassSurface(shape: RoundedRectangle(cornerRadius: 22, style: .continuous), style: surfaceStyle))
        .padding(4)
    }
}

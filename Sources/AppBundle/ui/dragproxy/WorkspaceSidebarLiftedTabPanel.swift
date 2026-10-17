import AppKit
import QuartzCore
import SwiftUI

/// A full-size row above every sidebar section, including its close affordance.
/// The panel is moved directly so pointer tracking never inherits list easing.
@MainActor
final class WorkspaceSidebarLiftedTabPanel: NSPanelHud {
    static let shared = WorkspaceSidebarLiftedTabPanel()
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private var rowFrame = CGRect.zero

    override private init() {
        super.init()
        identifier = NSUserInterfaceItemIdentifier("WinMux.liftedSidebarTab")
        hasShadow = false
        isFloatingPanel = true
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        ignoresMouseEvents = true
        backgroundColor = .clear
        applyWinMuxLayer(.dragCursorProxy)
        level = NSWindow.Level(rawValue: WinMuxPanelLayer.workspaceSidebar.level.rawValue + 1)
        contentView = hosting
        hosting.autoresizingMask = [.width, .height]
    }

    func begin(surface: WorkspaceSidebarSurfaceItem, frame: CGRect, title: String, leadingInset: CGFloat, compact: Bool) {
        DisplayRefreshDriver.shared.remove(owner: self)
        hosting.rootView = AnyView(WorkspaceSidebarLiftedTabView(surface: surface, size: frame.size,
            title: title, leadingInset: leadingInset, compact: compact))
        move(to: frame)
        orderFrontRegardless()
    }

    func move(to frame: CGRect) {
        rowFrame = frame
        let padded = frame.insetBy(dx: -18, dy: -18)
        let screen = Rect(topLeftX: padded.minX, topLeftY: padded.minY,
            width: padded.width, height: padded.height).toAppKitScreenRect
        setFrame(screen, display: false, animate: false)
    }

    func settle(to target: CGRect, reduceMotion: Bool) {
        guard !reduceMotion else { move(to: target); return }
        let initial = rowFrame
        let start = CACurrentMediaTime()
        DisplayRefreshDriver.shared.add(owner: self) { [weak self] _ in
            guard let self else { return }
            let progress = min(1, (CACurrentMediaTime() - start) / 0.11)
            let eased = 1 - pow(1 - progress, 3)
            self.move(to: initial.offsetBy(dx: (target.minX - initial.minX) * eased,
                dy: (target.minY - initial.minY) * eased))
            if progress >= 1 { DisplayRefreshDriver.shared.remove(owner: self) }
        }
    }

    func hide() {
        DisplayRefreshDriver.shared.remove(owner: self)
        orderOut(nil)
        hosting.rootView = AnyView(EmptyView())
    }
}

struct WorkspaceSidebarLiftedTabView: View {
    let surface: WorkspaceSidebarSurfaceItem
    let size: CGSize
    var title: String? = nil
    var leadingInset: CGFloat = 0
    var compact = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var isDark: Bool { (config.workspaceSidebar.chromeColorScheme ?? colorScheme) == .dark }

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceSidebarWindowRow(title: title ?? surface.title, badge: nil, isFocused: true,
                rowHeight: size.height, isHovered: true, style: .window,
                appBundleIds: [surface.appBundleId], appBundlePaths: [surface.appBundlePath],
                favicons: [surface.iconPNGBase64], fallbackSystemImage: surface.isBrowser ? "globe" : "app",
                isSelected: true, isLoading: surface.isLoading, isFloating: surface.isFloating)
                .padding(.leading, leadingInset)
            if !compact {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 24, height: 24)
            }
        }
        .environment(\.workspaceSidebarExternalRowSelection, true)
        .environment(\.workspaceSidebarCompactRows, compact)
        .frame(width: size.width, height: size.height)
        .background {
            RoundedRectangle(cornerRadius: compact ? 8 : WorkspaceSidebarTabStyle.cornerRadius, style: .continuous)
                .fill(isDark ? ChromeSelectionPalette.sidebar.selectionColor(dark: true, focused: true) : Color(white: 0.97))
                .overlay {
                    RoundedRectangle(cornerRadius: compact ? 8 : WorkspaceSidebarTabStyle.cornerRadius, style: .continuous)
                        .strokeBorder(isDark ? ChromeSelectionPalette.sidebar.outlineColor(dark: true, focused: true,
                            increasedContrast: contrast == .increased) : Color.primary.opacity(0.12),
                            lineWidth: contrast == .increased ? 1 : 0.5)
                }
                .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
                .padding(.vertical, compact ? 0 : WorkspaceSidebarTabStyle.verticalInset)
        }
        .padding(18)
        .environment(\.colorScheme, config.workspaceSidebar.chromeColorScheme ?? colorScheme)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

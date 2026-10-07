import AppKit
import SwiftUI
import WorkspaceCore

/// Fixed content, rendered by the production chrome in a live compositor window.
/// The document bodies are fixtures, not captured browser or editor sessions.
@MainActor
public func renderWinMuxChromeRefreshProofImages(in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let originalStyle = config.workspaceSidebar.chromeStyle
    defer { config.workspaceSidebar.chromeStyle = originalStyle }
    config.workspaceSidebar.chromeStyle = .liquidGlass
    for light in [true, false] {
        try renderMarketingView(ChromeRefreshProofScene(light: light),
            to: directory.appendingPathComponent("chrome-\(light ? "light" : "dark").png"),
            size: .init(width: 1200, height: 760), colorScheme: light ? .light : .dark)
    }
}

private struct ChromeRefreshProofScene: View {
    let light: Bool
    private var snapshot: WorkspaceSidebarSnapshot {
        var result = MarketingFixtures.sidebarSnapshot
        result.visibleWidth = 240
        result.configuration.expandedWidth = 240
        result.configuration.showsClock = false
        result.configuration.chromeStyle = .liquidGlass
        return result
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: light
                ? [Color(red: 0.86, green: 0.80, blue: 0.94), Color(red: 0.94, green: 0.86, blue: 0.80)]
                : [Color(red: 0.15, green: 0.12, blue: 0.23), Color(red: 0.19, green: 0.20, blue: 0.26)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 16) {
                WorkspaceSidebarView(snapshot: snapshot)
                    .frame(width: 240)
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WinMux · Chrome comparison").font(.system(size: 20, weight: .semibold))
                        Text("Production controls · Fixed document fixtures").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 22)
                    VStack(spacing: 0) {
                        HStack(spacing: 4) {
                            ForEach(MarketingFixtures.codeTabStrip.tabs) { tab in
                                WindowTabItemView(tab: focusedTab(tab), width: 260, height: 26, isDragSource: false, isHovered: false)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(5)
                        .background {
                            GlassSurface(shape: UnevenRoundedRectangle(
                                topLeadingRadius: 14,
                                bottomLeadingRadius: 0,
                                bottomTrailingRadius: 0,
                                topTrailingRadius: 14,
                                style: .continuous
                            ))
                        }
                        document("Design workspace", subtitle: "Selected tab · Focus in this group", lines: [
                            "Sidebar and browser refinement", "Clear selection across every tab surface",
                            "Native materials, quieter controls, more breathing room"
                        ])
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    VStack(spacing: 0) {
                        ChromeRefreshToolbarProof()
                            .frame(height: BrowserToolbarController.height)
                        document("Reference library", subtitle: "Browser pane · example.com", lines: [
                            "Project documentation", "Interaction notes", "Release checklist"
                        ])
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tab states").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        proofRow("Focused item", focused: true)
                        proofRow("Selected in another pane", focused: false)
                        proofRow("Inactive item", focused: false)
                        proofRow("Hovered item", focused: false, hovered: true)
                    }
                    .padding(12)
                    .background { GlassSurface(shape: RoundedRectangle(cornerRadius: 14)) }
                    Spacer(minLength: 12)
                }
                .padding(.trailing, 24)
            }
        }
    }

    private func proofRow(_ title: String, focused: Bool, hovered: Bool = false) -> some View {
        WorkspaceSidebarWindowRow(title: title, badge: nil, isFocused: focused,
            rowHeight: workspaceSidebarWorkspaceRowHeight,
            isHovered: hovered, style: .window, appBundleIds: ["com.apple.Safari"], appBundlePaths: [nil],
            isSelected: title == "Selected in another pane")
    }

    private func focusedTab(_ tab: WindowTabItemViewModel) -> WindowTabItemViewModel {
        var result = tab
        result.isFocused = tab.isActive
        return result
    }

    private func document(_ title: String, subtitle: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 24, weight: .semibold))
            ForEach(lines, id: \.self) { Text($0).font(.system(size: 13)).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(light ? Color.white.opacity(0.96) : Color(white: 0.12))
    }
}

@MainActor
public func renderWinMuxChromeStateProofImages(in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for light in [true, false] {
        for opaque in [false, true] {
            let scene = ChromeStateProofScene(opaque: opaque)
            try renderMarketingView(scene,
                to: directory.appendingPathComponent("states-\(light ? "light" : "dark")-\(opaque ? "solid" : "glass").png"),
                size: .init(width: 440, height: 460), colorScheme: light ? .light : .dark)
        }
    }
}

private struct ChromeStateProofScene: View {
    let opaque: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(opaque ? "Solid theme · Opaque chrome" : "Selection and browser states")
                .font(.system(size: 14, weight: .semibold))
            VStack(spacing: 4) {
                row("Selected and focused", selected: true, focused: true)
                row("Selected in another pane", selected: true)
                row("Keyboard search target", keyboard: true)
                row("Loading documentation", loading: true)
                row("A long inactive title that should truncate without shifting the icon")
            }
            .padding(10)
            .background { GlassSurface(shape: RoundedRectangle(cornerRadius: 14), style: opaque ? .solid : .liquidGlass) }
            Text("Pinned items").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            WorkspaceSidebarPinGrid(workspace: pins, projects: [], isCompact: false,
                availableWidth: 320, showsDropWell: false, actions: .init())
            Text("Closed launchers remain available; loading keeps a stable footprint.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(22)
        .background { GlassSurface(shape: Rectangle(), style: opaque ? .solid : .liquidGlass) }
    }

    private func row(_ title: String, selected: Bool = false, focused: Bool = false,
                     keyboard: Bool = false, loading: Bool = false) -> some View {
        WorkspaceSidebarWindowRow(title: title, badge: nil, isFocused: focused,
            rowHeight: workspaceSidebarWorkspaceRowHeight, isHovered: false, style: .window,
            appBundleIds: ["com.apple.Safari"], appBundlePaths: [nil],
            isSelected: selected, isKeyboardTarget: keyboard, isLoading: loading)
    }

    private var pins: WorkspaceSidebarWorkspaceViewModel {
        var result = MarketingFixtures.sidebarSnapshot.workspaces[0]
        result.isPinnedGroup = true
        result.pins = [
            pin("Selected", open: true, focused: true),
            pin("Loading", open: true, loading: true),
            pin("Closed", open: false),
        ]
        return result
    }

    private func pin(_ title: String, open: Bool, focused: Bool = false, loading: Bool = false) -> WorkspaceSidebarPinViewModel {
        .init(id: UUID(), workspaceName: "proof", title: title, bundleIdentifier: "com.apple.Safari",
            bundlePath: nil, iconPNGBase64: nil, surfaceID: nil, isFocused: focused,
            isOpen: open, isLoading: loading, isUnavailable: false, isBrowser: true)
    }
}

private struct ChromeRefreshToolbarProof: NSViewRepresentable {
    func makeNSView(context: Context) -> BrowserToolbarView { BrowserToolbarView() }
    func updateNSView(_ view: BrowserToolbarView, context: Context) {
        view.update(.init(surfaceID: .browserTab(profile: UUID(), tab: UUID()),
            frame: .zero, url: "https://example.com/reference", canGoBack: true,
            canGoForward: false, isLoading: false, isFocused: false), preserveAddress: false)
    }
}

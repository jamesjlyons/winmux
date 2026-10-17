import AppKit
import SwiftUI
import WorkspaceCore

/// Production sidebar and row states, with fixed content and no live workspace actions.
@MainActor
public func renderSidebarPillProof(in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for light in [true, false] {
        try renderMarketingView(SidebarPillProofScene(),
            to: directory.appendingPathComponent("sidebar-\(light ? "light" : "dark").png"),
            size: .init(width: 600, height: 560), colorScheme: light ? .light : .dark)
    }
}

private struct SidebarPillProofScene: View {
    @Environment(\.colorScheme) private var colorScheme
    private let surfaceIDs = (0..<7).map { _ in SurfaceID.nativeWindow(UUID()) }

    private var snapshot: WorkspaceSidebarSnapshot {
        var result = MarketingFixtures.sidebarSnapshot
        let monitor = result.workspaces[0].monitorScopeId
        func item(_ index: Int, _ title: String, focused: Bool = false) -> WorkspaceSidebarItemViewModel {
            .init(kind: .surface(.init(surfaceID: surfaceIDs[index], title: title,
                appName: "Safari", isFocused: focused, appBundleId: "com.apple.Safari")))
        }
        func workspace(_ name: String, _ title: String, _ items: [WorkspaceSidebarItemViewModel],
                       focused: Bool = false) -> WorkspaceSidebarWorkspaceViewModel {
            .init(name: name, projectId: result.activeProjectId, displayName: title, sidebarLabel: "",
                isGeneratedName: true, monitorScopeId: monitor, monitorName: nil,
                isFocused: focused, isVisible: focused, items: items)
        }
        result.workspaces = [
            workspace("notes", "Project notes", [item(0, "Project notes")]),
            workspace("research", "Website", [item(1, "Reference library", focused: true),
                item(2, "Release checklist"), item(3, "Research and documentation")], focused: true),
            workspace("drafts", "Design explorations", [item(4, "Design explorations")]),
        ]
        result.configuration.expandedWidth = 240
        result.configuration.collapsedWidth = 40
        result.configuration.showsBrowserControls = true
        result.configuration.showsClock = false
        result.configuration.chromeStyle = .solid
        result.configuration.solidChromeColor = .system
        result.visibleWidth = 240
        return result
    }

    private var batchSelection: TabSelectionContext {
        let pane = SurfacePane.surface(surfaceIDs[6])
        var state = TabMultiSelection<SurfacePane>()
        state.click(pane, order: [pane], shift: false, command: true)
        return .init(state: state, order: [pane])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("WinMux · Sidebar refinement").font(.system(size: 17, weight: .semibold))
            Text("Production views · Fixed example content").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 32) {
                WorkspaceSidebarView(snapshot: snapshot, actions: .init(send: { _ in }))
                    .frame(width: 240)
                VStack(alignment: .leading, spacing: 16) {
                    Text("Tab states").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    VStack(spacing: 2) {
                        row(0, "Resting tab", state: .init())
                        row(1, "Hover", state: .init(isHovered: true))
                        row(2, "Focused tab", state: .init(isFocused: true))
                        row(3, "Focused + hover", state: .init(isFocused: true, isHovered: true))
                        row(4, "Selected in another stack", state: .init(isSelected: true))
                        row(5, "Keyboard target", state: .init(isKeyboardTarget: true))
                        row(6, "Batch selection", state: .init())
                            .tabSelectionItem(.surface(surfaceIDs[6]))
                    }
                    .modifier(WorkspaceSidebarTabMotionScope())
                    .environment(\.tabSelection, batchSelection)
                    Text("The focused tab keeps the strongest pill. Hover, keyboard navigation and batch selection remain distinct.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(width: 240)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colorScheme == .dark ? WorkspaceSidebarTabStyle.darkBackground : Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ index: Int, _ title: String, state: ChromeItemState) -> some View {
        WorkspaceSidebarWindowRow(title: title, badge: nil, isFocused: state.isFocused,
            rowHeight: workspaceSidebarWorkspaceRowHeight, isHovered: state.isHovered,
            style: .window, appBundleIds: ["com.apple.Safari"], appBundlePaths: [],
            isSelected: state.isSelected, isKeyboardTarget: state.isKeyboardTarget,
            selectionID: surfaceIDs[index].description)
            .modifier(WorkspaceSidebarHoverClose(surface: surfaceIDs[index], title: title,
                actions: .init(send: { _ in }), selection: state))
    }
}

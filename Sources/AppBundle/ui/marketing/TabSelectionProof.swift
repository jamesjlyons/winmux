import AppKit
import SwiftUI
import WorkspaceCore

@MainActor
public func renderTabSelectionProof(in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for light in [true, false] {
        try renderMarketingView(TabSelectionProofScene(),
            to: directory.appendingPathComponent("multi-selection-\(light ? "light" : "dark").png"),
            size: .init(width: 760, height: 280), colorScheme: light ? .light : .dark)
    }
}

private struct TabSelectionProofScene: View {
    private let panes = (0..<4).map { _ in SurfacePane.surface(.browserTab(profile: UUID(), tab: UUID())) }
    private let titles = ["Reference library", "Project notes", "Release checklist", "Research"]
    private var selection: TabSelectionContext {
        var state = TabMultiSelection<SurfacePane>()
        state.click(panes[0], order: panes, shift: false, command: false)
        state.click(panes[2], order: panes, shift: true, command: false)
        return .init(state: state, order: panes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Multiple tab selection · Production component fixture").font(.system(size: 13, weight: .medium))
            HStack(spacing: 4) {
                ForEach(0..<4) { index in
                    StackTabLabel(title: titles[index], appName: "Browser", bundleID: nil, bundlePath: nil,
                        symbol: "globe", isActive: index == 0, isFocused: index == 0,
                        width: 172, height: 26, isDragSource: false, isHovered: false)
                        .tabSelectionItem(panes[index])
                }
            }.padding(5).background { GlassSurface(shape: RoundedRectangle(cornerRadius: 14)) }
            HStack(alignment: .top, spacing: 28) {
                VStack(spacing: 3) {
                    ForEach(0..<4) { index in
                        WorkspaceSidebarWindowRow(title: titles[index], badge: nil, isFocused: index == 0,
                            rowHeight: 28, isHovered: false, style: .window, appBundleIds: [], appBundlePaths: [],
                            fallbackSystemImage: "globe", isSelected: index == 0)
                            .tabSelectionItem(panes[index])
                    }
                }.frame(width: 260)
                Text("3 tabs selected\n\nShift-click a range. Cmd-click to toggle individual tabs. Right-click any selected tab for batch actions.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.tabSelection, selection)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

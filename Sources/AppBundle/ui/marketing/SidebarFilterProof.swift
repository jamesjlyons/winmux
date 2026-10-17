import AppKit
import SwiftUI
import WorkspaceCore

/// Exercises the production filter, arrangement rows and shared selection layer.
@MainActor
public func renderSidebarFilterProof(in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for light in [true, false] {
        let scene = HStack(alignment: .top, spacing: 20) {
            SidebarFilterProofColumn(model: .init(), heading: "All tabs")
            SidebarFilterProofColumn(model: .init(collapsed: true), heading: "Website collapsed")
            SidebarFilterProofColumn(model: .init(query: "fish"), heading: "Filter: fish")
            SidebarFilterProofColumn(model: .init(query: "release"), heading: "Filter: release")
        }.padding(24).allowsHitTesting(false)
            .background(light ? Color(nsColor: .windowBackgroundColor) : WorkspaceSidebarTabStyle.darkBackground)
        try renderMarketingView(scene, to: directory.appendingPathComponent("filter-\(light ? "light" : "dark").png"),
            size: .init(width: 1068, height: 530), colorScheme: light ? .light : .dark)
    }
    for milliseconds in [30, 90, 180, 320] {
        let model = SidebarFilterProofModel()
        let scene = SidebarFilterProofColumn(model: model, heading: "Filtering · fish")
            .allowsHitTesting(false)
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.query = "fish" } }
        try renderMarketingView(scene, to: directory.appendingPathComponent("filter-\(milliseconds)ms.png"),
            size: .init(width: 240, height: 480), colorScheme: .dark,
            settleDuration: 0.4 + Double(milliseconds) / 1000)
    }
}

@MainActor
public func recordSidebarFilterDemo(to output: URL) throws {
    let model = SidebarFilterProofModel()
    let scene = HStack(spacing: 24) {
        SidebarFilterProofColumn(model: model, heading: "Light").environment(\.colorScheme, .light)
        SidebarFilterProofColumn(model: model, heading: "Dark").environment(\.colorScheme, .dark)
    }.padding(24).background(Color(chromeHex: "#242424")).allowsHitTesting(false)
    let events: [(TimeInterval, () -> Void)] = [
        (0.8, { model.query = "f" }),
        (1.1, { model.query = "fish" }),
        (2.5, { model.query = "release" }),
        (3.8, { model.query = "" }),
        (4.8, { withAnimation(WorkspaceSidebarTabMotion.movement) { model.collapsed = true } }),
        (6.0, { model.query = "fish" }),
        (7.3, { model.query = "" }),
        (8.4, { withAnimation(WorkspaceSidebarTabMotion.movement) { model.collapsed = false } }),
        (9.5, { model.selectedIndex = 2 }),
        (10.7, { model.selectedIndex = 6 }),
        (12.0, { model.selectedIndex = 0 }),
    ]
    var next = 0
    try recordMarketingVideo(scene, to: output, size: .init(width: 552, height: 540), duration: 13.3) { elapsed in
        while next < events.count, elapsed >= events[next].0 { events[next].1(); next += 1 }
    }
}

@MainActor
private final class SidebarFilterProofModel: ObservableObject {
    @Published var query: String
    @Published var collapsed: Bool
    @Published var selectedIndex = 1
    let ids = (0..<7).map { _ in SurfaceID.nativeWindow(UUID()) }

    init(query: String = "", collapsed: Bool = false) { self.query = query; self.collapsed = collapsed }

    var workspaces: [WorkspaceSidebarWorkspaceViewModel] {
        let groups = [("Notes", ["Project notes"]),
                      ("Website", ["fish · replay-web", "Release checklist", "Research and documentation"]),
                      ("Studio", ["fish · experiments", "Design explorations"]),
                      ("Archive", ["Archived releases"])]
        var offset = 0
        return groups.map { name, titles in
            let items = titles.enumerated().map { index, title in
                WorkspaceSidebarItemViewModel(kind: .surface(.init(surfaceID: ids[offset + index], title: title,
                    appName: "Safari", isFocused: selectedIndex == offset + index, appBundleId: "com.apple.Safari")))
            }
            let active = (offset..<offset + titles.count).contains(selectedIndex)
            offset += titles.count
            return .init(name: name, projectId: workspaceProjectDefaultId,
                displayName: titles.count == 1 ? titles[0] : name, sidebarLabel: "", isGeneratedName: true,
                monitorScopeId: "sidebar-proof", monitorName: nil, isFocused: active, isVisible: active, items: items)
        }
    }
}

private struct SidebarFilterProofColumn: View {
    @ObservedObject var model: SidebarFilterProofModel
    let heading: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var layout: WorkspaceSidebarConfiguration {
        var layout = MarketingFixtures.sidebarSnapshot.configuration
        layout.expandedWidth = 240
        layout.collapsedWidth = 40
        layout.menuBarStyle = false
        return layout
    }

    var body: some View {
        let filtered = workspaceSidebarFilteredWorkspacesByProject([workspaceProjectDefaultId: model.workspaces],
            projects: [], query: model.query)[workspaceProjectDefaultId] ?? []
        VStack(alignment: .leading, spacing: 12) {
            Text(heading).font(.system(size: 13, weight: .medium)).padding(.horizontal, 10)
            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: workspaceSidebarSectionGap) {
                        ForEach(filtered) { workspace in
                            WorkspaceSidebarWorkspaceSection(workspace: workspace,
                                targetMonitorScopeId: "sidebar-proof", dragPreview: nil,
                                expansionProgress: 1, layout: layout, emitsDropTarget: false,
                                isFromOtherDisplay: false, isInUseOnOtherDisplay: false, isOnFocusedMonitor: true,
                                allowsWorkspaceActivation: true, isPinnedActiveWorkspace: false,
                                isActiveOnTargetMonitor: workspace.isFocused, projectContextLabel: nil, projectContextColor: nil,
                                renamingWorkspaceName: .constant(nil), renamingWorkspaceText: .constant(""),
                                onBeginRenameWorkspace: {}, onCommitRenameWorkspace: {}, onCancelRenameWorkspace: {},
                                selectedSearchTarget: model.query.isEmpty ? nil : workspaceSidebarSearchSelections(workspaces: filtered).first,
                                isSearchFiltering: !model.query.isEmpty, activeInUseOverrideWorkspaceName: .constant(nil),
                                actions: .init(), isViewExpanded: workspace.name == "Website"
                                    ? Binding(get: { !model.collapsed }, set: { model.collapsed = !$0 }) : .constant(true))
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 10)
                    .animation(reduceMotion ? nil : WorkspaceSidebarTabMotion.filtering, value: model.query)
                    .animation(reduceMotion ? nil : WorkspaceSidebarTabMotion.movement,
                        value: filtered.flatMap { [$0.id] + $0.items.flatMap(\.tabLayoutIdentity) })
                    .modifier(WorkspaceSidebarTabMotionScope(viewportHeight: viewport.size.height))
                }.coordinateSpace(name: "workspaceSidebarTabViewport")
            }
            Text(model.query.isEmpty ? "Showing all tabs" : "Filter: \(model.query)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(12)
        }
        .padding(.top, 12).frame(width: 240)
        .background(scheme == .dark ? WorkspaceSidebarTabStyle.darkBackground : Color(nsColor: .windowBackgroundColor))
        .environment(\.workspaceSidebarSearchQuery, model.query)
    }
}

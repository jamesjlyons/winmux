import AppKit
import SwiftUI
import WorkspaceCore

/// Exercises the production sidebar without launching the manager or user tabs.
@MainActor
public func renderSidebarTabMotionProof(in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for light in [true, false] {
        for width: CGFloat in [240, 140, 120, 40] {
            let model = SidebarTabMotionProofModel(width: width)
            try renderMarketingView(SidebarTabMotionProofView(model: model),
                to: directory.appendingPathComponent("tabs-\(Int(width))-\(light ? "light" : "dark").png"),
                size: .init(width: width, height: 460), colorScheme: light ? .light : .dark)
        }
    }
    for interrupted in [false, true] {
        for milliseconds in [20, 70, 170, 290, 420] {
            let model = SidebarTabMotionProofModel(width: 240)
            let view = SidebarTabMotionProofView(model: model).onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.select(3) }
                if interrupted {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.39) { model.select(1) }
                }
            }
            try renderMarketingView(view,
                to: directory.appendingPathComponent("\(interrupted ? "redirect" : "switch")-\(milliseconds)ms.png"),
                size: .init(width: 240, height: 460), colorScheme: .light,
                settleDuration: 0.3 + Double(milliseconds) / 1_000)
        }
    }
}

@MainActor
private final class SidebarTabMotionProofModel: ObservableObject {
    @Published var snapshot: WorkspaceSidebarSnapshot
    @Published var caption = "One continuous selection shape"

    init(width: CGFloat) {
        var snapshot = MarketingFixtures.sidebarSnapshot
        let monitor = snapshot.workspaces[0].monitorScopeId
        let titles = ["Reference library", "Project notes", "Release checklist", "Research and documentation"]
        snapshot.workspaces = titles.enumerated().map { index, title in
            .init(name: "tab-motion-\(index)", projectId: snapshot.activeProjectId,
                  displayName: title, sidebarLabel: "", isGeneratedName: true,
                  monitorScopeId: monitor, monitorName: nil, isFocused: index == 0, isVisible: index == 0,
                  items: [.init(kind: .surface(.init(surfaceID: .browserTab(profile: UUID(), tab: UUID()),
                      title: title, appName: "Browser", isFocused: index == 0)))])
        }
        snapshot.configuration.showsBrowserControls = true
        snapshot.configuration.showsClock = false
        snapshot.configuration.expandedWidth = width < 120 ? 240 : width
        snapshot.configuration.collapsedWidth = 40
        snapshot.configuration.chromeStyle = .solid
        snapshot.configuration.solidChromeColor = .system
        snapshot.visibleWidth = width
        self.snapshot = snapshot
    }

    func select(_ selected: Int) {
        snapshot.workspaces = snapshot.workspaces.enumerated().map { index, old in
            let surface = old.viewSurfaces[0]
            return .init(name: old.name, projectId: old.projectId, displayName: old.displayName,
                sidebarLabel: old.sidebarLabel, isGeneratedName: old.isGeneratedName,
                monitorScopeId: old.monitorScopeId, monitorName: old.monitorName,
                isFocused: index == selected, isVisible: index == selected,
                items: [.init(kind: .surface(.init(surfaceID: surface.surfaceID, title: surface.title,
                    appName: surface.appName, isFocused: index == selected)))])
        }
    }

    func addTab() {
        let template = snapshot.workspaces[0]
        snapshot.workspaces.append(.init(name: "tab-motion-new", projectId: template.projectId,
            displayName: "New tab", sidebarLabel: "", isGeneratedName: true,
            monitorScopeId: template.monitorScopeId, monitorName: nil, isFocused: false, isVisible: false,
            items: [.init(kind: .surface(.init(surfaceID: .browserTab(profile: UUID(), tab: UUID()),
                title: "New tab", appName: "Browser", isFocused: false)))]))
        select(snapshot.workspaces.count - 1)
    }

    func closeTab(at index: Int) {
        let selectedName = snapshot.workspaces.first(where: \.isFocused)?.name
        snapshot.workspaces.remove(at: index)
        select(snapshot.workspaces.firstIndex { $0.name == selectedName }
            ?? min(index, snapshot.workspaces.count - 1))
    }
}

private struct SidebarTabMotionProofView: View {
    @ObservedObject var model: SidebarTabMotionProofModel

    var body: some View { WorkspaceSidebarView(snapshot: model.snapshot) }
}

@MainActor
public func recordSidebarTabMotionDemo(to output: URL) throws {
    let model = SidebarTabMotionProofModel(width: 250)
    let events: [(TimeInterval, () -> Void)] = [
        (0.8, { model.caption = "Switch tabs · labels respond immediately" }),
        (1.1, { model.select(3) }), (2.1, { model.select(1) }),
        (3.1, { model.select(2) }), (4.1, { model.select(0) }),
        (5.0, { model.caption = "Rapid switching · motion redirects in place" }),
        (5.3, { model.select(3) }), (5.39, { model.select(1) }),
        (5.48, { model.select(2) }), (5.57, { model.select(0) }),
        (6.1, { model.select(3) }), (6.19, { model.select(1) }),
        (7.2, { model.caption = "Add a tab · content and selection move separately" }),
        (7.6, { model.addTab() }),
        (9.3, { model.caption = "Close a tab · quick fade, smooth repositioning" }),
        (9.7, { model.closeTab(at: 1) }),
        (11.0, { model.closeTab(at: 3) }),
        (12.0, { model.caption = "Stable labels. Fixed controls. Soft settling." }),
        (12.3, { model.select(0) }), (13.2, { model.select(2) }),
    ]
    var nextEvent = 0
    try recordMarketingVideo(SidebarTabMotionDemoView(model: model), to: output,
                             size: .init(width: 600, height: 600), duration: 14.5) { elapsed in
        while nextEvent < events.count, elapsed >= events[nextEvent].0 {
            events[nextEvent].1()
            nextEvent += 1
        }
    }
}

private struct SidebarTabMotionDemoView: View {
    @ObservedObject var model: SidebarTabMotionProofModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Vertical tabs").font(.system(size: 23, weight: .semibold))
                Spacer()
                Text("WINMUX").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
            }
            HStack(spacing: 36) {
                ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                    WorkspaceSidebarView(snapshot: model.snapshot)
                        .frame(width: 250, height: 430)
                        .environment(\.colorScheme, scheme)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay { RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.10), lineWidth: 0.5) }
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(model.caption).font(.system(size: 13, weight: .medium))
                Text("Actual SwiftUI sidebar · scripted demo · real-time playback")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .transaction { $0.animation = nil }
        }
        .padding(32)
        .frame(width: 600, height: 600)
        .foregroundStyle(.white)
        .background(Color(white: 0.065))
        .environment(\.colorScheme, .dark)
    }
}

import AppKit
import SwiftUI
import WorkspaceCore

/// Uses the production row, lifted surface, and gap geometry for visual checks.
@MainActor
public func renderSidebarTabReorderProof(in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for scheme in [ColorScheme.dark, .light] {
        try renderMarketingView(SidebarTabReorderProof(),
            to: directory.appendingPathComponent("tab-reorder-\(scheme == .dark ? "dark" : "light").png"),
            size: .init(width: 1308, height: 330), colorScheme: scheme)
    }
}

private struct SidebarTabReorderProof: View {
    @Environment(\.colorScheme) private var scheme
    private let frames: [(String, CGFloat, CGFloat)] = [
        ("Lift", 0, 0), ("Approach midpoint", -16, 0), ("Cross midpoint", -22, 0.22),
        ("Neighbor moves down", -26, 0.7), ("Gap reserved", -30, 1), ("Release · 110 ms", -37, 1),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Vertical tabs · moving gap").font(.system(size: 23, weight: .medium))
            HStack(alignment: .top, spacing: 16) {
                ForEach(frames.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 14) {
                        strip(translation: frames[index].1, neighborProgress: frames[index].2)
                        Text(frames[index].0).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(24)
        .background(Color(white: scheme == .dark ? 0.055 : 0.92))
    }

    private func strip(translation: CGFloat, neighborProgress: CGFloat) -> some View {
        let names = ["A", "B", "C", "D", "E"]
        let items = names.enumerated().map {
            WorkspaceSidebarWorkspaceReorderItem(name: $0.element,
                frame: .init(x: 8, y: 20 + CGFloat($0.offset) * 37, width: 177, height: 34))
        }
        let layout = WorkspaceSidebarTabReorderLayout(items: items, sourceName: "D")!
        let destination = layout.insertionIndex(translation: translation)
        let surface = WorkspaceSidebarSurfaceItem(surfaceID: .browserTab(profile: UUID(), tab: UUID()),
            title: "New Tab D", appName: "Browser", isFocused: true)
        return ZStack(alignment: .topLeading) {
            ForEach(items, id: \.name) { item in
                if item.name != "D" {
                    WorkspaceSidebarWindowRow(title: "New Tab \(item.name)", badge: nil, isFocused: false,
                        rowHeight: 34, isHovered: false, style: .window, appBundleIds: [], appBundlePaths: [],
                        fallbackSystemImage: "globe")
                        .frame(width: 177, height: 34)
                        .offset(x: 8, y: item.frame.minY + layout.offset(for: item.name, destinationIndex: destination) * neighborProgress)
                }
            }
            WorkspaceSidebarLiftedTabView(surface: surface, size: .init(width: 177, height: 34))
                .offset(x: 8 - 18, y: layout.source.frame.minY + translation - 18)
        }
        .frame(width: 194, height: 220, alignment: .topLeading)
        .background(Color(white: scheme == .dark ? 0.105 : 0.96))
    }
}

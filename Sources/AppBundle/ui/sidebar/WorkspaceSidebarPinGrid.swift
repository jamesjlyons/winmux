import AppKit
import SwiftUI

func workspaceSidebarCombinedPins(_ workspaces: [WorkspaceSidebarWorkspaceViewModel]) -> WorkspaceSidebarWorkspaceViewModel? {
    guard var result = workspaces.first(where: \.isPinnedGroup) else { return nil }
    result.pins = workspaces.filter(\.isPinnedGroup).flatMap(\.pins).sorted { $0.sortOrder < $1.sortOrder }
    return result
}


/// Pins occupy their own workspace, while their presentation stays separate
/// from the regular group cards. Closed launchers still participate in order.
struct WorkspaceSidebarPinGrid: View {
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let projects: [WorkspaceSidebarProjectViewModel]
    let isCompact: Bool
    let availableWidth: CGFloat
    let showsDropWell: Bool
    let actions: WorkspaceSidebarActions
    @State private var hoveredPin: UUID?

    private var tileSize: CGFloat { isCompact ? 32 : 44 }
    private var columnCount: Int { isCompact ? 1 : max(1, Int((availableWidth + 8) / 52)) }
    private var gridHeight: CGFloat {
        let rows = max(1, (workspace.pins.count + columnCount - 1) / columnCount)
        return CGFloat(min(rows, 3)) * (tileSize + 8) - 8
    }

    var body: some View {
        if !workspace.pins.isEmpty || showsDropWell {
            ScrollView(.vertical, showsIndicators: workspace.pins.count > columnCount * 3) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileSize), spacing: 8), count: columnCount),
                          alignment: isCompact ? .center : .leading, spacing: 8) {
                    ForEach(workspace.pins) { pin in pinTile(pin) }
                    if workspace.pins.isEmpty {
                        Image(systemName: "pin")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                            .frame(width: tileSize, height: tileSize)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3])))
                            .accessibilityLabel("Drop here to pin")
                    }
                }
                .padding(2)
                .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
            }
            .frame(height: gridHeight + 4)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: WorkspaceSidebarDropTargetPreferenceKey.self, value: [
                        .init(kind: .workspace(workspace.name), frame: geometry.frame(in: .named("workspaceSidebarContent")))
                    ])
                }
            }
            .workspaceSidebarDropViewport()
            .frame(height: gridHeight + 4)
            .padding(.bottom, 10)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pinned apps, tabs, and groups")
            .accessibilityIdentifier("winmux.sidebar.pins.\(workspace.projectId.rawValue)")
        }
    }

    private func pinTile(_ pin: WorkspaceSidebarPinViewModel) -> some View {
        Button { actions.send(.selectPin(pin.id)) } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: isCompact ? 8 : 11)
                    .fill(Color.primary.opacity(pin.isFocused ? 0.15 : hoveredPin == pin.id ? 0.11 : 0.055))
                pinIcon(pin)
                    .frame(width: 20, height: 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(pin.isUnavailable ? 0.45 : 1)
                if pin.isLoading {
                    ProgressView().controlSize(.mini).padding(.bottom, 2)
                } else if pin.isOpen {
                    Circle().fill(Color.primary.opacity(pin.isFocused ? 0.85 : 0.32))
                        .frame(width: 3, height: 3).padding(.bottom, isCompact ? 2 : 4)
                }
            }
            .frame(width: tileSize, height: tileSize)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(pin.isUnavailable ? "\(pin.title) — app unavailable" : pin.title)
        .accessibilityLabel("Pinned \(pin.isGroup ? "group" : pin.isBrowser ? "tab" : "app"): \(pin.title)\(pin.isOpen ? "" : ", closed")")
        .accessibilityIdentifier("winmux.sidebar.pin.\(pin.id.uuidString.lowercased())")
        .onHover { hoveredPin = $0 ? pin.id : nil }
        .modifier(WorkspaceSidebarOptionalDragModifier(isEnabled: true,
            onChanged: { actions.surfaceDragChanged(.pin(pin.id), $0) },
            onEnded: { actions.surfaceDragEnded(.pin(pin.id), $0) }))
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: WorkspaceSidebarDropTargetPreferenceKey.self, value: [
                    .init(kind: .pin(pin.id), frame: geometry.frame(in: .named("workspaceSidebarContent")))
                ])
            }
        }
        .contextMenu {
            Button(pin.isOpen ? "Open" : pin.isGroup ? "Reopen Group" : pin.isBrowser ? "Reopen Tab" : "Launch App") { actions.send(.selectPin(pin.id)) }
            Button(pin.isGroup ? "Unpin Group" : pin.isBrowser ? "Unpin Tab" : "Unpin App") { actions.send(.unpin(pin.id)) }
            if pin.isGroup { Button("Reopen Closed Items") { actions.send(.reopenClosedPinItems(pin.id)) } }
            Menu("Move to Space") {
                ForEach(projects) { project in
                    Button(project.displayName) { actions.send(.movePin(pin.id, toSpace: project.id)) }
                        .disabled(project.id == workspace.projectId)
                }
            }
            if pin.isOpen, let surface = pin.surfaceID {
                Divider()
                Button(pin.isBrowser ? "Close Tab" : "Close Window") { actions.send(.closeSurface(surface)) }
            }
        }
    }

    @ViewBuilder
    private func pinIcon(_ pin: WorkspaceSidebarPinViewModel) -> some View {
        if pin.isGroup {
            ZStack(alignment: .bottomTrailing) {
                HStack(spacing: -5) {
                    ForEach(Array(pin.members.prefix(2))) { member in
                        Group {
                            if let encoded = member.iconPNGBase64, let icon = WorkspaceSidebarPinImageCache.shared.image(for: encoded) {
                                Image(nsImage: icon).resizable().scaledToFit()
                            } else if let icon = appIconImage(bundleIdentifier: member.bundleIdentifier, bundlePath: member.bundlePath) {
                                Image(nsImage: icon).resizable().scaledToFit()
                            } else { Image(systemName: member.isBrowser ? "globe" : "app") }
                        }.frame(width: 15, height: 15)
                    }
                }
                Text("\(pin.memberCount)").font(.system(size: 8, weight: .bold)).padding(1).background(.regularMaterial, in: Circle()).offset(x: 6, y: 6)
            }
        } else if let encoded = pin.iconPNGBase64, let icon = WorkspaceSidebarPinImageCache.shared.image(for: encoded) {
            Image(nsImage: icon).resizable().scaledToFit()
        } else if !pin.isBrowser, let icon = appIconImage(bundleIdentifier: pin.bundleIdentifier, bundlePath: pin.bundlePath) {
            Image(nsImage: icon).resizable().scaledToFit()
        } else {
            Image(systemName: pin.isBrowser ? "globe" : "app.dashed").font(.system(size: 20))
        }
    }
}

/// Hover and focus changes redraw the grid frequently. Decode each favicon once,
/// with bounded storage, instead of allocating an image for every tile render.
@MainActor
final class WorkspaceSidebarPinImageCache {
    static let shared = WorkspaceSidebarPinImageCache()
    private let images = NSCache<NSString, NSImage>()

    init() {
        images.countLimit = 256
        images.totalCostLimit = 8 * 1024 * 1024
    }

    func image(for encoded: String) -> NSImage? {
        let key = encoded as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let data = Data(base64Encoded: encoded), let image = NSImage(data: data) else { return nil }
        let decodedBytes = image.representations.reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh * 4 }
        images.setObject(image, forKey: key, cost: max(data.count, decodedBytes))
        return image
    }
}

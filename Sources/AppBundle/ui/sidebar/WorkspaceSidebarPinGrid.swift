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
    var expandedAvailableWidth: CGFloat? = nil
    @State private var hoveredPin: UUID?

    private let tileHeight: CGFloat = 40
    private let tileSpacing: CGFloat = 6
    private var tileWidth: CGFloat {
        isCompact ? min(32, availableWidth) : max(32, (availableWidth - CGFloat(columnCount - 1) * tileSpacing) / CGFloat(columnCount))
    }
    private var columnCount: Int { isCompact ? 1 : columns(for: availableWidth) }
    private func columns(for width: CGFloat) -> Int { max(1, Int((width + tileSpacing) / (52 + tileSpacing))) }
    private var visibleRowCount: Int {
        let columns = columns(for: expandedAvailableWidth ?? availableWidth)
        return min(3, max(1, (workspace.pins.count + columns - 1) / columns))
    }
    private var gridHeight: CGFloat {
        // Keep the tabs below the shelf anchored while its icons reflow.
        CGFloat(visibleRowCount) * (tileHeight + tileSpacing) - tileSpacing
    }

    var body: some View {
        if !workspace.pins.isEmpty || showsDropWell {
            ScrollView(.vertical, showsIndicators: workspace.pins.count > columnCount * visibleRowCount) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileWidth), spacing: tileSpacing), count: columnCount),
                          alignment: isCompact ? .center : .leading, spacing: tileSpacing) {
                    ForEach(workspace.pins) { pin in pinTile(pin) }
                    if workspace.pins.isEmpty {
                        Image(systemName: "pin")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                            .frame(width: tileWidth, height: isCompact ? 32 : tileHeight)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3])))
                            .accessibilityLabel("Drop here to pin")
                            .frame(height: tileHeight)
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
            .padding(.bottom, 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pinned apps, pages, and Views")
            .accessibilityIdentifier("winmux.sidebar.pins.\(workspace.projectId.rawValue)")
        }
    }

    private func pinTile(_ pin: WorkspaceSidebarPinViewModel) -> some View {
        Button { actions.send(.selectPin(pin.id)) } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: isCompact ? 8 : 10, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                    .overlay {
                        RoundedRectangle(cornerRadius: isCompact ? 8 : 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.045), lineWidth: 0.5)
                    }
                ChromeSelectionBackground(state: .init(isSelected: pin.isSelected,
                    isFocused: pin.isFocused, isHovered: hoveredPin == pin.id), cornerRadius: isCompact ? 8 : 10)
                pinIcon(pin)
                    .frame(width: 18, height: 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(pin.isUnavailable ? 0.45 : 1)
                if pin.isLoading {
                    ProgressView().controlSize(.mini).padding(.bottom, 2)
                } else if pin.isOpen {
                    Circle().fill(Color.primary.opacity(pin.isFocused ? 0.85 : 0.32))
                        .frame(width: 3, height: 3).padding(.bottom, isCompact ? 2 : 4)
                }
            }
            .frame(width: tileWidth, height: isCompact ? 32 : tileHeight)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .frame(height: tileHeight)
        .help(pin.isUnavailable ? "\(pin.title) — app unavailable" : pin.title)
        .accessibilityLabel("Pinned \(pin.isGroup ? "View" : pin.isBrowser ? "tab" : "app"): \(pin.title)\(pin.isOpen ? "" : ", closed")")
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
            if !pin.isGroup, let id = pin.surfaceID {
                SurfaceViewActionsMenu(surface: id, actions: actions)
                Divider()
            }
            if pin.isGroup {
                ForEach(pin.groupMembers) { member in
                    Button(member.title) { actions.send(.selectPin(member.id)) }
                }
                Divider()
            }
            Button(pin.isGroup ? "Open View" : pin.isOpen ? "Open" : pin.isBrowser ? "Reopen Tab" : "Launch App") { actions.send(.selectPin(pin.id)) }
            Button(pin.isGroup ? "Unpin View" : pin.isBrowser ? "Unpin Tab" : "Unpin App") { actions.send(.unpin(pin.id)) }
            if pin.isGroup { Button("Reopen Closed Items") { actions.send(.reopenClosedPinItems(pin.id)) } }
            Menu("Move to Space") {
                ForEach(projects.filter { !$0.id.isIncognito }) { project in
                    Button(project.displayName) { actions.send(.movePin(pin.id, toSpace: project.id)) }
                        .disabled(project.id == workspace.projectId || (pin.isGroup && pin.groupMembers.contains { !$0.isOpen }))
                }
            }
            if pin.isGroup {
                Divider()
                Button("Close View") {
                    for member in pin.groupMembers { if let surface = member.surfaceID { actions.send(.closeSurface(surface)) } }
                }.disabled(!pin.isOpen)
            } else if pin.isOpen, let surface = pin.surfaceID {
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
                            if let encoded = member.iconPNGBase64, let icon = WorkspaceSidebarFaviconCache.shared.image(for: encoded) {
                                Image(nsImage: icon).resizable().scaledToFit()
                            } else if let icon = appIconImage(bundleIdentifier: member.bundleIdentifier, bundlePath: member.bundlePath) {
                                Image(nsImage: icon).resizable().scaledToFit()
                            } else { Image(systemName: member.isBrowser ? "globe" : "app") }
                        }.frame(width: 15, height: 15)
                    }
                }
                Text("\(pin.memberCount)").font(.system(size: 8, weight: .bold)).padding(1).background(.regularMaterial, in: Circle()).offset(x: 6, y: 6)
            }
        } else if let encoded = pin.iconPNGBase64, let icon = WorkspaceSidebarFaviconCache.shared.image(for: encoded) {
            Image(nsImage: icon).resizable().scaledToFit()
        } else if !pin.isBrowser, let icon = appIconImage(bundleIdentifier: pin.bundleIdentifier, bundlePath: pin.bundlePath) {
            Image(nsImage: icon).resizable().scaledToFit()
        } else {
            Image(systemName: pin.isBrowser ? "globe" : "app.dashed").font(.system(size: 20))
        }
    }
}

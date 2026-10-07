import AppKit
import SwiftUI
import WorkspaceCore

struct SharedStackStripView: View {
    let stack: SharedStackChrome
    let strip: WindowTabStripViewModel
    @State private var hovered: SurfacePane?
    @State private var dragging: SurfacePane?
    @State private var orderAtDragStart: [SurfacePane]?
    @State private var translation: CGFloat = 0
    @State private var detached = false
    @State private var scrollContent: CGRect = .zero
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var monitorScopeID: String? {
        Workspace.existing(byName: stack.workspaceName).map { workspaceSidebarMonitorScopeId(for: $0.workspaceMonitor) }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = windowTabStripTabWidth(stripWidth: proxy.size.width, count: stack.tabs.count)
            let viewport = max(0, proxy.size.width - 10 - 6 - windowTabStripReservedGroupHandleWidth() - windowTabStripTrailingGroupDragGutterWidth)
            let coordinateSpace = "shared-stack-\(stack.id)"
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: windowTabStripTabSpacing) {
                        ForEach(stack.tabs) { tab in
                            tabButton(tab, width: width, height: min(max(proxy.size.height - 10, 18), 26))
                        }
                    }.padding(.horizontal, windowTabStripContentHorizontalPadding)
                        .background {
                            GeometryReader { content in
                                Color.clear.preference(key: WindowTabStripScrollContentFramePreferenceKey.self,
                                    value: content.frame(in: .named(coordinateSpace)))
                            }
                        }
                }
                .coordinateSpace(name: coordinateSpace)
                .onPreferenceChange(WindowTabStripScrollContentFramePreferenceKey.self) { scrollContent = $0 }
                .mask {
                    WindowTabStripScrollFadeMask(
                        leadingFadeWidth: windowTabLeadingScrollFadeWidth(isScrollable: scrollContent.width > viewport,
                            contentMinX: scrollContent.minX, stripWidth: proxy.size.width),
                        trailingFadeWidth: windowTabTrailingScrollFadeWidth(isScrollable: scrollContent.width > viewport,
                            contentMaxX: scrollContent.maxX, viewportWidth: viewport, stripWidth: proxy.size.width))
                }
                .frame(maxWidth: .infinity)
                if let active = stack.tabs.first(where: \.isActive) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: windowTabStripReservedGroupHandleWidth() + windowTabStripTrailingGroupDragGutterWidth)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Move Stack")
                        .onTapGesture { focusSurfaceFromSidebar(active.surface) }
                        .gesture(DragGesture(minimumDistance: 4).onChanged { _ in
                            SharedStackDragController.shared.update(.group(stack.id), selecting: active.surface)
                        }.onEnded { _ in SharedStackDragController.shared.finish() })
                        .contextMenu {
                            SurfaceMoveMenu(subject: .group(stack.id), workspaceName: stack.workspaceName,
                                targetMonitorScopeId: monitorScopeID, actions: makeWorkspaceSidebarActionsAdapter(targetMonitorScopeId: monitorScopeID))
                        }
                }
            }
            .padding(.leading, 2).padding(.trailing, 8).padding(.vertical, 2)
        }
        .windowTabOcclusionMasked(panelFrame: strip.frame, occludingScreenFrames: strip.occludingFloatingWindowFrames)
        .environment(\.colorScheme, config.workspaceSidebar.chromeColorScheme ?? colorScheme)
        .onDisappear {
            if let pane = SharedStackDragController.shared.pane,
               pane == .group(stack.id) || stack.tabs.contains(where: { $0.id == pane }) {
                SharedStackDragController.shared.cancel()
            }
        }
    }

    private func tabButton(_ tab: SharedStackTab, width: CGFloat, height: CGFloat) -> some View {
        Button { focusSurfaceFromSidebar(tab.surface) } label: {
            StackTabLabel(title: tab.title, appName: tab.appName, bundleID: tab.bundleID, bundlePath: tab.bundlePath,
                symbol: tab.symbol, isActive: tab.isActive, isFocused: tab.isFocused,
                width: width, height: height, isDragSource: dragging == tab.id, isHovered: hovered == tab.id)
        }
        .buttonStyle(.plain)
        .disabled(!tab.isAvailable)
        .help(tab.title)
        .offset(x: offset(for: tab.id, width: width))
        .animation(reduceMotion ? nil : windowTabPillAnimation, value: targetIndex(width: width))
        .zIndex(dragging == tab.id ? 1 : 0)
        .onHover { hovered = $0 ? tab.id : nil }
        .highPriorityGesture(DragGesture(minimumDistance: 4).onChanged { value in
            if dragging == nil { orderAtDragStart = stack.tabs.map(\.id) }
            dragging = tab.id
            if detached || abs(value.translation.height) > tabReorderVerticalEscapeThreshold {
                detached = true; translation = 0
                SharedStackDragController.shared.update(tab.id, selecting: tab.surface)
            } else { translation = value.translation.width }
        }.onEnded { _ in
            if detached { SharedStackDragController.shared.finish() }
            else if let index = stack.tabs.firstIndex(where: { $0.id == tab.id }) {
                let destination = index + Int((translation / (width + windowTabStripTabSpacing)).rounded())
                if reorderSharedStackTab(tab.id, stack: stack.id, to: destination, expectedOrder: orderAtDragStart) { runWorkspaceSidebarSession {} }
            }
            dragging = nil; detached = false; translation = 0; orderAtDragStart = nil
        })
        .contextMenu {
            SurfaceMoveMenu(subject: tab.id.sidebarDragSubject, workspaceName: stack.workspaceName,
                targetMonitorScopeId: monitorScopeID, actions: makeWorkspaceSidebarActionsAdapter(targetMonitorScopeId: monitorScopeID))
            Button("Remove Tab From Stack") {
                if separateSharedStackTab(tab.id) { runWorkspaceSidebarSession {} }
            }
        }
    }

    private func targetIndex(width: CGFloat) -> Int? {
        guard !detached, let dragging, let index = stack.tabs.firstIndex(where: { $0.id == dragging }) else { return nil }
        return min(max(0, index + Int((translation / (width + windowTabStripTabSpacing)).rounded())), stack.tabs.count - 1)
    }

    private func offset(for pane: SurfacePane, width: CGFloat) -> CGFloat {
        guard let dragging, !detached else { return 0 }
        if pane == dragging { return translation }
        guard let source = stack.tabs.firstIndex(where: { $0.id == dragging }),
              let index = stack.tabs.firstIndex(where: { $0.id == pane }), let target = targetIndex(width: width) else { return 0 }
        if source < target, index > source, index <= target { return -(width + windowTabStripTabSpacing) }
        if source > target, index >= target, index < source { return width + windowTabStripTabSpacing }
        return 0
    }
}

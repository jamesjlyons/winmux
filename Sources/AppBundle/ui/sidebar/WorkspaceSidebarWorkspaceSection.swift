import AppKit
import Common
import SwiftUI
import WorkspaceCore

struct WorkspaceSidebarWorkspaceSection: View {
    let workspace: WorkspaceSidebarWorkspaceViewModel
    let targetMonitorScopeId: String
    let dragPreview: WorkspaceSidebarDropPreviewViewModel?
    let expansionProgress: CGFloat
    let layout: WorkspaceSidebarConfiguration
    let emitsDropTarget: Bool
    let isFromOtherDisplay: Bool
    let isInUseOnOtherDisplay: Bool
    let isOnFocusedMonitor: Bool
    let allowsWorkspaceActivation: Bool
    let isPinnedActiveWorkspace: Bool
    let isActiveOnTargetMonitor: Bool
    let projectContextLabel: String?
    let projectContextColor: Color?
    @Binding var renamingWorkspaceName: String?
    @Binding var renamingWorkspaceText: String
    let onBeginRenameWorkspace: @MainActor () -> Void
    let onCommitRenameWorkspace: @MainActor () -> Void
    let onCancelRenameWorkspace: @MainActor () -> Void
    let selectedSearchTarget: WorkspaceSidebarSearchSelection?
    let isSearchFiltering: Bool
    @Binding var activeInUseOverrideWorkspaceName: String?
    let actions: WorkspaceSidebarActions

    @State var isHovered = false
    @State var hoveredWindowId: UInt32? = nil
    @State var hoveredTabGroupId: UInt32? = nil
    @State var isDropTargeted = false
    @State var isDropSettling = false
    @State var isViewExpanded = true
    @ObservedObject private var reorderState = WorkspaceSidebarWorkspaceReorderState.shared
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var headerHeight: CGFloat { layout.menuBarStyle ? 26 : workspaceSidebarWorkspaceSectionHeaderHeight }
    let rowHeight: CGFloat = workspaceSidebarWorkspaceRowHeight

    var contentWidth: CGFloat { workspaceSidebarContentWidth(expansionProgress, layout: layout) }
    var sectionWidth: CGFloat { workspaceSidebarSectionWidth(expansionProgress, layout: layout) }
    var compactMetrics: WorkspaceSidebarCompactMetrics { .init(sectionWidth: sectionWidth) }
    var density: WorkspaceSidebarDensity { .init(sectionWidth: sectionWidth) }
    var isCompact: Bool { expansionProgress < workspaceSidebarRowsRevealProgress }
    var sectionMinHeight: CGFloat? {
        if allowsWorkspaceActivation, isInUseOnOtherDisplay, workspace.items.isEmpty {
            return workspaceSidebarInUseOverrideEmptySectionMinHeight
        }
        return nil
    }
    var isDropTarget: Bool { dragPreview?.targetWorkspaceName == workspace.name }
    var activeSidebarDragSourceWindowId: UInt32? { dragPreview?.sourceWindowId }
    var isShowingInUseOverlay: Bool { activeInUseOverrideWorkspaceName == workspace.name }
    var isSearchSelectedWorkspace: Bool {
        selectedSearchTarget == .workspace(workspace.name) ||
            (workspace.isViewMode && workspace.isSingleWindowView && workspace.viewSurfaces.first.map {
                selectedSearchTarget == .surface($0.surfaceID)
            } == true)
    }
    var isRenamingWorkspace: Bool { renamingWorkspaceName == workspace.name }
    var showsStandaloneViewRow: Bool { workspace.isSingleWindowView && !isCompact && !isRenamingWorkspace }
    var participatesInReorder: Bool { allowsWorkspaceReordering && reorderState.applies(to: targetMonitorScopeId) }
    var isReorderingWorkspace: Bool { participatesInReorder && reorderState.sourceName == workspace.name }
    var reorderOffset: CGFloat { participatesInReorder ? reorderState.offset(for: workspace.name) : 0 }
    var allowsWorkspaceReordering: Bool { !isPinnedActiveWorkspace && !isSearchFiltering && renamingWorkspaceName == nil }
    var inUseOverrideText: String {
        if let monitorName = workspace.monitorName, !monitorName.isEmpty {
            return "In use on \(monitorName)"
        }
        return "In use on another display"
    }
    var sectionShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isCompact ? compactMetrics.cornerRadius : workspaceSidebarSectionCornerRadius, style: .continuous)
    }

    var body: some View {
        interactiveSectionContent
            .padding(.vertical, 1)
            .padding(.horizontal, isCompact ? compactMetrics.horizontalInset : workspaceSidebarSectionInnerHorizontalInset)
            .frame(width: sectionWidth, alignment: .leading)
            .frame(minHeight: sectionMinHeight, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .opacity(compactFocusOpacity)
            .contentShape(Rectangle())
            .contextMenu {
                if BrowserWorkspaceController.shared.usesSurfaceTree {
                    Button("Pin Group") { actions.send(.pinWorkspace(workspace.name)) }
                }
                Button {
                    debugWorkspaceSidebarRenameLog("workspaceContextRename workspace=\(workspace.name) displayName=\(workspace.displayName) compact=\(isCompact)")
                    onBeginRenameWorkspace()
                } label: {
                    Text(workspace.isViewMode ? "Rename View" : "Rename Group")
                }
                Divider()
                Button(role: .destructive) {
                    actions.send(.deleteWorkspace(workspace.name))
                } label: {
                    Text(workspace.isViewMode ? "Delete View" : "Delete Group")
                }
            }
            .onHover { hover in
                isHovered = hover
                actions.hoverWorkspace(workspace.name, hover)
            }
            .onDrop(of: [workspaceSidebarDragPayloadType], delegate: WorkspaceSidebarDropDelegate(
                target: .workspace(workspace.name),
                actions: actions,
                performPayloadDrop: handlePayloadDrop,
                isTargeted: $isDropTargeted,
                isSettling: $isDropSettling,
            ))
            .environment(\.workspaceSidebarDensity, density)
            .environment(\.workspaceSidebarCompactRows, isCompact)
            .zIndex(isDropTarget ? 1 : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.82), value: dragPreview)
            .animation(isCompact ? workspaceSidebarCollapseAnimation : workspaceSidebarExpansionAnimation, value: expansionProgress)
            .animation(reduceMotion ? workspaceSidebarReducedMotionHoverAnimation : workspaceSidebarHoverAnimation, value: isHovered)
            .animation(reduceMotion ? workspaceSidebarReducedMotionHoverAnimation : workspaceSidebarHoverAnimation, value: hoveredWindowId)
            .animation(reduceMotion ? workspaceSidebarReducedMotionHoverAnimation : workspaceSidebarHoverAnimation, value: hoveredTabGroupId)
            .animation(reduceMotion ? workspaceSidebarReducedMotionHoverAnimation : workspaceSidebarHoverAnimation, value: isOnFocusedMonitor)
            .background {
                ZStack {
                    sectionBackground
                    if !isCompact && allowsWorkspaceActivation {
                        sectionActivationButton
                    }
                }
            }
            .overlay(alignment: .center) {
                inUseOverrideOverlay
                    .opacity(allowsWorkspaceActivation && isShowingInUseOverlay ? 1 : 0)
                    .allowsHitTesting(allowsWorkspaceActivation && isShowingInUseOverlay)
                    .zIndex(5)
            }
            .shadow(
                color: isDropTarget ? Color.primary.opacity(0.16) : .clear,
                radius: isDropTarget ? 12 : 0
            )
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: WorkspaceSidebarDropTargetPreferenceKey.self,
                        value: emitsDropTarget ? [WorkspaceSidebarDropTargetFrame(
                            kind: .workspace(workspace.name),
                            frame: geometry.frame(in: .named("workspaceSidebarContent")),
                        )] : [],
                    )
                }
            }
            .shadow(color: isReorderingWorkspace ? .black.opacity(0.18) : .clear, radius: 10, y: 4)
            .offset(y: reorderOffset)
            .animation(
                reduceMotion || (isReorderingWorkspace && !reorderState.isSettling)
                    ? nil : .interactiveSpring(response: 0.22, dampingFraction: 0.86),
                value: reorderOffset
            )
            .zIndex(isReorderingWorkspace ? 3 : (isDropTarget ? 1 : 0))
    }
}
extension WorkspaceSidebarWorkspaceSection {
    func handleSectionClick() {
        guard allowsWorkspaceActivation,
              shouldHandleWorkspaceSidebarActivation(
                editingWorkspaceName: renamingWorkspaceName,
                isSidebarDragInProgress: isWorkspaceSidebarDragInProgress()
              )
        else { return }
        if isInUseOnOtherDisplay {
            activeInUseOverrideWorkspaceName = workspace.name
            return
        }
        actions.send(.selectWorkspace(workspace.name))
    }

    func handlePayloadDrop(_ payload: WorkspaceSidebarDragPayload) {
        if workspace.isViewMode, case .surface(let id) = payload,
           requestWorkspaceViewCombination(.surface(id), target: .workspace(workspace.name)) { return }
        guard !workspaceSidebarPayload(payload, comesFromWorkspace: workspace.name) else {
            actions.send(.clearDropPreview)
            WindowDragCursorProxyPanel.shared.hide()
            return
        }
        switch payload {
            case .surface(let id): actions.send(.moveSurface(id, toWorkspace: workspace.name))
            case .surfaceGroup(let id): actions.send(.moveSurfaceGroup(id, toWorkspace: workspace.name))
            case .window(let windowId):
                actions.send(.moveWindow(windowId, toWorkspace: workspace.name))
            case .tabGroup(let representativeWindowId):
                actions.send(.moveTabGroup(representativeWindowId, toWorkspace: workspace.name))
        }
    }
}

@MainActor
private func workspaceSidebarPayload(_ payload: WorkspaceSidebarDragPayload, comesFromWorkspace workspaceName: String) -> Bool {
    switch payload {
        case .surface(let id):
            return BrowserWorkspaceController.shared.workspaceName(for: id) == workspaceName
        case .surfaceGroup(let id):
            return BrowserWorkspaceController.shared.workspaceName(forGroup: id) == workspaceName
        case .window(let windowId):
            return Window.get(byId: windowId)?.nodeWorkspace?.name == workspaceName
        case .tabGroup(let representativeWindowId):
            guard let window = Window.get(byId: representativeWindowId) else { return false }
            return dragSubjectNode(for: window, subject: .group).nodeWorkspace?.name == workspaceName
    }
}
extension WorkspaceSidebarWorkspaceSection {
    var sectionBackground: some View {
        sectionShape
            .fill(sectionBackgroundFill)
            .overlay {
                if isActiveWorkspaceSelection && !layout.menuBarStyle && !showsStandaloneViewRow {
                    sectionShape
                        .strokeBorder(Color.primary.opacity(isCompact ? 0.15 : 0.10), lineWidth: StrokeToken.control)
                }
                if isPinnedActiveWorkspace && !isSearchFiltering && !layout.menuBarStyle {
                    sectionShape
                        .strokeBorder(
                            Color.primary.opacity(0.16),
                            style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                        )
                }
            }
    }

    var sectionBackgroundFill: Color {
        if showsStandaloneViewRow && !isDropTarget && !isInUseOnOtherDisplay { return .clear }
        if layout.menuBarStyle {
            if isDropTarget { return Color.primary.opacity(0.12) }
            if isSearchSelectedWorkspace { return Color.primary.opacity(0.08) }
            if allowsWorkspaceActivation && isInUseOnOtherDisplay { return Color.red.opacity(0.06) }
            return Color.primary.opacity(isCompact ? (isActiveOnTargetMonitor ? 0.14 : (isHovered ? 0.08 : 0)) : 0)
        }
        if isDropTarget {
            // A neutral lift works against both solid colors and Liquid Glass without
            // introducing the system accent color into themed chrome.
            return Color.primary.opacity(0.10)
        }
        if isSearchSelectedWorkspace {
            return Color.primary.opacity(0.075)
        }
        if isSearchFiltering {
            return isHovered ? Color.primary.opacity(0.045) : Color.primary.opacity(0.015)
        }
        if allowsWorkspaceActivation && isInUseOnOtherDisplay {
            let redOpacity: Double = workspace.isFocused ? 0.16 : 0.065
            let hoveredRedOpacity: Double = workspace.isFocused ? 0.24 : 0.13
            return Color(nsColor: .systemRed).opacity(isHovered ? hoveredRedOpacity : redOpacity)
        }
        if isPinnedActiveWorkspace {
            return Color.primary.opacity(isHovered ? 0.09 : 0.06)
        }
        if isActiveOnTargetMonitor {
            let compactOpacity: Double = workspace.isFocused ? 0.13 : 0.075
            let expandedOpacity: Double = workspace.isFocused ? 0.055 : 0.025
            return Color.primary.opacity(isCompact ? compactOpacity : expandedOpacity)
        }
        if isFromOtherDisplay {
            return Color(nsColor: .systemPink).opacity(isHovered ? 0.10 : 0.05)
        }
        if isHovered {
            return Color.primary.opacity(0.045)
        }
        return .clear
    }

    var isActiveWorkspaceSelection: Bool {
        !isSearchFiltering && (isPinnedActiveWorkspace || isActiveOnTargetMonitor)
    }

    var compactFocusOpacity: Double {
        isCompact && !isOnFocusedMonitor ? 0.72 : 1
    }

    var inUseOverrideOverlay: some View {
        WorkspaceSidebarInUseOverrideOverlay(text: inUseOverrideText) {
            activeInUseOverrideWorkspaceName = nil
            actions.send(.overrideWorkspaceInUse(workspace.name))
        }
    }
}
extension WorkspaceSidebarWorkspaceSection {
    var workspaceBadge: some View {
        Text(workspaceBadgeText)
            .font(.system(size: layout.menuBarStyle ? min(13, compactMetrics.badgeFontSize) : compactMetrics.badgeFontSize, weight: isActiveOnTargetMonitor ? .medium : .regular))
            .monospacedDigit()
            .foregroundStyle(workspaceBadgeForeground)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .frame(width: compactMetrics.badgeWidth, height: compactMetrics.badgeWidth)
    }

    var workspaceBadgeText: String {
        if workspace.isGeneratedName, workspace.sidebarLabel.isEmpty {
            return generatedWorkspaceBadgeText
        }
        if workspace.isGeneratedName, let initial = workspace.displayName.first {
            return String(initial).uppercased()
        }
        return workspace.displayName.first.map { String($0).uppercased() } ?? "G"
    }

    var generatedWorkspaceBadgeText: String {
        let prefix = "Group "
        if workspace.displayName.hasPrefix(prefix) {
            let suffix = String(workspace.displayName.dropFirst(prefix.count))
            if !suffix.isEmpty { return suffix }
        }
        return workspace.displayName.first.map { String($0).uppercased() } ?? "G"
    }

    var workspaceBadgeForeground: Color {
        if isActiveOnTargetMonitor {
            return Color.primary
        }
        return Color.primary.opacity(0.70)
    }
}
extension WorkspaceSidebarWorkspaceSection {
    var headerButton: some View {
        Button(action: handleSectionClick) {
            header
                .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
                .frame(height: headerHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(workspace.displayName)
        .accessibilityValue(isActiveOnTargetMonitor ? "Selected" : "")
        .accessibilityHint("Click to switch groups. Drag to rearrange.")
        .modifier(WorkspaceSidebarWorkspaceDragModifier(name: workspace.name, isEnabled: allowsWorkspaceReordering, actions: actions))
    }

    var header: some View {
        Group {
            if isCompact {
                workspaceBadge
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                expandedHeader
            }
        }
        .help(isInUseOnOtherDisplay ? inUseOverrideText : workspace.displayName)
    }

    var expandedHeader: some View {
        HStack(spacing: workspaceSidebarHeaderSpacing) {
            if layout.menuBarStyle {
                Image(systemName: isPinnedActiveWorkspace ? "pin.fill" : "checkmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 10)
                    .opacity(isActiveOnTargetMonitor || isPinnedActiveWorkspace ? 1 : 0)
            }
            if isRenamingWorkspace {
                WorkspaceSidebarWorkspaceRenameField(
                    text: $renamingWorkspaceText,
                    workspaceName: workspace.name,
                    onCommit: onCommitRenameWorkspace,
                    onCancel: onCancelRenameWorkspace,
                )
            } else {
                Text(workspace.displayName)
                    .font(.system(size: 13, weight: isActiveOnTargetMonitor ? .medium : .regular))
                    .foregroundStyle(isActiveOnTargetMonitor ? Color.primary : Color.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if !density.isNarrow, let projectContextLabel, let projectContextColor {
                Text(projectContextLabel)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(projectContextColor.opacity(0.86))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .frame(height: 15)
                    .background {
                        Capsule(style: .continuous)
                            .fill(projectContextColor.opacity(0.13))
                    }
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(projectContextColor.opacity(0.24), lineWidth: 0.5)
                    }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, density.isNarrow ? 2 : workspaceSidebarHeaderRowLeadingPadding)
        .padding(.trailing, workspaceSidebarRowHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
extension WorkspaceSidebarWorkspaceSection {
    @ViewBuilder
    var windowRows: some View {
        if !workspace.items.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                if !pinnedItems.isEmpty {
                        Text("Pinned")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.leading, workspaceSidebarRowLeadingPadding)
                            .padding(.trailing, workspaceSidebarRowHorizontalPadding)
                            .padding(.top, 3)
                            .opacity(isCompact ? 0 : 1)
                            .frame(height: 16)
                            .accessibilityHidden(isCompact)
                    ForEach(pinnedItems) { item in workspaceItemView(item) }
                    if !ordinaryItems.isEmpty { Divider().padding(.vertical, 4) }
                }
                ForEach(ordinaryItems) { item in workspaceItemView(item) }
            }
            .padding(.leading, density.isNarrow || layout.menuBarStyle ? 0 : workspaceSidebarWindowRowsLeadingIndent)
        }
    }

    var pinnedItems: [WorkspaceSidebarItemViewModel] {
        workspace.items.filter { if case .pinnedBrowserTab = $0.kind { return true }; return false }
    }

    var ordinaryItems: [WorkspaceSidebarItemViewModel] {
        workspace.items.filter { if case .pinnedBrowserTab = $0.kind { return false }; return true }
    }

    @ViewBuilder
    func workspaceItemView(_ item: WorkspaceSidebarItemViewModel) -> some View {
        switch item.kind {
            case .surface, .surfaceGroup, .pinnedBrowserTab:
                sharedSurfaceItemView(item)
            case .browserTab(let tab):
                sharedSurfaceItemView(.init(kind: .surface(.init(
                    surfaceID: tab.surfaceID, title: tab.title, appName: "WinMux Browser", isFocused: tab.isFocused,
                    appBundleId: "com.jameslyons.winmux.browser.alpha", iconPNGBase64: tab.iconPNGBase64,
                    isSelected: tab.isSelected, isLoading: tab.isLoading
                ))))
            case .window(let window):
                workspaceWindowButton(window, allowsDrag: true)
            case .tabGroup(let group):
                workspaceTabGroupView(group)
        }
    }

    func sharedSurfaceItemView(_ item: WorkspaceSidebarItemViewModel) -> some View {
        WorkspaceSidebarSurfaceTreeView(
            item: item, workspaceName: workspace.name, targetMonitorScopeId: targetMonitorScopeId,
            selectedSearchTarget: selectedSearchTarget, isSearchFiltering: isSearchFiltering,
            actions: actions, onActivate: activateSharedSurface, onActivatePin: activatePinnedBrowserTab,
            unfilteredItems: TrayMenuModel.shared.workspaceSidebarWorkspaces.first(where: { $0.name == workspace.name })?.items ?? workspace.items
        )
    }

    func activatePinnedBrowserTab(_ id: UUID) {
        guard allowsWorkspaceActivation,
              shouldHandleWorkspaceSidebarActivation(editingWorkspaceName: renamingWorkspaceName,
                isSidebarDragInProgress: isWorkspaceSidebarDragInProgress()) else { return }
        if isInUseOnOtherDisplay { activeInUseOverrideWorkspaceName = workspace.name; return }
        activeInUseOverrideWorkspaceName = nil
        actions.send(.selectPinnedBrowserTab(id))
    }

    func activateSharedSurface(_ id: SurfaceID) {
        guard allowsWorkspaceActivation,
              shouldHandleWorkspaceSidebarActivation(
                editingWorkspaceName: renamingWorkspaceName,
                isSidebarDragInProgress: isWorkspaceSidebarDragInProgress()
              ) else { return }
        if isInUseOnOtherDisplay {
            activeInUseOverrideWorkspaceName = workspace.name
            return
        }
        activeInUseOverrideWorkspaceName = nil
        actions.send(.selectSurface(id))
    }

    @ViewBuilder
    var dropPreviewRow: some View {
        if !isCompact, dragPreview?.targetWorkspaceName == workspace.name {
            WorkspaceSidebarDropPreviewView(preview: dragPreview.orDie(), rowHeight: rowHeight)
            .transition(.asymmetric(
                insertion: .move(edge: .top).combined(with: .scale(scale: 0.96, anchor: .top)).combined(with: .opacity),
                removal: .identity,
            ))
        }
    }
}
extension WorkspaceSidebarWorkspaceSection {
    var interactiveSectionContent: some View {
        sectionContent.contentShape(sectionShape)
    }

    var sectionActivationButton: some View {
        Button(action: handleSectionClick) {
            Color.clear.contentShape(sectionShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(workspace.displayName)
        .accessibilityHidden(true)
    }

    var sectionContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            if workspace.isViewMode, !workspace.viewSurfaces.isEmpty, !isRenamingWorkspace {
                viewSummary
                if !workspace.isSingleWindowView && (isViewExpanded || isSearchFiltering) {
                    windowRows
                }
            } else {
            headerSlot
                .frame(height: headerHeight)
                .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
                .background {
                    if layout.menuBarStyle && !isCompact {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.primary.opacity(isHovered && hoveredWindowId == nil && hoveredTabGroupId == nil ? 0.08 : 0))
                    }
                }
            windowRows
            }
            dropPreviewRow
        }
    }

    private var viewSummary: some View {
        HStack(spacing: 2) {
            if !isCompact && !workspace.isSingleWindowView {
                Button { isViewExpanded.toggle() } label: {
                    Image(systemName: isViewExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium)).frame(width: 20, height: rowHeight)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isViewExpanded ? "Collapse arrangement" : "Expand arrangement")
            }
            Button(action: handleSectionClick) {
                if isCompact {
                    Group {
                        if let surface = viewIconSurface,
                           let icon = workspaceSidebarIconImage(favicon: surface.iconPNGBase64,
                                bundleIdentifier: surface.appBundleId, bundlePath: surface.appBundlePath) {
                            Image(nsImage: icon).resizable().scaledToFit().frame(width: 18, height: 18)
                        } else {
                            Image(systemName: workspace.isSingleWindowView ? "globe" : "rectangle.split.2x1")
                        }
                    }.frame(maxWidth: .infinity, minHeight: rowHeight)
                } else {
                    WorkspaceSidebarWindowRow(title: workspace.displayName,
                        badge: workspace.isSingleWindowView ? nil : "\(workspace.viewSurfaceCount)",
                        isFocused: workspace.isFocused, rowHeight: workspaceSidebarWorkspaceRowHeight,
                        isHovered: isHovered,
                        style: workspace.isSingleWindowView ? .window : .tabGroupHeader,
                        appBundleIds: viewIconSurfaces.map(\.appBundleId),
                        appBundlePaths: viewIconSurfaces.map(\.appBundlePath),
                        favicons: viewIconSurfaces.map(\.iconPNGBase64), fallbackSystemImage: "globe",
                        isSelected: isActiveOnTargetMonitor,
                        isKeyboardTarget: isSearchSelectedWorkspace,
                        isLoading: workspace.isSingleWindowView && viewIconSurface?.isLoading == true)
                }
            }
            .buttonStyle(.plain)
            .help(workspace.displayName)
            .accessibilityLabel(workspace.displayName)
            .modifier(WorkspaceSidebarOptionalDragModifier(isEnabled: workspace.isSingleWindowView,
                onChanged: { value in
                    if let id = workspace.viewSurfaces.first?.surfaceID { actions.surfaceDragChanged(.surface(id), value) }
                }, onEnded: { value in
                    if let id = workspace.viewSurfaces.first?.surfaceID { actions.surfaceDragEnded(.surface(id), value) }
                }))
            .modifier(WorkspaceSidebarHoverClose(surface: workspace.isSingleWindowView && !isCompact ? workspace.viewSurfaces.first?.surfaceID : nil,
                title: workspace.displayName, actions: actions,
                selection: .init(isSelected: isActiveOnTargetMonitor, isFocused: workspace.isFocused,
                    isHovered: isHovered, isKeyboardTarget: isSearchSelectedWorkspace)))
            .contextMenu {
                if !workspace.isSingleWindowView, !workspace.projectId.isIncognito {
                    Button("Pin Group") { actions.send(.pinWorkspaceView(workspace.name)) }
                }
                if workspace.isSingleWindowView, let surface = workspace.viewSurfaces.first {
                    SurfaceViewActionsMenu(surface: surface.surfaceID, actions: actions)
                    Button(surface.isBrowser ? "Pin Tab" : "Pin App") { actions.send(.pinSurface(surface.surfaceID)) }
                    SurfaceMoveMenu(subject: .surface(surface.surfaceID), workspaceName: workspace.name,
                        targetMonitorScopeId: targetMonitorScopeId, actions: actions)
                    Divider()
                    Button(surface.isBrowser ? "Close Tab" : "Close Window") { actions.send(.closeSurface(surface.surfaceID)) }
                }
            }
            if !isCompact && !workspace.isSingleWindowView {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 20, height: rowHeight)
                    .help("Drag to reorder arrangement")
                    .modifier(WorkspaceSidebarWorkspaceDragModifier(name: workspace.name,
                        isEnabled: allowsWorkspaceReordering, actions: actions))
            }
        }
    }

    private var viewIconSurface: WorkspaceSidebarSurfaceItem? {
        let complete = TrayMenuModel.shared.workspaceSidebarWorkspaces.first { $0.name == workspace.name } ?? workspace
        if complete.isSingleWindowView { return complete.viewSurfaces.first }
        guard complete.items.count == 1, case .surfaceGroup(let id, _) = complete.items[0].kind else { return nil }
        return workspaceSidebarSurfaceStackRepresentative(complete.viewSurfaces,
            activeSurfaceID: BrowserWorkspaceController.shared.surfaceTree.activeSurfaces[id])
    }

    private var viewIconSurfaces: [WorkspaceSidebarSurfaceItem] {
        viewIconSurface.map { [$0] } ?? workspace.viewSurfaces
    }

    @ViewBuilder
    var headerSlot: some View {
        if !isRenamingWorkspace {
            headerButton
        } else {
            header
                .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
        }
    }
}
extension WorkspaceSidebarWorkspaceSection {
    func workspaceTabGroupView(_ group: WorkspaceSidebarTabGroupViewModel) -> some View {
        let isDragging = activeSidebarDragSourceWindowId == group.representativeWindowId
        return VStack(alignment: .leading, spacing: 1) {
            tabGroupHeaderButton(group)
            tabGroupTabs(group, isDragging: isDragging)
        }
        .padding(.vertical, 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.78), value: isDragging)
    }

    func tabGroupTabs(_ group: WorkspaceSidebarTabGroupViewModel, isDragging: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(group.searchVisibleTabs ?? group.tabs) { tab in
                workspaceWindowButton(
                    tab,
                    allowsDrag: true,
                    subject: .window,
                    leadingHitInset: isCompact ? 0 : density.isNarrow ? 6 : workspaceSidebarTabGroupChildLeadingIndent,
                )
            }
        }
        .opacity(1)
    }
}
extension WorkspaceSidebarWorkspaceSection {
    func tabGroupHeaderButton(_ group: WorkspaceSidebarTabGroupViewModel) -> some View {
        Button {
            guard allowsWorkspaceActivation else { return }
            guard shouldHandleWorkspaceSidebarActivation(isEditing: false, isSidebarDragInProgress: isWorkspaceSidebarDragInProgress()) else { return }
            if isInUseOnOtherDisplay {
                activeInUseOverrideWorkspaceName = workspace.name
                return
            }
            activeInUseOverrideWorkspaceName = nil
            if let representative = group.tabs.first(where: { $0.windowId == group.representativeWindowId }) {
                actions.send(.selectSurface(representative.surfaceID))
            } else {
                actions.send(.selectWorkspace(group.workspaceName))
            }
        } label: {
            WorkspaceSidebarWindowRow(
                title: "\(group.windowCount) \(group.windowCount == 1 ? "window" : "windows")",
                badge: nil,
                isFocused: group.isFocused,
                rowHeight: rowHeight,
                isHovered: hoveredTabGroupId == group.representativeWindowId,
                style: .tabGroupHeader,
                appBundleIds: group.tabs.map(\.appBundleId),
                appBundlePaths: group.tabs.map(\.appBundlePath),
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Window group · Active: \(group.title.isEmpty ? "Untitled window" : group.title)")
        .accessibilityLabel("Tab group of \(group.windowCount) windows")
        .contextMenu {
            WindowMoveMenu(
                windowId: group.representativeWindowId,
                workspaceName: group.workspaceName,
                subject: .group,
                targetMonitorScopeId: targetMonitorScopeId,
                actions: actions,
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .modifier(WorkspaceSidebarOptionalDragModifier(
            isEnabled: true,
            onChanged: { actions.tabGroupDragChanged(group.representativeWindowId, $0) },
            onEnded: { actions.tabGroupDragEnded(group.representativeWindowId, $0) },
        ))
        .workspaceSidebarDrag(enabled: true) {
            WorkspaceSidebarDragPayload.tabGroup(group.representativeWindowId).itemProvider
        }
        .onHover { hover in
            hoveredTabGroupId = hover ? group.representativeWindowId :
                (hoveredTabGroupId == group.representativeWindowId ? nil : hoveredTabGroupId)
        }
        .opacity(1)
    }
}
extension WorkspaceSidebarWorkspaceSection {
    func workspaceWindowButton(
        _ window: WorkspaceSidebarWindowViewModel,
        allowsDrag: Bool,
        subject: WindowDragSubject = .window,
        leadingHitInset: CGFloat = 0,
    ) -> some View {
        Button {
            guard allowsWorkspaceActivation else { return }
            guard shouldHandleWorkspaceSidebarActivation(isEditing: false, isSidebarDragInProgress: isWorkspaceSidebarDragInProgress()) else { return }
            if isInUseOnOtherDisplay {
                activeInUseOverrideWorkspaceName = workspace.name
                return
            }
            activeInUseOverrideWorkspaceName = nil
            actions.send(.selectSurface(window.surfaceID))
        } label: {
            WorkspaceSidebarWindowRow(
                title: window.title ?? window.appName,
                badge: nil,
                isFocused: window.isFocused,
                rowHeight: rowHeight,
                isHovered: hoveredWindowId == window.windowId,
                style: leadingHitInset > 0 ? .tabGroupChild : .window,
                appBundleIds: [window.appBundleId],
                appBundlePaths: [window.appBundlePath],
                isSelected: workspace.items.contains { item in
                    if case .tabGroup(let group) = item.kind { return group.representativeWindowId == window.windowId }
                    return false
                },
                isKeyboardTarget: selectedSearchTarget == .surface(window.surfaceID),
            )
            .padding(.leading, leadingHitInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .modifier(WorkspaceSidebarOptionalDragModifier(
            isEnabled: allowsDrag,
            onChanged: { pointer in
                if subject == .group {
                    actions.tabGroupDragChanged(window.windowId, pointer)
                } else {
                    actions.windowDragChanged(window.windowId, pointer)
                }
            },
            onEnded: { pointer in
                if subject == .group {
                    actions.tabGroupDragEnded(window.windowId, pointer)
                } else {
                    actions.windowDragEnded(window.windowId, pointer)
                }
            },
        ))
        .workspaceSidebarDrag(enabled: allowsDrag) {
            WorkspaceSidebarDragPayload.window(window.windowId).itemProvider
        }
        .help(window.title ?? window.appName)
        .modifier(WorkspaceSidebarHoverClose(surface: window.surfaceID, title: window.title ?? window.appName, actions: actions,
            selection: .init(isSelected: workspace.items.contains { item in
                if case .tabGroup(let group) = item.kind { return group.representativeWindowId == window.windowId }
                return false
            }, isFocused: window.isFocused, isHovered: hoveredWindowId == window.windowId,
                isKeyboardTarget: selectedSearchTarget == .surface(window.surfaceID))))
        .contextMenu {
            if layout.showsBrowserControls {
                Button("Pin App") { actions.send(.pinSurface(window.surfaceID)) }
                Divider()
            }
            WindowMoveMenu(
                windowId: window.windowId,
                workspaceName: window.workspaceName,
                subject: subject,
                targetMonitorScopeId: targetMonitorScopeId,
                actions: actions,
            )
        }
        .onHover { hover in
            hoveredWindowId = nextWorkspaceSidebarHoveredWindowId(
                currentHoveredWindowId: hoveredWindowId,
                windowId: window.windowId,
                isHovering: hover,
            )
        }
        .opacity(1)
        .animation(.spring(response: 0.2, dampingFraction: 0.78), value: activeSidebarDragSourceWindowId == window.windowId)
    }
}

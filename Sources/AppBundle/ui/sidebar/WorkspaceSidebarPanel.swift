import AppKit
import Common
import CoreGraphics
import SwiftUI

let workspaceSidebarPanelId = "WinMux.workspaceSidebar"
let workspaceSidebarContentLeadingInset: CGFloat = 6
let workspaceSidebarContentTrailingInset: CGFloat = 6
let workspaceSidebarCompactRailHorizontalInset: CGFloat = 7
let workspaceSidebarSectionInnerHorizontalInset: CGFloat = 0
let workspaceSidebarSectionGap: CGFloat = 2
let workspaceSidebarBadgeWidth: CGFloat = 22
let workspaceSidebarHeaderSpacing: CGFloat = 10
let workspaceSidebarHeaderRowLeadingPadding: CGFloat = 6
let workspaceSidebarRowsRevealProgress: CGFloat = 0.58
let workspaceSidebarPanelRightCornerRadius: CGFloat = RadiusToken.panel
let workspaceSidebarPlateCornerRadius: CGFloat = RadiusToken.section
let workspaceSidebarSectionCornerRadius: CGFloat = workspaceSidebarPlateCornerRadius
let workspaceSidebarRowCornerRadius: CGFloat = RadiusToken.row
let workspaceSidebarRowHorizontalPadding: CGFloat = 4
let workspaceSidebarRowLeadingPadding: CGFloat = 8
let workspaceSidebarWindowRowsLeadingIndent: CGFloat = 8
let workspaceSidebarAppIconSize: CGFloat = 16
let workspaceSidebarAppIconTextSpacing: CGFloat = 8
let workspaceSidebarTabGroupChildLeadingIndent: CGFloat = workspaceSidebarAppIconSize + workspaceSidebarAppIconTextSpacing - 2
let workspaceSidebarControlHeight: CGFloat = 30
let workspaceSidebarDropdownHeight: CGFloat = 28
let workspaceSidebarSearchHeight: CGFloat = 28
let workspaceSidebarDropdownCornerRadius: CGFloat = RadiusToken.card
let workspaceSidebarDropdownPadding: CGFloat = 7
let workspaceSidebarDropdownLabelSize: CGFloat = 11.5
let workspaceSidebarDropdownSymbolSize: CGFloat = 10.5
let workspaceSidebarPagerHeight: CGFloat = 32
let workspaceSidebarWorkspaceSectionHeaderHeight: CGFloat = 34
let workspaceSidebarWorkspaceRowHeight: CGFloat = 34
let workspaceSidebarWorkspaceSectionHeightExpanded: CGFloat = 34
let workspaceSidebarInUseOverrideEmptySectionMinHeight: CGFloat = 76
let workspaceSidebarProjectDotFrameWidth: CGFloat = 24
let workspaceSidebarProjectDotFrameHeight: CGFloat = 24
let workspaceSidebarMenuRowHeight: CGFloat = 28
let workspaceSidebarMenuRowSpacing: CGFloat = 3
let workspaceSidebarMenuRowHorizontalPadding: CGFloat = 10
let workspaceSidebarHoverAnimation: Animation = MotionToken.hover
let workspaceSidebarReducedMotionHoverAnimation: Animation = MotionToken.quick
let workspaceSidebarExpansionDuration: TimeInterval = 0.05
let workspaceSidebarExpansionAnimation: Animation = .easeOut(duration: workspaceSidebarExpansionDuration)
let workspaceSidebarCollapseDuration: TimeInterval = 0.04
let workspaceSidebarCollapseAnimation: Animation = .easeOut(duration: workspaceSidebarCollapseDuration)
let workspaceSidebarCollapseDelay: TimeInterval = 0.04
let workspaceSidebarProjectSwipeIntentThreshold: CGFloat = 5
let workspaceSidebarProjectSwipeNavigateThreshold: CGFloat = 44
let workspaceSidebarProjectSwipeCreateThreshold: CGFloat = 104
let workspaceSidebarProjectSwipeFormationStart: CGFloat = 22
let workspaceSidebarHoverOpenThresholdFraction: CGFloat = 0.75
let workspaceSidebarDisplayEdgeCompactionMargin: CGFloat = 12
@MainActor
var workspaceSidebarDropTargets: [WorkspaceSidebarDropTarget] = []

struct WorkspaceSidebarProjectColorPreset: Hashable, Identifiable {
    let name: String
    let hex: String

    var id: String { hex }
}

let workspaceSidebarProjectColorPresets: [WorkspaceSidebarProjectColorPreset] = [
    WorkspaceSidebarProjectColorPreset(name: "Blue", hex: "#7BA3C9"),
    WorkspaceSidebarProjectColorPreset(name: "Cyan", hex: "#6FBAB4"),
    WorkspaceSidebarProjectColorPreset(name: "Green", hex: "#7DBF8E"),
    WorkspaceSidebarProjectColorPreset(name: "Yellow", hex: "#C9B97A"),
    WorkspaceSidebarProjectColorPreset(name: "Orange", hex: "#C4956E"),
    WorkspaceSidebarProjectColorPreset(name: "Red", hex: "#C48181"),
    WorkspaceSidebarProjectColorPreset(name: "Pink", hex: "#BF8AAE"),
    WorkspaceSidebarProjectColorPreset(name: "Violet", hex: "#9B8FC4"),
]
extension WorkspaceSidebarPanel {
    var presentedSidebarConfig: WorkspaceSidebarConfig {
        workspaceSidebarPresentedConfig(config.workspaceSidebar, autoHidesForFullscreen: presentsAutoHideForFullscreen)
    }

    func animateVisibleSidebarWidth(_ width: CGFloat, animation: Animation) {
        guard viewModel.workspaceSidebarVisibleWidth != width else { return }
        let interval = signposter.beginInterval("Sidebar width publication", id: signposter.makeSignpostID())
        defer { signposter.endInterval("Sidebar width publication", interval) }
        debugWorkspaceSidebarHoverLog("animateWidth panel=\(monitorScopeId) from=\(viewModel.workspaceSidebarVisibleWidth) to=\(width) frame=\(frame) mouse=\(NSEvent.mouseLocation) ignores=\(ignoresMouseEvents) expanded=\(viewModel.isWorkspaceSidebarExpanded)")
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var transaction = Transaction(animation: reduceMotion ? nil : animation)
        transaction.disablesAnimations = reduceMotion
        withTransaction(transaction) {
            viewModel.workspaceSidebarVisibleWidth = width
        }
        updateMousePassthrough()
        // The hover region just changed size under a possibly stationary cursor.
        scheduleHoverRecheckSoon()
    }

    func expandSidebar(to requestedWidth: CGFloat) {
        // Menu tracking and inline search can request expansion again after the
        // action fires. They must retain the current presentation's full width.
        let expandedWidth = config.workspaceSidebar.placement == .top || viewModel.workspaceSidebarBrowseMode == .organize ? expandedPresentationWidth : requestedWidth
        debugWorkspaceSidebarHoverLog("expandSidebar panel=\(monitorScopeId) target=\(expandedWidth) visible=\(viewModel.workspaceSidebarVisibleWidth) frame=\(frame) mouse=\(NSEvent.mouseLocation)")
        cancelExpansionWork()
        // Pointer movement inside an open sidebar is not another transition. Avoid
        // republishing the model and restarting the view's search/expansion work.
        guard !viewModel.isWorkspaceSidebarExpanded || viewModel.workspaceSidebarVisibleWidth != expandedWidth else {
            updateMousePassthrough()
            return
        }
        NotificationCenter.default.post(name: workspaceSidebarWillExpandNotification, object: self)
        viewModel.setIfChanged(\.isWorkspaceSidebarExpanded, true)
        if !isVisible {
            refresh()
        }
        guard viewModel.workspaceSidebarVisibleWidth != expandedWidth else {
            updateMousePassthrough()
            return
        }
        animateVisibleSidebarWidth(expandedWidth, animation: workspaceSidebarExpansionAnimation)
    }

    func cancelExpansionWork() {
        debugWorkspaceSidebarHoverLog("cancelExpansionWork panel=\(monitorScopeId) pendingCollapse=\(pendingCollapse != nil) pendingFinalize=\(pendingCollapseFinalize != nil)")
        pendingCollapse?.cancel()
        pendingCollapse = nil
        pendingCollapseFinalize?.cancel()
        pendingCollapseFinalize = nil
    }
}
extension WorkspaceSidebarPanel {
    func updateDropTargets(_ targets: [WorkspaceSidebarDropTargetFrame]) {
        dropTargetFrames = targets
        dropTargets = convertDropTargets(targets)
        Self.updateVisibleDropTargets()
    }

    func convertDropTargets(_ targets: [WorkspaceSidebarDropTargetFrame]) -> [WorkspaceSidebarDropTarget] {
        targets.compactMap { target in
            let windowRect = hostingView.convert(target.frame, to: nil)
            let screenRect = convertToScreen(windowRect)
            let clipRect = target.clipFrame.map { convertToScreen(hostingView.convert($0, to: nil)).monitorFrameNormalized() }
            return WorkspaceSidebarDropTarget(kind: target.kind, rect: screenRect.monitorFrameNormalized(), clipRect: clipRect)
        }
    }

    func visibleScreenRectNormalized() -> Rect? {
        guard isVisible, viewModel.workspaceSidebarVisibleWidth > 0 else { return nil }
        return CGRect(
            x: frame.minX,
            y: frame.minY,
            width: min(viewModel.workspaceSidebarVisibleWidth, frame.width),
            height: frame.height,
        ).monitorFrameNormalized()
    }
}
extension WorkspaceSidebarPanel {
    static func suppressEdgeTrapForWorkspaceActivation(duration: TimeInterval = 0.75) {
        let until = ProcessInfo.processInfo.systemUptime + duration
        for panel in visiblePanels {
            debugWorkspaceSidebarEdgeTrapLog("suppress panel=\(panel.monitorScopeId) until=\(until) sample=\(MousePointerTracker.shared.currentSample)")
            panel.edgeTrapStartedAt = nil
            panel.edgeTrapSuppressedUntil = max(panel.edgeTrapSuppressedUntil, until)
            panel.lastEdgeTrapSample = MousePointerTracker.shared.currentSample
        }
    }

    static func trapCursorForVisiblePanelsIfNeeded() {
        for panel in visiblePanels {
            panel.trapCursorForLeftEdgeSidebarActivationIfNeeded()
        }
    }

    func trapCursorForLeftEdgeSidebarActivationIfNeeded() {
        let sample = MousePointerTracker.shared.currentSample
        let collapsedWidth = workspaceSidebarRestingWidth(presentedSidebarConfig)
        debugWorkspaceSidebarEdgeTrapLog(
            "entry panel=\(monitorScopeId) visible=\(isVisible) enabled=\(config.workspaceSidebar.enabled) shift=\(currentSessionModifierFlags().contains(.maskShift)) mouseDrag=\(isMouseWindowDragInProgress()) sidebarDrag=\(isWorkspaceSidebarItemDragActive()) width=\(viewModel.workspaceSidebarVisibleWidth) collapsed=\(collapsedWidth) sample=\(sample) previous=\(String(describing: lastEdgeTrapSample)) suppressUntil=\(edgeTrapSuppressedUntil) startedAt=\(String(describing: edgeTrapStartedAt))"
        )
        guard isVisible,
              config.workspaceSidebar.enabled,
              workspaceSidebarAllowsLeftEdgeTrap(presentedSidebarConfig),
              !currentSessionModifierFlags().contains(.maskShift),
              !isMouseWindowDragInProgress(),
              !isWorkspaceSidebarItemDragActive(),
              viewModel.workspaceSidebarVisibleWidth <= collapsedWidth + 0.5
        else {
            debugWorkspaceSidebarEdgeTrapLog("skipPreconditions panel=\(monitorScopeId)")
            edgeTrapStartedAt = nil
            lastEdgeTrapSample = sample
            return
        }

        defer { lastEdgeTrapSample = sample }
        let previous = lastEdgeTrapSample
        guard sample.timestamp >= edgeTrapSuppressedUntil,
              let layoutMonitor = sortedMonitors.first(where: { workspaceSidebarMonitorScopeId(for: $0) == monitorScopeId })
        else {
            debugWorkspaceSidebarEdgeTrapLog("skipSuppressedOrNoMonitor panel=\(monitorScopeId) sampleTime=\(sample.timestamp) suppressUntil=\(edgeTrapSuppressedUntil)")
            edgeTrapStartedAt = nil
            return
        }
        let hasLeftMonitor = hasMonitorImmediatelyLeft(of: layoutMonitor)
        let crossesTrapRegion = crossesLeftEdgeTrapRegion(point: sample.point, previous: previous?.point, of: layoutMonitor)
        guard hasLeftMonitor, crossesTrapRegion else {
            debugWorkspaceSidebarEdgeTrapLog("skipRegion panel=\(monitorScopeId) hasLeftMonitor=\(hasLeftMonitor) crosses=\(crossesTrapRegion) monitorFrame=\(layoutMonitor.rect) samplePoint=\(sample.point) previousPoint=\(String(describing: previous?.point))")
            edgeTrapStartedAt = nil
            return
        }

        let deltaX = previous.map { sample.point.x - $0.point.x } ?? 0
        let isLeftwardFlick = deltaX <= -edgeTrapReleaseVelocityThreshold
        let isContinuingTrap = edgeTrapStartedAt != nil && sample.point.x <= layoutMonitor.rect.minX + edgeTrapBandWidth
        let shouldTrap = isContinuingTrap || isLeftwardFlick || isMouseWindowDragInProgress()
        guard shouldTrap else {
            debugWorkspaceSidebarEdgeTrapLog("skipVelocity panel=\(monitorScopeId) deltaX=\(deltaX) isLeftwardFlick=\(isLeftwardFlick) isContinuingTrap=\(isContinuingTrap)")
            edgeTrapStartedAt = nil
            return
        }

        let startedAt = edgeTrapStartedAt ?? sample.timestamp
        edgeTrapStartedAt = startedAt
        guard sample.timestamp - startedAt < edgeTrapReleaseDelay else {
            debugWorkspaceSidebarEdgeTrapLog("release panel=\(monitorScopeId) elapsed=\(sample.timestamp - startedAt) grace=\(edgeTrapCrossingGrace)")
            edgeTrapStartedAt = nil
            edgeTrapSuppressedUntil = sample.timestamp + edgeTrapCrossingGrace
            return
        }

        let trappedPoint = CGPoint(
            x: layoutMonitor.rect.minX + 1,
            y: sample.point.y.coerce(in: layoutMonitor.rect.minY ... max(layoutMonitor.rect.minY, layoutMonitor.rect.maxY - 1))
        )
        debugWorkspaceSidebarEdgeTrapLog("warp panel=\(monitorScopeId) from=\(sample.point) to=\(trappedPoint) deltaX=\(deltaX) isLeftwardFlick=\(isLeftwardFlick) isContinuingTrap=\(isContinuingTrap) elapsed=\(sample.timestamp - startedAt) monitorFrame=\(layoutMonitor.rect)")
        CGWarpMouseCursorPosition(trappedPoint)
        MousePointerTracker.shared.note(point: trappedPoint, timestamp: sample.timestamp)
    }

    private func hasMonitorImmediatelyLeft(of monitor: Monitor) -> Bool {
        sortedMonitors.contains { other in
            other.rect.maxX == monitor.rect.minX &&
                other.rect.maxY > monitor.rect.minY &&
                other.rect.minY < monitor.rect.maxY
        }
    }

    private func isInsideVerticalSpan(_ point: CGPoint, of monitor: Monitor) -> Bool {
        point.y >= monitor.rect.minY && point.y < monitor.rect.maxY
    }

    private func crossesLeftEdgeTrapRegion(point: CGPoint, previous: CGPoint?, of monitor: Monitor) -> Bool {
        if isInsideVerticalSpan(point, of: monitor),
           point.x >= monitor.rect.minX - edgeTrapBandWidth,
           point.x <= monitor.rect.minX + edgeTrapBandWidth
        {
            return true
        }
        guard let previous else { return false }
        let crossedLeftEdge = previous.x >= monitor.rect.minX && point.x < monitor.rect.minX
        let crossedBackIntoMonitor = previous.x < monitor.rect.minX && point.x >= monitor.rect.minX
        let crossedTrapBand = previous.x > monitor.rect.minX + edgeTrapBandWidth &&
            point.x < monitor.rect.minX - edgeTrapBandWidth
        guard crossedLeftEdge || crossedBackIntoMonitor || crossedTrapBand else { return false }
        return segmentIntersectsVerticalSpan(from: previous, to: point, of: monitor)
    }

    private func segmentIntersectsVerticalSpan(from start: CGPoint, to end: CGPoint, of monitor: Monitor) -> Bool {
        let minY = min(start.y, end.y)
        let maxY = max(start.y, end.y)
        return maxY >= monitor.rect.minY && minY < monitor.rect.maxY
    }
}
enum WorkspaceSidebarInlineTextKey {
    case text(String)
    case deleteBackward
    case deleteForward
    case deleteWordBackward
    case deleteToBeginningOfLine
    case moveUp
    case moveDown
    case commit
    case cancel
    case ignored
}

private let workspaceSidebarInlineTextEventTapCallback: CGEventTapCallBack = { _, type, event, _ in
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    let key = workspaceSidebarInlineTextKey(from: event)
    if case .ignored = key {
        return Unmanaged.passUnretained(event)
    }
    DispatchQueue.main.async {
        _ = WorkspaceSidebarPanel.activeInlineTextEditingPanel?.handleInlineTextEditingKey(key)
    }
    return nil
}

private func workspaceSidebarInlineTextKey(from event: CGEvent) -> WorkspaceSidebarInlineTextKey {
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let usesCommand = flags.contains(.maskCommand)
    let usesOption = flags.contains(.maskAlternate)
    let usesControl = flags.contains(.maskControl)
    switch keyCode {
        case 36, 76:
            return .commit
        case 53:
            return .cancel
        case 51:
            if usesCommand {
                return .deleteToBeginningOfLine
            }
            if usesOption {
                return .deleteWordBackward
            }
            return .deleteBackward
        case 117:
            return .deleteForward
        case 126:
            return .moveUp
        case 125:
            return .moveDown
        default:
            break
    }

    guard !usesCommand, !usesOption, !usesControl else {
        return .ignored
    }

    var length = 0
    var chars = [UniChar](repeating: 0, count: 8)
    event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
    guard length > 0 else { return .ignored }
    let text = String(utf16CodeUnits: chars, count: length)
    guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        return .ignored
    }
    return text.isEmpty ? .ignored : .text(text)
}

extension WorkspaceSidebarPanel {
    func inlineTextKey(from event: NSEvent) -> WorkspaceSidebarInlineTextKey {
        let usesCommand = event.modifierFlags.contains(.command)
        let usesOption = event.modifierFlags.contains(.option)
        let usesControl = event.modifierFlags.contains(.control)
        switch event.keyCode {
            case 36, 76:
                return .commit
            case 53:
                return .cancel
            case 51:
                if usesCommand {
                    return .deleteToBeginningOfLine
                }
                if usesOption {
                    return .deleteWordBackward
                }
                return .deleteBackward
            case 117:
                return .deleteForward
            case 126:
                return .moveUp
            case 125:
                return .moveDown
            default:
                break
        }

        guard !usesCommand, !usesOption, !usesControl,
              let text = event.characters,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            return .ignored
        }
        return text.isEmpty ? .ignored : .text(text)
    }

    func beginInlineTextEditing(
        locksExpansion: Bool = true,
        cancelsOnPointerExit: Bool = true,
        onCancel: (@MainActor () -> Void)? = nil,
        onKeyDown: (@MainActor (WorkspaceSidebarInlineTextKey) -> Void)? = nil
    ) {
        debugWorkspaceSidebarRenameLog("beginInlineTextEditing isKeyBefore=\(isKeyWindow) firstResponder=\(String(describing: firstResponder)) mouseInside=\(isMouseInsideVisibleRegion())")
        let startsSession = !inlineTextEditingActive || Self.activeInlineTextEditingPanel !== self
        inlineTextEditingActive = true
        inlineTextEditingLocksExpansion = locksExpansion
        inlineTextEditingCancelsOnPointerExit = cancelsOnPointerExit
        WorkspaceSidebarPanel.activeInlineTextEditingPanel = self
        inlineTextEditingCancel = onCancel
        inlineTextEditingKeyDown = onKeyDown
        // Command search hands its buffered keys to SwiftUI without starting
        // another session, activating the app again, or replacing the event tap.
        if startsSession {
            inlineTextEditingStartedAt = .now
            inlineTextEditingPointerEnteredVisibleRegion = isMouseInsideVisibleRegion()
            prepareForInlineTextEditing()
            installInlineTextEditingKeyEventTap()
        }
        installInlineTextEditingEventMonitors()
    }

    func endInlineTextEditing() {
        guard inlineTextEditingActive else { return }
        debugWorkspaceSidebarRenameLog("endInlineTextEditing isKey=\(isKeyWindow) firstResponder=\(String(describing: firstResponder))")
        inlineTextEditingActive = false
        inlineTextEditingLocksExpansion = true
        inlineTextEditingCancelsOnPointerExit = true
        if WorkspaceSidebarPanel.activeInlineTextEditingPanel === self {
            WorkspaceSidebarPanel.activeInlineTextEditingPanel = nil
        }
        inlineTextEditingCancel = nil
        inlineTextEditingKeyDown = nil
        inlineTextEditingPointerEnteredVisibleRegion = false
        removeInlineTextEditingEventMonitors()
        removeInlineTextEditingKeyEventTap()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.updateHoverStateFromMousePosition()
        }
    }

    func prepareForInlineTextEditing() {
        debugWorkspaceSidebarRenameLog("prepareForInlineTextEditing before visible=\(isVisible) isKey=\(isKeyWindow) ignoresMouse=\(ignoresMouseEvents) firstResponder=\(String(describing: firstResponder))")
        cancelExpansionWork()
        expandSidebar(to: CGFloat(config.workspaceSidebar.width))
        ignoresMouseEvents = false
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        makeKey()
        NSApp.activate(ignoringOtherApps: true)
        debugWorkspaceSidebarRenameLog("prepareForInlineTextEditing after visible=\(isVisible) isKey=\(isKeyWindow) ignoresMouse=\(ignoresMouseEvents) firstResponder=\(String(describing: firstResponder)) activeApp=\(NSApp.isActive)")
    }

    func cancelInlineTextEditing() {
        guard inlineTextEditingActive else { return }
        debugWorkspaceSidebarRenameLog("cancelInlineTextEditing isKey=\(isKeyWindow) firstResponder=\(String(describing: firstResponder))")
        inlineTextEditingCancel?()
    }

    func handleInlineTextEditingKey(_ key: WorkspaceSidebarInlineTextKey) -> Bool {
        guard inlineTextEditingActive, let inlineTextEditingKeyDown else { return false }
        debugWorkspaceSidebarRenameLog("handleInlineTextEditingKey key=\(key)")
        inlineTextEditingKeyDown(key)
        if case .ignored = key {
            return false
        }
        return true
    }

    func shouldCancelInlineTextEditingForOutsidePointer(isMouseDown: Bool) -> Bool {
        guard inlineTextEditingCancelsOnPointerExit else { return false }
        if isMouseInsideVisibleRegion() {
            inlineTextEditingPointerEnteredVisibleRegion = true
            return false
        }
        if inlineTextEditingPointerEnteredVisibleRegion {
            debugWorkspaceSidebarRenameLog("outsidePointerCancel afterEntered isMouseDown=\(isMouseDown)")
            return true
        }
        let shouldCancel = isMouseDown && Date().timeIntervalSince(inlineTextEditingStartedAt) > 0.25
        if shouldCancel {
            debugWorkspaceSidebarRenameLog("outsidePointerCancel clickGraceElapsed")
        }
        return shouldCancel
    }

    func installInlineTextEditingEventMonitors() {
        // Search deliberately stays active on pointer exit. Installing four
        // monitors for that policy only enqueued no-op work on every mouse move.
        guard inlineTextEditingCancelsOnPointerExit else {
            removeInlineTextEditingEventMonitors()
            return
        }
        guard inlineTextEditingEventMonitors.isEmpty else { return }
        let mouseDownMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let localMouseDown = NSEvent.addLocalMonitorForEvents(matching: mouseDownMask) { [weak self] event in
            guard let self else { return event }
            if !self.isEventInsideVisibleRegion(event),
               self.shouldCancelInlineTextEditingForOutsidePointer(isMouseDown: true)
            {
                Task { @MainActor in self.cancelInlineTextEditing() }
            }
            return event
        }
        let localMouseMove = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] event in
            guard let self else { return event }
            if self.shouldCancelInlineTextEditingForOutsidePointer(isMouseDown: false) {
                Task { @MainActor in self.cancelInlineTextEditing() }
            }
            return event
        }
        let globalMouseDown = NSEvent.addGlobalMonitorForEvents(matching: mouseDownMask) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                if !self.isScreenPointInsideVisibleRegion(event.locationInWindow),
                   self.shouldCancelInlineTextEditingForOutsidePointer(isMouseDown: true)
                {
                    self.cancelInlineTextEditing()
                }
            }
        }
        let globalMouseMove = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.shouldCancelInlineTextEditingForOutsidePointer(isMouseDown: false) {
                    self.cancelInlineTextEditing()
                }
            }
        }
        inlineTextEditingEventMonitors = [localMouseDown, localMouseMove, globalMouseDown, globalMouseMove].compactMap { $0 }
    }

    func removeInlineTextEditingEventMonitors() {
        for monitor in inlineTextEditingEventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        inlineTextEditingEventMonitors = []
    }

    func installInlineTextEditingKeyEventTap() {
        removeInlineTextEditingKeyEventTap()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: workspaceSidebarInlineTextEventTapCallback,
            userInfo: nil
        ) else {
            debugWorkspaceSidebarRenameLog("installKeyEventTap failed")
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            debugWorkspaceSidebarRenameLog("installKeyEventTap source failed")
            return
        }
        inlineTextEditingKeyEventTap = tap
        inlineTextEditingKeyEventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        debugWorkspaceSidebarRenameLog("installKeyEventTap ok")
    }

    func removeInlineTextEditingKeyEventTap() {
        if let source = inlineTextEditingKeyEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = inlineTextEditingKeyEventTap {
            CFMachPortInvalidate(tap)
        }
        inlineTextEditingKeyEventTap = nil
        inlineTextEditingKeyEventTapRunLoopSource = nil
    }

    func isEventInsideVisibleRegion(_ event: NSEvent) -> Bool {
        guard event.window === self else { return false }
        let point = convertPoint(toScreen: event.locationInWindow)
        return isScreenPointInsideVisibleRegion(point)
    }

    func isScreenPointInsideVisibleRegion(_ point: CGPoint) -> Bool {
        guard isVisible else { return false }
        let visibleRegion = NSRect(
            x: frame.minX,
            y: frame.minY,
            width: viewModel.workspaceSidebarVisibleWidth,
            height: frame.height,
        )
        return visibleRegion.contains(point)
    }
}
struct WorkspaceSidebarPanelLayout {
    let frame: NSRect
    let expandedWidth: CGFloat
    let collapsedWidth: CGFloat
}

extension WorkspaceSidebarPanel {
    func currentSidebarPanelLayout() -> WorkspaceSidebarPanelLayout? {
        currentSidebarPanelLayout(on: workspaceSidebarMonitor(forScopeId: monitorScopeId) ?? workspaceSidebarResolvedPanelMonitor())
    }

    func currentSidebarPanelLayout(on monitor: Monitor) -> WorkspaceSidebarPanelLayout? {
        guard TrayMenuModel.shared.isEnabled,
              config.workspaceSidebar.enabled,
              let screen = workspaceSidebarPanelScreen(for: monitor)
        else { return nil }
        let hasFullscreenContent = shouldSuppressWorkspaceSidebarForFullscreenContent(on: monitor)
        let sidebarConfig = workspaceSidebarPresentedConfig(config.workspaceSidebar, autoHidesForFullscreen: hasFullscreenContent)
        if sidebarConfig.placement == .top {
            // The top bar has no edge reveal, so fullscreen content hides it entirely.
            guard !hasFullscreenContent else { return nil }
            let topFrame = workspaceTopBarFrame(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, configuration: sidebarConfig)
            return WorkspaceSidebarPanelLayout(frame: topFrame, expandedWidth: topFrame.width, collapsedWidth: topFrame.width)
        }
        let expandedWidth = CGFloat(sidebarConfig.width)
        let maximumExpandedWidth = viewModel.workspaceSidebarBrowseMode == .organize
            ? WorkspaceSidebarOrganizeLayout(expandedWidth: expandedWidth, projectCount: viewModel.workspaceSidebarProjects.count, availableWidth: screen.frame.width).visibleWidth
            : min(expandedWidth, screen.frame.width)
        let collapsedWidth = workspaceSidebarRestingWidth(sidebarConfig)
        guard expandedWidth > 0, collapsedWidth >= 0 else { return nil }

        return WorkspaceSidebarPanelLayout(
            frame: workspaceSidebarPanelFrame(screenFrame: screen.frame, width: maximumExpandedWidth, configuration: sidebarConfig),
            expandedWidth: expandedWidth,
            collapsedWidth: collapsedWidth,
        )
    }

    func workspaceSidebarPanelScreen() -> NSScreen? {
        workspaceSidebarPanelScreen(for: workspaceSidebarMonitor(forScopeId: monitorScopeId) ?? workspaceSidebarResolvedPanelMonitor())
    }

    func workspaceSidebarPanelScreen(for monitor: Monitor) -> NSScreen? {
        NSScreen.screens.getOrNil(
            atIndex: monitor.monitorAppKitNsScreenScreensId - 1
        ) ?? NSScreen.screens.first
    }
}
extension WorkspaceSidebarPanel {
    func setHovering(_ isHovering: Bool) {
        guard config.workspaceSidebar.placement == .side else { return }
        guard !isResizingSidebar else { return }
        // An explicit hide/collapse must survive a stationary pointer. Re-arm
        // hover after it leaves the activation region; a keyboard open bypasses it.
        if commandSuppressesHoverExpansion {
            guard !isHovering else { return }
            commandSuppressesHoverExpansion = false
        }
        let expandedWidth = CGFloat(config.workspaceSidebar.width)
        let collapsedWidth = workspaceSidebarRestingWidth(presentedSidebarConfig)
        if viewModel.workspaceSidebarVisibleWidth > collapsedWidth + 0.5 || pendingCollapse != nil {
            debugWorkspaceSidebarHoverLog("setHovering panel=\(monitorScopeId) isHovering=\(isHovering) visible=\(viewModel.workspaceSidebarVisibleWidth) frame=\(frame) mouse=\(NSEvent.mouseLocation)")
        }
        if isHovering {
            handleHoverEnter(
                expandedWidth: max(expandedWidth, viewModel.workspaceSidebarVisibleWidth),
                collapsedWidth: collapsedWidth
            )
        } else {
            handleHoverExit(collapsedWidth: collapsedWidth)
        }
    }

    func shouldLockExpansionForSidebarDrag() -> Bool {
        shouldLockWorkspaceSidebarExpansion(
            hasDropPreview: TrayMenuModel.shared.workspaceSidebarDropPreview != nil,
            hasPinnedDraggedWindow: hasPinnedDraggedWindow(),
            isSidebarDragInProgress: isWorkspaceSidebarDragInProgress(),
            hasActiveEditor: isMenuTrackingOrInGracePeriod() || shouldKeepSidebarOpenForInlineTextEditing(),
        ) || isMouseWindowDragInProgress()
    }

    func shouldKeepSidebarOpenForInlineTextEditing() -> Bool {
        projectIconPicker != nil || isResizingSidebar || commandExpansionLocksCollapse || (inlineTextEditingActive && inlineTextEditingLocksExpansion)
    }
}
extension WorkspaceSidebarPanel {
    func showHoverCue(cueWidth: CGFloat, expandedWidth: CGFloat) {
        // A deliberate entry goes straight to its final width in this event.
        // Dispatching even a zero-delay work item puts opening behind unrelated
        // main-queue work and can cost an extra display frame.
        if isMouseDeepEnoughToExpand() {
            expandSidebar(to: expandedWidth)
            return
        }
        if !isVisible {
            refresh()
        }
        if viewModel.workspaceSidebarVisibleWidth < cueWidth {
            animateVisibleSidebarWidth(
                cueWidth,
                animation: .spring(response: hoverCueAnimationResponse, dampingFraction: 0.72),
            )
        } else {
            updateMousePassthrough()
        }
    }
}
extension WorkspaceSidebarPanel {
    func handleHoverEnter(expandedWidth: CGFloat, collapsedWidth: CGFloat) {
        let cueWidth = workspaceSidebarHoverCueWidth(collapsedWidth: collapsedWidth, expandedWidth: expandedWidth)
        let isExpansionLocked = shouldLockExpansionForSidebarDrag()
        let isExternalWindowDrag = isMouseWindowDragInProgress()
        let isSidebarOriginatedDrag = getCurrentMouseDragStartedInSidebar()
        let shouldSuppressDragExpansion = shouldSuppressWorkspaceSidebarHoverExpansionForDrag(
            isSidebarItemDragActive: isWorkspaceSidebarItemDragActive(),
            isSidebarOriginatedDrag: isSidebarOriginatedDrag,
        )
        pendingCollapse?.cancel()
        pendingCollapse = nil
        pendingCollapseFinalize?.cancel()
        pendingCollapseFinalize = nil
        if shouldSuppressDragExpansion {
            updateMousePassthrough()
            return
        }

        if isExternalWindowDrag && !isSidebarOriginatedDrag && isMousePushedAgainstDisplayEdge() && viewModel.workspaceSidebarBrowseMode != .organize {
            showCollapsedSidebarDuringExternalDrag(
                collapsedWidth: workspaceSidebarHoverActivationWidth(presentedSidebarConfig)
            )
            return
        }
        if !shouldDelayWorkspaceSidebarExpansion(
            isExpanded: viewModel.isWorkspaceSidebarExpanded,
            isExpansionLocked: isExpansionLocked,
            isMouseWindowDragInProgress: isExternalWindowDrag,
        ) {
            expandSidebar(to: expandedWidth)
            return
        }
        showHoverCue(cueWidth: cueWidth, expandedWidth: expandedWidth)
    }

    func showCollapsedSidebarDuringExternalDrag(collapsedWidth: CGFloat) {
        if !isVisible {
            refresh()
        }
        if viewModel.workspaceSidebarVisibleWidth != collapsedWidth {
            animateVisibleSidebarWidth(collapsedWidth, animation: workspaceSidebarCollapseAnimation)
        } else {
            updateMousePassthrough()
        }
    }
}
extension WorkspaceSidebarPanel {
    func handleHoverExit(collapsedWidth: CGFloat) {
        debugWorkspaceSidebarHoverLog("handleHoverExit panel=\(monitorScopeId) visible=\(viewModel.workspaceSidebarVisibleWidth) collapsed=\(collapsedWidth) expanded=\(viewModel.isWorkspaceSidebarExpanded) suppressActive=\(Date() < organizeCollapseSuppressedUntil) mouse=\(NSEvent.mouseLocation)")
        guard Date() >= organizeCollapseSuppressedUntil, !shouldLockExpansionForSidebarDrag() else { return }
        if workspaceSidebarKeepsExpandedAtRest(presentedSidebarConfig) {
            cancelExpansionWork()
            resetBrowseMode()
            expandSidebar(to: CGFloat(config.workspaceSidebar.width))
            return
        }
        let needsCollapse =
            viewModel.isWorkspaceSidebarExpanded ||
            viewModel.workspaceSidebarVisibleWidth != collapsedWidth
        guard needsCollapse, pendingCollapse == nil, pendingCollapseFinalize == nil else {
            debugWorkspaceSidebarHoverLog("handleHoverExit noop panel=\(monitorScopeId) needsCollapse=\(needsCollapse) pendingCollapse=\(pendingCollapse != nil)")
            return
        }
        scheduleCollapse(collapsedWidth: collapsedWidth)
    }

    func scheduleCollapse(collapsedWidth: CGFloat) {
        guard !workspaceSidebarKeepsExpandedAtRest(presentedSidebarConfig), pendingCollapse == nil, pendingCollapseFinalize == nil else { return }
        debugWorkspaceSidebarHoverLog("scheduleCollapse panel=\(monitorScopeId) visible=\(viewModel.workspaceSidebarVisibleWidth) collapsed=\(collapsedWidth) mouse=\(NSEvent.mouseLocation)")
        let collapse = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCollapse = nil
            guard !workspaceSidebarKeepsExpandedAtRest(presentedSidebarConfig) else { return }
            debugWorkspaceSidebarHoverLog("collapseFire panel=\(self.monitorScopeId) visible=\(self.viewModel.workspaceSidebarVisibleWidth) mouse=\(NSEvent.mouseLocation) suppressActive=\(Date() < self.organizeCollapseSuppressedUntil)")
            guard Date() >= self.organizeCollapseSuppressedUntil else {
                debugWorkspaceSidebarHoverLog("collapseFire suppressed panel=\(self.monitorScopeId)")
                return
            }
            let inside = self.isMouseInsideHoverRegion()
            let locked = self.shouldLockExpansionForSidebarDrag()
            guard !inside, !locked else {
                debugWorkspaceSidebarHoverLog("collapseFire cancelled panel=\(self.monitorScopeId) inside=\(inside) locked=\(locked)")
                return
            }
            // Keep content intact during the short exit grace period. Start its
            // transition together with the width change, after cancellation checks.
            NotificationCenter.default.post(name: workspaceSidebarWillCollapseNotification, object: self)
            self.animateVisibleSidebarWidth(collapsedWidth, animation: workspaceSidebarCollapseAnimation)
            self.scheduleCollapseFinalize()
        }
        pendingCollapse = collapse
        let collapseDelay: TimeInterval = viewModel.isWorkspaceSidebarExpanded ? workspaceSidebarCollapseDelay : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay, execute: collapse)
    }

    func scheduleCollapseFinalize() {
        let finalize = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCollapseFinalize = nil
            guard !workspaceSidebarKeepsExpandedAtRest(presentedSidebarConfig) else { return }
            debugWorkspaceSidebarHoverLog("collapseFinalize panel=\(self.monitorScopeId) visible=\(self.viewModel.workspaceSidebarVisibleWidth) mouse=\(NSEvent.mouseLocation) suppressActive=\(Date() < self.organizeCollapseSuppressedUntil)")
            guard Date() >= self.organizeCollapseSuppressedUntil else { return }
            let inside = self.isMouseInsideHoverRegion()
            let locked = self.shouldLockExpansionForSidebarDrag()
            guard !inside, !locked else {
                debugWorkspaceSidebarHoverLog("collapseFinalize cancelled panel=\(self.monitorScopeId) inside=\(inside) locked=\(locked)")
                return
            }
            self.resetBrowseMode()
            viewModel.isWorkspaceSidebarExpanded = false
            self.updateMousePassthrough()
        }
        pendingCollapseFinalize = finalize
        DispatchQueue.main.asyncAfter(deadline: .now() + workspaceSidebarCollapseDuration, execute: finalize)
    }
}
extension WorkspaceSidebarPanel {
    func installMenuTrackingObservers() {
        let center = NotificationCenter.default
        menuTrackingObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.beginMenuTrackingIfNeeded() }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.endMenuTrackingIfNeeded() }
            },
        ]
    }

    func beginMenuTrackingIfNeeded() {
        guard isVisible,
              viewModel.workspaceSidebarVisibleWidth > 0,
              isMouseInsideVisibleRegion()
        else { return }
        menuTrackingDepth += 1
        menuTrackingGraceUntil = .distantFuture
        pendingCollapse?.cancel()
        pendingCollapse = nil
        pendingCollapseFinalize?.cancel()
        pendingCollapseFinalize = nil
        expandSidebar(to: CGFloat(config.workspaceSidebar.width))
    }

    func endMenuTrackingIfNeeded() {
        guard menuTrackingDepth > 0 else { return }
        menuTrackingDepth -= 1
        guard menuTrackingDepth == 0 else { return }
        menuTrackingGraceUntil = Date().addingTimeInterval(menuTrackingEndGrace)
        // Recheck once after grace expires, even if the pointer stopped moving.
        DispatchQueue.main.asyncAfter(deadline: .now() + menuTrackingEndGrace + 0.01) { [weak self] in
            self?.updateHoverStateFromMousePosition()
        }
    }

    func isMenuTrackingOrInGracePeriod(now: Date = .now) -> Bool {
        menuTrackingDepth > 0 || now < menuTrackingGraceUntil
    }
}
extension WorkspaceSidebarPanel {
    /// Hover state is a pure function of the mouse position and the panel geometry, so it is
    /// driven by the global/local pointer-event monitors (mouse position changes) plus explicit
    /// rechecks at the points where the panel itself appears or resizes (geometry changes).
    /// This used to be a permanent CVDisplayLink subscription polling at 30Hz, which kept the
    /// display link running and woke the main actor every vsync even when the machine was idle.
    /// PointerActivityCoalescer already limits movement to the display refresh rate;
    /// do not add another timer here, especially on displays faster than 60 Hz.
    static func noteHoverPointerActivityForVisiblePanels() {
        for panel in visiblePanels {
            // Use the existing coalesced pointer stream instead of installing
            // another monitor pair (and delayed installers) on each keyboard open.
            panel.unlockCommandSidebarExpansionIfMouseMoved()
            panel.updateHoverStateFromMousePosition()
        }
    }

    /// For lock-release points that arrive without pointer movement (drag ends on mouse-up
    /// with a stationary cursor): the expansion locks cleared, so hover must be re-evaluated
    /// even though no pointer event will fire.
    static func scheduleHoverRecheckForVisiblePanels() {
        for panel in visiblePanels {
            panel.scheduleHoverRecheckSoon()
        }
    }

    /// Deferred (not inline) so hover reevaluation can be requested from inside
    /// expansion/collapse/refresh paths without re-entering them synchronously.
    func scheduleHoverRecheckSoon() {
        guard !hasPendingHoverRecheck else { return }
        hasPendingHoverRecheck = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasPendingHoverRecheck = false
            self.updateHoverStateFromMousePosition()
        }
    }

    func updateHoverStateFromMousePosition() {
        guard isVisible else { return }
        updateMousePassthrough()
        setHovering(isMouseInsideHoverRegion())
    }
}
extension WorkspaceSidebarPanel {
    func updateMousePassthrough() {
        let inside = isMouseInsideVisibleRegion()
        let shouldIgnoreMouseEvents = !inside
        if ignoresMouseEvents != shouldIgnoreMouseEvents {
            debugWorkspaceSidebarHoverLog("mousePassthrough panel=\(monitorScopeId) ignores \(ignoresMouseEvents)->\(shouldIgnoreMouseEvents) insideVisible=\(inside) visibleWidth=\(viewModel.workspaceSidebarVisibleWidth) frame=\(frame) mouse=\(NSEvent.mouseLocation)")
            ignoresMouseEvents = shouldIgnoreMouseEvents
        }
    }

    func isMouseInsideHoverRegion() -> Bool {
        guard isVisible else { return false }
        let hoverWidth = max(
            viewModel.workspaceSidebarVisibleWidth,
            workspaceSidebarHoverActivationWidth(presentedSidebarConfig),
        ) + hoverExitTolerance
        // Keep edge activation reachable across the gap, including in auto-hide mode.
        let screenMinX = workspaceSidebarPanelScreen()?.frame.minX ?? frame.minX
        let hoverRegion = NSRect(x: screenMinX, y: frame.minY, width: frame.minX - screenMinX + hoverWidth, height: frame.height)
        let inside = hoverRegion.contains(NSEvent.mouseLocation)
        if viewModel.workspaceSidebarVisibleWidth > workspaceSidebarRestingWidth(presentedSidebarConfig) + 0.5 || pendingCollapse != nil {
            debugWorkspaceSidebarHoverLog("hoverRegion panel=\(monitorScopeId) inside=\(inside) hoverWidth=\(hoverWidth) visibleWidth=\(viewModel.workspaceSidebarVisibleWidth) frame=\(frame) mouse=\(NSEvent.mouseLocation) suppressUntil=\(organizeCollapseSuppressedUntil)")
        }
        return inside
    }

    func isMouseInsideVisibleRegion() -> Bool {
        guard isVisible else { return false }
        let visibleRegion = NSRect(
            x: frame.minX,
            y: frame.minY,
            width: viewModel.workspaceSidebarVisibleWidth,
            height: frame.height,
        )
        return visibleRegion.contains(NSEvent.mouseLocation)
    }

    func isMouseDeepEnoughToExpand() -> Bool {
        guard isVisible else { return false }
        return isWorkspaceSidebarHoverDeepEnoughToExpand(
            mouseX: NSEvent.mouseLocation.x,
            sidebarMinX: frame.minX,
            collapsedWidth: workspaceSidebarHoverActivationWidth(presentedSidebarConfig),
        )
    }
}
extension WorkspaceSidebarPanel {
    func refresh() {
        refresh(on: workspaceSidebarMonitor(forScopeId: monitorScopeId) ?? workspaceSidebarResolvedPanelMonitor())
    }

    func refresh(on monitor: Monitor) {
        if let lastNavigationPlacement, lastNavigationPlacement != config.workspaceSidebar.placement {
            cancelExpansionWork()
            cancelInlineTextEditing()
            endInlineTextEditing()
            resetBrowseMode()
            persistentExpansionWidth = nil
            viewModel.workspaceSidebarVisibleWidth = 0
            viewModel.isWorkspaceSidebarExpanded = false
            updateDropTargets([])
            viewModel.objectWillChange.send()
        }
        lastNavigationPlacement = config.workspaceSidebar.placement
        presentsAutoHideForFullscreen = config.workspaceSidebar.placement == .side &&
            shouldSuppressWorkspaceSidebarForFullscreenContent(on: monitor)
        guard let layout = currentSidebarPanelLayout(on: monitor) else {
            cancelExpansionWork()
            resetHiddenSidebarState()
            return
        }

        if frame != layout.frame {
            setFrame(layout.frame, display: true, animate: false)
            updateDropTargets(dropTargetFrames)
        }
        if workspaceSidebarKeepsExpandedAtRest(presentedSidebarConfig) {
            cancelExpansionWork()
            let targetWidth = expandedPresentationWidth
            persistentExpansionWidth = layout.expandedWidth
            viewModel.setIfChanged(\.isWorkspaceSidebarExpanded, true)
            if viewModel.workspaceSidebarVisibleWidth != targetWidth {
                viewModel.workspaceSidebarVisibleWidth = targetWidth
            }
        } else if persistentExpansionWidth != nil {
            cancelExpansionWork()
            persistentExpansionWidth = nil
            viewModel.isWorkspaceSidebarExpanded = false
            viewModel.workspaceSidebarVisibleWidth = layout.collapsedWidth
        } else if viewModel.workspaceSidebarBrowseMode == .organize, viewModel.isWorkspaceSidebarExpanded,
                  pendingCollapse == nil, pendingCollapseFinalize == nil {
            viewModel.setIfChanged(\.workspaceSidebarVisibleWidth, expandedPresentationWidth)
        } else if viewModel.workspaceSidebarVisibleWidth == 0 {
            viewModel.workspaceSidebarVisibleWidth = viewModel.isWorkspaceSidebarExpanded
                ? layout.expandedWidth
                : layout.collapsedWidth
        } else if !viewModel.isWorkspaceSidebarExpanded,
                  pendingCollapse == nil,
                  viewModel.workspaceSidebarVisibleWidth != layout.collapsedWidth
        {
            // Apply auto-hide/collapsed-width changes immediately on config reload.
            viewModel.workspaceSidebarVisibleWidth = layout.collapsedWidth
        }
        updateMousePassthrough()
        orderFrontRegardless()
        // Panel geometry may have just changed under a stationary cursor; hover is otherwise
        // event-driven from the pointer monitors.
        scheduleHoverRecheckSoon()
    }

    func refreshForCurrentDragIfNeeded() {
        guard isMouseWindowDragInProgress() else { return }
        WorkspaceSidebarPanel.refreshAll()
    }

    func resetHiddenSidebarState() {
        resetBrowseMode()
        projectIconPicker?.close()
        // Runs for every inactive panel on every refreshAll — guard the shared-model writes so
        // they don't invalidate every observer each session.
        updateDropTargets([])
        setWorkspaceSidebarDropPreviewIfChanged(nil)
        TrayMenuModel.shared.setIfChanged(\.workspaceSidebarHoveredWorkspaceName, nil)
        viewModel.setIfChanged(\.workspaceSidebarVisibleWidth, 0)
        if isVisible {
            orderOut(nil)
        }
    }
}

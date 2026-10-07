import AppKit
import Common
import QuartzCore
import WorkspaceCore

/// One interaction owns the Chromium body and its helper-owned chrome. The
/// durable tree changes only on release; live frames travel through owner IPC.
@MainActor
final class BrowserWindowDragController {
    static let shared = BrowserWindowDragController()

    private enum Kind { case header, observedBrowser, native }
    private final class Drag {
        let id: SurfaceID
        let host: UInt32
        let pid: Int32?
        let kind: Kind
        let start: CGPoint
        let original: CGRect
        var desired: CGRect
        var observed: CGRect
        var layoutAtStart: [SurfacePlacement] = []
        var shake = WindowShakeGestureRecognizer()
        var settlingUntil: CFTimeInterval?
        init(id: SurfaceID, host: UInt32, pid: Int32?, kind: Kind, start: CGPoint, frame: CGRect) {
            self.id = id; self.host = host; self.pid = pid; self.kind = kind
            self.start = start; original = frame; desired = frame; observed = frame
        }
    }
    private var drag: Drag?
    private var candidate: Drag?
    private var cancelledGesture: SurfaceID?
    private var pointer = CGPoint.zero
    private var controller: BrowserWorkspaceController { .shared }
    var isDragging: Bool { drag != nil }

    var bodyFrameOverrides: [SurfaceID: SurfaceFrame] {
        guard let drag, drag.kind != .native, drag.settlingUntil == nil,
              let frame = Self.surfaceFrame(drag.desired) else { return [:] }
        return [drag.id: frame]
    }

    func isMovingNativeSurface(_ id: SurfaceID) -> Bool {
        drag?.id == id && drag?.kind == .native && drag?.settlingUntil == nil
    }

    func presentationItem(_ item: BrowserToolbarItem) -> BrowserToolbarItem {
        guard let drag, drag.id == item.surfaceID, drag.host == item.hostWindowID else { return item }
        return item.replacingBodyFrame(drag.observed, screenTop: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    func beginHeaderDrag(surfaceID: SurfaceID, at point: CGPoint) {
        guard enabled, drag == nil, cancelledGesture == nil,
              let item = BrowserToolbarController.shared.presentationItems.first(where: { $0.surfaceID == surfaceID }),
              let host = item.hostWindowID, let pid = controller.browserProcess(for: surfaceID),
              let frame = actualFrame(host, processID: pid) else { return }
        let next = Drag(id: surfaceID, host: host, pid: pid, kind: .header, start: point, frame: frame)
        guard isCurrent(next) else { return }
        next.layoutAtStart = layout(for: surfaceID)
        candidate = nil
        pointer = point
        drag = next
        controller.cancelPendingBrowserFocusHold()
        startObserving()
        updateIntent()
    }

    func updateHeaderDrag(at point: CGPoint) {
        guard let drag, drag.kind == .header, drag.settlingUntil == nil else { return }
        pointer = point
        let next = drag.original.offsetBy(dx: point.x - drag.start.x, dy: point.y - drag.start.y)
        guard Self.surfaceFrame(next) != nil else { return }
        drag.desired = next
        controller.publishBrowserLayouts()
        updateIntent()
    }

    func finishHeaderDrag(at point: CGPoint) {
        guard drag?.kind == .header, drag?.settlingUntil == nil else { return }
        updateHeaderDrag(at: point)
        finish(commit: true)
    }

    func cancel() {
        if NSEvent.pressedMouseButtons & 1 != 0 { cancelledGesture = drag?.id }
        candidate = nil
        if drag?.settlingUntil == nil { finish(commit: false) }
        stopObservingIfIdle()
    }

    func notePointerEvent(type: NSEvent.EventType, at point: CGPoint) {
        pointer = point
        switch type {
        case .leftMouseDown:
            cancelledGesture = nil
            guard enabled, drag == nil else { return }
            // Only the frontmost hit native host can become a candidate. A page
            // click/selection is never a drag unless its window frame changes.
            candidate = browserCandidate(at: point)
            if candidate != nil { startObserving() }
        case .leftMouseDragged:
            if drag?.kind == .header { return } // Header callbacks own its gesture.
            sample()
        case .leftMouseUp:
            if let cancelled = cancelledGesture {
                cancelledGesture = nil
                if let window = Window.get(bySurfaceID: cancelled) {
                    if window.isFloating {
                        let destination = point.monitorApproximation.activeWorkspace
                        if controller.canPlaceSurface(window.surfaceID, in: destination) {
                            window.bindAsFloatingWindow(to: destination)
                        }
                    }
                    window.lastAppliedLayoutPhysicalRect = nil
                    window.lastAppliedLayoutVirtualRect = nil
                    suppressPostDragAxObserverEvents(for: [window.windowId])
                }
                controller.publishBrowserLayouts(force: true)
                runWorkspaceSidebarSession {}
            }
            if drag?.settlingUntil == nil, drag != nil { sample(); finish(commit: true) }
            candidate = nil
            stopObservingIfIdle()
        default: break
        }
    }

    /// Native app windows in a shared workspace use the same SurfaceID drop
    /// model. Their own titlebar owns movement; WinMux only previews and commits.
    func handleNativeGeometryChange(_ window: Window) -> Bool {
        if drag?.id == window.surfaceID || cancelledGesture == window.surfaceID { return true }
        guard enabled, drag == nil, NSEvent.pressedMouseButtons & 1 != 0,
              !window.isFloating, let workspace = window.nodeWorkspace,
              controller.hasMixedLayout(in: workspace),
              controller.surfaceTree.workspace(of: window.surfaceID) == workspace.name,
              controller.canMoveSurface(window.surfaceID),
              let original = window.lastAppliedLayoutPhysicalRect,
              let actual = actualFrame(window.windowId, processID: nil) else { return false }
        let point = normalizeAppKitScreenPoint(NSEvent.mouseLocation)
        // Resize handles can sit just outside the native frame. Geometry must
        // have changed while the pointer is at this window before taking over.
        let originalFrame = CGRect(x: original.topLeftX, y: original.topLeftY, width: original.width, height: original.height)
        guard !Self.close(actual, originalFrame), actual.insetBy(dx: -8, dy: -8).contains(point) else { return false }
        drag = Drag(id: window.surfaceID, host: window.windowId, pid: nil, kind: .native,
                    start: point, frame: originalFrame)
        drag?.observed = actual
        drag?.layoutAtStart = layout(for: window.surfaceID)
        candidate = nil
        pointer = point
        startObserving()
        updateIntent()
        return true
    }

    private var enabled: Bool {
        !isUnitTest && TrayMenuModel.shared.isEnabled && controller.usesSurfaceTree && BrowserNativeManagement.lease != nil
    }

    private func startObserving() {
        DisplayRefreshDriver.shared.add(owner: self) { [weak self] _ in self?.sample() }
    }

    private func stopObservingIfIdle() {
        if drag == nil && candidate == nil { DisplayRefreshDriver.shared.remove(owner: self) }
    }

    private func sample() {
        guard enabled else { clear(); return }
        if drag == nil, let candidate {
            guard isCurrent(candidate) else { self.candidate = nil; stopObservingIfIdle(); return }
            guard NSEvent.pressedMouseButtons & 1 != 0 else { self.candidate = nil; stopObservingIfIdle(); return }
            if let actual = actualFrame(candidate.host, processID: candidate.pid), !Self.close(actual, candidate.original) {
                drag = candidate
                self.candidate = nil
                candidate.desired = actual
                candidate.observed = actual
                candidate.layoutAtStart = layout(for: candidate.id)
                controller.cancelPendingBrowserFocusHold()
            }
        }
        guard let drag else { return }
        guard isCurrent(drag),
              let actual = actualFrame(drag.host, processID: drag.pid) else {
            clear(); controller.publishBrowserLayouts(force: true); return
        }
        drag.observed = actual
        if drag.settlingUntil == nil, drag.kind == .native, !isResize(drag), config.enableShakeToToggleTiling,
           WorkspaceSidebarPanel.panel(containing: pointer) == nil, let window = Window.get(bySurfaceID: drag.id),
           drag.shake.observe(.init(point: pointer, timestamp: ProcessInfo.processInfo.systemUptime)),
           ProcessInfo.processInfo.systemUptime - window.shakeWindowState.lastToggleTimestamp >= windowShakeToggleCooldown {
            // Finish this grab after floating so a later AX event cannot also
            // start the legacy gesture driver or toggle the same window twice.
            cancelledGesture = drag.id
            clear()
            WindowMouseInteractionDriver.shared.toggleFloatingForShake(window)
            window.shakeWindowState.lastToggleTimestamp = ProcessInfo.processInfo.systemUptime
            controller.publishBrowserLayouts(force: true)
            runWorkspaceSidebarSession {}
            return
        }
        if drag.kind != .native { BrowserToolbarController.shared.applyDragFrame(for: drag.id, bodyFrame: actual) }
        if let deadline = drag.settlingUntil {
            let planned = Workspace.all.flatMap(controller.plannedSurfaces).first { $0.surfaceID == drag.id && $0.visible }
            let target = planned.flatMap { placement -> CGRect? in
                let frame = drag.kind == .native ? placement.frame : BrowserPageChromeGeometry(frame: placement.frame)?.bodyFrame
                return frame.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            }
            if target.map({ Self.close(actual, $0) }) == true || CACurrentMediaTime() >= deadline { clear() }
            return
        }
        if drag.kind == .observedBrowser { drag.desired = actual }
        pointer = normalizeAppKitScreenPoint(NSEvent.mouseLocation)
        updateIntent()
        if NSEvent.pressedMouseButtons & 1 == 0 { finish(commit: true) }
    }

    private func updateIntent() {
        guard let drag, drag.settlingUntil == nil,
              !isResize(drag), let destination = resolveBrowserSurfaceDrop(source: drag.id, pointer: pointer) else {
            WindowDropIntentOverlayPanelController.shared.hide(); return
        }
        WindowDropIntentOverlayPanelController.shared.show(destination.overlay)
    }

    private func finish(commit: Bool) {
        guard let drag, drag.settlingUntil == nil else { return }
        candidate = nil
        // Stop overriding placement before committing, so even a synchronous
        // refresh restores the final plan rather than the last dragged frame.
        drag.settlingUntil = CACurrentMediaTime() + 1.5
        WindowDropIntentOverlayPanelController.shared.hide()
        let commit = commit && isCurrent(drag) && drag.layoutAtStart == layout(for: drag.id)
        if commit, isResize(drag) {
            _ = controller.resizeObservedSurface(drag.id, from: drag.original, to: drag.observed)
        } else if commit, let destination = resolveBrowserSurfaceDrop(source: drag.id, pointer: pointer) {
            _ = commitBrowserSurfaceDrop(destination)
        }
        if let window = Window.get(bySurfaceID: drag.id) {
            window.lastAppliedLayoutPhysicalRect = nil
            window.lastAppliedLayoutVirtualRect = nil
            suppressPostDragAxObserverEvents(for: [window.windowId])
        }
        controller.publishBrowserLayouts(force: true)
        runWorkspaceSidebarSession {}
    }

    private func clear() {
        let id = drag?.id
        drag = nil
        candidate = nil
        WindowDropIntentOverlayPanelController.shared.hide()
        if let id { BrowserToolbarController.shared.restorePlannedFrame(for: id) }
        stopObservingIfIdle()
    }

    private func isCurrent(_ drag: Drag) -> Bool {
        guard controller.isAvailable(drag.id),
              let name = controller.workspaceName(for: drag.id),
              let workspace = Workspace.existing(byName: name), workspace.isVisible,
              controller.plannedSurfaces(in: workspace).contains(where: { $0.surfaceID == drag.id && $0.visible }) else { return false }
        if drag.kind != .native {
            guard controller.browserProcess(for: drag.id) == drag.pid,
                  controller.owner(of: drag.id)?.inventory.tabs[drag.id]?.hostWindowID == drag.host else { return false }
        }
        return true
    }

    private func isResize(_ drag: Drag) -> Bool {
        drag.kind != .header && (abs(drag.observed.width - drag.original.width) > 1 || abs(drag.observed.height - drag.original.height) > 1)
    }

    private func layout(for id: SurfaceID) -> [SurfacePlacement] {
        guard let name = controller.workspaceName(for: id), let workspace = Workspace.existing(byName: name) else { return [] }
        return controller.plannedSurfaces(in: workspace)
    }

    private func browserCandidate(at point: CGPoint) -> Drag? {
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for entry in entries {
            guard (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point),
                  let host = entry[kCGWindowNumber as String] as? UInt32 else { continue }
            guard let item = BrowserToolbarController.shared.presentationItems.first(where: { $0.hostWindowID == host }),
                  let pid = controller.browserProcess(for: item.surfaceID),
                  entry[kCGWindowOwnerPID as String] as? Int32 == pid else { return nil }
            return Drag(id: item.surfaceID, host: host, pid: pid, kind: .observedBrowser, start: point, frame: rect)
        }
        return nil
    }

    private func actualFrame(_ host: UInt32, processID: Int32?) -> CGRect? {
        guard let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, host) as? [[String: Any]],
              let entry = entries.first(where: { $0[kCGWindowNumber as String] as? UInt32 == host }),
              processID == nil || entry[kCGWindowOwnerPID as String] as? Int32 == processID,
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds), Self.surfaceFrame(rect) != nil else { return nil }
        return rect
    }

    private static func surfaceFrame(_ rect: CGRect) -> SurfaceFrame? {
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              abs(rect.minX) <= 100000, abs(rect.minY) <= 100000,
              (1...30000).contains(rect.width), (1...30000).contains(rect.height) else { return nil }
        return .init(x: Int(rect.minX.rounded()), y: Int(rect.minY.rounded()),
                     width: Int(rect.width.rounded()), height: Int(rect.height.rounded()))
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }
}

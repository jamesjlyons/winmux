import AppKit
import QuartzCore

/// Owns presentation frames only. The tree retains the destination geometry so
/// layout, focus navigation and hit testing never consume an intermediate tile.
@MainActor
final class WindowLayoutAnimator {
    static let shared = WindowLayoutAnimator()

    @MainActor private final class Entry {
        weak var window: MacWindow?
        var motion: WindowFrameAnimation
        var cancellation = RunLoopJob()
        var finishing = false
        var finishStartedAt: TimeInterval?
        var lastFrame: CGRect?
        let workspace: Workspace
        let monitor: Rect

        init(window: MacWindow, start: Rect, target: Rect, workspace: Workspace) {
            self.window = window
            self.motion = WindowFrameAnimation(from: start.axAnimationFrame, to: target.axAnimationFrame)
            self.workspace = workspace
            self.monitor = workspace.workspaceMonitor.rect
        }
    }

    private var entries: [UInt32: Entry] = [:]
    private var lastTick: TimeInterval?
    private var watchdog: Timer?

    private var enabled: Bool {
        config.animations.enabled && config.animations.durationMs > 0 &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Only changed, already visible tiles glide. In particular, a parked window
    /// must never fly across the screen on a workspace or tab switch.
    func animate(_ window: MacWindow, to target: Rect, previous: Rect?) -> Bool {
        guard enabled, !isStartup, !serverArgs.isReadOnly,
              TrayMenuModel.shared.isEnabled, !AppShutdownCoordinator.shared.isShuttingDown,
              !window.skipNextLayoutAnimation, !window.isHiddenInCorner, !window.isFloating,
              currentlyManipulatedWithMouseWindowId == nil,
              !BrowserWindowDragController.shared.isMovingNativeSurface(window.surfaceID),
              let workspace = window.nodeWorkspace, workspace.isVisible,
              target.axAnimationFrame.isValidAnimationFrame
        else {
            window.skipNextLayoutAnimation = false
            cancel(window.windowId)
            return false
        }

        if let entry = entries[window.windowId], entry.window === window,
           !entry.cancellation.isCancelled, entry.workspace === workspace,
           entry.monitor == workspace.workspaceMonitor.rect {
            if entry.motion.target != target.axAnimationFrame {
                // Invalidate a final write/readback that has not returned yet.
                if entry.finishing {
                    entry.cancellation.cancel()
                    entry.cancellation = RunLoopJob()
                    window.layoutAnimationCancellation = entry.cancellation
                    entry.finishing = false
                    entry.finishStartedAt = nil
                }
                entry.motion.retarget(target.axAnimationFrame)
            }
            return true
        }

        cancel(window.windowId)
        guard let previous, previous != target else { return false }
        let start = window.lastKnownActualRect ?? previous
        guard start.axAnimationFrame.isValidAnimationFrame,
              workspace.workspaceMonitor.rect.contains(start.center),
              workspace.workspaceMonitor.rect.contains(target.center),
              start != target else { return false }
        let entry = Entry(window: window, start: start, target: target, workspace: workspace)
        entries[window.windowId] = entry
        window.layoutAnimationCancellation = entry.cancellation
        startClock()
        return true
    }

    func presentationFrame(_ id: UInt32) -> Rect? {
        guard let entry = entries[id], !entry.cancellation.isCancelled else { return nil }
        let frame = entry.finishing ? entry.motion.target : entry.motion.frame
        return Rect(topLeftX: frame.minX, topLeftY: frame.minY, width: frame.width, height: frame.height)
    }

    /// Invalidate native caches, but don't treat our frame notifications as a
    /// user drag or schedule a full layout for every display tick.
    func consumesGeometryEvent(_ id: UInt32?) -> Bool {
        guard let id, let entry = entries[id], !entry.cancellation.isCancelled else { return false }
        if isLeftMouseButtonDown {
            cancel(id)
            return false
        }
        entry.window?.invalidateLastKnownNativeState(layoutChanged: false)
        return true
    }

    func cancel(_ id: UInt32) {
        entries.removeValue(forKey: id)?.cancellation.cancel()
        stopClockIfIdle()
    }

    func cancelAll() {
        for entry in entries.values { entry.cancellation.cancel() }
        entries.removeAll()
        stopClockIfIdle()
    }

    private func startClock() {
        guard watchdog == nil else { return }
        lastTick = CACurrentMediaTime()
        DisplayRefreshDriver.shared.add(owner: self) { [weak self] timestamp in self?.tick(timestamp) }
        // A display can disappear or stop ticking during sleep. Finish on the
        // wall clock as well, so no window is stranded halfway to its tile.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, CACurrentMediaTime() - (self.lastTick ?? 0) >= 0.2 else { return }
                self.tick(CACurrentMediaTime())
            }
        }
        watchdog = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopClockIfIdle() {
        guard entries.isEmpty else { return }
        DisplayRefreshDriver.shared.remove(owner: self)
        watchdog?.invalidate()
        watchdog = nil
        lastTick = nil
    }

    private func tick(_ timestamp: TimeInterval) {
        let dt = max(0, timestamp - (lastTick ?? timestamp))
        lastTick = timestamp
        for (id, entry) in entries {
            guard let window = entry.window, !entry.cancellation.isCancelled,
                  MacWindow.allWindowsMap[id] === window,
                  TrayMenuModel.shared.isEnabled, !AppShutdownCoordinator.shared.isShuttingDown,
                  !serverArgs.isReadOnly, window.nodeWorkspace === entry.workspace,
                  entry.workspace.isVisible, !window.isHiddenInCorner, !window.isFloating,
                  currentlyManipulatedWithMouseWindowId == nil,
                  !BrowserWindowDragController.shared.isMovingNativeSurface(window.surfaceID)
            else { cancel(id); continue }
            guard entry.monitor == entry.workspace.workspaceMonitor.rect else {
                cancel(id)
                scheduleRefreshSession(.ax("Window animation monitor changed"), scope: .geometry(window))
                continue
            }
            if entry.finishing {
                // A retired AX element or quarantined owner may never call the
                // completion. Bound the lifetime of both the clock and suppression.
                if timestamp - (entry.finishStartedAt ?? timestamp) > 5 {
                    cancel(id)
                    scheduleRefreshSession(.ax("Window animation timed out"), scope: .geometry(window))
                }
                continue
            }
            let arrived = !enabled || entry.motion.advance(by: dt, duration: Double(config.animations.durationMs) / 1000)
            let frame = arrived ? entry.motion.target : entry.motion.frame
            if !arrived && entry.lastFrame == frame { continue }
            entry.lastFrame = frame
            entry.finishing = arrived
            if arrived { entry.finishStartedAt = timestamp }
            let cancellation = entry.cancellation
            window.macApp.setAxAnimationFrame(id, frame, cancellation: cancellation, final: arrived) { [weak self] actual in
                guard let self, let current = self.entries[id], current === entry,
                      current.cancellation === cancellation, !cancellation.isCancelled else { return }
                self.entries.removeValue(forKey: id)
                window.recordAuthoritativeActualRect(actual)
                // Reuse the existing verified layout/minimum-size path after
                // arrival. Intermediate sizes must never become learned minima.
                scheduleRefreshSession(.ax("Window animation arrived"), scope: .geometry(window))
                WindowTabStripPanelController.shared.refresh()
                self.stopClockIfIdle()
            }
        }
        WindowTabStripPanelController.shared.refresh()
        stopClockIfIdle()
    }
}

extension CGRect {
    var isValidAnimationFrame: Bool {
        [origin.x, origin.y, width, height].allSatisfy(\.isFinite) && width >= 1 && height >= 1
    }
}

extension Window {
    @MainActor
    func setLayoutFrame(_ rect: Rect, previous: Rect?) {
        if let native = self as? MacWindow, WindowLayoutAnimator.shared.animate(native, to: rect, previous: previous) { return }
        setAxFrame(rect.topLeftCorner, rect.size)
    }
}

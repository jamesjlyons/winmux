import AppKit
import QuartzCore

/// A shared stack's strip is placed from the layout plan, while the window
/// below it glides: a native one through WindowLayoutAnimator, a browser host
/// inside Chromium. Glide the chrome with the same spring so it stays attached
/// instead of jumping ahead to the destination.
@MainActor
final class SharedStackChromeGlide {
    private struct Motion {
        var frame: WindowFrameAnimation
        var groupFrame: WindowFrameAnimation
    }

    private var motions: [WindowTabStripIdentity: Motion] = [:]
    private var targets: [WindowTabStripIdentity: (frame: CGRect, groupFrame: CGRect)] = [:]
    private var lastTick: CFTimeInterval?
    private let onTick: () -> Void

    init(onTick: @escaping () -> Void) {
        self.onTick = onTick
    }

    var isAnimating: Bool { !motions.isEmpty }

    /// Returns the strip at its presentation frames. Only a strip that is
    /// already on screen glides; a revealed strip appears at its destination.
    func present(_ strip: WindowTabStripViewModel, isOnScreen: Bool) -> WindowTabStripViewModel {
        let target = (frame: strip.frame, groupFrame: strip.groupFrame)
        let previous = targets.updateValue(target, forKey: strip.id)
        let durationMs = WindowLayoutAnimator.shared.browserHostAnimationMs
        guard durationMs > 0, isOnScreen else {
            motions.removeValue(forKey: strip.id)
            stopIfIdle()
            return strip
        }
        if var motion = motions[strip.id] {
            motion.frame.retarget(target.frame)
            motion.groupFrame.retarget(target.groupFrame)
            motions[strip.id] = motion
        } else if let previous, previous.groupFrame != target.groupFrame || previous.frame != target.frame,
                  sameScreen(previous.groupFrame, target.groupFrame) {
            motions[strip.id] = Motion(frame: WindowFrameAnimation(from: previous.frame, to: target.frame),
                                       groupFrame: WindowFrameAnimation(from: previous.groupFrame, to: target.groupFrame))
            start()
        }
        guard let motion = motions[strip.id] else { return strip }
        return strip.withFrames(frame: motion.frame.frame, groupFrame: motion.groupFrame.frame)
    }

    func cancelAll() {
        motions.removeAll()
        stopIfIdle()
    }

    private func sameScreen(_ a: CGRect, _ b: CGRect) -> Bool {
        let screen = { (rect: CGRect) in NSScreen.screens.firstIndex { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) } }
        return screen(a) != nil && screen(a) == screen(b)
    }

    private func start() {
        guard lastTick == nil else { return }
        lastTick = CACurrentMediaTime()
        DisplayRefreshDriver.shared.add(owner: self) { [weak self] timestamp in self?.tick(timestamp) }
    }

    private func stopIfIdle() {
        guard motions.isEmpty, lastTick != nil else { return }
        DisplayRefreshDriver.shared.remove(owner: self)
        lastTick = nil
    }

    private func tick(_ timestamp: CFTimeInterval) {
        let dt = max(0, timestamp - (lastTick ?? timestamp))
        lastTick = timestamp
        let duration = Double(config.animations.durationMs) / 1000
        for (id, var motion) in motions {
            let frameArrived = motion.frame.advance(by: dt, duration: duration)
            let groupArrived = motion.groupFrame.advance(by: dt, duration: duration)
            motions[id] = frameArrived && groupArrived ? nil : motion
        }
        onTick()
        stopIfIdle()
    }
}

extension WindowTabStripViewModel {
    func withFrames(frame: CGRect, groupFrame: CGRect) -> WindowTabStripViewModel {
        var copy = WindowTabStripViewModel(
            id: id, workspaceName: workspaceName, frame: frame, groupFrame: groupFrame,
            activeWindowId: activeWindowId, activeWindowCornerRadius: activeWindowCornerRadius,
            tabs: tabs, occludingFloatingWindowFrames: occludingFloatingWindowFrames)
        copy.sharedStack = sharedStack
        return copy
    }
}

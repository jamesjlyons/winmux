import CoreGraphics
import CoreVideo
import Foundation
import QuartzCore

private let displayRefreshHostClockFrequency = CVGetHostClockFrequency()

private func displayRefreshDriverCallback(
    _: CVDisplayLink,
    _ now: UnsafePointer<CVTimeStamp>,
    _: UnsafePointer<CVTimeStamp>,
    _: CVOptionFlags,
    _: UnsafeMutablePointer<CVOptionFlags>,
    _ userInfo: UnsafeMutableRawPointer?,
) -> CVReturn {
    guard let userInfo else { return kCVReturnSuccess }
    let driver = Unmanaged<DisplayRefreshDriver>.fromOpaque(userInfo).takeUnretainedValue()
    let timestamp = displayRefreshHostClockFrequency > 0
        ? Double(now.pointee.hostTime) / displayRefreshHostClockFrequency
        : CACurrentMediaTime()
    driver.enqueue(timestamp: timestamp)
    return kCVReturnSuccess
}

@MainActor
final class DisplayRefreshDriver: @unchecked Sendable {
    static let shared = DisplayRefreshDriver()

    private struct Subscription {
        weak var owner: AnyObject?
        let startedAt: CFTimeInterval
        let callback: (CFTimeInterval) -> Void
    }

    nonisolated private let mailbox = DisplayFrameMailbox()

    nonisolated fileprivate func enqueue(timestamp: CFTimeInterval) {
        guard let generation = mailbox.submit(timestamp) else { return }
        Task { @MainActor in
            guard let latest = self.mailbox.take(generation: generation) else { return }
            signposter.emitEvent("Display delivery", "sample age ms: \((CACurrentMediaTime() - latest) * 1000)")
            self.fire(timestamp: latest)
        }
    }

    private var subscriptions: [ObjectIdentifier: Subscription] = [:]
    private var displayLink: CVDisplayLink?
    private var fallbackTimer: Timer?

    private init() {}

    func add(owner: AnyObject, callback: @escaping (CFTimeInterval) -> Void) {
        let key = ObjectIdentifier(owner)
        let startedAt = subscriptions[key]?.startedAt ?? CACurrentMediaTime()
        subscriptions[key] = Subscription(owner: owner, startedAt: startedAt, callback: callback)
        startIfNeeded()
    }

    func remove(owner: AnyObject) {
        subscriptions.removeValue(forKey: ObjectIdentifier(owner))
        stopIfIdle()
    }

    private func startIfNeeded() {
        guard !subscriptions.isEmpty, displayLink == nil, fallbackTimer == nil else { return }
        mailbox.start()
        if startDisplayLink() {
            return
        }
        startFallbackTimer()
    }

    private func startDisplayLink() -> Bool {
        var rawLink: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&rawLink) == kCVReturnSuccess,
              let rawLink
        else {
            return false
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard CVDisplayLinkSetOutputCallback(rawLink, displayRefreshDriverCallback, userInfo) == kCVReturnSuccess,
              CVDisplayLinkStart(rawLink) == kCVReturnSuccess
        else {
            return false
        }
        displayLink = rawLink
        return true
    }

    private func startFallbackTimer() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            DisplayRefreshDriver.shared.enqueue(timestamp: CACurrentMediaTime())
        }
        fallbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopIfIdle() {
        pruneReleasedOwners()
        guard subscriptions.isEmpty else { return }
        mailbox.stop()
        if let displayLink {
            CVDisplayLinkStop(displayLink)
            self.displayLink = nil
        }
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    private func pruneReleasedOwners() {
        var releasedOwners: [ObjectIdentifier]?
        for (id, subscription) in subscriptions where subscription.owner == nil {
            if releasedOwners == nil {
                releasedOwners = []
            }
            releasedOwners?.append(id)
        }
        guard let releasedOwners else { return }
        for id in releasedOwners {
            subscriptions.removeValue(forKey: id)
        }
    }

    fileprivate func fire(timestamp: CFTimeInterval) {
        pruneReleasedOwners()
        guard !subscriptions.isEmpty else {
            stopIfIdle()
            return
        }
        for subscription in subscriptions.values where timestamp >= subscription.startedAt {
            subscription.callback(timestamp)
        }
    }

}

func displayRefreshEaseInOut(_ progress: CGFloat) -> CGFloat {
    let clamped = min(max(progress, 0), 1)
    return clamped * clamped * (3 - 2 * clamped)
}

func displayRefreshInterpolate(_ start: CGFloat, _ end: CGFloat, progress: CGFloat) -> CGFloat {
    start + (end - start) * progress
}

func displayRefreshInterpolate(_ start: CGRect, _ end: CGRect, progress: CGFloat) -> CGRect {
    CGRect(
        x: displayRefreshInterpolate(start.minX, end.minX, progress: progress),
        y: displayRefreshInterpolate(start.minY, end.minY, progress: progress),
        width: displayRefreshInterpolate(start.width, end.width, progress: progress),
        height: displayRefreshInterpolate(start.height, end.height, progress: progress),
    )
}

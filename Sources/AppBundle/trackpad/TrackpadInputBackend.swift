import AppKit
import PrivateApi

enum TrackpadBackendStatus: Equatable, Sendable {
    case unavailable
    case listening(Int)
}

@MainActor
protocol TrackpadInputBackend: AnyObject {
    func start(
        deliver: @escaping @Sendable ([TrackpadGestureEvent], Double) -> Void,
        invalidInput: @escaping @Sendable () -> Void,
    ) -> TrackpadBackendStatus
    func stop()
}

private let trackpadContactCallback: WMTrackpadCallback = { device, timestamp, contacts, count, valid, context in
    guard let context else { return }
    let session = Unmanaged<TrackpadInputSession>.fromOpaque(context).takeUnretainedValue()
    let values = contacts.map { pointer in
        (0..<Int(count)).map { TrackpadContact(id: pointer[$0].identifier, x: pointer[$0].x, y: pointer[$0].y) }
    } ?? []
    let buttonDown = (0..<5).contains { index in
        CGEventSource.buttonState(.combinedSessionState, button: CGMouseButton(rawValue: UInt32(index))!)
    }
    session.receive(TrackpadFrame(device: device, timestamp: timestamp, contacts: values, buttonDown: buttonDown), valid: valid)
}

@MainActor
final class MultitouchTrackpadBackend: TrackpadInputBackend {
    private var session: TrackpadInputSession?

    func start(
        deliver: @escaping @Sendable ([TrackpadGestureEvent], Double) -> Void,
        invalidInput: @escaping @Sendable () -> Void,
    ) -> TrackpadBackendStatus {
        stop()
        let session = TrackpadInputSession(deliver: deliver, invalidInput: invalidInput)
        self.session = session
        let count = WMTrackpadStart(trackpadContactCallback, Unmanaged.passUnretained(session).toOpaque())
        if count < 0 { stop(); return .unavailable }
        return .listening(Int(count))
    }

    func stop() {
        guard let session else { return }
        WMTrackpadStop()
        session.stop()
        self.session = nil
    }
}

/// The C bridge guarantees callback/context lifetime. Everything mutable below
/// is confined to queue; the unchecked conformance does not protect UI state.
private final class TrackpadInputSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "winmux.trackpad", qos: .userInteractive)
    private let deliver: @Sendable ([TrackpadGestureEvent], Double) -> Void
    private let invalidInput: @Sendable () -> Void
    private var recognizer = TrackpadSwipeRecognizer()
    private var receipts: [UInt: Double] = [:]
    private var watchdog: DispatchSourceTimer?
    private var stopped = false

    init(deliver: @escaping @Sendable ([TrackpadGestureEvent], Double) -> Void, invalidInput: @escaping @Sendable () -> Void) {
        self.deliver = deliver
        self.invalidInput = invalidInput
    }

    func receive(_ frame: TrackpadFrame, valid: Bool) {
        let receivedAt = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            guard !stopped else { return }
            guard valid, frame.isValid else {
                stopped = true
                watchdog?.cancel()
                watchdog = nil
                invalidInput()
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - receivedAt > TrackpadSwipeRecognizer.staleInterval {
                let events = recognizer.expire(device: frame.device) + [.ended(frame.device)]
                deliver(events, now)
                return
            }
            if frame.contacts.isEmpty { receipts.removeValue(forKey: frame.device) }
            else { receipts[frame.device] = receivedAt }
            let events = recognizer.observe(frame)
            if !events.isEmpty { deliver(events, receivedAt) }
            updateWatchdog()
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            watchdog?.cancel()
            watchdog = nil
            receipts.removeAll()
        }
    }

    private func updateWatchdog() {
        if receipts.isEmpty {
            watchdog?.cancel()
            watchdog = nil
        } else if watchdog == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.expireStalledStreams() }
            watchdog = timer
            timer.resume()
        }
    }

    private func expireStalledStreams() {
        let now = ProcessInfo.processInfo.systemUptime
        for (device, lastReceipt) in receipts where now - lastReceipt > TrackpadSwipeRecognizer.staleInterval {
            receipts.removeValue(forKey: device)
            deliver(recognizer.expire(device: device) + [.ended(device)], now)
        }
        updateWatchdog()
    }
}

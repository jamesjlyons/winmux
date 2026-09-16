import Foundation
import IOKit

/// Device discovery is event-driven. Iterators must be drained to arm/rearm
/// IOKit's notifications, including immediately after registration.
@MainActor
final class TrackpadDeviceObserver {
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private let changed: @MainActor () -> Void

    init(changed: @escaping @MainActor () -> Void) { self.changed = changed }

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let callback: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            MainActor.assumeIsolated {
                let observer = Unmanaged<TrackpadDeviceObserver>.fromOpaque(context).takeUnretainedValue()
                observer.drain(iterator)
                observer.changed()
            }
        }
        for notification in [kIOMatchedNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(port, notification,
                IOServiceMatching("AppleMultitouchDevice"), callback,
                Unmanaged.passUnretained(self).toOpaque(), &iterator)
            if result == KERN_SUCCESS {
                iterators.append(iterator)
                drain(iterator)
            }
        }
    }

    func stop() {
        for iterator in iterators { IOObjectRelease(iterator) }
        iterators.removeAll()
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }

    private func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }
}

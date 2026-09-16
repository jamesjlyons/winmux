import AppKit
import Combine
import Common

enum TrackpadNavigationStatus: Equatable {
    case off, paused, unavailable, invalidInput, noTrackpad
    case ready(Int)

    var description: String {
        switch self {
            case .off: "Off"
            case .paused: "Paused while WinMux is inactive"
            case .unavailable: "Trackpad input is unavailable on this Mac"
            case .invalidInput: "Trackpad input changed unexpectedly. Turn this off and on to retry."
            case .noTrackpad: "Waiting for a trackpad"
            case .ready(let count): "Ready · \(count) trackpad\(count == 1 ? "" : "s")"
        }
    }
}

@MainActor
final class TrackpadNavigationController: ObservableObject {
    static let shared = TrackpadNavigationController()
    @Published private(set) var status: TrackpadNavigationStatus = .off
    private(set) var ownedDevices: Set<UInt> = []
    private let backend: any TrackpadInputBackend
    private let nativeFocusMatches: @MainActor (UInt32) async -> Bool
    private let activate: @MainActor (Window, Window) -> Void
    private var configuration = TrackpadNavigationConfig()
    private var candidate: (device: UInt, target: TrackpadTabTarget)?
    private var generation: UInt64 = 0
    private var navigationRevision: UInt64 = 0
    private var running = false
    private var sessionActive = true
    private var sleeping = false
    private var observing = false
    private var observers: [NSObjectProtocol] = []
    private var restartTask: Task<Void, Never>?
    private lazy var deviceObserver = TrackpadDeviceObserver { [weak self] in self?.scheduleDeviceRestart() }

    init(
        backend: any TrackpadInputBackend = MultitouchTrackpadBackend(),
        nativeFocusMatches: @escaping @MainActor (UInt32) async -> Bool = { id in
            (try? await getNativeFocusedWindow())?.windowId == id
        },
        activate: @escaping @MainActor (Window, Window) -> Void = { source, destination in
            if source.nearestWindowTabGroup?.usesDoubleSidedWindows == true {
                DoubleSidedWindowController.shared.flip(source)
            } else {
                focusWindowFromTabStrip(destination.windowId, fallbackWorkspace: focus.workspace.name)
            }
        }
    ) {
        self.backend = backend
        self.nativeFocusMatches = nativeFocusMatches
        self.activate = activate
    }

    func startObserving() {
        guard !observing, !isUnitTest else { return }
        observing = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let name = notification.name
                MainActor.assumeIsolated { self?.workspaceChanged(name) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleDeviceRestart() }
            })
        sync()
    }

    func sync() {
        guard !isUnitTest else { return }
        let active = isWinMuxRuntimeReady && TrayMenuModel.shared.isEnabled && !serverArgs.isReadOnly &&
            !AppShutdownCoordinator.shared.isShuttingDown && sessionActive && !sleeping && AXIsProcessTrusted()
        update(configuration: config.trackpadNavigation, isActive: active)
    }

    func update(configuration newConfiguration: TrackpadNavigationConfig, isActive: Bool) {
        if configuration != newConfiguration {
            stopBackend()
            configuration = newConfiguration
        }
        guard configuration.enabled, isActive else {
            stopBackend()
            deviceObserver.stop()
            status = configuration.enabled ? .paused : .off
            return
        }
        if observing { deviceObserver.start() }
        guard !running, status != .invalidInput else { return }
        generation &+= 1
        let currentGeneration = generation
        running = true
        let result = backend.start(deliver: { [weak self] events, receivedAt in
            DispatchQueue.main.async {
                self?.receive(events, receivedAt: receivedAt, generation: currentGeneration)
            }
        }, invalidInput: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                self.stopBackend()
                self.status = .invalidInput
            }
        })
        switch result {
            case .unavailable: status = .unavailable
            case .listening(0): status = .noTrackpad
            case .listening(let count): status = .ready(count)
        }
    }

    func cancelCandidate() {
        candidate = nil
        navigationRevision &+= 1
    }

    func shutdown() {
        stopBackend()
        deviceObserver.stop()
        restartTask?.cancel()
        restartTask = nil
        status = .paused
    }

    private func stopBackend() {
        generation &+= 1
        cancelCandidate()
        ownedDevices.removeAll()
        if running { backend.stop() }
        running = false
    }

    private func receive(_ events: [TrackpadGestureEvent], receivedAt: Double, generation expected: UInt64) {
        guard running, generation == expected else { return }
        let fresh = ProcessInfo.processInfo.systemUptime - receivedAt <= TrackpadSwipeRecognizer.staleInterval
        for event in events {
            switch event {
                case .began(let device):
                    ownedDevices.insert(device)
                    cancelCandidate()
                    if fresh, ownedDevices.count == 1, canNavigate, let target = TrackpadTabTarget.capture() {
                        candidate = (device, target)
                    }
                case .cancelled(let device):
                    if candidate?.device == device { cancelCandidate() }
                case .ended(let device):
                    ownedDevices.remove(device)
                    // A committed action may still be awaiting its native-focus
                    // check when fingers lift. Ending must not cancel that action.
                    if candidate?.device == device { cancelCandidate() }
                case .committed(let device, let direction):
                    guard fresh, canNavigate, let candidate, candidate.device == device else { continue }
                    self.candidate = nil
                    commit(candidate.target, direction: direction, generation: expected, receivedAt: receivedAt)
            }
        }
    }

    private var canNavigate: Bool {
        let runtimeActive = isUnitTest || (TrayMenuModel.shared.isEnabled && !serverArgs.isReadOnly && AXIsProcessTrusted())
        return runtimeActive && !DoubleSidedWindowController.shared.isAnimating && NSEvent.pressedMouseButtons == 0 &&
            !isWorkspaceSidebarDragInProgress() && !isWindowTabStripDragInProgress() && getCurrentMouseManipulationKind() == .none
    }

    private func commit(_ target: TrackpadTabTarget, direction: TrackpadSwipeDirection, generation expected: UInt64, receivedAt: Double) {
        let revision = navigationRevision
        Task { @MainActor in
            guard await nativeFocusMatches(target.windowId), generation == expected,
                  navigationRevision == revision, canNavigate,
                  ProcessInfo.processInfo.systemUptime - receivedAt <= TrackpadSwipeRecognizer.staleInterval,
                  let resolved = target.resolve(direction: direction, reversed: configuration.reverseDirection)
            else { return }
            let interval = signposter.beginInterval("Trackpad tab activation")
            activate(resolved.source, resolved.destination)
            signposter.endInterval("Trackpad tab activation", interval)
        }
    }

    private func workspaceChanged(_ name: Notification.Name) {
        cancelCandidate()
        switch name {
            case NSWorkspace.willSleepNotification: sleeping = true
            case NSWorkspace.didWakeNotification: sleeping = false
            case NSWorkspace.sessionDidResignActiveNotification: sessionActive = false
            case NSWorkspace.sessionDidBecomeActiveNotification: sessionActive = true
            default: return
        }
        sync()
    }

    private func scheduleDeviceRestart() {
        cancelCandidate()
        restartTask?.cancel()
        restartTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            stopBackend()
            sync()
        }
    }
}

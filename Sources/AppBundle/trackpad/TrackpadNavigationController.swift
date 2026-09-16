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
    private let frontmostPID: @MainActor () -> Int32?
    private let now: @MainActor () -> Double
    private let activate: @MainActor (Window, Window) -> Void
    private var configuration = TrackpadNavigationConfig()
    private var candidate: (device: UInt, target: TrackpadTabTarget)?
    private var generation: UInt64 = 0
    private struct FocusTransition {
        let target: TrackpadTabTarget
        var windowPIDs: [UInt32: Int32]
        let expiresAt: Double
    }
    private var focusTransition: FocusTransition?
    private var running = false
    private var sessionActive = true
    private var sleeping = false
    private var observing = false
    private var observers: [NSObjectProtocol] = []
    private var restartTask: Task<Void, Never>?
    private lazy var deviceObserver = TrackpadDeviceObserver { [weak self] in self?.scheduleDeviceRestart() }

    init(
        backend: any TrackpadInputBackend = MultitouchTrackpadBackend(),
        frontmostPID: @escaping @MainActor () -> Int32? = {
            isUnitTest ? focus.windowOrNil?.app.pid : NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
        activate: @escaping @MainActor (Window, Window) -> Void = { source, destination in
            if source.nearestWindowTabGroup?.usesDoubleSidedWindows == true {
                DoubleSidedWindowController.shared.flip(source)
            } else {
                focusWindowFromTabStrip(destination.windowId, fallbackWorkspace: focus.workspace.name)
            }
        }
    ) {
        self.backend = backend
        self.frontmostPID = frontmostPID
        self.now = now
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
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    if name == NSWorkspace.didActivateApplicationNotification {
                        self?.applicationActivated(pid)
                    } else {
                        self?.workspaceChanged(name)
                    }
                }
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
    }

    /// Explicit focus changes and other input end our short native-focus grace
    /// period. Starting the next swipe does not: AX may still be catching up.
    func cancelNavigation() {
        cancelCandidate()
        focusTransition = nil
    }

    private var activeTransition: FocusTransition? {
        guard let transition = focusTransition, now() < transition.expiresAt,
              transition.target.focusedWindow != nil
        else {
            focusTransition = nil
            return nil
        }
        return transition
    }

    func shouldIgnoreNativeFocus(_ window: Window?) -> Bool {
        guard let transition = activeTransition, let window else { return false }
        return window.windowId != transition.target.windowId && transition.windowPIDs[window.windowId] != nil
    }

    func applicationActivated(_ pid: Int32?) {
        // An activation notification can itself arrive after another activation.
        guard pid == frontmostPID() else { return }
        if let pid, pid == focus.windowOrNil?.app.pid || activeTransition?.windowPIDs.values.contains(pid) == true { return }
        cancelNavigation()
    }

    private func canNavigate(from window: Window) -> Bool {
        guard let pid = frontmostPID() else { return false }
        return pid == window.app.pid || activeTransition?.windowPIDs.values.contains(pid) == true
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
        cancelNavigation()
        ownedDevices.removeAll()
        if running { backend.stop() }
        running = false
    }

    private func receive(_ events: [TrackpadGestureEvent], receivedAt: Double, generation expected: UInt64) {
        guard running, generation == expected else { return }
        let fresh = now() - receivedAt <= TrackpadSwipeRecognizer.staleInterval
        for event in events {
            switch event {
                case .began(let device):
                    ownedDevices.insert(device)
                    cancelCandidate()
                    if fresh, ownedDevices.count == 1, canNavigate, let target = TrackpadTabTarget.capture(),
                       let window = target.focusedWindow, canNavigate(from: window) {
                        candidate = (device, target)
                    }
                case .cancelled(let device):
                    if candidate?.device == device { cancelCandidate() }
                case .ended(let device):
                    ownedDevices.remove(device)
                    if candidate?.device == device { cancelCandidate() }
                case .committed(let device, let direction):
                    guard fresh, canNavigate, let candidate, candidate.device == device else { continue }
                    self.candidate = nil
                    commit(candidate.target, direction: direction)
            }
        }
    }

    private var canNavigate: Bool {
        let runtimeActive = isUnitTest || (TrayMenuModel.shared.isEnabled && !serverArgs.isReadOnly && AXIsProcessTrusted())
        return runtimeActive && NSEvent.pressedMouseButtons == 0 &&
            !isWorkspaceSidebarDragInProgress() && !isWindowTabStripDragInProgress() && getCurrentMouseManipulationKind() == .none
    }

    private func commit(_ target: TrackpadTabTarget, direction: TrackpadSwipeDirection) {
        guard let resolved = target.resolve(direction: direction, reversed: configuration.reverseDirection),
              canNavigate(from: resolved.source)
        else { return }
        var windowPIDs = activeTransition?.windowPIDs ?? [:]
        windowPIDs[resolved.source.windowId] = resolved.source.app.pid
        windowPIDs[resolved.destination.windowId] = resolved.destination.app.pid
        let interval = signposter.beginInterval("Trackpad tab activation")
        // No AX round trip or task hop here. Each swipe advances the logical tab
        // synchronously, so a burst composes in order, including direction changes.
        activate(resolved.source, resolved.destination)
        signposter.endInterval("Trackpad tab activation", interval)
        guard let nextTarget = TrackpadTabTarget.capture(), nextTarget.windowId == resolved.destination.windowId else { return }
        focusTransition = FocusTransition(target: nextTarget, windowPIDs: windowPIDs, expiresAt: now() + 0.5)
    }

    private func workspaceChanged(_ name: Notification.Name) {
        cancelNavigation()
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
        cancelNavigation()
        restartTask?.cancel()
        restartTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            stopBackend()
            sync()
        }
    }
}

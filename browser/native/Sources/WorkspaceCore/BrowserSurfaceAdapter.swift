import Foundation

public enum BrowserSurfaceAction: String, Sendable {
    case focus, close
    case cancelFocus = "cancel_focus"
}

public struct BrowserActionRequest: Equatable, Sendable {
    public let epoch: UUID
    public let operation: UUID
    public let surfaceID: SurfaceID
    public let action: BrowserSurfaceAction
    public let revision: UInt64
    public let generation: UInt64
}

public struct BrowserLayoutRequest: Sendable {
    public let epoch: UUID, operation: UUID
    public let revision: UInt64, generation: UInt64
    public let hosts: [BrowserHostPlacement]
}

public enum BrowserActionReply: String, Sendable {
    case issued, unavailable, unsupported
    case staleLayout = "stale_layout"
    case staleEpoch = "stale_epoch", staleRevision = "stale_revision", staleFocus = "stale_focus"
    case operationConflict = "operation_conflict", invalidRequest = "invalid_request"
}

public struct BrowserFocusIntent: Equatable, Sendable {
    public let request: BrowserActionRequest
    /// Nil is pending dispatch. `issued` acknowledges dispatch only; neither
    /// this reply nor a tab's selected flag establishes native input readiness.
    public fileprivate(set) var reply: BrowserActionReply?
}

/// UI-facing connection state. The authenticated endpoint supplies the transport
/// and forwards its validated inventory. Workspace placement belongs elsewhere.
@MainActor
public final class BrowserSurfaceSession {
    public typealias Transport = @MainActor (BrowserActionRequest, @escaping @MainActor (BrowserActionReply) -> Void) -> Void
    public private(set) var epoch: UUID?
    public private(set) var inventory = BrowserInventory()
    public private(set) var focusIntent: BrowserFocusIntent?
    public let focusCoordinator: SurfaceFocusCoordinator
    public typealias LayoutTransport = @MainActor (BrowserLayoutRequest, @escaping @MainActor (BrowserActionReply) -> Void) -> Void
    private let sendLayout: LayoutTransport?
    public var supportsLayout = false
    private var layoutGeneration: UInt64 = 0
    private var desiredLayout: [BrowserHostPlacement]?
    private var acknowledgedLayout: [BrowserHostPlacement]?
    private var inFlightLayout: UUID?
    private var layoutAttemptRevision: UInt64?
    private var layoutCompletion: (@MainActor (BrowserActionReply) -> Void)?
    private let send: Transport

    public init(focusCoordinator: SurfaceFocusCoordinator = SurfaceFocusCoordinator(), sendLayout: LayoutTransport? = nil, send: @escaping Transport) {
        self.focusCoordinator = focusCoordinator
        self.send = send
        self.sendLayout = sendLayout
    }

    public func connect(epoch: UUID) {
        self.epoch = epoch
        inventory = BrowserInventory()
        focusIntent = nil
        inFlightLayout = nil
        acknowledgedLayout = nil
        layoutAttemptRevision = nil
    }

    public func disconnect(epoch: UUID) {
        guard self.epoch == epoch else { return }
        self.epoch = nil
        inventory = BrowserInventory()
        focusIntent = nil
        inFlightLayout = nil
        acknowledgedLayout = nil
        layoutAttemptRevision = nil
    }

    @discardableResult
    public func reconcile(_ message: BrowserInventoryMessage, epoch: UUID) -> Bool {
        guard self.epoch == epoch, inventory.apply(message) else { return false }
        if let focusIntent, inventory.tabs[focusIntent.request.surfaceID] == nil {
            self.focusIntent = nil
        }
        return true
    }

    public func requestLayout(_ hosts: [BrowserHostPlacement], completion: @escaping @MainActor (BrowserActionReply) -> Void) {
        guard supportsLayout, sendLayout != nil else { completion(.unsupported); return }
        if desiredLayout != hosts { layoutAttemptRevision = nil }
        desiredLayout = hosts
        layoutCompletion = completion
        flushLayout()
    }

    private func flushLayout() {
        guard let epoch, let sendLayout, let hosts = desiredLayout, inFlightLayout == nil,
              hosts != acknowledgedLayout, layoutAttemptRevision != inventory.revision,
              layoutGeneration < UInt64.max else { return }
        layoutGeneration += 1
        let request = BrowserLayoutRequest(epoch: epoch, operation: UUID(), revision: inventory.revision,
                                           generation: layoutGeneration, hosts: hosts)
        inFlightLayout = request.operation
        layoutAttemptRevision = inventory.revision
        let completion = layoutCompletion
        sendLayout(request) { [weak self] reply in
            guard let self, self.epoch == epoch, self.inFlightLayout == request.operation else { return }
            self.inFlightLayout = nil
            if reply == .issued { self.acknowledgedLayout = hosts }
            if self.desiredLayout == hosts { completion?(reply) }
            if self.desiredLayout != hosts { self.layoutAttemptRevision = nil; self.flushLayout() }
        }
    }

    fileprivate func request(_ action: BrowserSurfaceAction, surfaceID: SurfaceID) -> SurfaceActionOutcome {
        guard let epoch, inventory.tabs[surfaceID] != nil else { return .unavailable }
        var generation: UInt64 = 0
        if action == .focus {
            guard let next = focusCoordinator.select(surfaceID) else { return .unavailable }
            generation = next
        }
        let request = BrowserActionRequest(epoch: epoch, operation: UUID(), surfaceID: surfaceID, action: action,
                                           revision: inventory.revision, generation: generation)
        if action == .focus { focusIntent = BrowserFocusIntent(request: request) }
        send(request) { [weak self] reply in
            guard let self, self.epoch == request.epoch,
                  self.focusCoordinator.isCurrent(request.generation, target: request.surfaceID),
                  self.focusIntent?.request.operation == request.operation else { return }
            self.focusIntent?.reply = reply
        }
        // Close acknowledgements intentionally do not remove a row. Only the
        // browser's inventory delta can confirm the tab actually went away.
        return .issued
    }

    /// Send a fence through the browser UI queue. Native selection can happen
    /// immediately; the caller may reaffirm it after the fence if still current.
    public func supersedeFocus(generation: UInt64, target: SurfaceID,
                               completion: @escaping @MainActor (BrowserActionReply) -> Void) {
        focusIntent = nil
        guard let epoch else { completion(.unavailable); return }
        let request = BrowserActionRequest(epoch: epoch, operation: UUID(), surfaceID: target,
                                          action: .cancelFocus, revision: inventory.revision, generation: generation)
        send(request) { [weak self] reply in
            guard self?.epoch == epoch else { return }
            completion(reply)
        }
    }
}

@MainActor
public struct BrowserTabSurfaceAdapter: SurfaceAdapter {
    public let surfaceID: SurfaceID
    public let capabilities: SurfaceCapabilities = [.focus, .close]
    private weak var session: BrowserSurfaceSession?

    public init(surfaceID: SurfaceID, session: BrowserSurfaceSession) {
        self.surfaceID = surfaceID
        self.session = session
    }

    public func requestFocus() -> SurfaceActionOutcome { session?.request(.focus, surfaceID: surfaceID) ?? .unavailable }
    public func requestClose() -> SurfaceActionOutcome { session?.request(.close, surfaceID: surfaceID) ?? .unavailable }
}

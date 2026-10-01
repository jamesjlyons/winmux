import Foundation

public enum BrowserSurfaceAction: String, Sendable {
    case focus, close
}

public struct BrowserActionRequest: Equatable, Sendable {
    public let epoch: UUID
    public let operation: UUID
    public let surfaceID: SurfaceID
    public let action: BrowserSurfaceAction
    public let revision: UInt64
    public let generation: UInt64
}

public enum BrowserActionReply: String, Sendable {
    case issued, unavailable, unsupported
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
    private var nextFocusGeneration: UInt64 = 0
    private let send: Transport

    public init(send: @escaping Transport) { self.send = send }

    public func connect(epoch: UUID) {
        self.epoch = epoch
        inventory = BrowserInventory()
        focusIntent = nil
        nextFocusGeneration = 0
    }

    public func disconnect(epoch: UUID) {
        guard self.epoch == epoch else { return }
        self.epoch = nil
        inventory = BrowserInventory()
        focusIntent = nil
    }

    @discardableResult
    public func reconcile(_ message: BrowserInventoryMessage, epoch: UUID) -> Bool {
        guard self.epoch == epoch, inventory.apply(message) else { return false }
        if let focusIntent, inventory.tabs[focusIntent.request.surfaceID] == nil {
            self.focusIntent = nil
        }
        return true
    }

    fileprivate func request(_ action: BrowserSurfaceAction, surfaceID: SurfaceID) -> SurfaceActionOutcome {
        guard let epoch, inventory.tabs[surfaceID] != nil else { return .unavailable }
        if action == .focus {
            guard nextFocusGeneration < .max else { return .unavailable }
            nextFocusGeneration += 1
        }
        let request = BrowserActionRequest(epoch: epoch, operation: UUID(), surfaceID: surfaceID, action: action,
                                           revision: inventory.revision, generation: action == .focus ? nextFocusGeneration : 0)
        if action == .focus { focusIntent = BrowserFocusIntent(request: request) }
        send(request) { [weak self] reply in
            guard let self, self.epoch == request.epoch,
                  self.focusIntent?.request.operation == request.operation else { return }
            self.focusIntent?.reply = reply
        }
        // Close acknowledgements intentionally do not remove a row. Only the
        // browser's inventory delta can confirm the tab actually went away.
        return .issued
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

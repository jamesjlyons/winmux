import Foundation

public enum BrowserSurfaceAction: String, Sendable {
    case focus, close, back, forward, reload, stop, navigate, extensions
    case newTab = "new_tab"
    case manageExtensions = "manage_extensions"
    case cancelFocus = "cancel_focus"
}

public struct BrowserActionRequest: Equatable, Sendable {
    public let epoch: UUID
    public let operation: UUID
    public let surfaceID: SurfaceID
    public let action: BrowserSurfaceAction
    public let revision: UInt64
    public let generation: UInt64
    public let url: String?
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
    public var supportsBrowserControls = false
    private struct PendingAction {
        let request: BrowserActionRequest
        let completion: (@MainActor (BrowserActionReply) -> Void)?
    }
    private var pendingActions: [PendingAction] = []
    private var layoutGeneration: UInt64 = 0
    private var desiredLayout: [BrowserHostPlacement]?
    private var acknowledgedLayout: [BrowserHostPlacement]?
    private var layoutAcknowledgementToken = UUID()
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
        pendingActions.removeAll()
        inFlightLayout = nil
        acknowledgedLayout = nil
        layoutAttemptRevision = nil
    }

    public func disconnect(epoch: UUID) {
        guard self.epoch == epoch else { return }
        self.epoch = nil
        inventory = BrowserInventory()
        focusIntent = nil
        pendingActions.removeAll()
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
        flushPendingActions()
        return true
    }

    /// Native movement can invalidate a successfully dispatched frame without
    /// changing the workspace plan. Require a fresh request from the caller;
    /// neither invalidation nor a late reply should resend an obsolete plan.
    /// Keep the in-flight operation until its reply so transport stays serialized.
    public func invalidateLayoutAcknowledgement() {
        layoutAcknowledgementToken = UUID()
        acknowledgedLayout = nil
        layoutAttemptRevision = nil
        desiredLayout = nil
        layoutCompletion = nil
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
        let acknowledgementToken = layoutAcknowledgementToken
        sendLayout(request) { [weak self] reply in
            guard let self, self.epoch == epoch, self.inFlightLayout == request.operation else { return }
            self.inFlightLayout = nil
            let acknowledgementIsCurrent = self.layoutAcknowledgementToken == acknowledgementToken
            if acknowledgementIsCurrent && reply == .issued { self.acknowledgedLayout = hosts }
            if acknowledgementIsCurrent && self.desiredLayout == hosts { completion?(reply) }
            if !acknowledgementIsCurrent || self.desiredLayout != hosts {
                self.layoutAttemptRevision = nil
                self.flushLayout()
            }
        }
    }

    /// Dispatches browser-owned commands. Inventory remains authoritative; a
    /// successful reply acknowledges dispatch, not navigation completion.
    @discardableResult
    public func request(_ action: BrowserSurfaceAction, surfaceID: SurfaceID, url: String? = nil,
                        completion: (@MainActor (BrowserActionReply) -> Void)? = nil) -> SurfaceActionOutcome {
        guard action == .focus || action == .close || supportsBrowserControls else {
            completion?(.unsupported); return .unsupported
        }
        guard action != .cancelFocus else { completion?(.invalidRequest); return .unsupported }
        guard let epoch, let tab = inventory.tabs[surfaceID] else { completion?(.unavailable); return .unavailable }
        guard (action != .navigate || url?.isEmpty == false),
              url == nil || action == .navigate || action == .newTab,
              (url?.utf8.count ?? 0) <= 16_384 else { completion?(.invalidRequest); return .unsupported }
        guard action != .back || tab.canGoBack,
              action != .forward || tab.canGoForward else { completion?(.unavailable); return .unavailable }
        var generation: UInt64 = 0
        if action == .focus {
            guard let next = focusCoordinator.select(surfaceID) else { return .unavailable }
            generation = next
        }
        let request = BrowserActionRequest(epoch: epoch, operation: UUID(), surfaceID: surfaceID, action: action,
                                           revision: inventory.revision, generation: generation, url: url)
        if action == .focus { focusIntent = BrowserFocusIntent(request: request) }
        sendAction(request, canRetry: action != .focus && action != .close, completion: completion)
        // Close acknowledgements intentionally do not remove a row. Only the
        // browser's inventory delta can confirm the tab actually went away.
        return .issued
    }

    private func sendAction(_ request: BrowserActionRequest, canRetry: Bool,
                            completion: (@MainActor (BrowserActionReply) -> Void)?) {
        send(request) { [weak self] reply in
            guard let self, self.epoch == request.epoch else { return }
            if reply == .staleRevision, canRetry, self.pendingActions.count < 16 {
                self.pendingActions.append(PendingAction(request: request, completion: completion))
                self.flushPendingActions()
                return
            }
            if request.action == .focus,
               self.focusCoordinator.isCurrent(request.generation, target: request.surfaceID),
               self.focusIntent?.request.operation == request.operation {
                self.focusIntent?.reply = reply
            }
            completion?(reply)
        }
    }

    private func flushPendingActions() {
        let ready = pendingActions.filter { inventory.revision > $0.request.revision }
        pendingActions.removeAll { inventory.revision > $0.request.revision }
        for pending in ready {
            let request = pending.request
            guard inventory.tabs[request.surfaceID] != nil else {
                pending.completion?(.unavailable); continue
            }
            let retry = BrowserActionRequest(epoch: request.epoch, operation: UUID(),
                                             surfaceID: request.surfaceID, action: request.action,
                                             revision: inventory.revision, generation: request.generation,
                                             url: request.url)
            // stale_revision is returned before Chromium dispatches anything.
            // A single retry consumes newer authoritative inventory; issued
            // commands and uncertain transport failures are never replayed.
            sendAction(retry, canRetry: false, completion: pending.completion)
        }
    }

    /// Send a fence through the browser UI queue. Native selection can happen
    /// immediately; the caller may reaffirm it after the fence if still current.
    public func supersedeFocus(generation: UInt64, target: SurfaceID,
                               completion: @escaping @MainActor (BrowserActionReply) -> Void) {
        focusIntent = nil
        guard let epoch else { completion(.unavailable); return }
        let request = BrowserActionRequest(epoch: epoch, operation: UUID(), surfaceID: target,
                                          action: .cancelFocus, revision: inventory.revision, generation: generation, url: nil)
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

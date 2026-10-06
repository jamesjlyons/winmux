import Foundation

public enum BrowserSurfaceAction: String, Sendable {
    case focus, close, back, forward, reload, stop, navigate, extensions, minimize, fullscreen, zoom
    case search, privacy
    case keepActive = "keep_active", siteBlocking = "site_blocking"
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
    public private(set) var lastLayoutRequest: BrowserLayoutRequest?
    public private(set) var lastLayoutReply: BrowserActionReply?
    public private(set) var layoutTimeoutCount: UInt64 = 0
    /// Monotonic transport age, not a measurement of rendered presentation.
    public var pendingLayoutMilliseconds: Double? {
        layoutDispatchedAt.map { Double(DispatchTime.now().uptimeNanoseconds - $0) / 1_000_000 }
    }
    private let sendLayout: LayoutTransport?
    public var supportsLayout = false
    public var supportsBrowserControls = false
    public var supportsPrivacy = false
    public var supportsTabCreation = false
    public var supportsWorkspaceProfiles = false
    public typealias NewTabTransport = @MainActor (BrowserNewTabRequest, @escaping @MainActor (BrowserActionReply, SurfaceID?) -> Void) -> Void
    private let sendNewTab: NewTabTransport?
    private struct PendingAction {
        let request: BrowserActionRequest
        let completion: (@MainActor (BrowserActionReply) -> Void)?
    }
    private var pendingActions: [PendingAction] = []
    private struct PendingCreation {
        let request: BrowserNewTabRequest
        let completion: @MainActor (BrowserActionReply, SurfaceID?) -> Void
    }
    private var pendingCreations: [PendingCreation] = []
    private var layoutGeneration: UInt64 = 0
    private var desiredLayout: [BrowserHostPlacement]?
    private var acknowledgedLayout: [BrowserHostPlacement]?
    private var layoutAcknowledgementToken = UUID()
    private var inFlightLayout: UUID?
    private var layoutAttemptRevision: UInt64?
    private var layoutCompletion: (@MainActor (BrowserActionReply) -> Void)?
    private var layoutDispatchedAt: UInt64?
    private var layoutTimeoutRetries = 0
    private var cancelLayoutDeadline: (@MainActor () -> Void)?
    // Injectable so missing replies and late callbacks can be tested without
    // wall-clock sleeps. Only authoritative, generation-fenced layouts retry;
    // navigation, creation, close and other actions never use this mechanism.
    typealias LayoutDeadlineScheduler = @MainActor (Duration, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)
    var scheduleLayoutDeadline: LayoutDeadlineScheduler = { delay, expired in
        let task = Task { @MainActor in
            do { try await Task.sleep(for: delay) } catch { return }
            expired()
        }
        return { task.cancel() }
    }
    private let send: Transport
    private let canRetryFocus: @MainActor () -> Bool

    public init(focusCoordinator: SurfaceFocusCoordinator = SurfaceFocusCoordinator(), sendLayout: LayoutTransport? = nil, sendNewTab: NewTabTransport? = nil,
                canRetryFocus: @escaping @MainActor () -> Bool = { true }, send: @escaping Transport) {
        self.focusCoordinator = focusCoordinator
        self.send = send
        self.sendLayout = sendLayout
        self.sendNewTab = sendNewTab
        self.canRetryFocus = canRetryFocus
    }

    public func connect(epoch: UUID) {
        clearLayoutDeadline()
        layoutTimeoutRetries = 0
        layoutTimeoutCount = 0
        self.epoch = epoch
        inventory = BrowserInventory()
        focusIntent = nil
        pendingActions.removeAll()
        let creations = pendingCreations
        pendingCreations.removeAll()
        creations.forEach { $0.completion(.staleEpoch, nil) }
        inFlightLayout = nil
        acknowledgedLayout = nil
        lastLayoutRequest = nil
        lastLayoutReply = nil
        layoutAttemptRevision = nil
    }

    public func disconnect(epoch: UUID) {
        guard self.epoch == epoch else { return }
        clearLayoutDeadline()
        layoutTimeoutRetries = 0
        self.epoch = nil
        inventory = BrowserInventory()
        focusIntent = nil
        pendingActions.removeAll()
        let creations = pendingCreations
        pendingCreations.removeAll()
        creations.forEach { $0.completion(.staleEpoch, nil) }
        inFlightLayout = nil
        acknowledgedLayout = nil
        lastLayoutRequest = nil
        lastLayoutReply = nil
        layoutAttemptRevision = nil
    }

    @discardableResult
    public func reconcile(_ message: BrowserInventoryMessage, epoch: UUID) -> Bool {
        guard self.epoch == epoch, inventory.apply(message) else { return false }
        if let focusIntent, inventory.tabs[focusIntent.request.surfaceID] == nil {
            self.focusIntent = nil
        }
        flushPendingActions()
        flushPendingCreations()
        return true
    }

    /// Native movement can invalidate a successfully dispatched frame without
    /// changing the workspace plan. Require a fresh request from the caller;
    /// neither invalidation nor a late reply should resend an obsolete plan.
    /// Keep the in-flight operation until its reply or deadline so ordinary
    /// transport stays serialized, while a lost callback cannot block recovery.
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
        if inFlightLayout == nil { layoutTimeoutRetries = 0 }
        flushLayout()
    }

    private func clearLayoutDeadline() {
        cancelLayoutDeadline?()
        cancelLayoutDeadline = nil
        layoutDispatchedAt = nil
    }

    private func layoutDeadlineExpired(_ request: BrowserLayoutRequest) {
        guard epoch == request.epoch, inFlightLayout == request.operation else { return }
        clearLayoutDeadline()
        inFlightLayout = nil
        lastLayoutReply = .unavailable
        if layoutTimeoutCount < UInt64.max { layoutTimeoutCount += 1 }
        // The timed-out request may have applied. An older acknowledged plan
        // cannot deduplicate a subsequent repair, even if the user returned to it.
        acknowledgedLayout = nil
        guard desiredLayout != nil else { return }
        if desiredLayout != request.hosts || inventory.revision > request.revision {
            // The latest group/inventory has not been attempted yet. An older
            // plan's exhausted budget must never mark that replacement failed.
            layoutTimeoutRetries = 0
        } else {
            guard layoutTimeoutRetries < 2 else {
                // An unchanged plan/revision receives at most three requests
                // (at 0, 1 and 3s). Actual new work can start a fresh budget.
                layoutAttemptRevision = inventory.revision
                layoutCompletion?(.unavailable)
                return
            }
            layoutTimeoutRetries += 1
        }
        layoutAttemptRevision = nil
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
        lastLayoutRequest = request
        lastLayoutReply = nil
        layoutAttemptRevision = inventory.revision
        let completion = layoutCompletion
        let acknowledgementToken = layoutAcknowledgementToken
        layoutDispatchedAt = DispatchTime.now().uptimeNanoseconds
        cancelLayoutDeadline = scheduleLayoutDeadline(.seconds(1 << layoutTimeoutRetries)) { [weak self] in
            self?.layoutDeadlineExpired(request)
        }
        sendLayout(request) { [weak self] reply in
            guard let self, self.epoch == epoch, self.inFlightLayout == request.operation else { return }
            self.clearLayoutDeadline()
            self.layoutTimeoutRetries = 0
            self.inFlightLayout = nil
            self.lastLayoutReply = reply
            let acknowledgementIsCurrent = self.layoutAcknowledgementToken == acknowledgementToken
            if acknowledgementIsCurrent && reply == .issued { self.acknowledgedLayout = hosts }
            if acknowledgementIsCurrent && self.desiredLayout == hosts { completion?(reply) }
            if !acknowledgementIsCurrent || self.desiredLayout != hosts {
                self.layoutAttemptRevision = nil
                self.flushLayout()
            } else if reply == .staleRevision, self.inventory.revision > request.revision {
                // New inventory can arrive while an unchanged plan is in flight.
                // Its refresh cannot send until this reply releases the transport.
                // Retry against that already observed revision without waiting for
                // another event; the attempt guard permits only one per revision.
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
        if [.search, .privacy, .keepActive, .siteBlocking].contains(action), !supportsPrivacy { completion?(.unsupported); return .unsupported }
        guard (action != .navigate || url?.isEmpty == false),
              url == nil || [.navigate, .newTab, .search, .privacy, .keepActive, .siteBlocking].contains(action),
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
        sendAction(request, canRetry: action != .close, completion: completion)
        // Close acknowledgements intentionally do not remove a row. Only the
        // browser's inventory delta can confirm the tab actually went away.
        return .issued
    }

    private func sendAction(_ request: BrowserActionRequest, canRetry: Bool,
                            completion: (@MainActor (BrowserActionReply) -> Void)?) {
        send(request) { [weak self] reply in
            guard let self, self.epoch == request.epoch else { return }
            if reply == .staleRevision, canRetry, self.pendingActions.count < 16 {
                if request.action == .focus,
                   (!self.canRetryFocus() || !self.focusCoordinator.isCurrent(request.generation, target: request.surfaceID) ||
                    self.focusIntent?.request.operation != request.operation) {
                    completion?(.staleFocus)
                    return
                }
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
            var generation = request.generation
            if request.action == .focus {
                // Chromium rejected this before dispatch, but consumed its
                // focus generation. Retry only the still-current intent with
                // a fresh generation; a newer page or native selection wins.
                guard canRetryFocus(), focusCoordinator.isCurrent(request.generation, target: request.surfaceID),
                      focusIntent?.request.operation == request.operation else {
                    pending.completion?(.staleFocus); continue
                }
                guard let next = focusCoordinator.select(request.surfaceID) else {
                    pending.completion?(.unavailable); continue
                }
                generation = next
            }
            let retry = BrowserActionRequest(epoch: request.epoch, operation: UUID(),
                                             surfaceID: request.surfaceID, action: request.action,
                                             revision: inventory.revision, generation: generation,
                                             url: request.url)
            if request.action == .focus { focusIntent = BrowserFocusIntent(request: retry) }
            // stale_revision is returned before Chromium dispatches anything.
            // A single retry consumes newer authoritative inventory; issued
            // commands and uncertain transport failures are never replayed.
            sendAction(retry, canRetry: false, completion: pending.completion)
        }
    }

    /// A session owns creation even when its authoritative inventory is empty.
    /// No uncertain transport failure is retried, so a shortcut opens one page.
    @discardableResult
    public func openTab(sourceSurfaceID: SurfaceID? = nil, profileID: UUID? = nil, url: String? = nil,
                        workspaceProfile: WorkspaceBrowserProfileTarget? = nil,
                        completion: @escaping @MainActor (BrowserActionReply, SurfaceID?) -> Void) -> SurfaceActionOutcome {
        guard supportsTabCreation, sendNewTab != nil else { completion(.unsupported, nil); return .unsupported }
        guard workspaceProfile == nil || supportsWorkspaceProfiles else { completion(.unsupported, nil); return .unsupported }
        guard workspaceProfile == nil || (sourceSurfaceID == nil && profileID == nil && workspaceProfile?.isValid == true) else {
            completion(.invalidRequest, nil); return .unsupported
        }
        guard let epoch else { completion(.unavailable, nil); return .unavailable }
        guard sourceSurfaceID == nil || inventory.tabs[sourceSurfaceID!] != nil else {
            completion(.unavailable, nil); return .unavailable
        }
        guard url == nil || (url?.isEmpty == false && (url?.utf8.count ?? 0) <= 16_384) else {
            completion(.invalidRequest, nil); return .unsupported
        }
        let sourceProfile = sourceSurfaceID.flatMap { id -> UUID? in
            if case .browserTab(let profile, _) = id { return profile }; return nil
        }
        guard profileID == nil || sourceProfile == nil || profileID == sourceProfile else {
            completion(.invalidRequest, nil); return .unsupported
        }
        let request = BrowserNewTabRequest(epoch: epoch, operation: UUID(), sourceSurfaceID: sourceSurfaceID,
                                           profileID: profileID ?? sourceProfile, revision: inventory.revision, url: url,
                                           workspaceProfile: workspaceProfile)
        sendCreation(request, canRetry: true, completion: completion)
        return .issued
    }

    private func sendCreation(_ request: BrowserNewTabRequest, canRetry: Bool,
                              completion: @escaping @MainActor (BrowserActionReply, SurfaceID?) -> Void) {
        guard let sendNewTab else { completion(.unsupported, nil); return }
        sendNewTab(request) { [weak self] reply, id in
            let epoch = request.epoch
            guard self?.epoch == epoch else { completion(.staleEpoch, nil); return }
            guard let self else { completion(.unavailable, nil); return }
            if reply == .staleRevision, canRetry, self.pendingCreations.count < 16 {
                self.pendingCreations.append(PendingCreation(request: request, completion: completion))
                self.flushPendingCreations()
                return
            }
            guard reply != .issued || id.map({ id in
                if case .browserTab(let profile, _) = id {
                    let expected = request.workspaceProfile?.profileID ?? request.profileID
                    return expected == nil || profile == expected
                }
                return false
            }) == true else {
                completion(.invalidRequest, nil); return
            }
            completion(reply, reply == .issued ? id : nil)
        }
    }

    private func flushPendingCreations() {
        let ready = pendingCreations.filter { inventory.revision > $0.request.revision }
        pendingCreations.removeAll { inventory.revision > $0.request.revision }
        for pending in ready {
            let request = pending.request
            let source = request.sourceSurfaceID.flatMap { inventory.tabs[$0] != nil ? $0 : nil }
            let retry = BrowserNewTabRequest(epoch: request.epoch, operation: UUID(), sourceSurfaceID: source,
                                              profileID: request.profileID, revision: inventory.revision, url: request.url,
                                              workspaceProfile: request.workspaceProfile)
            sendCreation(retry, canRetry: false, completion: pending.completion)
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

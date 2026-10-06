import AppKit
import Common
import WorkspaceCore

@MainActor final class BrowserProfileMove {
    let id = UUID()
    let session: BrowserSurfaceSession
    let epoch: UUID?
    let existingSurfaces: Set<SurfaceID>
    let destination: Workspace
    let space: WorkspaceProjectId
    let profile: WorkspaceBrowserProfileTarget
    let sources: [SurfaceID: String]
    let urls: [SurfaceID: String]
    let closedPin: BrowserSidebarPin?
    let commit: () -> Bool
    var replacements: [SurfaceID: SurfaceID] = [:]
    var closedPinReplacement: SurfaceID?
    var repliesRemaining: Int
    var dispatching = true
    var timeout: Task<Void, Never>?

    init(session: BrowserSurfaceSession, destination: Workspace, profile: WorkspaceBrowserProfileTarget,
         sources: [SurfaceID: String], urls: [SurfaceID: String], closedPin: BrowserSidebarPin?,
         commit: @escaping () -> Bool) {
        self.session = session; epoch = session.epoch
        existingSurfaces = Set(session.inventory.tabs.keys)
        self.destination = destination; space = destination.projectId; self.profile = profile
        self.sources = sources; self.urls = urls; self.closedPin = closedPin; self.commit = commit
        repliesRemaining = urls.count + (closedPin == nil ? 0 : 1)
    }

    var created: [SurfaceID] { Array(replacements.values) + (closedPinReplacement.map { [$0] } ?? []) }
}

extension BrowserWorkspaceController {
    /// nil permits the existing synchronous move. true means an asynchronous
    /// profile move was accepted; no source membership changes until commit.
    func moveUsingDestinationProfile(_ surfaces: [SurfaceID], closedPin: BrowserSidebarPin? = nil,
                                     to destination: Workspace, commit: @escaping () -> Bool) -> Bool? {
        guard surfaces.allSatisfy({ canPlaceSurface($0, in: destination) }), closedPin == nil || !destination.isIncognito else { return false }
        guard !committingProfileMove else { return nil }
        guard !pendingProfileMoves.values.contains(where: { move in
            surfaces.contains { move.sources[$0] != nil } ||
                (closedPin != nil && move.closedPin?.id == closedPin?.id)
        }) else { return false }
        let browser = surfaces.filter { $0.browserProfileID != nil }
        let sourceNames = browser.compactMap { workspaceName(for: $0) } + (closedPin.map { [$0.workspaceName] } ?? [])
        guard sourceNames.contains(where: { Workspace.existing(byName: $0)?.projectId != destination.projectId }) else { return nil }
        guard !destination.isArchived, let profile = try? browserProfileTarget(for: destination.projectId) else {
            reportProfileMoveFailure(); return false
        }
        // Preserve the legacy single-profile flow, including a pin whose open
        // reply has not arrived yet. Named profiles always require a modern owner.
        if profile == .shared, browserProfiles.isEmpty,
           tabCreationSession()?.supportsWorkspaceProfiles != true { return nil }
        func matches(_ id: SurfaceID) -> Bool {
            if let expected = profile.profileID { return id.browserProfileID == expected }
            guard let session = owner(of: id) else { return false }
            if let shared = session.inventory.tabs[id]?.isSharedProfile { return shared }
            // Legacy owners predate Space profiles. An unknown modern owner is
            // conservatively routed through Shared, never guessed from its UUID.
            return !session.supportsWorkspaceProfiles && browserProfiles.isEmpty
        }
        let changing = browser.filter { !matches($0) }
        let changingPin = closedPin.flatMap { pin -> BrowserSidebarPin? in
            if profile.profileID == pin.profileID { return nil }
            if profile == .shared, knownSurfaces.contains(where: { $0.browserProfileID == pin.profileID && matches($0) }) { return nil }
            return pin
        }
        guard !changing.isEmpty || changingPin != nil else { return nil }
        guard let session = changing.first.flatMap({ owner(of: $0) }) ?? tabCreationSession(),
              session.supportsWorkspaceProfiles,
              changing.allSatisfy({ owner(of: $0) === session }),
              closedPin.map({ !pendingSidebarPinOpenings.contains($0.id) }) ?? true else {
            reportProfileMoveFailure(); return false
        }
        var sources: [SurfaceID: String] = [:], urls: [SurfaceID: String] = [:]
        for id in surfaces {
            guard let source = workspaceName(for: id), isAvailable(id) else { return false }
            sources[id] = source
        }
        for id in changing {
            guard let record = session.inventory.tabs[id] else { return false }
            urls[id] = record.url
        }
        let move = BrowserProfileMove(session: session, destination: destination, profile: profile,
            sources: sources, urls: urls, closedPin: changingPin, commit: commit)
        pendingProfileMoves[move.id] = move
        move.timeout = Task { [weak self, weak move] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, let move, self.pendingProfileMoves[move.id] != nil else { return }
            self.cancelProfileMove(move)
        }
        func create(_ url: String, replacing old: SurfaceID?) {
            session.openTab(url: url.isEmpty ? "chrome://newtab/" : url, workspaceProfile: profile) { [weak self] reply, new in
                guard let self else { return }
                guard self.pendingProfileMoves[move.id] != nil else {
                    if reply == .issued, let new { self.discardProfileMoveCopy(new) }
                    return
                }
                guard reply == .issued, let new, !surfaces.contains(new), !move.created.contains(new) else {
                    self.cancelProfileMove(move); return
                }
                if let old { move.replacements[old] = new } else { move.closedPinReplacement = new }
                move.repliesRemaining -= 1
                self.completePendingProfileMoves()
            }
        }
        for (old, url) in urls where pendingProfileMoves[move.id] != nil { create(url, replacing: old) }
        if let changingPin, pendingProfileMoves[move.id] != nil { create(changingPin.url, replacing: nil) }
        move.dispatching = false
        completePendingProfileMoves()
        return true
    }

    func completePendingProfileMoves() {
        for id in profileMoveCopiesToClose where isAvailable(id) {
            profileMoveCopiesToClose.remove(id)
            _ = close(id)
        }
        for move in Array(pendingProfileMoves.values) {
            guard !move.dispatching, move.repliesRemaining == 0 else { continue }
            guard move.session.epoch == move.epoch,
                  Workspace.existing(byName: move.destination.name) === move.destination,
                  !move.destination.isArchived, move.destination.projectId == move.space,
                  (try? browserProfileTarget(for: move.space)) == move.profile,
                  move.sources.allSatisfy({ workspaceName(for: $0.key) == $0.value && isAvailable($0.key) }),
                  move.urls.allSatisfy({ move.session.inventory.tabs[$0.key]?.url == $0.value }),
                  move.closedPin.map({ browserSidebarPins.contains($0) }) ?? true else {
                cancelProfileMove(move); continue
            }
            // Owner inventory and the creation reply can arrive in either order.
            guard move.created.allSatisfy({ owner(of: $0) === move.session }) else { continue }
            committingProfileMove = true
            let committed = move.commit()
            committingProfileMove = false
            guard committed else { cancelProfileMove(move); continue }
            pendingProfileMoves.removeValue(forKey: move.id)
            move.timeout?.cancel()
            installProfileMoveReplacements(move)
        }
    }

    func discardProfileMoveCopy(_ id: SurfaceID) {
        if isAvailable(id) { _ = close(id) }
        else { profileMoveCopiesToClose.insert(id) }
    }

    func isProfileMoveCopy(_ id: SurfaceID) -> Bool {
        pendingProfileMoves.values.contains { $0.created.contains(id) }
    }

    func isProfileMoveArrival(_ id: SurfaceID, session: BrowserSurfaceSession) -> Bool {
        pendingProfileMoves.values.contains { $0.session === session && !$0.existingSurfaces.contains(id) }
    }

    func cancelProfileMove(_ move: BrowserProfileMove) {
        guard pendingProfileMoves.removeValue(forKey: move.id) != nil else { return }
        move.timeout?.cancel()
        for id in move.created { discardProfileMoveCopy(id) }
        reportProfileMoveFailure()
    }

    private func reportProfileMoveFailure() {
        if !isUnitTest { showWorkspaceSidebarError("Could not move the page into the destination browser profile. Your original tabs are unchanged.") }
    }
}

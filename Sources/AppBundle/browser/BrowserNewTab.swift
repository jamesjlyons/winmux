import Common
import Foundation
import WorkspaceCore

extension SurfaceID {
    var browserProfileID: UUID? { if case .browserTab(let profile, _) = self { return profile }; return nil }
}

extension BrowserWorkspaceController {
    @discardableResult
    func openBrowserTab(url: String? = nil, workspaceName: String? = nil, profileID: UUID? = nil,
                        explicitPlacement: Bool = false,
                        created: (@MainActor (SurfaceID) -> Void)? = nil,
                        completion: (@MainActor (BrowserActionReply) -> Void)? = nil) -> SurfaceActionOutcome {
        let requestedWorkspace = workspaceName.flatMap { Workspace.existing(byName: $0) } ?? focus.workspace
        let workspaceProfile: WorkspaceBrowserProfileTarget?
        do {
            workspaceProfile = profileID == nil ? try browserProfileTarget(for: requestedWorkspace.projectId) : nil
        } catch {
            if !isUnitTest { showWorkspaceSidebarError(error.localizedDescription) }
            completion?(.unavailable)
            return .unavailable
        }
        guard let session = tabCreationSession(profileID: profileID ?? workspaceProfile?.profileID) else {
            NSLog("WinMux new tab: no connected creation owner")
            completion?(.unavailable)
            return .unavailable
        }
        // Older owners retain their original default behavior. A named profile
        // must fail visibly rather than silently use the previous account.
        if workspaceProfile?.profileID != nil && !session.supportsWorkspaceProfiles {
            if !isUnitTest { showWorkspaceSidebarError("Restart with the browser build that supports Space profiles.") }
            completion?(.unsupported)
            return .unsupported
        }
        let routedProfile = session.supportsWorkspaceProfiles ? workspaceProfile : nil
        let workspace = (url == nil ? regularWorkspaceForNewItem(requestedWorkspace) : requestedWorkspace).name
        let source = routedProfile == nil ? focusCoordinator.target.flatMap { session.inventory.tabs[$0] != nil &&
            (profileID == nil || $0.browserProfileID == profileID) ? $0 : nil }
            : nil
        let creation = UUID(), startingFocus = focusCoordinator.generation
        latestBrowserTabCreation = creation
        pendingBrowserTabSelections.removeAll()
        pendingBrowserTabAddress = nil
        cancelPendingBrowserFocusHold()
        NSLog("WinMux new tab: dispatch")
        return session.openTab(sourceSurfaceID: source, profileID: profileID, url: url, workspaceProfile: routedProfile) { [weak self] reply, id in
            NSLog("WinMux new tab: %@", reply.rawValue)
            if reply == .issued, let id, let self {
                let selectCreated = self.latestBrowserTabCreation == creation &&
                    (self.focusCoordinator.generation == startingFocus || self.focusCoordinator.target == id)
                let destination = config.workspaceInteractionMode == .views && !explicitPlacement
                    ? self.standaloneBrowserDestination(id, in: requestedWorkspace) : workspace
                self.placeCreatedBrowserTab(id, in: destination, focusAddress: url == nil,
                                           selectCreated: selectCreated, focusGeneration: startingFocus)
                created?(id)
            }
            if reply != .issued, routedProfile != nil, !isUnitTest {
                showWorkspaceSidebarError("Could not open a tab in the selected browser profile. Your existing tabs are unchanged.")
            }
            completion?(reply)
        }
    }

    func completePendingBrowserTabSelections() {
        for (id, address) in pendingBrowserTabSelections where owner(of: id) != nil {
            pendingBrowserTabSelections[id] = nil
            guard pendingBrowserTabFocusGeneration == focusCoordinator.generation || focusCoordinator.target == id else { continue }
            if select(id) == .issued, address { pendingBrowserTabAddress = id }
        }
    }

    func focusCreatedBrowserTabAddress() {
        guard let id = pendingBrowserTabAddress else { return }
        guard focusCoordinator.target == id, owner(of: id) != nil else { pendingBrowserTabAddress = nil; return }
        if BrowserToolbarController.shared.focusAddress(for: id) { pendingBrowserTabAddress = nil }
    }
}

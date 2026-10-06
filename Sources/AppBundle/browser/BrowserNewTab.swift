import Common
import Foundation
import WorkspaceCore

extension SurfaceID {
    var browserProfileID: UUID? { if case .browserTab(let profile, _) = self { return profile }; return nil }
}

extension BrowserWorkspaceController {
    @discardableResult
    func openBrowserTab(url: String? = nil, workspaceName: String? = nil, profileID: UUID? = nil, selectNewPage: Bool = true,
                        created: (@MainActor (SurfaceID) -> Void)? = nil,
                        completion: (@MainActor (BrowserActionReply) -> Void)? = nil) -> SurfaceActionOutcome {
        guard let session = tabCreationSession(profileID: profileID) else {
            NSLog("WinMux new tab: no connected creation owner")
            completion?(.unavailable)
            return .unavailable
        }
        let requestedWorkspace = workspaceName.flatMap { Workspace.existing(byName: $0) } ?? focus.workspace
        let workspace = (url == nil ? regularWorkspaceForNewItem(requestedWorkspace) : requestedWorkspace).name
        let source = focusCoordinator.target.flatMap { session.inventory.tabs[$0] != nil &&
            (profileID == nil || $0.browserProfileID == profileID) ? $0 : nil }
        let creation = UUID(), startingFocus = focusCoordinator.generation
        if selectNewPage {
            latestBrowserTabCreation = creation
            pendingBrowserTabSelections.removeAll()
            pendingBrowserTabAddress = nil
            cancelPendingBrowserFocusHold()
        }
        NSLog("WinMux new tab: dispatch")
        return session.openTab(sourceSurfaceID: source, profileID: profileID, url: url) { [weak self] reply, id in
            NSLog("WinMux new tab: %@", reply.rawValue)
            if reply == .issued, let id, let self {
                let selectCreated = selectNewPage && self.latestBrowserTabCreation == creation &&
                    (self.focusCoordinator.generation == startingFocus || self.focusCoordinator.target == id)
                self.placeCreatedBrowserTab(id, in: workspace, focusAddress: url == nil,
                                           selectCreated: selectCreated, focusGeneration: startingFocus)
                created?(id)
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

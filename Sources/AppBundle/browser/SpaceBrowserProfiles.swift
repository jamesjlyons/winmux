import Foundation
import WorkspaceCore

enum SpaceBrowserProfileError: LocalizedError {
    case invalidName, duplicateName, tooManyProfiles, missingProfile
    var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a short profile name without line breaks or control characters."
        case .duplicateName: "A browser profile with that name already exists. Choose it from the Browser Profile menu."
        case .tooManyProfiles: "This workspace has reached its browser profile limit."
        case .missingProfile: "That browser profile is no longer available. Choose a profile for this Space."
        }
    }
}

extension BrowserWorkspaceController {
    /// Lookup failure never falls back to another account.
    func browserProfileTarget(for space: WorkspaceProjectId) throws -> WorkspaceBrowserProfileTarget {
        guard let id = browserProfileBySpace[space.rawValue] else { return .shared }
        guard let profile = browserProfiles.first(where: { $0.id == id }) else { throw SpaceBrowserProfileError.missingProfile }
        return .named(profile)
    }

    @discardableResult
    func createBrowserProfile(named name: String, for space: WorkspaceProjectId) throws -> WorkspaceBrowserProfile {
        let profile = WorkspaceBrowserProfile(name: name)
        guard profile.isValid else { throw SpaceBrowserProfileError.invalidName }
        guard profile.name.caseInsensitiveCompare("Shared") != .orderedSame,
              !browserProfiles.contains(where: { $0.name.caseInsensitiveCompare(profile.name) == .orderedSame }) else {
            throw SpaceBrowserProfileError.duplicateName
        }
        guard browserProfiles.count < WorkspaceBrowserProfile.maximumCount else { throw SpaceBrowserProfileError.tooManyProfiles }
        browserProfiles.append(profile)
        try setBrowserProfile(profile.id, for: space)
        return profile
    }

    func setBrowserProfile(_ id: UUID?, for space: WorkspaceProjectId) throws {
        guard id == nil || browserProfiles.contains(where: { $0.id == id }) else { throw SpaceBrowserProfileError.missingProfile }
        browserProfileBySpace[space.rawValue] = id
        scheduleRefresh()
    }
}

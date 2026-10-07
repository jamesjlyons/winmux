import Foundation

/// An ephemeral return position for a temporarily floating owner. It is scoped
/// to one View and can never overwrite edits made while the owner was away.
public struct SurfaceDetachedPlacement: Sendable {
    fileprivate let surface: SurfaceID
    fileprivate let workspace: String
    fileprivate let original: SurfaceTree
    fileprivate let remainder: SurfaceTree
}

extension SurfaceTree {
    public func detachedPlacement(of surface: SurfaceID) -> SurfaceDetachedPlacement? {
        guard let workspace = workspace(of: surface) else { return nil }
        let original = isolatedOrganization(in: workspace)
        var remainder = original
        remainder.remove(surface)
        remainder.activeSurfaces = [:]
        return .init(surface: surface, workspace: workspace, original: original, remainder: remainder)
    }

    /// The adapter first registers the returning owner. Restore its old split
    /// or stack only if every remaining member, container, and weight matches.
    @discardableResult
    public mutating func restorePlacement(of surface: SurfaceID, from saved: SurfaceDetachedPlacement) -> Bool {
        guard surface == saved.surface, workspace(of: surface) == saved.workspace else { return false }
        var remainder = isolatedOrganization(in: saved.workspace)
        remainder.remove(surface)
        remainder.activeSurfaces = [:]
        guard remainder == saved.remainder else { return false }
        var candidate = self
        candidate.roots[saved.workspace] = saved.original.roots[saved.workspace]
        candidate.layouts.merge(saved.original.layouts) { _, saved in saved }
        candidate.weights.merge(saved.original.weights) { _, saved in saved }
        candidate.activeSurfaces.merge(saved.original.activeSurfaces) { current, _ in current }
        candidate.pruneMetadata()
        guard let data = try? JSONEncoder().encode(candidate),
              (try? JSONDecoder().decode(Self.self, from: data)) != nil else { return false }
        self = candidate
        return true
    }

    private func isolatedOrganization(in workspace: String) -> SurfaceTree {
        var result = self
        result.roots = result.roots.filter { $0.key == workspace }
        result.pruneMetadata()
        return result
    }
}

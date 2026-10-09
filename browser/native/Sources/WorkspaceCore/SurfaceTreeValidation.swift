import Foundation

extension SurfaceTree {
    var isValidOrganization: Bool { (try? validateOrganization()) != nil }

    /// Shared by decoding and live edits. Validation must not serialize the
    /// entire session on every move, split, or restore.
    func validateOrganization() throws {
        guard weights.count <= 20000, weights.values.allSatisfy({ $0.isFinite && (1...30000).contains($0) }),
              roots.count <= 1024, roots.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 })
        else { throw SurfaceSnapshotError.invalidTree }
        var offsets: [SurfaceID: Int] = [:]
        var groups: Set<UUID> = []
        var weightKeys: Set<String> = []
        func visit(_ nodes: [SurfaceTreeNode], depth: Int) throws {
            guard depth <= 32 else { throw SurfaceSnapshotError.invalidTree }
            for node in nodes {
                if !weights.isEmpty { weightKeys.insert(node.weightKey) }
                switch node {
                case .surface(let id):
                    guard offsets[id] == nil, offsets.count < 10000 else { throw SurfaceSnapshotError.invalidTree }
                    offsets[id] = offsets.count
                case .group(let id, let children):
                    guard groups.insert(id).inserted, groups.count <= 10000, children.count >= 2
                    else { throw SurfaceSnapshotError.invalidTree }
                    let start = offsets.count
                    try visit(children, depth: depth + 1)
                    // A subtree's leaves occupy one contiguous traversal range.
                    // Check selection without flattening every ancestor again.
                    if let selected = activeSurfaces[id] {
                        guard let offset = offsets[selected], (start..<offsets.count).contains(offset)
                        else { throw SurfaceSnapshotError.invalidTree }
                    }
                }
            }
        }
        for nodes in roots.values { try visit(nodes, depth: 0) }
        guard weights.keys.allSatisfy(weightKeys.contains), layouts.keys.allSatisfy(groups.contains),
              activeSurfaces.keys.allSatisfy(groups.contains) else { throw SurfaceSnapshotError.invalidTree }
    }
}

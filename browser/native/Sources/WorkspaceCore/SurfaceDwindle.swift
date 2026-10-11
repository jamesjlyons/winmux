import Foundation

extension SurfaceTree {
    /// Follow the focused pane's current split, keeping explicit stacks whole.
    /// Adaptive viewport planning can still arrange root panes into a grid.
    @discardableResult
    public mutating func insertAdaptive(_ id: SurfaceID, beside target: SurfaceID) -> Bool {
        insertTiledArrival(id, beside: target, axis: nil)
    }

    /// Insert beside the focused pane along its longer dimension. Only the
    /// immediate parent can absorb the arrival; searching farther up the tree
    /// would flatten the alternating splits that make a dwindle layout.
    /// The caller supplies the pane's bounds before the arrival is laid out.
    @discardableResult
    public mutating func insertDwindle(_ id: SurfaceID, beside target: SurfaceID, frame: SurfaceFrame) -> Bool {
        guard frame.isValid else { return false }
        return insertTiledArrival(id, beside: target, axis: frame.width >= frame.height ? .horizontal : .vertical)
    }

    private mutating func insertTiledArrival(_ id: SurfaceID, beside target: SurfaceID, axis: SurfaceContainerLayout?) -> Bool {
        guard id != target, let name = workspace(of: target), workspace(of: id) == name else { return false }
        var candidate = self
        candidate.remove(id)
        // An explicit stack is one pane. Its tabs and selection survive a tiled
        // arrival; the separate stack-arrival policy can still add native tabs.
        let anchor = candidate.ancestors(of: .surface(target)).first(where: {
            if case .group(let group, _) = $0 { return (candidate.layouts[group] ?? .stack) == .stack }
            return false
        })?.pane ?? .surface(target)
        var nodes = candidate.roots[name] ?? []
        func insert(into nodes: inout [SurfaceTreeNode], layout: SurfaceContainerLayout) -> Bool {
            for index in nodes.indices {
                let node = nodes[index]
                if node.pane == anchor {
                    if axis == nil || layout == axis {
                        let saved = nodes.compactMap { candidate.weights[$0.weightKey] }
                        // Preserve resized siblings' relative allocations. The
                        // new pane receives 1/(n+1) of the parent, as in Dinky.
                        candidate.weights[id.description] = saved.isEmpty ? 1 : saved.reduce(0, +) / Double(saved.count)
                        nodes.insert(.surface(id), at: index + 1)
                    } else {
                        let group = UUID(), replacement = SurfaceTreeNode.group(group, [node, .surface(id)])
                        // A missing weight means the sibling average, not 1.
                        let saved = nodes.compactMap { candidate.weights[$0.weightKey] }
                        candidate.weights[replacement.weightKey] = candidate.weights[node.weightKey]
                            ?? (saved.isEmpty ? 1 : saved.reduce(0, +) / Double(saved.count))
                        candidate.weights[node.weightKey] = 1
                        candidate.weights[id.description] = 1
                        candidate.layouts[group] = axis
                        candidate.activeSurfaces[group] = target
                        nodes[index] = replacement
                    }
                    return true
                }
                if case .group(let group, var children) = node,
                   insert(into: &children, layout: candidate.layouts[group] ?? .stack) {
                    nodes[index] = .group(group, children)
                    return true
                }
            }
            return false
        }
        guard insert(into: &nodes, layout: .horizontal) else { return false }
        candidate.roots[name] = nodes
        candidate.pruneMetadata()
        guard candidate.isValidOrganization else { return false }
        self = candidate
        return true
    }
}

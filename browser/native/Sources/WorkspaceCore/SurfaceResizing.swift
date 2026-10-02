import Foundation

public enum SurfaceResizeDimension: Sendable { case width, height, smart, smartOpposite }

extension SurfaceTree {
    /// Resize the nearest matching split using the current physical allocation.
    /// Store relative weights so resizing survives monitor changes and restarts.
    @discardableResult
    public mutating func resize(_ target: SurfaceID, dimension: SurfaceResizeDimension, amount: Double,
                                absolute: Bool = false, frame: SurfaceFrame,
                                minimumSizes: [SurfaceID: SurfaceMinimumSize] = [:]) -> Bool {
        guard amount.isFinite, let workspace = workspace(of: target), let roots = roots[workspace] else { return false }
        let plan = placements(in: workspace, frame: frame, minimumSizes: minimumSizes, selectedSurface: target)
        var candidates: [([SurfaceTreeNode], SurfaceContainerLayout)] = []
        func visit(_ nodes: [SurfaceTreeNode], layout: SurfaceContainerLayout) {
            for node in nodes where node.surfaces.contains(target) {
                if case .group(let id, let children) = node { visit(children, layout: layouts[id] ?? .stack) }
            }
            if nodes.count > 1 && layout != .stack { candidates.append((nodes, layout)) }
        }
        visit(roots, layout: .horizontal)
        let desired: SurfaceContainerLayout?
        switch dimension {
        case .width: desired = .horizontal
        case .height: desired = .vertical
        case .smart: desired = candidates.first?.1
        case .smartOpposite: desired = candidates.first.map { $0.1 == .horizontal ? .vertical : .horizontal }
        }
        guard let desired, let (siblings, _) = candidates.first(where: { $0.1 == desired }),
              let index = siblings.firstIndex(where: { $0.surfaces.contains(target) }) else { return false }
        func extent(_ node: SurfaceTreeNode) -> (Int, Int)? {
            let frames = plan.filter { node.surfaces.contains($0.surfaceID) }.map(\.frame)
            let starts = frames.map { desired == .horizontal ? $0.x : $0.y }
            let ends = frames.map { desired == .horizontal ? $0.x + $0.width : $0.y + $0.height }
            guard let start = starts.min(), let end = ends.max() else { return nil }
            return (start, end)
        }
        func minimum(_ node: SurfaceTreeNode) -> Double {
            switch node {
            case .surface(let id):
                guard let size = minimumSizes[id], size.isValid else { return 1 }
                return Double(desired == .horizontal ? size.width : size.height)
            case .group(let id, let children):
                let values = children.map(minimum)
                return layouts[id] == desired ? values.reduce(0, +) : values.max() ?? 1
            }
        }
        let extents = siblings.compactMap(extent)
        guard extents.count == siblings.count,
              zip(extents, extents.dropFirst()).allSatisfy({ $0.0.1 == $0.1.0 }) else { return false }
        // Overlapping frames mean this split is temporarily stacked because its
        // minimum sizes do not fit. Never resize that fallback as a real split.
        var lengths = extents.map { Double($0.1 - $0.0) }
        let minima = siblings.map(minimum)
        let others = siblings.indices.filter { $0 != index }
        let slack = others.reduce(0.0) { $0 + max(0, lengths[$1] - minima[$1]) }
        let requested = absolute ? amount - lengths[index] : amount
        let delta = min(slack, max(minima[index] - lengths[index], requested))
        guard abs(delta) >= 0.5 else { return false }
        for other in others {
            lengths[other] -= delta > 0 ? delta * max(0, lengths[other] - minima[other]) / slack : delta / Double(others.count)
        }
        lengths[index] += delta
        setWeights(Dictionary(uniqueKeysWithValues: zip(siblings, lengths).map { ($0.0.weightKey, $0.1) }))
        return true
    }
}

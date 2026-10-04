import Foundation

public enum SurfaceResizeDimension: Sendable { case width, height, smart, smartOpposite }

extension SurfaceTree {
    /// Resize the nearest matching split using the current physical allocation.
    /// Store relative weights so resizing survives monitor changes and restarts.
    @discardableResult
    public mutating func resize(_ target: SurfaceID, dimension: SurfaceResizeDimension, amount: Double,
                                absolute: Bool = false, frame: SurfaceFrame,
                                minimumSizes: [SurfaceID: SurfaceMinimumSize] = [:],
                                rootPresentation: SurfaceRootPresentation = .adaptiveTiles) -> Bool {
        guard amount.isFinite, let workspace = workspace(of: target), let roots = roots[workspace] else { return false }
        let plan = placements(in: workspace, frame: frame, minimumSizes: minimumSizes, selectedSurface: target, rootPresentation: rootPresentation)
        func bounds(_ node: SurfaceTreeNode, in placements: [SurfacePlacement]) -> SurfaceFrame? {
            let frames = placements.filter { node.surfaces.contains($0.surfaceID) }.map(\.frame)
            guard let x = frames.map(\.x).min(), let y = frames.map(\.y).min(),
                  let right = frames.map({ $0.x + $0.width }).max(), let bottom = frames.map({ $0.y + $0.height }).max() else { return nil }
            return .init(x: x, y: y, width: right - x, height: bottom - y)
        }
        struct Candidate {
            let siblings: [[SurfaceTreeNode]]
            let layout: SurfaceContainerLayout
            let adaptive: Bool
        }
        var candidates: [Candidate] = []
        func visit(_ nodes: [SurfaceTreeNode], layout: SurfaceContainerLayout, visitingChildren: Bool = true) {
            if visitingChildren {
                for node in nodes where node.surfaces.contains(target) {
                    if case .group(let id, let children) = node { visit(children, layout: layouts[id] ?? .stack) }
                }
            }
            guard nodes.count > 1, layout != .stack else { return }
            let frames = nodes.compactMap { bounds($0, in: plan) }
            guard frames.count == nodes.count,
                  zip(frames, frames.dropFirst()).allSatisfy({
                      layout == .horizontal ? $0.0.x + $0.0.width == $0.1.x : $0.0.y + $0.0.height == $0.1.y
                  }) else { return }
            candidates.append(.init(siblings: nodes.map { [$0] }, layout: layout, adaptive: false))
        }
        for node in roots where node.surfaces.contains(target) {
            if case .group(let id, let children) = node { visit(children, layout: layouts[id] ?? .stack) }
        }
        let rootFrames = roots.compactMap { bounds($0, in: plan) }
        let columnStarts = Array(Set(rootFrames.map(\.x))).sorted()
        let rowStarts = Array(Set(rootFrames.map(\.y))).sorted()
        let columns = columnStarts.map { x in roots.indices.filter { rootFrames.indices.contains($0) && rootFrames[$0].x == x } }
        let rows = rowStarts.map { y in roots.indices.filter { rootFrames.indices.contains($0) && rootFrames[$0].y == y } }
        if rootPresentation == .selectedRoot {
            // Only explicit splits inside the selected view can be resized.
        } else if rootFrames.count == roots.count && (rowStarts.count > 1 || columns.count < roots.count) {
            // Adaptive cells share column widths and row heights. A temporary
            // stack contributes one allocation even when it holds many leaves.
            if columns.count > 1 { candidates.append(.init(siblings: columns.map { $0.map { roots[$0] } }, layout: .horizontal, adaptive: true)) }
            if rows.count > 1 { candidates.append(.init(siblings: rows.map { $0.map { roots[$0] } }, layout: .vertical, adaptive: true)) }
        } else { visit(roots, layout: .horizontal, visitingChildren: false) }
        let desired: SurfaceContainerLayout?
        switch dimension {
        case .width: desired = .horizontal
        case .height: desired = .vertical
        case .smart: desired = candidates.first?.layout
        case .smartOpposite: desired = candidates.first.map { $0.layout == .horizontal ? .vertical : .horizontal }
        }
        guard let desired, let candidate = candidates.first(where: { $0.layout == desired }),
              let index = candidate.siblings.firstIndex(where: { $0.contains { $0.surfaces.contains(target) } }) else { return false }
        func extent(_ nodes: [SurfaceTreeNode]) -> (Int, Int)? {
            let frames = nodes.compactMap { bounds($0, in: plan) }
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
        let extents = candidate.siblings.compactMap(extent)
        guard extents.count == candidate.siblings.count,
              zip(extents, extents.dropFirst()).allSatisfy({ $0.0.1 == $0.1.0 }) else { return false }
        var lengths = extents.map { Double($0.1 - $0.0) }
        let minima = candidate.siblings.map { $0.map(minimum).max() ?? 1 }
        let others = candidate.siblings.indices.filter { $0 != index }
        let slack = others.reduce(0.0) { $0 + max(0, lengths[$1] - minima[$1]) }
        let requested = absolute ? amount - lengths[index] : amount
        let delta = min(slack, max(minima[index] - lengths[index], requested))
        guard abs(delta) >= 0.5 else { return false }
        for other in others {
            lengths[other] -= delta > 0 ? delta * max(0, lengths[other] - minima[other]) / slack : delta / Double(others.count)
        }
        lengths[index] += delta
        guard candidate.adaptive else {
            setWeights(Dictionary(uniqueKeysWithValues: zip(candidate.siblings, lengths).map { ($0.0[0].weightKey, $0.1) }))
            return true
        }
        let columnWidths = desired == .horizontal ? lengths : columns.map { Double(rootFrames[$0[0]].width) }
        let rowHeights = desired == .vertical ? lengths : rows.map { Double(rootFrames[$0[0]].height) }
        struct Cell {
            let row: Int, column: Int, members: [Int]
            var weight: Double
        }
        var cells: [Cell] = []
        for row in rows.indices {
            for column in columns.indices {
                let members = rows[row].filter { columns[column].contains($0) }
                if !members.isEmpty {
                    cells.append(.init(row: row, column: column, members: members,
                                       weight: columnWidths[column] * rowHeights[row]))
                }
            }
        }
        // A full grid uses cell areas to preserve both axes. For a partial last
        // row, fit the two sets of averages together and verify before saving.
        let columnCells = columns.indices.map { column in cells.indices.filter { cells[$0].column == column } }
        let rowCells = rows.indices.map { row in cells.indices.filter { cells[$0].row == row } }
        let columnTotals = columns.indices.map { columnWidths[$0] * Double(columnCells[$0].count) }
        var rowTotals = rows.indices.map { rowHeights[$0] * Double(rowCells[$0].count) }
        let rowScale = columnTotals.reduce(0, +) / rowTotals.reduce(0, +)
        rowTotals = rowTotals.map { $0 * rowScale }
        for _ in 0..<128 {
            for row in rows.indices {
                let total = rowCells[row].reduce(0.0) { $0 + cells[$1].weight }
                for cell in rowCells[row] { cells[cell].weight *= rowTotals[row] / total }
            }
            for column in columns.indices {
                let total = columnCells[column].reduce(0.0) { $0 + cells[$1].weight }
                for cell in columnCells[column] { cells[cell].weight *= columnTotals[column] / total }
            }
            if rows.indices.allSatisfy({ row in
                abs(rowCells[row].reduce(0.0) { $0 + cells[$1].weight } - rowTotals[row]) < 0.000001
            }) { break }
        }
        guard let largest = cells.map(\.weight).max(), largest.isFinite, largest > 0 else { return false }
        let scale = Double(max(frame.width, frame.height)) / largest
        var values: [String: Double] = [:]
        for cell in cells {
            let value = cell.weight * scale
            guard value.isFinite, (1...30000).contains(value) else { return false }
            for member in cell.members { values[roots[member].weightKey] = value }
        }
        var resized = self
        resized.setWeights(values)
        let updated = resized.placements(in: workspace, frame: frame, minimumSizes: minimumSizes, selectedSurface: target, rootPresentation: rootPresentation)
        for node in roots.indices {
            guard let actual = bounds(roots[node], in: updated),
                  let column = columns.firstIndex(where: { $0.contains(node) }),
                  let row = rows.firstIndex(where: { $0.contains(node) }),
                  abs(Double(actual.width) - columnWidths[column]) <= 1,
                  abs(Double(actual.height) - rowHeights[row]) <= 1 else { return false }
        }
        self = resized
        return true
    }
}

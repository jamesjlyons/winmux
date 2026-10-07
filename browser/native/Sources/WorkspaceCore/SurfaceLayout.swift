import Foundation

public enum SurfaceContainerLayout: String, Codable, Sendable { case stack, horizontal, vertical }
public enum SurfaceRootPresentation: Sendable { case adaptiveTiles, selectedRoot }

public struct SurfaceMinimumSize: Equatable, Codable, Sendable {
    public let width: Int, height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var isValid: Bool { (1...30000).contains(width) && (1...30000).contains(height) }
}

public struct SurfaceFrame: Equatable, Codable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        (-100000...100000).contains(x) && (-100000...100000).contains(y) &&
        (1...30000).contains(width) && (1...30000).contains(height)
    }
}

public struct SurfacePlacement: Equatable, Sendable {
    public let surfaceID: SurfaceID
    public let containerID: UUID
    public let frame: SurfaceFrame
    public let visible: Bool
    /// Ordered leaves in the nearest effective stack at this viewport size.
    /// Includes temporary fit fallbacks without changing the saved tree.
    public let navigationStack: [SurfaceID]
}

/// Space owned by an explicit stack, outside the selected pane's content.
/// Temporary viewport overflow and single panes never acquire this chrome.
public struct SurfaceStackChrome: Equatable, Sendable {
    public let headerHeight: Int, sideInset: Int, bottomInset: Int
    public init(headerHeight: Int = 0, sideInset: Int = 0, bottomInset: Int = 0) {
        self.headerHeight = min(1000, max(0, headerHeight))
        self.sideInset = min(1000, max(0, sideInset))
        self.bottomInset = min(1000, max(0, bottomInset))
    }
}

public struct SurfaceLayoutGaps: Equatable, Sendable {
    public let horizontal: Int, vertical: Int
    public init(horizontal: Int = 0, vertical: Int = 0) {
        self.horizontal = min(1000, max(0, horizontal))
        self.vertical = min(1000, max(0, vertical))
    }
}

public struct SurfaceStackPlacement: Equatable, Sendable {
    public let groupID: UUID
    public let frame: SurfaceFrame
    public let headerFrame: SurfaceFrame
    public let panes: [SurfacePane]
    public let selected: SurfacePane
    public let visible: Bool
}

public struct SurfaceLayoutPlan: Equatable, Sendable {
    public var surfaces: [SurfacePlacement] = []
    public var stacks: [SurfaceStackPlacement] = []
    /// Complete allocations, including any chrome owned by each pane. Resizing
    /// uses these bounds rather than inferring a group from its inset leaves.
    public var frames: [SurfacePane: SurfaceFrame] = [:]
    public init() {}
}

public struct BrowserHostPlacement: Equatable, Codable, Sendable {
    public let containerID: UUID
    public let surfaces: [SurfaceID]
    public let selected: SurfaceID?
    public let x: Int, y: Int, width: Int, height: Int
    public let visible: Bool
    public let nativeControls: Bool
    enum CodingKeys: String, CodingKey { case containerID = "container_id", surfaces, selected, x, y, width, height, visible, nativeControls = "native_controls" }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(containerID: try values.decode(UUID.self, forKey: .containerID),
                  surfaces: try values.decode([SurfaceID].self, forKey: .surfaces),
                  selected: try values.decodeIfPresent(SurfaceID.self, forKey: .selected),
                  frame: .init(x: try values.decode(Int.self, forKey: .x), y: try values.decode(Int.self, forKey: .y),
                               width: try values.decode(Int.self, forKey: .width), height: try values.decode(Int.self, forKey: .height)),
                  visible: try values.decode(Bool.self, forKey: .visible),
                  nativeControls: try values.decodeIfPresent(Bool.self, forKey: .nativeControls) ?? false)
    }
    public init(containerID: UUID, surfaces: [SurfaceID], selected: SurfaceID?, frame: SurfaceFrame, visible: Bool, nativeControls: Bool = false) {
        self.nativeControls = nativeControls
        self.containerID = containerID; self.surfaces = surfaces; self.selected = selected
        x = frame.x; y = frame.y; width = frame.width; height = frame.height; self.visible = visible
    }
}

extension SurfaceTree {
    public func placements(in workspace: String, frame: SurfaceFrame, visible: Bool = true,
                           minimumSizes: [SurfaceID: SurfaceMinimumSize] = [:], selectedSurface: SurfaceID? = nil,
                           recentSelections: [SurfaceID] = [], rootPresentation: SurfaceRootPresentation = .adaptiveTiles,
                           stackChrome: SurfaceStackChrome = .init(), gaps: SurfaceLayoutGaps = .init()) -> [SurfacePlacement] {
        layout(in: workspace, frame: frame, visible: visible, minimumSizes: minimumSizes, selectedSurface: selectedSurface,
               recentSelections: recentSelections, rootPresentation: rootPresentation, stackChrome: stackChrome, gaps: gaps).surfaces
    }

    public func layout(in workspace: String, frame: SurfaceFrame, visible: Bool = true,
                       minimumSizes: [SurfaceID: SurfaceMinimumSize] = [:], selectedSurface: SurfaceID? = nil,
                       recentSelections: [SurfaceID] = [], rootPresentation: SurfaceRootPresentation = .adaptiveTiles,
                       stackChrome: SurfaceStackChrome = .init(), gaps: SurfaceLayoutGaps = .init(),
                       expandedPane: SurfacePane? = nil) -> SurfaceLayoutPlan {
        guard frame.isValid else { return .init() }
        if let expandedPane, self.workspace(of: expandedPane) == workspace, let node = node(for: expandedPane) {
            // Expansion is a presentation, never an organization edit. Preserve
            // hidden owner placements so adapters can explicitly park siblings.
            var plan = layout(in: workspace, frame: frame, visible: false, minimumSizes: minimumSizes,
                              selectedSurface: selectedSurface, recentSelections: recentSelections,
                              rootPresentation: rootPresentation, gaps: gaps)
            var expanded = self
            expanded.roots[workspace] = [node]
            let shown = expanded.layout(in: workspace, frame: frame, visible: visible, minimumSizes: minimumSizes,
                                        selectedSurface: selectedSurface, recentSelections: recentSelections, gaps: gaps)
            let replacements = Dictionary(uniqueKeysWithValues: shown.surfaces.map { ($0.surfaceID, $0) })
            plan.surfaces = plan.surfaces.map { replacements[$0.surfaceID] ?? $0 }
            plan.frames.merge(shown.frames) { _, new in new }
            return plan
        }
        var result = SurfaceLayoutPlan()
        func finish(_ surfaces: [SurfacePlacement]) -> SurfaceLayoutPlan {
            result.surfaces = surfaces
            return result
        }
        func minimum(_ node: SurfaceTreeNode) -> SurfaceMinimumSize {
            switch node {
            case .surface(let id):
                return minimumSizes[id].flatMap { $0.isValid ? $0 : nil } ?? .init(width: 1, height: 1)
            case .group(let id, let children):
                let sizes = children.map(minimum)
                let style = layouts[id] ?? .stack
                let chrome = style == .stack && children.count > 1 && stackChrome.headerHeight > 0
                return .init(width: (style == .horizontal ? sizes.reduce(0) { $0 + $1.width } : sizes.map(\.width).max() ?? 1)
                                + (style == .horizontal ? gaps.horizontal * max(0, children.count - 1) : 0)
                                + (chrome ? 2 * stackChrome.sideInset : 0),
                             height: (style == .vertical ? sizes.reduce(0) { $0 + $1.height } : sizes.map(\.height).max() ?? 1)
                                + (style == .vertical ? gaps.vertical * max(0, children.count - 1) : 0)
                                + (chrome ? stackChrome.headerHeight + stackChrome.bottomInset : 0))
            }
        }
        // Weighted allocation with small panes pinned at their owner minimum. Keep
        // every integer point and distribute the remaining space deterministically.
        func lengths(_ minima: [Int], weights: [Double], total: Int) -> [Int] {
            var result = Array(repeating: 0, count: minima.count)
            var pending = Array(minima.indices), remaining = total
            while !pending.isEmpty {
                let sum = pending.reduce(0.0) { $0 + weights[$1] }
                var cumulative = 0.0, allocated = 0
                let shares = pending.map { index -> Int in
                    cumulative += weights[index]
                    // Floating-point multiplication/division can put the final
                    // ratio a fraction below one; give the last pane the exact
                    // remainder so no point disappears between layout passes.
                    let rawEdge = Double(remaining) * cumulative / sum
                    let stableEdge = abs(rawEdge - rawEdge.rounded()) < 0.0000001 ? rawEdge.rounded() : rawEdge
                    let edge = index == pending.last ? remaining : Int(stableEdge)
                    defer { allocated = edge }
                    return edge - allocated
                }
                let constrained = pending.indices.filter { shares[$0] < minima[pending[$0]] }
                if constrained.isEmpty {
                    for offset in pending.indices { result[pending[offset]] = shares[offset] }
                    break
                }
                let fixed = Set(constrained.map { pending[$0] })
                for index in fixed { result[index] = minima[index]; remaining -= minima[index] }
                pending.removeAll { fixed.contains($0) }
            }
            return result
        }
        func walk(_ nodes: [SurfaceTreeNode], frame: SurfaceFrame, visible: Bool,
                  layout: SurfaceContainerLayout, container: UUID?, inheritedStack: [SurfaceID],
                  rootSelection: SurfaceID? = nil) -> [SurfacePlacement] {
            guard !nodes.isEmpty else { return [] }
            let sizes = nodes.map(minimum)
            let fits = layout == .horizontal
                ? sizes.reduce(0, { $0 + $1.width }) + gaps.horizontal * (nodes.count - 1) <= frame.width && sizes.allSatisfy { $0.height <= frame.height }
                : sizes.reduce(0, { $0 + $1.height }) + gaps.vertical * (nodes.count - 1) <= frame.height && sizes.allSatisfy { $0.width <= frame.width }
            let effective = layout != .stack && !fits ? SurfaceContainerLayout.stack : layout
            let navigationStack = effective == .stack && nodes.count > 1 ? nodes.flatMap(\.surfaces) : inheritedStack
            let active = (rootSelection ?? selectedSurface).flatMap { id in nodes.contains { $0.surfaces.contains(id) } ? id : nil }
                ?? container.flatMap { activeSurfaces[$0] }
            let selected = nodes.firstIndex { active.map($0.surfaces.contains) ?? false } ?? 0
            var frame = frame
            if layout == .stack, let container, nodes.count > 1, stackChrome.headerHeight > 0, frame.height > 1 {
                let header = min(stackChrome.headerHeight, frame.height - 1)
                let side = min(stackChrome.sideInset, (frame.width - 1) / 2)
                let bottom = min(stackChrome.bottomInset, frame.height - header - 1)
                result.stacks.append(.init(groupID: container, frame: frame,
                    headerFrame: .init(x: frame.x, y: frame.y, width: frame.width, height: header),
                    panes: nodes.map(\.pane), selected: nodes[selected].pane, visible: visible))
                frame.x += side; frame.y += header
                frame.width -= 2 * side; frame.height -= header + bottom
            }
            // New pages/groups inherit a typical sibling weight. Stored values
            // are physical allocations from a resize, so defaulting a new leaf
            // to 1 would collapse it to its minimum beside resized siblings.
            let existingWeights = nodes.compactMap { weights[$0.weightKey] }
            let defaultWeight = existingWeights.isEmpty ? 1 : existingWeights.reduce(0, +) / Double(existingWeights.count)
            let gap = effective == .horizontal ? gaps.horizontal : gaps.vertical
            let spans = effective == .stack ? [] : lengths(sizes.map { effective == .horizontal ? $0.width : $0.height }, weights: nodes.map { weights[$0.weightKey] ?? defaultWeight }, total: (effective == .horizontal ? frame.width : frame.height) - gap * (nodes.count - 1))
            var offset = 0
            return nodes.enumerated().flatMap { index, node -> [SurfacePlacement] in
                var rect = frame
                if effective == .horizontal {
                    rect.x += offset; rect.width = spans[index]; offset += spans[index] + gap
                } else if effective == .vertical {
                    rect.y += offset; rect.height = spans[index]; offset += spans[index] + gap
                }
                let shown = visible && (effective != .stack || selected == index)
                result.frames[node.pane] = rect
                switch node {
                case .surface(let id):
                    let leaf: UUID
                    switch id { case .nativeWindow(let uuid): leaf = uuid; case .browserTab(_, let uuid): leaf = uuid }
                    return [.init(surfaceID: id, containerID: layout == .stack ? (container ?? leaf) : leaf,
                                  frame: rect, visible: shown, navigationStack: navigationStack)]
                case .group(let id, let children):
                    return walk(children, frame: rect, visible: shown, layout: layouts[id] ?? .stack,
                                container: id, inheritedStack: navigationStack)
                }
            }
        }
        let nodes = roots[workspace] ?? []
        if rootPresentation == .selectedRoot {
            let selected = selectedSurface.flatMap { id in nodes.firstIndex { $0.surfaces.contains(id) } }
                ?? recentSelections.lazy.compactMap { id in nodes.firstIndex { $0.surfaces.contains(id) } }.first ?? 0
            // Keep hidden placements in the plan so owners receive explicit hide
            // requests. A view switch is not a synthetic stack or saved edit.
            return finish(nodes.enumerated().flatMap { index, node in
                walk([node], frame: frame, visible: visible && index == selected,
                     layout: .horizontal, container: nil, inheritedStack: [])
            })
        }
        let sizes = nodes.map(minimum)
        // Retain normal horizontal splits and their saved resize weights. Root
        // overflow is different from an explicit user split: try both axes and
        // a grid before putting every independent page/window in one stack.
        if sizes.reduce(0, { $0 + $1.width }) + gaps.horizontal * max(0, nodes.count - 1) <= frame.width && sizes.allSatisfy({ $0.height <= frame.height }) {
            return finish(walk(nodes, frame: frame, visible: visible, layout: .horizontal, container: nil, inheritedStack: []))
        }
        guard let grid = adaptiveRootGrid(nodes: nodes, sizes: sizes, frame: frame, weights: weights, gaps: gaps) else {
            return finish(walk(nodes, frame: frame, visible: visible, layout: .horizontal, container: nil, inheritedStack: []))
        }
        let widths = lengths(grid.columnMinimums, weights: grid.columnWeights, total: frame.width - gaps.horizontal * (grid.columns - 1))
        let heights = lengths(grid.rowMinimums, weights: grid.rowWeights, total: frame.height - gaps.vertical * (grid.rows - 1))
        var rowOffsets = [0], columnOffsets = [0]
        for height in heights { rowOffsets.append(rowOffsets.last! + height + gaps.vertical) }
        for width in widths { columnOffsets.append(columnOffsets.last! + width + gaps.horizontal) }
        return finish((0..<grid.cellCount).flatMap { cell -> [SurfacePlacement] in
            let column = cell % grid.columns, row = cell / grid.columns
            let start = cell * nodes.count / grid.cellCount, end = (cell + 1) * nodes.count / grid.cellCount
            let members = Array(nodes[start..<end])
            let rect = SurfaceFrame(x: frame.x + columnOffsets[column], y: frame.y + rowOffsets[row],
                                    width: widths[column], height: heights[row])
            // Overflow stays in ordered, independently navigable stacks. Passing
            // the current selection through walk keeps its owner visible while
            // preserving each saved nested split or stack inside the cell.
            let cellSelection = selectedSurface.flatMap { id in members.contains { $0.surfaces.contains(id) } ? id : nil }
                ?? (members.count > 1 ? recentSelections.first { id in members.contains { $0.surfaces.contains(id) } } : nil)
            return walk(members, frame: rect, visible: visible,
                        layout: .stack, container: nil, inheritedStack: [], rootSelection: cellSelection)
        })
    }
}

private struct AdaptiveRootGrid {
    let columns: Int, rows: Int, cellCount: Int
    let columnMinimums: [Int], rowMinimums: [Int]
    let columnWeights: [Double], rowWeights: [Double]
}

/// Pure viewport planning: adaptive cells never add groups or overwrite a saved
/// split. The common case examines only a handful of physical grid capacities.
private func adaptiveRootGrid(nodes: [SurfaceTreeNode], sizes: [SurfaceMinimumSize],
                              frame: SurfaceFrame, weights: [String: Double], gaps: SurfaceLayoutGaps) -> AdaptiveRootGrid? {
    guard !nodes.isEmpty else { return nil }
    let count = nodes.count
    let columnLimit = min(count, (frame.width + gaps.horizontal) / ((sizes.map(\.width).min() ?? 1) + gaps.horizontal))
    let rowLimit = min(count, (frame.height + gaps.vertical) / ((sizes.map(\.height).min() ?? 1) + gaps.vertical))
    guard columnLimit > 0, rowLimit > 0 else { return nil }
    let existingWeights = nodes.compactMap { weights[$0.weightKey] }
    let defaultWeight = existingWeights.isEmpty ? 1 : existingWeights.reduce(0, +) / Double(existingWeights.count)
    let nodeWeights = nodes.map { weights[$0.weightKey] ?? defaultWeight }

    func axisCounts(_ limit: Int) -> [Int] {
        if count <= 128 || limit <= 16 { return Array(1...limit) }
        // At most 16 samples per axis for unusually large inventories. Include
        // every small count (normal owner minima permit few rows/columns), then
        // evenly sample the remaining range. Runtime stays linear in inventory
        // size instead of testing every possible grid up to 10,000 surfaces.
        return Array(Set(Array(1...8) + (1...8).map { max(1, limit * $0 / 8) })).sorted()
    }
    let columns = axisCounts(columnLimit), sampledRows = axisCounts(rowLimit)
    var best: AdaptiveRootGrid?, bestShape = Double.infinity
    for columnCount in columns {
        let allRows = (count + columnCount - 1) / columnCount
        let rows = Set(sampledRows.filter { $0 <= allRows } + (allRows <= rowLimit ? [allRows] : [])).sorted()
        for rowCount in rows {
            let cellCount = min(count, columnCount * rowCount)
            if let best, cellCount < best.cellCount { continue }
            var columnMinimums = Array(repeating: 0, count: columnCount)
            var rowMinimums = Array(repeating: 0, count: rowCount)
            var columnWeights = Array(repeating: 0.0, count: columnCount)
            var rowWeights = Array(repeating: 0.0, count: rowCount)
            var columnCells = Array(repeating: 0, count: columnCount)
            var rowCells = Array(repeating: 0, count: rowCount)
            for cell in 0..<cellCount {
                let column = cell % columnCount, row = cell / columnCount
                let start = cell * count / cellCount, end = (cell + 1) * count / cellCount
                var width = 1, height = 1, weight = 0.0
                for index in start..<end {
                    width = max(width, sizes[index].width)
                    height = max(height, sizes[index].height)
                    weight += nodeWeights[index]
                }
                columnMinimums[column] = max(columnMinimums[column], width)
                rowMinimums[row] = max(rowMinimums[row], height)
                let cellWeight = weight / Double(end - start)
                columnWeights[column] += cellWeight
                rowWeights[row] += cellWeight
                columnCells[column] += 1
                rowCells[row] += 1
            }
            guard columnMinimums.reduce(0, +) + gaps.horizontal * (columnCount - 1) <= frame.width,
                  rowMinimums.reduce(0, +) + gaps.vertical * (rowCount - 1) <= frame.height else { continue }
            for index in columnWeights.indices { columnWeights[index] /= Double(columnCells[index]) }
            for index in rowWeights.indices { rowWeights[index] /= Double(rowCells[index]) }
            // Prefer compact cells, penalizing an otherwise attractive shape
            // that would leave much of its final row unused. Ties are resolved
            // by the stable ascending row/column iteration order.
            let aspect = Double(frame.width) * Double(rowCount) / (Double(frame.height) * Double(columnCount))
            let unused = Double(columnCount * rowCount - cellCount) / Double(columnCount * rowCount)
            let shape = abs(log(aspect)) + 2 * unused
            if best == nil || cellCount > best!.cellCount || shape < bestShape {
                best = .init(columns: columnCount, rows: rowCount, cellCount: cellCount,
                             columnMinimums: columnMinimums, rowMinimums: rowMinimums,
                             columnWeights: columnWeights, rowWeights: rowWeights)
                bestShape = shape
            }
        }
    }
    return best
}

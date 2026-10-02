import Foundation

public enum SurfaceContainerLayout: String, Codable, Sendable { case stack, horizontal, vertical }

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
}

public struct BrowserHostPlacement: Equatable, Codable, Sendable {
    public let containerID: UUID
    public let surfaces: [SurfaceID]
    public let selected: SurfaceID?
    public let x: Int, y: Int, width: Int, height: Int
    public let visible: Bool
    enum CodingKeys: String, CodingKey { case containerID = "container_id", surfaces, selected, x, y, width, height, visible }
    public init(containerID: UUID, surfaces: [SurfaceID], selected: SurfaceID?, frame: SurfaceFrame, visible: Bool) {
        self.containerID = containerID; self.surfaces = surfaces; self.selected = selected
        x = frame.x; y = frame.y; width = frame.width; height = frame.height; self.visible = visible
    }
}

extension SurfaceTree {
    public func placements(in workspace: String, frame: SurfaceFrame, visible: Bool = true,
                           minimumSizes: [SurfaceID: SurfaceMinimumSize] = [:], selectedSurface: SurfaceID? = nil) -> [SurfacePlacement] {
        guard frame.isValid else { return [] }
        func minimum(_ node: SurfaceTreeNode) -> SurfaceMinimumSize {
            switch node {
            case .surface(let id):
                return minimumSizes[id].flatMap { $0.isValid ? $0 : nil } ?? .init(width: 1, height: 1)
            case .group(let id, let children):
                let sizes = children.map(minimum)
                let style = layouts[id] ?? .stack
                return .init(width: style == .horizontal ? sizes.reduce(0) { $0 + $1.width } : sizes.map(\.width).max() ?? 1,
                             height: style == .vertical ? sizes.reduce(0) { $0 + $1.height } : sizes.map(\.height).max() ?? 1)
            }
        }
        // Equal allocation with small panes pinned at their owner minimum. Keep
        // every integer point and distribute the remaining space deterministically.
        func lengths(_ minima: [Int], total: Int) -> [Int] {
            var result = Array(repeating: 0, count: minima.count)
            var pending = Array(minima.indices), remaining = total
            while !pending.isEmpty {
                let shares = pending.indices.map { remaining * ($0 + 1) / pending.count - remaining * $0 / pending.count }
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
                  layout: SurfaceContainerLayout, container: UUID?) -> [SurfacePlacement] {
            guard !nodes.isEmpty else { return [] }
            let sizes = nodes.map(minimum)
            let fits = layout == .horizontal
                ? sizes.reduce(0, { $0 + $1.width }) <= frame.width && sizes.allSatisfy { $0.height <= frame.height }
                : sizes.reduce(0, { $0 + $1.height }) <= frame.height && sizes.allSatisfy { $0.width <= frame.width }
            let effective = layout != .stack && !fits ? SurfaceContainerLayout.stack : layout
            let active = selectedSurface.flatMap { id in nodes.contains { $0.surfaces.contains(id) } ? id : nil }
                ?? container.flatMap { activeSurfaces[$0] }
            let selected = nodes.firstIndex { active.map($0.surfaces.contains) ?? false } ?? 0
            let spans = effective == .stack ? [] : lengths(sizes.map { effective == .horizontal ? $0.width : $0.height }, total: effective == .horizontal ? frame.width : frame.height)
            var offset = 0
            return nodes.enumerated().flatMap { index, node -> [SurfacePlacement] in
                var rect = frame
                if effective == .horizontal {
                    rect.x += offset; rect.width = spans[index]; offset += spans[index]
                } else if effective == .vertical {
                    rect.y += offset; rect.height = spans[index]; offset += spans[index]
                }
                let shown = visible && (effective != .stack || selected == index)
                switch node {
                case .surface(let id):
                    let leaf: UUID
                    switch id { case .nativeWindow(let uuid): leaf = uuid; case .browserTab(_, let uuid): leaf = uuid }
                    return [.init(surfaceID: id, containerID: layout == .stack ? (container ?? leaf) : leaf, frame: rect, visible: shown)]
                case .group(let id, let children):
                    return walk(children, frame: rect, visible: shown, layout: layouts[id] ?? .stack, container: id)
                }
            }
        }
        return walk(roots[workspace] ?? [], frame: frame, visible: visible, layout: .horizontal, container: nil)
    }
}

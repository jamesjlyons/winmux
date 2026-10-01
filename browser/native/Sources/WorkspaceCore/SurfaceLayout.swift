import Foundation

public enum SurfaceContainerLayout: String, Codable, Sendable { case stack, horizontal, vertical }

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
    public func placements(in workspace: String, frame: SurfaceFrame, visible: Bool = true) -> [SurfacePlacement] {
        guard frame.isValid else { return [] }
        func walk(_ nodes: [SurfaceTreeNode], frame: SurfaceFrame, visible: Bool,
                  layout: SurfaceContainerLayout, container: UUID?) -> [SurfacePlacement] {
            guard !nodes.isEmpty else { return [] }
            let active = container.flatMap { activeSurfaces[$0] }
            let selected = nodes.firstIndex { active.map($0.surfaces.contains) ?? false } ?? 0
            return nodes.enumerated().flatMap { index, node -> [SurfacePlacement] in
                var rect = frame
                if layout == .horizontal {
                    let start = frame.width * index / nodes.count, end = frame.width * (index + 1) / nodes.count
                    rect.x += start; rect.width = end - start
                } else if layout == .vertical {
                    let start = frame.height * index / nodes.count, end = frame.height * (index + 1) / nodes.count
                    rect.y += start; rect.height = end - start
                }
                let shown = visible && (layout != .stack || selected == index)
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

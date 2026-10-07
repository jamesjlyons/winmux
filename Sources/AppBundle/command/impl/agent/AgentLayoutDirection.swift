import Common
import WorkspaceCore

enum AgentLayoutDirection: String, Codable {
    case horizontal
    case vertical

    var orientation: Orientation { self == .horizontal ? .h : .v }
    var sharedLayout: SurfaceContainerLayout { self == .horizontal ? .horizontal : .vertical }
}

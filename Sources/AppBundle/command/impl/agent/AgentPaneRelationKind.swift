import Common
import WorkspaceCore

enum AgentPaneRelationKind: String, Codable {
    case leftOf
    case rightOf
    case above
    case below

    var sharedDirection: SurfaceDirection {
        switch self {
        case .leftOf: .left
        case .rightOf: .right
        case .above: .up
        case .below: .down
        }
    }

    var orientation: Orientation {
        switch self {
            case .leftOf, .rightOf: .h
            case .above, .below: .v
        }
    }

    var sourceIsAfterTarget: Bool {
        switch self {
            case .rightOf, .below: true
            case .leftOf, .above: false
        }
    }
}

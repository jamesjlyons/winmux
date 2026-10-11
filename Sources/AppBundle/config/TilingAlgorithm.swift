enum TilingAlgorithm: String, CaseIterable, Hashable, Sendable {
    case adaptive
    case dwindle

    var title: String {
        switch self {
        case .adaptive: "Adaptive"
        case .dwindle: "Dwindle (Dinky-style)"
        }
    }

    var detail: String {
        switch self {
        case .adaptive: "Use the current layout, with columns, a grid, or overflow stacks as space allows."
        case .dwindle: "Tile new items beside the focused pane, splitting its longer dimension. Applies when new pages and windows tile in the current View; existing arrangements stay in place."
        }
    }
}

/// Arrival behavior is independent of how Spaces and Views are presented.
/// The native-specific cases preserve existing app-window configuration.
enum NewItemPlacement: String, CaseIterable, Hashable, Sendable {
    case newView = "new-view"
    case tile
    case stackNative = "stack-native"
    case floatNative = "float-native"

    var title: String {
        switch self {
        case .newView: "New View"
        case .tile: "Tile in current View"
        case .stackNative: "Add app windows to active stack"
        case .floatNative: "Float app windows"
        }
    }

    var detail: String {
        switch self {
        case .newView: "Open each new page or app window in a View after its source. Combine Views explicitly to split or stack them."
        case .tile: "Place new pages and app windows alongside the source in its current View."
        case .stackNative: "Add app windows to the active app stack when available; otherwise tile them. New browser pages tile in the current View."
        case .floatNative: "Leave new app windows floating. New browser pages tile in the current View."
        }
    }
}

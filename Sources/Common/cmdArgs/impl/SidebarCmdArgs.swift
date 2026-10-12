public struct SidebarCmdArgs: CmdArgs {
    public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { commonState = .init(rawArgs) }
    public var action: Lateinit<Action> = .uninitialized

    public enum Action: String, CaseIterable, Sendable {
        case show, hide, expand, collapse, toggle
        case toggleExpanded = "toggle-expanded"
    }

    public static let parser: CmdParser<Self> = .init(
        kind: .sidebar,
        allowInConfig: true,
        help: """
        USAGE: sidebar (show|hide|expand|collapse|toggle|toggle-expanded)

        Change the saved sidebar visibility on all displays.
        show: reveal the compact rail, retaining Expanded if already selected.
        hide: auto-hide the sidebar; hovering at the edge can still reveal it.
        expand: keep the full sidebar visible. collapse: keep the compact rail visible.
        toggle: switch between auto-hide and the compact rail.
        toggle-expanded: switch between Expanded and Compact.
        Use open-sidebar to temporarily open the sidebar and search.
        """,
        flags: [:],
        posArgs: [newMandatoryPosArgParser(\.action, { input in
            .init(parseEnum(input.arg, Action.self), advanceBy: 1)
        }, placeholder: Action.unionLiteral)],
    )
}

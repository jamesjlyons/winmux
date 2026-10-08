public struct ToggleViewModeCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .toggleViewMode,
        allowInConfig: true,
        help: """
        USAGE: toggle-view-mode

        Toggle the saved app-wide placement mode between Full view and Tiling.
        """,
        flags: [:],
        posArgs: [],
    )
}

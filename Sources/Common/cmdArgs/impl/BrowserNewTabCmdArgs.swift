public struct BrowserNewTabCmdArgs: CmdArgs {
    public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .browserNewTab, allowInConfig: true,
        help: "USAGE: browser-new-tab\n\nOpen a browser page in the current group, including when all pages are closed.",
        flags: [:], posArgs: [])
}

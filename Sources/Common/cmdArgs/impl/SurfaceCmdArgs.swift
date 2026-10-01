public struct SurfaceCmdArgs: CmdArgs {
    public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { commonState = .init(rawArgs) }
    public var operands: [String] = []
    public var focusFollowsSurface = false
    public static let parser: CmdParser<Self> = .init(
        kind: .surface, allowInConfig: true,
        help: """
        USAGE: surface list
           OR: surface (focus|close) (<surface-id>|selected)
           OR: surface move (<surface-id>|selected) <workspace> [--focus-follows-surface]

        List returns JSON references, availability and selection; no page contents.
        IDs are native:<uuid> or browser:<profile-uuid>:<tab-uuid>.
        Focus/close success means issued to the owner, not completed.
        """,
        flags: ["--focus-follows-surface": trueBoolFlag(\.focusFollowsSurface)],
        posArgs: [ArgParser(\.operands, { input in
            let args = input.nonFlagArgs()
            return .succ(Array(args), advanceBy: args.count)
        }, argPlaceholderIfMandatory: "<action>")])
}

func parseSurfaceCmdArgs(_ args: StrArrSlice) -> ParsedCmd<SurfaceCmdArgs> {
    parseSpecificCmdArgs(SurfaceCmdArgs(rawArgs: args), args)
        .filter("Expected surface list, surface (focus|close) <id|selected>, or surface move <id|selected> <workspace>") {
            switch $0.operands.first {
            case "list": $0.operands.count == 1
            case "focus", "close": $0.operands.count == 2
            case "move": $0.operands.count == 3 && !$0.operands[2].isEmpty
            default: false
            }
        }
        .filter("--focus-follows-surface requires surface move") { !$0.focusFollowsSurface || $0.operands.first == "move" }
        .flatMap { parsed in
            guard parsed.operands.first == "move" else { return .cmd(parsed) }
            switch WorkspaceName.parse(parsed.operands[2]) {
            case .success: return .cmd(parsed)
            case .failure(let error): return .failure(error)
            }
        }
}

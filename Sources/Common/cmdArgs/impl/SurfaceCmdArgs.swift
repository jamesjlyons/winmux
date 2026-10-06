public struct SurfaceCmdArgs: CmdArgs {
    public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { commonState = .init(rawArgs) }
    public var operands: [String] = []
    public var focusFollowsSurface = false
    public static let parser: CmdParser<Self> = .init(
        kind: .surface, allowInConfig: true,
        help: """
        USAGE: surface list
           OR: surface (focus|close|ungroup|pin|unpin) (<surface-id>|selected)
           OR: surface move (<surface-id>|selected) <workspace> [--focus-follows-surface]
           OR: surface group (<surface-id>|selected) (<surface-id>|next|prev) (stack|horizontal|vertical)
           OR: surface layout (<surface-id>|selected) (stack|horizontal|vertical)
           OR: surface reorder (<surface-id>|selected) (earlier|later)

        List returns JSON references, availability and selection; no page contents.
        IDs are native:<uuid> or browser:<profile-uuid>:<tab-uuid>.
        Focus/close success means issued to the owner, not completed.
        Pin preserves an existing explicit group; unpin keeps its live layout.
        """,
        flags: ["--focus-follows-surface": trueBoolFlag(\.focusFollowsSurface)],
        posArgs: [ArgParser(\.operands, { input in
            let args = input.nonFlagArgs()
            return .succ(Array(args), advanceBy: args.count)
        }, argPlaceholderIfMandatory: "<action>")])
}

func parseSurfaceCmdArgs(_ args: StrArrSlice) -> ParsedCmd<SurfaceCmdArgs> {
    parseSpecificCmdArgs(SurfaceCmdArgs(rawArgs: args), args)
        .filter("Invalid surface action or operands; see surface --help") {
            switch $0.operands.first {
            case "list": $0.operands.count == 1
            case "focus", "close", "ungroup", "pin", "unpin": $0.operands.count == 2
            case "move": $0.operands.count == 3 && !$0.operands[2].isEmpty
            case "group": $0.operands.count == 4 && ["stack", "horizontal", "vertical"].contains($0.operands[3])
            case "layout": $0.operands.count == 3 && ["stack", "horizontal", "vertical"].contains($0.operands[2])
            case "reorder": $0.operands.count == 3 && ["earlier", "later"].contains($0.operands[2])
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

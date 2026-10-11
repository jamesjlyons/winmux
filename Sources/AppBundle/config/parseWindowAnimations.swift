import Common
import TOMLKit

struct WindowAnimationsConfig: ConvenienceCopyable {
    var enabled = true
    var durationMs = 180
}

func parseWindowAnimations(
    _ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace, _ errors: inout [TomlParseError],
) -> WindowAnimationsConfig {
    parseTable(raw, WindowAnimationsConfig(), [
        "enabled": Parser(\.enabled, parseBool),
        "duration-ms": Parser(\.durationMs) { raw, trace in
            parseInt(raw, trace).filter(.semantic(trace, "Must be in [0, 1000] range")) { (0...1000).contains($0) }
        },
    ], backtrace, &errors)
}

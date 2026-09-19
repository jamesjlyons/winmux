import Common
import TOMLKit

struct TrackpadNavigationConfig: ConvenienceCopyable, Equatable, Sendable {
    var enabled = false
    var reverseDirection = false
}

func parseTrackpadNavigation(
    _ raw: TOMLValueConvertible,
    _ backtrace: TomlBacktrace,
    _ errors: inout [TomlParseError],
) -> TrackpadNavigationConfig {
    parseTable(raw, TrackpadNavigationConfig(), [
        "enabled": Parser(\.enabled, parseBool),
        "reverse-direction": Parser(\.reverseDirection, parseBool),
    ], backtrace, &errors)
}

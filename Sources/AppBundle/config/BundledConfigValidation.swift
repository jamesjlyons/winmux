import Foundation
import TOMLKit

/// Validate without initializing the global config or starting window management.
/// Packaging and workspace startup must both check the file with the actual parser.
@MainActor
public func validateBundledDefaultConfig(at url: URL? = nil) throws {
    guard let url = url ?? Bundle.main.url(forResource: "default-config", withExtension: "toml") else {
        throw BundledConfigValidationError.missing
    }
    let text = try String(contentsOf: url, encoding: .utf8)
    // parseConfig's syntax-error fallback reads the global default config.
    // Check syntax first to avoid recursively loading a malformed bundled file.
    do { _ = try TOMLTable(string: text) }
    catch { throw BundledConfigValidationError.invalid([String(describing: error)]) }
    let errors = parseConfig(text).errors
    if !errors.isEmpty {
        throw BundledConfigValidationError.invalid(errors.map(\.description))
    }
}

enum BundledConfigValidationError: LocalizedError {
    case missing
    case invalid([String])

    var errorDescription: String? {
        switch self {
        case .missing:
            "WinMux's bundled default configuration is missing. Replace the complete app package."
        case .invalid(let errors):
            "WinMux's bundled default configuration is incompatible with this build: " + errors.joined(separator: "; ")
        }
    }
}

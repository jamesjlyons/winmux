import AppKit
import Common

@MainActor
var appForTests: (any AbstractApp)? = nil

@MainActor
private var focusedApp: (any AbstractApp)? {
    get async throws {
        if isUnitTest {
            return appForTests
        } else {
            check(appForTests == nil)
            return try await NSWorkspace.shared.frontmostApplication.flatMapAsync { @MainActor @Sendable in
                try await MacApp.getOrRegister($0)
            }
        }
    }
}

@MainActor
func getNativeFocusedWindow() async throws -> Window? {
    let interval = signposter.beginInterval("Native focus lookup", id: signposter.makeSignpostID())
    defer { signposter.endInterval("Native focus lookup", interval) }
    return try await focusedApp?.getFocusedWindow()
}

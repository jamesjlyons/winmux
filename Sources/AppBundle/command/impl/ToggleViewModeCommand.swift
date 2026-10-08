import Common

struct ToggleViewModeCommand: Command {
    let args: ToggleViewModeCmdArgs
    let shouldResetClosedWindowsCache = false

    @MainActor
    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        do {
            try await ViewModeToggleController.shared.toggle()
            return true
        } catch {
            let message = "Could not change view mode: \(error.localizedDescription)"
            ShortcutSettingsModel.shared.errorMessage = message
            if !isUnitTest { showWorkspaceSidebarError(message) }
            return io.err(message)
        }
    }
}

/// Main-actor tasks can interleave while config reload awaits hotkey activation.
/// Chain requests so each computes its destination after the previous one applies.
@MainActor
final class ViewModeToggleController {
    static let shared = ViewModeToggleController(
        current: { config.newItemPlacement },
        save: { mode in
            try await saveSettingsConfig(section: nil, key: "new-item-placement", renderedValue: "'\(mode.rawValue)'")
        },
        notify: { mode in
            if !isUnitTest { ViewModeToastPanel.shared.show(mode: mode) }
        },
    )

    private var pending: Task<Void, Never>?
    private let current: () -> NewItemPlacement
    private let save: (NewItemPlacement) async throws -> Void
    private let notify: (NewItemPlacement) -> Void

    init(current: @escaping () -> NewItemPlacement,
         save: @escaping (NewItemPlacement) async throws -> Void,
         notify: @escaping (NewItemPlacement) -> Void) {
        self.current = current
        self.save = save
        self.notify = notify
    }

    func toggle() async throws {
        let previous = pending
        let request = Task { @MainActor in
            await previous?.value
            let next = current().toggledViewMode
            try await save(next)
            notify(next)
        }
        pending = Task { @MainActor in _ = await request.result }
        try await request.value
    }
}

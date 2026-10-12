import Common
import Foundation

struct SidebarCommand: Command {
    let args: SidebarCmdArgs
    let shouldResetClosedWindowsCache = false

    @MainActor
    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        do {
            try await SidebarVisibilityController.shared.perform(args.action.val)
            return true
        } catch {
            let message = "Could not change sidebar visibility: \(error.localizedDescription)"
            ShortcutSettingsModel.shared.errorMessage = message
            if !isUnitTest { showWorkspaceSidebarError(message) }
            return io.err(message)
        }
    }
}

func workspaceSidebarVisibility(after action: SidebarCmdArgs.Action, current: WorkspaceSidebarVisibility) -> WorkspaceSidebarVisibility {
    switch action {
    case .show: current == .autoHide ? .compact : current
    case .hide: .autoHide
    case .expand: .expanded
    case .collapse: .compact
    case .toggle: current == .autoHide ? .compact : .autoHide
    case .toggleExpanded: current == .expanded ? .compact : .expanded
    case .cycle:
        switch current {
        case .autoHide: .compact
        case .compact: .expanded
        case .expanded: .autoHide
        }
    }
}

/// Config reload suspends while re-registering shortcuts. Serialize requests so
/// rapid visibility changes read the result of the previous request, including after failure.
@MainActor
final class SidebarVisibilityController {
    static let shared = SidebarVisibilityController(
        current: { config.workspaceSidebar.visibility },
        save: { visibility in
            try await saveSettingsConfig(section: "workspace-sidebar", key: "visibility", renderedValue: "'\(visibility.rawValue)'")
        },
        apply: { visibility in
            for panel in WorkspaceSidebarPanel.visiblePanels {
                panel.commandSuppressesHoverExpansion = visibility != .expanded
                closeWorkspaceSidebarFromCommand(panel)
            }
        }
    )

    private var pending: Task<Void, Never>?
    private let current: () -> WorkspaceSidebarVisibility
    private let save: (WorkspaceSidebarVisibility) async throws -> Void
    private let apply: (WorkspaceSidebarVisibility) -> Void

    init(current: @escaping () -> WorkspaceSidebarVisibility,
         save: @escaping (WorkspaceSidebarVisibility) async throws -> Void,
         apply: @escaping (WorkspaceSidebarVisibility) -> Void) {
        self.current = current
        self.save = save
        self.apply = apply
    }

    func perform(_ action: SidebarCmdArgs.Action) async throws {
        let previous = pending
        let request = Task { @MainActor in
            await previous?.value
            let current = current()
            let next = workspaceSidebarVisibility(after: action, current: current)
            if next != current { try await save(next) }
            // Apply even an unchanged mode: a hover-open panel must still close.
            apply(next)
        }
        pending = Task { @MainActor in _ = await request.result }
        try await request.value
    }
}

import Foundation
import AppKit

@MainActor
func openWorkspaceSidebarFromCommand() {
    guard TrayMenuModel.shared.isEnabled, config.workspaceSidebar.enabled else { return }
    let focusedScopeId = TrayMenuModel.shared.workspaceSidebarFocusedMonitorScopeId
    // Visible panels already receive content updates from the chrome scheduler.
    // Opening one must not synchronously resync and refresh every display.
    if WorkspaceSidebarPanel.panel(for: focusedScopeId)?.isVisible != true {
        WorkspaceSidebarPanel.refreshAll()
    }
    let panel = WorkspaceSidebarPanel.panel(for: focusedScopeId)
        ?? WorkspaceSidebarPanel.visiblePanels.first
        ?? WorkspaceSidebarPanel.shared
    if config.workspaceSidebar.placement == .top {
        NotificationCenter.default.post(name: workspaceSidebarCommandSearchKeyNotification, object: panel)
        return
    }
    if panel.inlineTextEditingActive ||
        (panel.viewModel.isWorkspaceSidebarExpanded && !workspaceSidebarKeepsExpandedAtRest(panel.presentedSidebarConfig))
    {
        closeWorkspaceSidebarFromCommand(panel)
        return
    }
    panel.commandExpansionLocksCollapse = true
    panel.commandSuppressesHoverExpansion = false
    panel.shouldLockNextSidebarSearchExpansion = true
    panel.bufferedCommandSidebarSearchKeys = []
    armWorkspaceSidebarCommandMouseUnlock(panel)
    panel.expandSidebar(to: CGFloat(config.workspaceSidebar.width))
    panel.beginInlineTextEditing(
        locksExpansion: true,
        cancelsOnPointerExit: false,
        onCancel: {
            closeWorkspaceSidebarFromCommand(panel)
        },
        onKeyDown: { key in
            switch key {
                case .cancel:
                    closeWorkspaceSidebarFromCommand(panel)
                case .ignored:
                    break
                default:
                    panel.bufferedCommandSidebarSearchKeys.append(key)
                    NotificationCenter.default.post(
                        name: workspaceSidebarCommandSearchKeyNotification,
                        object: panel,
                        userInfo: [
                            workspaceSidebarCommandSearchPanelUserInfoKey: panel,
                            workspaceSidebarCommandSearchKeyUserInfoKey: key,
                        ]
                    )
            }
        },
    )
}

@MainActor
func closeWorkspaceSidebarFromCommand(_ panel: WorkspaceSidebarPanel) {
    panel.resetBrowseMode()
    panel.projectIconPicker?.close()
    panel.endInlineTextEditing()
    panel.pendingCollapse?.cancel()
    panel.pendingCollapse = nil
    panel.pendingCollapseFinalize?.cancel()
    panel.pendingCollapseFinalize = nil
    let staysExpanded = workspaceSidebarKeepsExpandedAtRest(panel.presentedSidebarConfig)
    if !staysExpanded {
        NotificationCenter.default.post(name: workspaceSidebarWillCollapseNotification, object: panel)
    }
    panel.commandExpansionLocksCollapse = false
    panel.shouldLockNextSidebarSearchExpansion = false
    panel.bufferedCommandSidebarSearchKeys = []
    clearWorkspaceSidebarCommandMouseUnlock(panel)
    panel.animateVisibleSidebarWidth(config.workspaceSidebar.placement == .top ? panel.frame.width : workspaceSidebarRestingWidth(panel.presentedSidebarConfig), animation: staysExpanded ? workspaceSidebarExpansionAnimation : workspaceSidebarCollapseAnimation)
    panel.viewModel.isWorkspaceSidebarExpanded = staysExpanded
    panel.updateMousePassthrough()
}

@MainActor
func armWorkspaceSidebarCommandMouseUnlock(_ panel: WorkspaceSidebarPanel) {
    panel.commandMouseUnlockPoint = mouseLocation
    panel.commandMouseUnlockAfter = ProcessInfo.processInfo.systemUptime + 0.08
}

@MainActor
func clearWorkspaceSidebarCommandMouseUnlock(_ panel: WorkspaceSidebarPanel) {
    panel.commandMouseUnlockPoint = nil
    panel.commandMouseUnlockAfter = 0
}

private let workspaceSidebarCommandMouseUnlockDistance: CGFloat = 1

extension WorkspaceSidebarPanel {
    @MainActor
    func unlockCommandSidebarExpansionIfMouseMoved(
        to point: CGPoint = mouseLocation,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime,
    ) {
        guard commandExpansionLocksCollapse,
              timestamp >= commandMouseUnlockAfter,
              let origin = commandMouseUnlockPoint
        else { return }
        guard hypot(point.x - origin.x, point.y - origin.y) > workspaceSidebarCommandMouseUnlockDistance else { return }
        commandExpansionLocksCollapse = false
        shouldLockNextSidebarSearchExpansion = false
        inlineTextEditingLocksExpansion = false
        clearWorkspaceSidebarCommandMouseUnlock(self)
    }
}

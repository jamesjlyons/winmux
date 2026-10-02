import AppKit
import Common
import WorkspaceCore

struct LayoutCommand: Command {
    let args: LayoutCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        let controller = BrowserWorkspaceController.shared
        var nativeConversionTarget: LiveFocus?
        if controller.usesSurfaceTree, args.windowId == nil, env.windowId == nil,
           args.workspaceName == nil, env.workspaceName == nil,
           let id = controller.focusCoordinator.target ?? focus.windowOrNil?.surfaceID {
            let convertsNativeTiling = args.toggleBetween.val.contains { $0 == .tiling || $0 == .floating }
            if convertsNativeTiling, case .nativeWindow = id {
                // Resolve the durable selection, including a floating window
                // that no longer belongs to shared tiled organization.
                guard let window = Window.get(bySurfaceID: id) else {
                    return io.err("Selected native surface is unavailable")
                }
                guard let target = window.toLiveFocusOrReportError(io) else { return false }
                nativeConversionTarget = target
            } else {
                let group = controller.surfaceTree.containingGroup(of: id)
                let current = group.flatMap { controller.surfaceTree.layouts[$0] } ?? .horizontal
                var choices: [SurfaceContainerLayout] = []
                for description in args.toggleBetween.val {
                    switch description {
                    case .tabGroup, .hTabGroup, .vTabGroup: choices.append(.stack)
                    case .horizontal, .h_tiles: choices.append(.horizontal)
                    case .vertical, .v_tiles: choices.append(.vertical)
                    case .tiles: choices.append(current == .vertical ? .vertical : .horizontal)
                    case .tiling, .floating: return io.err("Floating/tiling conversion is not supported for browser surfaces")
                    }
                }
                guard let next = choices.first(where: { $0 != current }) ?? choices.first else { return false }
                return controller.editOrganization(of: id) { $0.setLayout(containing: id, to: next) }
                    || io.err("Cannot change shared layout: owners must be available and the container must have at least two items")
            }
        }
        guard let target = nativeConversionTarget ?? args.resolveTargetOrReportError(env, io) else { return false }
        guard let window = target.windowOrNil else {
            return io.err(noWindowIsFocused)
        }
        let targetDescription = args.toggleBetween.val.first(where: { !window.matchesDescription($0) })
            ?? args.toggleBetween.val.first.orDie()
        if window.matchesDescription(targetDescription) { return false }
        switch targetDescription {
            case .hTabGroup:
                return changeTilingLayout(io, targetLayout: .tabGroup, targetOrientation: .h, window: window)
            case .vTabGroup:
                return changeTilingLayout(io, targetLayout: .tabGroup, targetOrientation: .v, window: window)
            case .h_tiles:
                return changeTilingLayout(io, targetLayout: .tiles, targetOrientation: .h, window: window)
            case .v_tiles:
                return changeTilingLayout(io, targetLayout: .tiles, targetOrientation: .v, window: window)
            case .tabGroup:
                return changeTilingLayout(io, targetLayout: .tabGroup, targetOrientation: nil, window: window)
            case .tiles:
                return changeTilingLayout(io, targetLayout: .tiles, targetOrientation: nil, window: window)
            case .horizontal:
                return changeTilingLayout(io, targetLayout: nil, targetOrientation: .h, window: window)
            case .vertical:
                return changeTilingLayout(io, targetLayout: nil, targetOrientation: .v, window: window)
            case .tiling:
                guard let parent = window.parent else { return false }
                switch parent.cases {
                    case .macosPopupWindowsContainer:
                        return false // Impossible
                    case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
                        return io.err("Can't change layout for macOS minimized, fullscreen windows or windows or hidden apps. This behavior is subject to change")
                    case .tilingContainer:
                        return true // Nothing to do
                    case .workspace(let workspace):
                        window.lastFloatingSize = try await window.getAxSize() ?? window.lastFloatingSize
                        try await window.relayoutWindow(on: workspace, forceTile: true)
                        controller.nativeTilingStateChanged(window)
                        return true
                }
            case .floating:
                let workspace = target.workspace
                window.bindAsFloatingWindow(to: workspace)
                if let size = window.lastFloatingSize { window.setAxFrame(nil, size) }
                controller.nativeTilingStateChanged(window)
                return true
        }
    }
}

@MainActor private func changeTilingLayout(_ io: CmdIo, targetLayout: Layout?, targetOrientation: Orientation?, window: Window) -> Bool {
    guard let parent = window.parent else { return false }
    switch parent.cases {
        case .tilingContainer(let parent):
            let targetOrientation = targetOrientation ?? parent.orientation
            let targetLayout = targetLayout ?? parent.layout
            parent.layout = targetLayout
            parent.changeOrientation(targetOrientation)
            return true
        case .workspace, .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
             .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return io.err("The window is non-tiling")
    }
}

extension Window {
    fileprivate func matchesDescription(_ layout: LayoutCmdArgs.LayoutDescription) -> Bool {
        return switch layout {
            case .tabGroup:   (parent as? TilingContainer)?.layout == .tabGroup
            case .tiles:       (parent as? TilingContainer)?.layout == .tiles
            case .horizontal:  (parent as? TilingContainer)?.orientation == .h
            case .vertical:    (parent as? TilingContainer)?.orientation == .v
            case .hTabGroup:   (parent as? TilingContainer).map { $0.layout == .tabGroup && $0.orientation == .h } == true
            case .vTabGroup:   (parent as? TilingContainer).map { $0.layout == .tabGroup && $0.orientation == .v } == true
            case .h_tiles:     (parent as? TilingContainer).map { $0.layout == .tiles && $0.orientation == .h } == true
            case .v_tiles:     (parent as? TilingContainer).map { $0.layout == .tiles && $0.orientation == .v } == true
            case .tiling:      parent is TilingContainer
            case .floating:    parent is Workspace
        }
    }
}

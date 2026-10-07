import AppKit
import WorkspaceCore

struct SharedStackChrome: Equatable {
    let id: UUID
    let workspaceName: String
    let tabs: [SharedStackTab]
}

struct SharedStackTab: Equatable, Identifiable {
    let id: SurfacePane
    let surface: SurfaceID
    let title: String
    let appName: String
    let bundleID: String?
    let bundlePath: String?
    let symbol: String?
    let isActive: Bool
    let isFocused: Bool
    var isAvailable = true
}

@MainActor
func buildSharedStackChrome(controller: BrowserWorkspaceController = .shared) async -> [WindowTabStripViewModel] {
    guard controller.usesSurfaceTree, TrayMenuModel.shared.isEnabled, config.windowTabs.enabled,
          !shouldSuppressChromeForNativeFullscreenContent else { return [] }
    var result: [WindowTabStripViewModel] = []
    let tree = controller.surfaceTree
    let generation = controller.focusCoordinator.generation
    for workspace in Workspace.all where workspace.isVisible && controller.hasSharedLayout(in: workspace) {
        let live = controller.liveLayoutTree(in: workspace)
        let layout = controller.plannedLayout(in: workspace)
        let visibleStacks = layout.stacks.filter(\.visible)
        guard !visibleStacks.isEmpty else { continue }
        let occlusions = await windowTabOccludingFloatingWindowFrames(in: workspace)
        // Floating-window reads can suspend. Never publish a strip for an old
        // layout, monitor allocation, selection, or workspace after they resume.
        guard controller.surfaceTree == tree, controller.focusCoordinator.generation == generation,
              workspace.isVisible, controller.plannedLayout(in: workspace) == layout else { return [] }
        for stack in visibleStacks {
            let tabs = stack.panes.compactMap { pane -> SharedStackTab? in
                guard let node = live.node(for: pane) else { return nil }
                let selected: SurfaceID?
                if let focused = controller.focusCoordinator.target, node.surfaces.contains(focused) { selected = focused }
                else if case .group(let id) = pane { selected = live.activeSurfaces[id] }
                else { selected = nil }
                guard let surface = selected.flatMap({ node.surfaces.contains($0) && controller.isAvailable($0) ? $0 : nil })
                    ?? node.surfaces.first(where: controller.isAvailable) ?? node.surfaces.first else { return nil }
                let window = Window.get(bySurfaceID: surface)
                let record = controller.owner(of: surface)?.inventory.tabs[surface]
                let appName = window?.app.name ?? window?.app.rawAppBundleId ?? "Browser"
                let available = controller.isAvailable(surface)
                let title = window.flatMap { getSessionWindowTitle($0) } ?? record?.title ?? (available ? appName : "Unavailable page")
                let isGroup: Bool = if case .group = pane { true } else { false }
                let focused = controller.focusCoordinator.target ?? focus.windowOrNil?.surfaceID
                return .init(id: pane, surface: surface,
                    title: isGroup ? "\(title) · \(node.surfaces.count) items" : title,
                    appName: appName, bundleID: window?.app.rawAppBundleId, bundlePath: window?.app.bundlePath,
                    symbol: isGroup ? "rectangle.split.2x1" : (surface.browserProfileID != nil ? "globe" : nil),
                    isActive: pane == stack.selected,
                    isFocused: focused.map(node.surfaces.contains) == true, isAvailable: available)
            }
            guard tabs.count == stack.panes.count, tabs.contains(where: \.isAvailable),
                  let active = tabs.first(where: \.isActive) else { continue }
            let windowID = Window.get(bySurfaceID: active.surface)?.windowId
                ?? controller.owner(of: active.surface)?.inventory.tabs[active.surface]?.hostWindowID
            // Ordering IDs are real owner-provided CGWindowIDs. A browser page
            // never becomes a synthetic native Window just to display its tab.
            let chrome = SharedStackChrome(id: stack.groupID, workspaceName: workspace.name, tabs: tabs)
            let top = mainMonitor.height
            result.append(.init(id: .shared(stack.groupID), workspaceName: workspace.name,
                frame: BrowserPageChromeGeometry.appKitRect(stack.headerFrame, screenTop: top),
                groupFrame: BrowserPageChromeGeometry.appKitRect(stack.frame, screenTop: top),
                activeWindowId: windowID, activeWindowCornerRadius: windowTabGroupAppCornerRadius(activeWindowId: windowID),
                tabs: [], occludingFloatingWindowFrames: occlusions, sharedStack: chrome))
        }
    }
    return result
}

@MainActor
@discardableResult
func reorderSharedStackTab(_ pane: SurfacePane, stack: UUID, to index: Int, expectedOrder: [SurfacePane]? = nil,
                           controller: BrowserWorkspaceController = .shared) -> Bool {
    guard let name = controller.surfaceTree.workspace(ofGroup: stack),
          case .group(_, let children) = controller.surfaceTree.group(stack),
          expectedOrder.map({ $0 == children.map(\.pane) }) ?? true,
          controller.surfaceTree.node(for: pane)?.surfaces.allSatisfy(controller.canMoveSurface) == true else { return false }
    return controller.editOrganization(in: [name]) { $0.reorder(pane, inStack: stack, toIndex: index) }
}

@MainActor
@discardableResult
func separateSharedStackTab(_ pane: SurfacePane, controller: BrowserWorkspaceController = .shared) -> Bool {
    guard let name = controller.surfaceTree.workspace(of: pane),
          controller.surfaceTree.node(for: pane)?.surfaces.allSatisfy(controller.canMoveSurface) == true else { return false }
    return controller.editOrganization(in: [name]) { $0.separate(pane) }
}

extension SurfacePane {
    var sidebarDragSubject: WorkspaceSidebarSurfaceDragSubject {
        switch self { case .surface(let id): .surface(id); case .group(let id): .group(id) }
    }
}

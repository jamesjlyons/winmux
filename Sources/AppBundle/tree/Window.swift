import AppKit
import Common
import WorkspaceCore

open class Window: TreeNode, Hashable {
    private(set) var surfaceID: SurfaceID = .nativeWindow(UUID())
    @MainActor private static var surfaceWindows: [SurfaceID: WeakSurfaceWindow] = [:]
    private(set) var windowId: UInt32
    private(set) var nativeTabGroup: NativeTabGroupSnapshot?
    var nativeTabCount: Int { max(nativeTabGroup?.count ?? 1, 1) }

    /// Native tab selection changes the physical AX/CG window, not the owner
    /// object, surface, tree position, or pin binding.
    @MainActor func adoptNativeTabGroup(_ group: NativeTabGroupSnapshot) {
        guard nativeTabGroup != group else { return }
        let changedWindow = windowId != group.selectedWindowID
        if changedWindow {
            invalidateCachedWindowTitle(self)
            windowId = group.selectedWindowID
            invalidateCachedWindowTitle(self)
            invalidateLastKnownNativeState(includingSharedLayoutSize: true)
            lastAppliedLayoutPhysicalRect = nil
        }
        nativeTabGroup = group
        recordChange([.metadata, .persistence])
    }

    @MainActor func clearNativeTabGroup() {
        guard nativeTabGroup != nil else { return }
        nativeTabGroup = nil
        recordChange([.metadata, .persistence])
    }
    let app: any AbstractApp
    var lastFloatingSize: CGSize? {
        didSet { if oldValue != lastFloatingSize { recordChange([.geometry, .persistence]) } }
    }
    var isFullscreen: Bool = false {
        didSet { if oldValue != isFullscreen { recordChange([.structure, .geometry, .persistence]) } }
    }
    var noOuterGapsInFullscreen: Bool = false {
        didSet { if oldValue != noOuterGapsInFullscreen { recordChange([.structure, .geometry, .persistence]) } }
    }
    var layoutReason: LayoutReason = .standard {
        didSet { if oldValue != layoutReason { recordChange([.structure, .geometry, .persistence]) } }
    }
    /// A size verified after a completed shared-layout AX write. Parking only changes
    /// position, so returning to this size need not wait for another minimum-size probe.
    @MainActor var lastConfirmedSharedLayoutSize: CGSize?
    @MainActor var restoredFloatingFrameMonitorRect: Rect?
    /// Event-invalidated caches of the native window state (frame, fullscreen, minimized),
    /// read on hot paths instead of polling every window over AX. Entering/exiting native
    /// fullscreen always resizes the window (invalidated via moved/resized events); minimize
    /// state changes emit miniaturized/deminiaturized events. nil means "no observation since
    /// the last event" and readers must fetch live.
    ///
    /// Writes go through the record methods below: an async AX observation races the very
    /// events that invalidate these caches, and a stale value written back after the
    /// transition's events were consumed would look valid forever (nothing would invalidate
    /// it again). Observed values are therefore discarded unless the generation captured
    /// before the fetch is still current.
    @MainActor private(set) var lastKnownActualRect: Rect? = nil
    @MainActor private(set) var lastKnownNativeFullscreen: Bool? = nil
    @MainActor private(set) var lastKnownNativeMinimized: Bool? = nil
    @MainActor private var lastKnownNativeStateGeneration: UInt64 = 0

    @MainActor
    func invalidateLastKnownNativeState(includingSharedLayoutSize: Bool = false, layoutChanged: Bool = true) {
        if layoutChanged {
            recordChange(.geometry)
            if isFloating { recordChange(.persistence) }
        }
        lastKnownNativeStateGeneration += 1
        lastKnownActualRect = nil
        lastKnownNativeFullscreen = nil
        lastKnownNativeMinimized = nil
        if includingSharedLayoutSize { lastConfirmedSharedLayoutSize = nil }
    }

    /// Capture before starting an async AX observation and pass to the matching record method.
    @MainActor
    func nativeStateObservationToken() -> UInt64 { lastKnownNativeStateGeneration }

    @MainActor
    func recordObservedActualRect(_ rect: Rect?, token: UInt64) {
        if lastKnownNativeStateGeneration == token {
            if lastKnownActualRect != rect {
                recordChange(.presentation)
                if isFloating { recordChange(.persistence) }
            }
            lastKnownActualRect = rect
            if let rect, rect.size != lastConfirmedSharedLayoutSize { lastConfirmedSharedLayoutSize = nil }
        }
    }

    @MainActor
    func recordObservedNativeState(fullscreen: Bool, minimized: Bool, token: UInt64) {
        if lastKnownNativeStateGeneration == token {
            if lastKnownNativeFullscreen != fullscreen || lastKnownNativeMinimized != minimized {
                recordChange([.structure, .geometry])
            }
            lastKnownNativeFullscreen = fullscreen
            lastKnownNativeMinimized = minimized
        }
    }

    @MainActor
    func recordObservedNativeFullscreen(_ fullscreen: Bool, token: UInt64) {
        if lastKnownNativeStateGeneration == token {
            if lastKnownNativeFullscreen != fullscreen { recordChange([.structure, .geometry]) }
            lastKnownNativeFullscreen = fullscreen
        }
    }

    /// For writers that know the current frame because they just set or saved it themselves
    /// (interaction-opacity parking/restore, initial registration). Supersedes any in-flight
    /// observation so a slow fetch can't clobber the deliberately written value.
    @MainActor
    func recordAuthoritativeActualRect(_ rect: Rect?) {
        if isFloating, lastKnownActualRect != rect { recordChange(.persistence) }
        lastKnownNativeStateGeneration += 1
        lastKnownActualRect = rect
        if let rect, rect.size != lastConfirmedSharedLayoutSize { lastConfirmedSharedLayoutSize = nil }
    }

    @MainActor
    init(id: UInt32, _ app: any AbstractApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.windowId = id
        self.app = app
        self.lastFloatingSize = lastFloatingSize
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
        Window.surfaceWindows[surfaceID] = WeakSurfaceWindow(self)
    }

    @MainActor static func get(bySurfaceID id: SurfaceID) -> Window? {
        guard let window = surfaceWindows[id]?.window, window.isBound,
              get(byId: window.windowId) === window else {
            surfaceWindows.removeValue(forKey: id)
            return nil
        }
        return window
    }

    /// Called only after a saved runtime binding or an unambiguous relaunch
    /// descriptor has matched. Numeric IDs alone cannot establish ownership.
    @MainActor @discardableResult
    func restoreSurfaceID(_ id: SurfaceID) -> Bool {
        guard case .nativeWindow = id else { return false }
        guard let existing = Window.get(bySurfaceID: id) else {
            unregisterSurface()
            surfaceID = id
            recordChange([.structure, .persistence])
            Window.surfaceWindows[id] = WeakSurfaceWindow(self)
            return true
        }
        return existing === self
    }

    @MainActor func unregisterSurface() {
        Window.surfaceWindows.removeValue(forKey: surfaceID)
    }

    @MainActor static func resetSurfaceRegistryForTests() {
        precondition(isUnitTest)
        surfaceWindows.removeAll()
    }

    @MainActor static func get(byId windowId: UInt32) -> Window? { // todo make non optional
        isUnitTest
            ? Workspace.all.flatMap { $0.allLeafWindowsRecursive }.first(where: { $0.windowId == windowId })
            : MacWindow.resolvingNativeTab(windowId)
    }

    @MainActor
    func closeAxWindow() { die("Not implemented") }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    func getAxSize() async throws -> CGSize? { die("Not implemented") }
    var title: String { get async throws { die("Not implemented") } }
    var isMacosFullscreen: Bool { get async throws { false } }
    var isMacosMinimized: Bool { get async throws { false } } // todo replace with enum MacOsWindowNativeState { normal, fullscreen, invisible }
    var isHiddenInCorner: Bool { die("Not implemented") }
    @MainActor
    func nativeFocus() { die("Not implemented") }
    func getAxRect() async throws -> Rect? { die("Not implemented") }
    func getCenter() async throws -> CGPoint? { try await getAxRect()?.center }

    func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) { die("Not implemented") }
}

private final class WeakSurfaceWindow {
    weak var window: Window?
    init(_ window: Window) { self.window = window }
}

enum LayoutReason: Codable, Equatable, Sendable {
    case standard
    /// Reason for the cur temp layout is macOS native fullscreen, minimize, or hide
    case macos(prevParentKind: NonLeafTreeNodeKind, prevWorkspaceName: String?)
}

extension Window {
    var isFloating: Bool { parent is Workspace } // todo drop. It will be a source of bugs when sticky is introduced

    @discardableResult
    @MainActor
    func bindAsFloatingWindow(to workspace: Workspace) -> BindingData? {
        bind(to: workspace, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    @MainActor
    func rememberMacOsLayoutOrigin(detachFromWorkspace: Bool = false) {
        guard let parent else { return }
        layoutReason = .macos(
            prevParentKind: parent.kind,
            prevWorkspaceName: detachFromWorkspace ? nil : nodeWorkspace?.name,
        )
    }

    func asMacWindow() -> MacWindow { self as! MacWindow }
}

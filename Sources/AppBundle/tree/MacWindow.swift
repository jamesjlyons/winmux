import AppKit
import Common

final class MacWindow: Window {
    let macApp: MacApp
    private var unhiddenFrame: WindowParkingSnapshot?
    private var unhiddenWasFloating = false
    /// The corner the window is parked in, together with the monitor rect it was parked
    /// against: when the monitor's geometry changes (or the workspace moves to another
    /// monitor), the old corner position is wrong and the window must be re-parked even
    /// though the corner still matches. One value so the two can't desync.
    private var hiddenInCorner: (corner: OptimalHideCorner, monitorVisibleRect: Rect)?

    @MainActor
    private init(_ id: UInt32, _ actor: MacApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.macApp = actor
        super.init(id: id, actor, lastFloatingSize: lastFloatingSize, parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static var allWindowsMap: [UInt32: MacWindow] = [:]
    @MainActor static var allWindows: [MacWindow] { Array(allWindowsMap.values) }

    @MainActor
    @discardableResult
    static func getOrRegister(windowId: UInt32, macApp: MacApp) async throws -> MacWindow? {
        // Quarantine all UI from an authenticated browser process, including
        // popup/extension windows. Only bridge-owned normal hosts may be placed.
        guard !BrowserWorkspaceController.shared.excludesNativeDiscovery(processID: macApp.pid) else { return nil }
        if let existing = allWindowsMap[windowId] {
            // No AX round-trip for known windows: this runs for every window on every refresh
            // barrier, and lastKnownActualRect stays correct without polling because moved /
            // resized AX events invalidate it and consumers re-fetch on demand.
            return existing
        }
        let rect = try await macApp.getAxRect(windowId)
        let data = try await unbindAndGetBindingDataForNewWindow(
            windowId,
            macApp,
            isStartup
                ? (rect?.center.monitorApproximation ?? mainMonitor).activeWorkspace
                : focus.workspace,
            window: nil,
        )

        // atomic synchronous section
        guard !BrowserWorkspaceController.shared.excludesNativeDiscovery(processID: macApp.pid) else { return nil }
        if let existing = allWindowsMap[windowId] { return existing }
        let window = MacWindow(windowId, macApp, lastFloatingSize: rect?.size, parent: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        window.recordAuthoritativeActualRect(rect)
        allWindowsMap[windowId] = window

        try await debugWindowsIfRecording(window)
        let didRestorePersistedFrozenWorld = RestartSessionController.shared.claims(window)
        let didRestoreClosedWindowsCache = didRestorePersistedFrozenWorld ? false : try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: window)
        if !didRestorePersistedFrozenWorld && !didRestoreClosedWindowsCache {
            let source = window.nodeWorkspace
            let explicitlyRouted = try await tryOnWindowDetected(window)
            if !explicitlyRouted, let source {
                BrowserWorkspaceController.shared.placeOrdinaryNativeArrival(window, in: source)
            }
            noteNewFloatingWindow(window)
        }
        return window
    }

    /// Ownership handoff is not a close: no close cache, replacement focus or AX writes.
    @MainActor func relinquishToBrowser() {
        guard MacWindow.allWindowsMap.removeValue(forKey: windowId) === self else { return }
        unregisterSurface()
        unbindFromParent()
    }

    // var description: String {
    //     let description = [
    //         ("title", title),
    //         ("role", axWindow.get(Ax.roleAttr)),
    //         ("subrole", axWindow.get(Ax.subroleAttr)),
    //         ("identifier", axWindow.get(Ax.identifierAttr)),
    //         ("modal", axWindow.get(Ax.modalAttr).map { String($0) } ?? ""),
    //         ("windowId", String(windowId)),
    //     ].map { "\($0.0): '\(String(describing: $0.1))'" }.joined(separator: ", ")
    //     return "Window(\(description))"
    // }

    func isWindowHeuristic(_ windowLevel: MacOsWindowLevel?) async throws -> Bool { // todo cache
        try await macApp.isWindowHeuristic(windowId, windowLevel)
    }

    func isDialogHeuristic(_ windowLevel: MacOsWindowLevel?) async throws -> Bool { // todo cache
        try await macApp.isDialogHeuristic(windowId, windowLevel)
    }

    func dumpAxInfo() async throws -> [String: Json] {
        try await macApp.dumpWindowAxInfo(windowId: windowId)
    }

    func setNativeFullscreen(_ value: Bool) {
        macApp.setNativeFullscreen(windowId, value)
    }

    func setNativeMinimized(_ value: Bool) {
        macApp.setNativeMinimized(windowId, value)
    }

    // skipClosedWindowsCache is an optimization when it's definitely not necessary to cache closed window.
    //                        If you are unsure, it's better to pass `false`
    @MainActor
    func garbageCollect(skipClosedWindowsCache: Bool) {
        if MacWindow.allWindowsMap.removeValue(forKey: windowId) == nil {
            return
        }
        unregisterSurface()
        if !skipClosedWindowsCache { cacheClosedWindowIfNeeded() }
        let parent = unbindFromParent().parent
        let deadWindowWorkspace = parent.nodeWorkspace
        let currentFocus = focus
        let previousFocus = prevFocus
        let previousPreviousFocus = prevPrevFocus
        let refreshSnapshot = refreshSessionFocusSnapshot
        let refreshSnapshotCloseFallback = refreshSnapshot?.fallbackWhenFocusedWindowCloses?.liveOrNil
        let refreshSnapshotPreviousFocus = refreshSessionFocusSnapshot?.prevFocus?.liveOrNil
        let refreshSnapshotPreviousPreviousFocus = refreshSessionFocusSnapshot?.prevPrevFocus?.liveOrNil
        debugFocusLog(
            "MacWindow.garbageCollect closing=\(windowId) currentFocus=\(debugDescribe(currentFocus)) prev=\(debugDescribe(previousFocus)) prevPrev=\(debugDescribe(previousPreviousFocus)) snapshot=\(debugDescribe(refreshSnapshot))"
        )
        if let replacementFocus = focusAfterWindowClosure(
            closingWindow: self,
            deadWindowWorkspace: deadWindowWorkspace,
            currentFocus: currentFocus,
            previousFocus: previousFocus,
            previousPreviousFocus: previousPreviousFocus,
            refreshSnapshotCloseFallback: refreshSnapshotCloseFallback,
            refreshSnapshotPreviousFocus: refreshSnapshotPreviousFocus,
            refreshSnapshotPreviousPreviousFocus: refreshSnapshotPreviousPreviousFocus,
            previousFocusedWorkspace: prevFocusedWorkspace,
            previousFocusedWorkspaceDate: prevFocusedWorkspaceDate,
        ) {
            switch parent.cases {
                case .tilingContainer, .workspace, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer:
                    debugFocusLog("MacWindow.garbageCollect replacement closing=\(windowId) replacement=\(debugDescribe(replacementFocus))")
                    _ = setFocus(to: replacementFocus)
                    if replacementFocus.windowOrNil != currentFocus.windowOrNil {
                        replacementFocus.windowOrNil?.nativeFocus()
                    }
                case .macosPopupWindowsContainer, .macosMinimizedWindowsContainer:
                    break // Don't switch back on popup destruction
            }
        }
    }

    @MainActor override var title: String { get async throws { try await macApp.getAxTitle(windowId) ?? "" } }
    @MainActor override var isMacosFullscreen: Bool { get async throws { try await macApp.isMacosNativeFullscreen(windowId) == true } }
    @MainActor override var isMacosMinimized: Bool { get async throws { try await macApp.isMacosNativeMinimized(windowId) == true } }

    @MainActor
    override func nativeFocus() {
        macApp.nativeFocus(windowId)
    }

    @MainActor
    func requestCloseForProjectDeletion(timeout: TimeInterval = 1.5) async -> Bool {
        guard (try? await macApp.pressCloseButton(windowId)) == true else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await macApp.containsAxWindow(windowId)) == false {
                garbageCollect(skipClosedWindowsCache: true)
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    override func closeAxWindow() {
        garbageCollect(skipClosedWindowsCache: true)
        macApp.closeAndUnregisterAxWindow(windowId)
    }

    // todo it's part of the window layout and should be moved to layoutRecursive.swift
    @MainActor
    func hideInCorner(_ corner: OptimalHideCorner, force: Bool = false) async throws {
        guard let nodeMonitor else { return }
        if !force, isHiddenInCorner, hiddenInCorner?.corner == corner,
           hiddenInCorner?.monitorVisibleRect == nodeMonitor.visibleRect
        {
            return
        }
        // Tiled positions already belong to the layout; only floating windows
        // need a fresh native observation to preserve their user-owned frame.
        if !isHiddenInCorner {
            let windowRect: Rect?
            if isFloating {
                windowRect = try await getAxRect()
            } else if let known = lastAppliedLayoutPhysicalRect ?? lastKnownActualRect {
                windowRect = known
            } else {
                windowRect = try await getAxRect()
            }
            guard let windowRect else { return }
            // Check for isHiddenInCorner for the second time because of the suspension point above
            if !isHiddenInCorner {
                unhiddenFrame = WindowParkingSnapshot(frame: windowRect, monitorRect: nodeMonitor.rect)
                unhiddenWasFloating = isFloating
            }
        }
        let p: CGPoint
        switch corner {
            case .bottomLeftCorner:
                let size: CGSize?
                if let known = lastKnownActualRect?.size {
                    size = known
                } else {
                    size = try await getAxSize()
                }
                guard let s = size else { fallthrough }
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/WinMux/issues/527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = macApp.appId == .zoom ? .zero : CGPoint(x: 1, y: -1)
                p = nodeMonitor.visibleRect.bottomLeftCorner + onePixelOffset + CGPoint(x: -s.width, y: 0)
            case .bottomRightCorner:
                // Zoom will jump off if you do one pixel offset https://github.com/nikitabobko/WinMux/issues/527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = macApp.appId == .zoom ? .zero : CGPoint(x: 1, y: 1)
                p = nodeMonitor.visibleRect.bottomRightCorner - onePixelOffset
        }
        setAxFrame(p, nil)
        hiddenInCorner = (corner, nodeMonitor.visibleRect)
    }

    @MainActor
    func unhideFromCorner() {
        guard let unhiddenFrame else { return }
        guard let nodeWorkspace else { return } // hiding only makes sense for workspace windows
        guard let parent else { return }

        func restoreToSavedWorkspacePosition() {
            restoreFloatingFrame(unhiddenFrame, on: nodeWorkspace.workspaceMonitor.rect, restoreSize: unhiddenWasFloating)
        }

        switch getChildParentRelation(child: self, parent: parent) {
            // Just a small optimization to avoid unnecessary AX calls for non floating windows
            // Tiling windows should be unhidden with layoutRecursive anyway
            case .floatingWindow:
                restoreToSavedWorkspacePosition()
            case .macosNativeFullscreenWindow, .macosNativeHiddenAppWindow, .macosNativeMinimizedWindow,
                 .macosPopupWindow, .tiling, .rootTilingContainer, .shimContainerRelation: break
        }

        self.unhiddenFrame = nil
        self.hiddenInCorner = nil
    }

    override var isHiddenInCorner: Bool {
        unhiddenFrame != nil
    }

    /// The parked AX frame is offscreen; persist the user's floating position instead.
    @MainActor var frameForSessionRestore: CGRect? {
        if let unhiddenFrame, let monitor = nodeMonitor {
            let frame = unhiddenFrame.restoredFrame(on: monitor.rect)
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
        }
        return lastKnownActualRect.map { CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }
    }

    override func getAxSize() async throws -> CGSize? {
        try await macApp.getAxSize(windowId)
    }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        macApp.setAxFrame(windowId, topLeft, size)
    }

    func setAxFrameBlocking(_ topLeft: CGPoint?, _ size: CGSize?) async throws {
        try await macApp.setAxFrameBlocking(windowId, topLeft, size)
    }

    @MainActor
    override func getAxRect() async throws -> Rect? {
        let observationToken = nativeStateObservationToken()
        let rect = try await macApp.getAxRect(windowId)
        let windowId = self.windowId
        await MainActor.run {
            Window.get(byId: windowId)?.recordObservedActualRect(rect, token: observationToken)
        }
        return rect
    }
}

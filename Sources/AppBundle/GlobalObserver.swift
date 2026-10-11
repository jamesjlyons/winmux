import AppKit
import Common
import HotKey

enum GlobalObserver {
    @MainActor private static var isInitialized = false
    @MainActor private static var notificationObserverTokens: [NSObjectProtocol] = []
    @MainActor private static var eventMonitorTokens: [Any] = []

    private static func onNotif(_ notification: Notification) {
        // Third line of defence against lock screen window. See: closedWindowsCache
        // Second and third lines of defence are technically needed only to avoid potential flickering
        if (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == lockScreenAppBundleId {
            return
        }
        let notifName = notification.name.rawValue
        let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
        let scope = WindowRefreshScope.workspaceNotification(notifName, pid: pid)
        Task { @MainActor in
            if !TrayMenuModel.shared.isEnabled { return }
            if notifName == NSWorkspace.didActivateApplicationNotification.rawValue {
                scheduleRefreshSession(.globalObserver(notifName), optimisticallyPreLayoutWorkspaces: true)
            } else {
                scheduleRefreshSession(.globalObserver(notifName), scope: scope)
            }
        }
    }

    private static func onHideApp(_ notification: Notification) {
        let notifName = notification.name.rawValue
        Task { @MainActor in
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try await runLightSession(.globalObserver(notifName), token) {
                if config.automaticallyUnhideMacosHiddenApps {
                    if let w = prevFocus?.windowOrNil,
                       w.macAppUnsafe.nsApp.isHidden,
                       // "Hide others" (cmd-alt-h) -> don't force focus
                       // "Hide app" (cmd-h) -> force focus
                       MacApp.allAppsMap.values.count(where: { $0.nsApp.isHidden }) == 1
                    {
                        // Force focus
                        _ = w.focusWindow()
                        w.nativeFocus()
                    }
                    for app in MacApp.allAppsMap.values {
                        app.nsApp.unhide()
                    }
                }
            }
        }
    }

    // NSEvent monitor callbacks arrive on the main thread. Running their bodies synchronously
    // instead of spawning a Task avoids an allocation + run-loop hop per input event — pointer
    // events fire at 60-120Hz, so the Task-per-event pattern adds constant latency and churn.
    private static func runOnMainActor(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in body() }
        }
    }

    private static func onKeyDown(_ event: NSEvent) {
        let isEscape = event.keyCode == 53
        let switchesApp = event.modifierFlags.contains(.command) && (event.keyCode == 48 || event.keyCode == 50)
        runOnMainActor {
            noteNativeSpaceActivationIntent(switchesApp)
            if isEscape { cancelWorkspaceSidebarSurfaceDrag() }
            if isEscape, BrowserWindowDragController.shared.isDragging {
                BrowserWindowDragController.shared.cancel()
            }
            TrackpadNavigationController.shared.cancelNavigation()
            noteTapBindingKeyDown()
        }
    }

    private static func onFlagsChanged(_ event: NSEvent) {
        let keyCode = event.keyCode
        let modifierFlags = event.modifierFlags
        runOnMainActor {
            noteTapBindingFlagsChanged(keyCode: keyCode, modifierFlags: modifierFlags)
        }
    }

    private static func onPointerActivity(_ event: NSEvent) {
        let eventType = event.type
        let isLeftMouseDownEvent = eventType == .leftMouseDown
        let isMouseDownEvent = isLeftMouseDownEvent || event.type == .rightMouseDown || event.type == .otherMouseDown
        let timestamp = event.timestamp
        let screenPoint = NSEvent.mouseLocation
        let point = normalizeAppKitScreenPoint(screenPoint)
        let targetPID = event.cgEvent.map { pid_t($0.getIntegerValueField(.eventTargetUnixProcessID)) }
        runOnMainActor {
            noteTapBindingKeyDown()
            let work: @MainActor () -> Void = {
                MousePointerTracker.shared.note(point: point, timestamp: timestamp)
                noteWorkspaceSidebarSurfaceDragPointerEvent(type: eventType, at: point)
                SharedStackDragController.shared.notePointerEvent(type: eventType, at: point)
                BrowserWindowDragController.shared.notePointerEvent(type: eventType, at: point)
                WorkspaceSidebarPanel.trapCursorForVisiblePanelsIfNeeded()
                WorkspaceSidebarPanel.noteHoverPointerActivityForVisiblePanels(timestamp: timestamp)
                if isMouseDownEvent {
                    // Dock activation and clicking a different display are explicit
                    // navigation. An ordinary close/minimize click grants no such
                    // permission to subsequent AX fallback notifications.
                    let clickedDock = targetPID.flatMap(NSRunningApplication.init(processIdentifier:))?.bundleIdentifier == "com.apple.dock"
                    let otherSpace = point.monitorApproximation.activeWorkspace.projectId != focus.workspace.projectId
                    if isLeftMouseDownEvent { MouseReleaseDiscovery.shared.mouseDown(targetPID: clickedDock ? nil : targetPID) }
                    noteNativeSpaceActivationIntent(clickedDock || otherSpace)
                    TrackpadNavigationController.shared.cancelNavigation()
                    BrowserWorkspaceController.shared.cancelPendingBrowserFocusHold()
                }
                WindowTabStripPanelController.shared.updateMousePolicies(at: screenPoint)
                if isLeftMouseDownEvent {
                    Task { @MainActor in
                        await WindowMouseInteractionDriver.shared.capturePendingResizeCandidate()
                    }
                }
            }
            if eventType == .mouseMoved || eventType == .scrollWheel {
                PointerActivityCoalescer.shared.submit(work)
            } else {
                PointerActivityCoalescer.shared.flush()
                work()
            }
        }
    }

    @MainActor
    static func initObserver() {
        guard !isInitialized else { return }
        isInitialized = true

        let nc = NSWorkspace.shared.notificationCenter
        notificationObserverTokens.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: onNotif))
        notificationObserverTokens.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: onNotif))
        notificationObserverTokens.append(nc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main, using: onHideApp))
        notificationObserverTokens.append(nc.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main, using: onNotif))
        notificationObserverTokens.append(nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: onNotif))
        notificationObserverTokens.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: onNotif))
        notificationObserverTokens.append(nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: onNotif))
        notificationObserverTokens.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: onNotif))

        retainEventMonitor(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            // todo reduce number of refreshSession in the callback
            //  resetManipulatedWithMouseIfPossible might call its own refreshSession
            //  The end of the callback calls refreshSession
            Task { @MainActor in
                finishWorkspaceSidebarDragAfterGlobalMouseUp()
                guard let token: RunSessionGuard = .isServerEnabled else { return }
                let dragOwner = currentlyManipulatedWithMouseWindowId.flatMap { Window.get(byId: $0)?.app.pid }
                try await resetManipulatedWithMouseIfPossible()
                // Drag-end releases the sidebar expansion locks without any pointer movement;
                // hover must be re-evaluated for a stationary cursor.
                WorkspaceSidebarPanel.scheduleHoverRecheckForVisiblePanels()
                let mouseLocation = mouseLocation
                let clickedMonitor = mouseLocation.monitorApproximation
                switch true {
                    // Detect clicks on desktop of different monitors
                    case clickedMonitor.activeWorkspace != focus.workspace:
                        _ = try await runLightSession(.globalObserverLeftMouseUp, token) {
                            clickedMonitor.activeWorkspace.focusWorkspace()
                        }
                    // Detect close button clicks for unfocused windows. Yes, kAXUIElementDestroyedNotification is that unreliable
                    //  And trigger new window detection that could be delayed due to mouseDown event
                    default:
                        MouseReleaseDiscovery.shared.mouseUp(dragOwner: dragOwner)
                }
            }
        })

        retainEventMonitor(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { event in
            let timestamp = event.timestamp
            let point = normalizeAppKitScreenPoint(NSEvent.mouseLocation)
            runOnMainActor {
                MousePointerTracker.shared.note(point: point, timestamp: timestamp)
                WorkspaceSidebarPanel.trapCursorForVisiblePanelsIfNeeded()
                if !BrowserWindowDragController.shared.isDragging { refreshPendingWindowDragIntentFromGlobalMouseDrag() }
            }
        })

        let pointerActivityMask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel,
        ]
        retainEventMonitor(NSEvent.addGlobalMonitorForEvents(matching: pointerActivityMask, handler: onPointerActivity))
        retainEventMonitor(NSEvent.addLocalMonitorForEvents(matching: pointerActivityMask) { event in
            onPointerActivity(event)
            return event
        })

        retainEventMonitor(NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: onFlagsChanged))
        retainEventMonitor(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            onFlagsChanged(event)
            return event
        })

        retainEventMonitor(NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: onKeyDown))
        retainEventMonitor(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            onKeyDown(event)
            // Check if this key matches a recently-pressed prefix (sequence binding)
            if handleSequenceKeyDown(event: event) {
                return nil // consume the event
            }
            // If this is a sequence prefix key (e.g. Escape), arm the sequence detector
            if let prefix = Key(carbonKeyCode: UInt32(event.keyCode)),
               sequenceBindingsPrefixKeys.contains(prefix) {
                noteSequencePrefixKeyPressed(prefix)
            }
            if event.modifierFlags.contains(.control), event.keyCode == 34 {
                return nil // consume the event
            }
            return event
        })
    }

    @MainActor private static func retainEventMonitor(_ monitor: Any?) {
        guard let monitor else { return }
        eventMonitorTokens.append(monitor)
    }
}

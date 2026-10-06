#if canImport(AppBundle)
import AppBundle
import AppKit
@preconcurrency import ApplicationServices
import BridgeCore
import Security
import ServiceManagement
import WorkspaceCore

@MainActor
func containingBrowser() throws -> URL {
    let helper = Bundle.main.bundleURL.standardizedFileURL
    let browser = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard helper == browser.appendingPathComponent("Contents/Helpers/WinMux Workspace.app"),
          Bundle(url: browser)?.bundleIdentifier == SigningIdentity.browserID,
          let requirementText = SigningIdentity.requirement(identifier: SigningIdentity.browserID,
                                                           teamID: try SigningIdentity.ownTeamID()) else {
        throw WorkspaceActivationError.differentPackage
    }
    var code: SecStaticCode?, requirement: SecRequirement?
    guard SecStaticCodeCreateWithPath(browser as CFURL, [], &code) == errSecSuccess, let code,
          SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
          SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else {
        throw WorkspaceActivationError.differentPackage
    }
    return browser
}

/// A launch coordinator; it never becomes the window manager itself. Normal
/// launches stay invisible unless permissions or an error need attention.
/// The Workspace Setup menu explicitly opens the diagnostic controls.
@MainActor
final class WorkspaceSetup: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let browser: URL
    let store: WorkspaceActivationStore
    let fixture: (pid: Int32, launch: Date)?
    let serviceName: String
    var service: SMAppService { SMAppService.agent(plistName: serviceName + ".plist") }
    let status = NSTextField(wrappingLabelWithString: "")
    let startButton = NSButton(title: "Start Workspace", target: nil, action: nil)
    let stopButton = NSButton(title: "Stop Workspace", target: nil, action: nil)
    let openButton = NSButton(title: "Open Browser", target: nil, action: nil)
    let approvalButton = NSButton(title: "Open Login Items Settings", target: nil, action: nil)
    let securityUpdates = NSButton(checkboxWithTitle: "Allow security and component updates", target: nil, action: nil)
    let extensionUpdates = NSButton(checkboxWithTitle: "Allow extension update checks", target: nil, action: nil)
    let filterUpdates = NSButton(checkboxWithTitle: "Allow ad and tracker filter updates", target: nil, action: nil)
    let accessibilityStatus = NSTextField(wrappingLabelWithString: "")
    let accessibilityButton = NSButton(title: "Open Accessibility Settings", target: nil, action: nil)
    var startIntent = WorkspaceSetupStartIntent()
    var openExistingWorkspace: Bool
    var showSetup: Bool
    var window: NSWindow?
    var presentation: WorkspaceLaunchPresentation = .hidden
    let attentionDetail = NSTextField(wrappingLabelWithString: "")
    var timer: Timer?
    var busy = false
    var automaticOpen: UUID? {
        didSet { if automaticOpen == nil { automaticOpenStartedAt = nil } }
    }
    var automaticOpenStartedAt: TimeInterval?
    var pendingActivation: UUID?
    var retriedStartup = false
    var isClosing = false
    var message: String?

    init(fixturePID: Int32?, openExistingWorkspace: Bool = false) throws {
        self.openExistingWorkspace = openExistingWorkspace
        showSetup = !openExistingWorkspace
        browser = try containingBrowser()
        store = try WorkspaceActivationStore()
        if let pid = fixturePID {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                  app.bundleIdentifier == "com.jameslyons.winmux.browser.native-fixture",
                  let launch = processLaunchDate(pid) else { throw WorkspaceActivationError.invalidRequest }
            fixture = (pid, launch)
            guard let name = Bundle.main.object(forInfoDictionaryKey: "WinMuxValidationService") as? String else {
                throw WorkspaceActivationError.invalidRequest
            }
            serviceName = name
        } else { fixture = nil; serviceName = WorkspaceActivation.serviceName }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        refresh()
    }

    private func makeSetupWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 630),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        let viewsTrial = WorkspaceActivationStore.isViewsTrial
        window.title = fixture == nil ? (viewsTrial ? "WinMux Views Trial Setup" : "WinMux Workspace Setup") : "WinMux Workspace Setup — Fixture Validation"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let title = NSTextField(labelWithString: "Workspace status")
        title.font = .boldSystemFont(ofSize: 20)
        let explanation = NSTextField(wrappingLabelWithString: fixture == nil
            ? "WinMux starts when you open the app. Use these controls to inspect, stop, or restart the workspace."
            : "Validation manages only the two synthetic fixture windows, with a fresh browser profile. Your app windows stay outside this workspace.")
        let shortcuts = NSTextField(wrappingLabelWithString:
            "Option–J / K switches items. Option–Space changes the layout.\nStop Workspace restores native windows and leaves the browser open. You can then reopen standalone WinMux.")
        for button in [startButton, stopButton, openButton, approvalButton, accessibilityButton] { button.target = self; button.bezelStyle = .rounded }
        startButton.action = #selector(start); stopButton.action = #selector(stop)
        openButton.action = #selector(openBrowser); approvalButton.action = #selector(openApproval)
        if let request = try? store.readRequest() {
            let consent = BrowserServiceConsent.read(profile: request.profile(in: store.root))
            securityUpdates.state = consent.securityUpdates ? .on : .off
            extensionUpdates.state = consent.extensionUpdates ? .on : .off
            filterUpdates.state = consent.filterUpdates ? .on : .off
        }
        let privacy = NSStackView(views: [securityUpdates, extensionUpdates, filterUpdates])
        privacy.orientation = .vertical; privacy.alignment = .leading; privacy.spacing = 6
        let privacyNote = NSTextField(wrappingLabelWithString: "These services connect in the background. Browsing works with them off. Telemetry and search suggestions stay off. You can change these choices in Privacy Settings.")
        accessibilityButton.action = #selector(openAccessibility)
        let buttons = NSStackView(views: [startButton, openButton, stopButton])
        buttons.orientation = .horizontal; buttons.spacing = 10
        let stack = NSStackView(views: [title, explanation, accessibilityStatus, accessibilityButton,
                                      privacy, privacyNote, status, buttons, approvalButton, shortcuts])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
        ])
        return window
    }

    private func present(_ next: WorkspaceLaunchPresentation) {
        attentionDetail.stringValue = next == .failure ? status.stringValue : next == .accessibility
            ? "Allow WinMux Workspace in System Settings → Privacy & Security → Accessibility so WinMux can arrange app windows. Launch continues automatically after you allow it."
            : "Allow WinMux Workspace in System Settings → General → Login Items & Extensions. Launch continues automatically after you allow it."
        guard next != presentation else { return }
        presentation = next
        window?.orderOut(nil)
        guard next != .hidden else {
            NSApp.setActivationPolicy(.accessory)
            return
        }
        if next == .setup {
            window = makeSetupWindow()
        } else {
            let prompt = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 225),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            prompt.title = "WinMux"
            prompt.isReleasedWhenClosed = false
            prompt.delegate = self
            let title = NSTextField(labelWithString: next == .failure ? "WinMux couldn’t start"
                : next == .accessibility ? "Allow window management" : "Allow WinMux to run")
            title.font = .boldSystemFont(ofSize: 20)
            let action = NSButton(title: next == .failure ? "Workspace Setup…" : "Open System Settings",
                target: self, action: next == .failure ? #selector(openSetup)
                    : next == .accessibility ? #selector(openAccessibility) : #selector(openApproval))
            let cancel = NSButton(title: next == .failure ? "Quit" : "Cancel", target: self, action: #selector(cancelLaunch))
            for button in [action, cancel] { button.bezelStyle = .rounded }
            let buttons = NSStackView(views: [action, cancel])
            buttons.spacing = 10
            let stack = NSStackView(views: [title, attentionDetail, buttons])
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
            stack.translatesAutoresizingMaskIntoConstraints = false
            prompt.contentView!.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: prompt.contentView!.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: prompt.contentView!.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: prompt.contentView!.topAnchor, constant: 24),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: prompt.contentView!.bottomAnchor, constant: -24),
            ])
            window = prompt
        }
        NSApp.setActivationPolicy(.regular)
        window?.center(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSetup() { showSetup = true; refresh() }
    @objc private func cancelLaunch() { NSApp.terminate(nil) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !busy else { return false }
        if !showSetup { NSApp.terminate(nil); return false }
        return true
    }
    func windowWillClose(_ notification: Notification) { stopPolling() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !busy else { return .terminateCancel }
        stopPolling()
        if !showSetup, let pendingActivation {
            // Cancelling a permission prompt must not leave a registered agent
            // that starts managing windows after the coordinator has exited.
            busy = true
            Task { @MainActor in
                do {
                    let lock = try store.lock()
                    defer { withExtendedLifetime(lock) {} }
                    guard let request = try requestForThisPackage(), request.id == pendingActivation else {
                        throw WorkspaceActivationError.differentPackage
                    }
                    let previous = try store.readStatus()
                    if service.status != .notRegistered && service.status != .notFound { try await service.unregister() }
                    for _ in 0..<100 {
                        if previous.flatMap({ liveHelper($0) }) == nil { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard previous.flatMap({ liveHelper($0) }) == nil else { throw WorkspaceActivationError.busy }
                    try store.writeStatus(.init(requestID: request.id, phase: "stopped", helperPID: 0, helperLaunch: nil))
                    self.pendingActivation = nil
                    NSApp.reply(toApplicationShouldTerminate: true)
                } catch {
                    busy = false; isClosing = false
                    message = "Could not cancel startup: " + error.localizedDescription
                    NSApp.reply(toApplicationShouldTerminate: false)
                    refresh()
                }
            }
            return .terminateLater
        }
        return .terminateNow
    }

    private func stopPolling() {
        isClosing = true
        startIntent.cancel()
        openExistingWorkspace = false
        automaticOpen = nil
        timer?.invalidate()
        timer = nil
    }

    private func scheduleNextRefresh() {
        timer?.invalidate()
        timer = nil
        guard !busy, !isClosing else { return }
        let interval = workspaceSetupRefreshInterval(
            automaticLaunchStartedAt: automaticOpenStartedAt,
            now: ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    isolated deinit { timer?.invalidate() }

    func requestForThisPackage() throws -> WorkspaceActivation? {
        let request = try store.readRequest()
        guard request == nil || (request?.browserPath == browser.path && request?.machService == serviceName) else {
            throw WorkspaceActivationError.differentPackage
        }
        return request
    }

    func liveHelper(_ state: WorkspaceActivationStatus, browserPath: String? = nil) -> NSRunningApplication? {
        let expected = browserPath.map { URL(fileURLWithPath: $0).appendingPathComponent(
            "Contents/Helpers/WinMux Workspace.app/Contents/MacOS/WinMuxWorkspaceHelper") } ?? Bundle.main.executableURL
        guard state.helperPID > 0, let app = NSRunningApplication(processIdentifier: state.helperPID),
              !app.isTerminated, processLaunchDate(state.helperPID) == state.helperLaunch,
              app.executableURL?.standardizedFileURL == expected?.standardizedFileURL else { return nil }
        return app
    }

    func ready(_ request: WorkspaceActivation) throws -> Bool {
        guard service.status == .enabled, let state = try store.readStatus(), state.requestID == request.id,
              state.phase == "ready", liveHelper(state) != nil else { return false }
        return true
    }

    func refresh() {
        timer?.invalidate()
        timer = nil
        guard !busy, !isClosing else { return }
        defer { scheduleNextRefresh() }
        if startIntent.consumePermissionGrant(accessibilityGranted: AXIsProcessTrusted()) {
            start()
            return
        }
        do {
            let request = try store.readRequest()
            let state = try store.readStatus()
            let existingService = request.map { SMAppService.agent(plistName: $0.machService + ".plist") } ?? service
            let activeProcess = state.map { liveHelper($0, browserPath: request?.browserPath) != nil } ?? false
            let registered = existingService.status == .enabled || existingService.status == .requiresApproval || activeProcess
            let ours = request.map { $0.browserPath == browser.path && $0.machService == serviceName } ?? !registered
            if let request, state?.requestID == request.id,
               workspaceShouldRecoverLaunch(automaticLaunch: !showSetup && (openExistingWorkspace || automaticOpen != nil),
                    ownsEnabledService: ours && service.status == .enabled, helperAlive: activeProcess,
                    phase: state?.phase, alreadyRetried: retriedStartup) {
                recoverStoppedLaunch(request)
                return
            }
            if let automaticOpen, request?.id != automaticOpen ||
                (state?.requestID == automaticOpen && (state?.phase == "failed" || state?.phase == "stopped")) {
                message = state?.phase == "failed" ? "Workspace could not start: " + (state?.detail ?? "")
                    : "Workspace startup was interrupted. Open WinMux again to retry."
                self.automaticOpen = nil
            }
            let running = try ours && (request.map { try ready($0) } ?? false)
            let waitingForAccessibility = startIntent.awaitingAccessibility
            let needsAccessibility = !running && (!AXIsProcessTrusted() ||
                (state?.requestID == request?.id && state?.phase == "needs_accessibility"))
            accessibilityStatus.stringValue = needsAccessibility
                ? "Accessibility: required to arrange app windows. Enable WinMux Workspace in Privacy & Security → Accessibility."
                : "Accessibility: allowed."
            accessibilityButton.isHidden = !needsAccessibility
            startButton.title = waitingForAccessibility ? "Waiting for Accessibility…" : "Start Workspace"
            startButton.isEnabled = !registered && !waitingForAccessibility
            stopButton.title = waitingForAccessibility ? "Cancel Start" : "Stop Workspace"
            stopButton.isEnabled = waitingForAccessibility || (registered && ours)
            openButton.isEnabled = running
            approvalButton.isHidden = service.status != .requiresApproval
            if let message { status.stringValue = message }
            else if !ours && registered { status.stringValue = WorkspaceActivationError.differentPackage.localizedDescription }
            else if waitingForAccessibility { status.stringValue = "Enable Accessibility, then return here. Startup will continue automatically." }
            else if service.status == .requiresApproval { status.stringValue = "Allow WinMux Workspace in Login Items, then return here." }
            else if running { status.stringValue = "Workspace is running. Its browser and saved layout are ready." }
            else if registered, state?.requestID == request?.id, state?.phase == "stopping" {
                status.stringValue = "Finishing workspace shutdown and restoring app windows…"
            }
            else if registered, let state, state.requestID == request?.id, state.phase == "failed" {
                status.stringValue = "Workspace could not start: " + state.detail + " Stop Workspace before retrying."
            } else if registered, needsAccessibility {
                status.stringValue = "The workspace is waiting for Accessibility permission. Open Accessibility Settings to continue."
            } else { status.stringValue = registered ? "Waiting for workspace startup and macOS permissions…" : "Workspace is stopped. Existing apps and profiles are unchanged." }
            present(.resolve(showSetup: showSetup,
                failed: message != nil || (!ours && registered) || (state?.requestID == request?.id && state?.phase == "failed"),
                needsAccessibility: waitingForAccessibility || (registered && ours && needsAccessibility),
                needsBackgroundApproval: ours && service.status == .requiresApproval))
            if running, let request, automaticOpen == request.id || openExistingWorkspace {
                automaticOpen = nil
                openExistingWorkspace = false
                try launchBrowser(request, closeSetupWhenOpened: true)
            } else if openExistingWorkspace, !registered, !waitingForAccessibility, message == nil {
                // Opening the app during shutdown waits for the old helper to
                // exit before starting again. The manual setup menu stays idle.
                openExistingWorkspace = false
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isClosing else { return }
                    self.start()
                }
            }
        } catch {
            status.stringValue = error.localizedDescription; startButton.isEnabled = false; openButton.isEnabled = false
            present(showSetup ? .setup : .failure)
        }
    }

    private func recoverStoppedLaunch(_ request: WorkspaceActivation) {
        retriedStartup = true
        busy = true
        Task { @MainActor in
            do {
                let lock = try store.lock()
                defer { withExtendedLifetime(lock) {} }
                guard try requestForThisPackage() == request,
                      (try store.readStatus()).flatMap({ liveHelper($0) }) == nil else {
                    throw WorkspaceActivationError.busy
                }
                try await service.unregister()
                automaticOpen = nil
                pendingActivation = nil
                openExistingWorkspace = true
                message = nil
            } catch { message = error.localizedDescription }
            busy = false
            refresh()
        }
    }

    @objc func openApproval() { SMAppService.openSystemSettingsLoginItems() }

    private func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @objc func openAccessibility() {
        requestAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func start() {
        defer { refresh() }
        do {
            let lock = try store.lock()
            defer { withExtendedLifetime(lock) {} }
            guard service.status == .notRegistered || service.status == .notFound else { throw WorkspaceActivationError.busy }
            if let existing = try store.readRequest() {
                let other = SMAppService.agent(plistName: existing.machService + ".plist")
                guard other.status != .enabled && other.status != .requiresApproval,
                      (try store.readStatus()).flatMap({ liveHelper($0, browserPath: existing.browserPath) }) == nil else {
                    throw WorkspaceActivationError.busy
                }
            }
            try checkBrowserNativeOwnership()
            guard startIntent.request(accessibilityGranted: AXIsProcessTrusted()) else {
                requestAccessibility()
                message = nil
                return
            }
            if let fixture {
                guard let app = NSRunningApplication(processIdentifier: fixture.pid), !app.isTerminated,
                      processLaunchDate(fixture.pid) == fixture.launch else { throw WorkspaceActivationError.invalidRequest }
            }
            let request = try WorkspaceActivation(browser: browser, validationID: fixture.map { _ in UUID() },
                                                  nativeProcessID: fixture?.pid, nativeProcessLaunch: fixture?.launch,
                                                  testService: fixture == nil ? nil : serviceName)
            var consent = BrowserServiceConsent.read(profile: request.profile(in: store.root))
            if showSetup {
                consent.securityUpdates = securityUpdates.state == .on
                consent.extensionUpdates = extensionUpdates.state == .on
                consent.filterUpdates = filterUpdates.state == .on
            }
            try store.writeRequest(request, consent: consent)
            try store.writeStatus(.init(requestID: request.id, phase: "starting", helperPID: 0, helperLaunch: nil))
            try service.register()
            pendingActivation = request.id
            automaticOpen = request.id
            automaticOpenStartedAt = ProcessInfo.processInfo.systemUptime
            message = nil
        } catch { message = error.localizedDescription }
    }

    @objc func stop() {
        guard !busy else { return }
        openExistingWorkspace = false
        if startIntent.awaitingAccessibility {
            startIntent.cancel()
            message = nil
            refresh()
            return
        }
        busy = true; automaticOpen = nil
        timer?.invalidate()
        timer = nil
        startButton.isEnabled = false; stopButton.isEnabled = false; openButton.isEnabled = false
        status.stringValue = "Stopping workspace and restoring native windows…"
        Task { @MainActor in
            do {
                let lock = try store.lock()
                defer { withExtendedLifetime(lock) {} }
                guard let request = try requestForThisPackage() else { throw WorkspaceActivationError.invalidRequest }
                let previous = try store.readStatus()
                try await service.unregister()
                // unregister removes only our managed service. Its SIGTERM path
                // flushes placement and restores windows before exiting.
                for _ in 0..<100 {
                    if previous.flatMap({ liveHelper($0) }) == nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard previous.flatMap({ liveHelper($0) }) == nil else { throw WorkspaceActivationError.busy }
                try store.writeStatus(.init(requestID: request.id, phase: "stopped", helperPID: 0, helperLaunch: nil))
                pendingActivation = nil
                message = nil
            } catch { message = error.localizedDescription }
            busy = false; refresh()
        }
    }

    @objc func openBrowser() {
        defer { refresh() }
        do {
            guard let request = try requestForThisPackage(), try ready(request) else { throw WorkspaceActivationError.unavailable }
            automaticOpen = nil
            try launchBrowser(request)
        } catch { message = error.localizedDescription }
    }

    func launchBrowser(_ request: WorkspaceActivation, closeSetupWhenOpened: Bool = false) throws {
        guard try ready(request) else { throw WorkspaceActivationError.unavailable }
        try store.prepareDirectories(for: request)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--user-data-dir=" + request.profile(in: store.root).path,
                                   "--profile-directory=Default",
                                   "--no-first-run", "--no-default-browser-check", "--restore-last-session"]
        // Select Chromium's bootstrap profile explicitly so multiple Space
        // profiles never trigger its startup picker. Session restore still
        // loads each saved profile; new tabs use the active Space's profile
        // through the workspace bridge, independently of this bootstrap.
        // Launch this setup process with WINMUX_TRACE_LAYOUT=1 to trace the
        // normal Start Workspace flow. Chromium logs protocol phases only;
        // this opt-in never enables test faults or changes workspace behavior.
        if ProcessInfo.processInfo.environment["WINMUX_TRACE_LAYOUT"] == "1" {
            configuration.arguments.append("--winmux-trace-layout")
        }
        if request.validationID != nil {
            configuration.arguments += ["--winmux-sidebar-preview", "--winmux-test-service=" + request.machService,
                "--winmux-bridge-report=" + request.directory(in: store.root).appendingPathComponent("bridge.json").path]
            let page = request.directory(in: store.root).appendingPathComponent("workspace-fixture.html")
            try Data("<!doctype html><title>WinMux Workspace Validation</title><h1>Workspace validation</h1><input aria-label='Retained input'>".utf8).write(to: page, options: .atomic)
            configuration.arguments.append(page.absoluteString)
        } else { configuration.arguments.append("--winmux-managed-workspace") }
        busy = true
        startButton.isEnabled = false; stopButton.isEnabled = false; openButton.isEnabled = false
        NSWorkspace.shared.openApplication(at: browser, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                if let error { self.message = error.localizedDescription; self.refresh() }
                else {
                    self.pendingActivation = nil
                    if closeSetupWhenOpened { NSApp.terminate(nil) }
                    else { self.refresh() }
                }
            }
        }
    }
}
#endif

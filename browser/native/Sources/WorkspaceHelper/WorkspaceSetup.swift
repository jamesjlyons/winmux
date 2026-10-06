#if canImport(AppBundle)
import AppBundle
import AppKit
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

/// A distinct foreground setup instance; it never exports the workspace service
/// or becomes a window manager itself. Opening this window does not activate anything.
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
    var window: NSWindow!
    var timer: Timer?
    var busy = false
    var automaticOpen: UUID? {
        didSet { if automaticOpen == nil { automaticOpenStartedAt = nil } }
    }
    var automaticOpenStartedAt: TimeInterval?
    var isClosing = false
    var message: String?

    init(fixturePID: Int32?) throws {
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = fixture == nil ? "WinMux Workspace Setup" : "WinMux Workspace Setup — Fixture Validation"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let title = NSTextField(labelWithString: "Bring tabs and Mac windows together")
        title.font = .boldSystemFont(ofSize: 20)
        let explanation = NSTextField(wrappingLabelWithString: fixture == nil
            ? "Start a separate browser workspace with its own profile and settings. Quit standalone WinMux first. Your existing browser sessions stay open."
            : "Validation manages only the two synthetic fixture windows, with a fresh browser profile. Your app windows stay outside this workspace.")
        let shortcuts = NSTextField(wrappingLabelWithString:
            "Option–J / K switches items. Option–Space changes the layout.\nStop Workspace restores native windows and leaves the browser open. You can then reopen standalone WinMux.")
        for button in [startButton, stopButton, openButton, approvalButton] { button.target = self; button.bezelStyle = .rounded }
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
        let buttons = NSStackView(views: [startButton, openButton, stopButton])
        buttons.orientation = .horizontal; buttons.spacing = 10
        let stack = NSStackView(views: [title, explanation, shortcuts, privacy, privacyNote, status, buttons, approvalButton])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
        ])
        refresh()
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
    func windowWillClose(_ notification: Notification) { stopPolling() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !busy else { return .terminateCancel }
        stopPolling()
        return .terminateNow
    }

    private func stopPolling() {
        isClosing = true
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
        do {
            let request = try store.readRequest()
            let state = try store.readStatus()
            if let automaticOpen, request?.id != automaticOpen ||
                (state?.requestID == automaticOpen && (state?.phase == "failed" || state?.phase == "stopped")) {
                self.automaticOpen = nil
            }
            let existingService = request.map { SMAppService.agent(plistName: $0.machService + ".plist") } ?? service
            let activeProcess = state.map { liveHelper($0, browserPath: request?.browserPath) != nil } ?? false
            let registered = existingService.status == .enabled || existingService.status == .requiresApproval || activeProcess
            let ours = request == nil || (request?.browserPath == browser.path && request?.machService == serviceName)
            let running = try ours && (request.map { try ready($0) } ?? false)
            startButton.isEnabled = !registered
            stopButton.isEnabled = registered && ours
            openButton.isEnabled = running
            approvalButton.isHidden = service.status != .requiresApproval
            if let message { status.stringValue = message }
            else if !ours && registered { status.stringValue = WorkspaceActivationError.differentPackage.localizedDescription }
            else if service.status == .requiresApproval { status.stringValue = "Allow WinMux Workspace in Login Items, then return here." }
            else if running { status.stringValue = "Workspace is running. Its browser and saved layout are ready." }
            else if registered, let state, state.requestID == request?.id, state.phase == "failed" {
                status.stringValue = "Workspace could not start: " + state.detail + " Stop Workspace before retrying."
            } else { status.stringValue = registered ? "Waiting for workspace startup and macOS permissions…" : "Workspace is stopped. Existing apps and profiles are unchanged." }
            if running, let request, automaticOpen == request.id {
                automaticOpen = nil
                try launchBrowser(request)
            }
        } catch { status.stringValue = error.localizedDescription; startButton.isEnabled = false; openButton.isEnabled = false }
    }

    @objc func openApproval() { SMAppService.openSystemSettingsLoginItems() }

    @objc func start() {
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
            if let fixture {
                guard let app = NSRunningApplication(processIdentifier: fixture.pid), !app.isTerminated,
                      processLaunchDate(fixture.pid) == fixture.launch else { throw WorkspaceActivationError.invalidRequest }
            }
            let request = try WorkspaceActivation(browser: browser, validationID: fixture.map { _ in UUID() },
                                                  nativeProcessID: fixture?.pid, nativeProcessLaunch: fixture?.launch,
                                                  testService: fixture == nil ? nil : serviceName)
            var consent = BrowserServiceConsent()
            consent.securityUpdates = securityUpdates.state == .on
            consent.extensionUpdates = extensionUpdates.state == .on
            consent.filterUpdates = filterUpdates.state == .on
            try store.writeRequest(request, consent: consent)
            try store.writeStatus(.init(requestID: request.id, phase: "starting", helperPID: 0, helperLaunch: nil))
            try service.register()
            automaticOpen = request.id
            automaticOpenStartedAt = ProcessInfo.processInfo.systemUptime
            message = nil
        } catch { message = error.localizedDescription }
        refresh()
    }

    @objc func stop() {
        guard !busy else { return }
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

    func launchBrowser(_ request: WorkspaceActivation) throws {
        guard try ready(request) else { throw WorkspaceActivationError.unavailable }
        try store.prepareDirectories(for: request)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--user-data-dir=" + request.profile(in: store.root).path,
                                   "--no-first-run", "--no-default-browser-check", "--restore-last-session"]
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
        NSWorkspace.shared.openApplication(at: browser, configuration: configuration) { [weak self] _, error in
            if let error { Task { @MainActor in self?.message = error.localizedDescription; self?.refresh() } }
        }
    }
}
#endif

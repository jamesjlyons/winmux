import AppKit
import Common
import Foundation

@MainActor
final class RestartSessionController {
    static let shared = RestartSessionController()
    private(set) var pending: RestartSessionSnapshot?
    private(set) var lastSave = "Not saved this run"
    private(set) var lastRestore = "No session loaded"
    private(set) var matchedCount = 0
    private(set) var unmatchedCount = 0
    private var restoredIds: Set<UInt32> = []
    private var restoredWorkspaces: Set<String> = []
    private var cancelledWorkspaces: Set<String> = []
    private var retryDeadline: Date = .distantPast
    private var retryTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private let writer = RestartSessionWriter()
    private var saveRevision: UInt64 = 0
    private var lastSavedInputs: RestartSessionRevision?
    private var allowsSaving = true
    private var restoring = false
    private var restoredFocus = false
    private var sessionIsActive = true
    private var sessionObservers: [NSObjectProtocol] = []
    private let fileOverride: RestartSessionFile?
    private let isAppStillRunning: (RestartWindowIdentity) -> Bool
    private let now: () -> Date

    private var discoveryInterval: TimeInterval {
        pending?.bootSession == currentBootSession() ? 10 : 60
    }

    init(file: RestartSessionFile? = nil, isAppStillRunning: @escaping (RestartWindowIdentity) -> Bool = { identity in
        guard let app = NSRunningApplication(processIdentifier: identity.pid) else { return false }
        return app.bundleIdentifier == identity.bundleId && app.launchDate == identity.launchDate
    }, now: @escaping () -> Date = { .now }) {
        fileOverride = file
        self.isAppStillRunning = isAppStillRunning
        self.now = now
    }

    var file: RestartSessionFile {
        if let fileOverride { return fileOverride }
        if let state = serverArgs.browserState { return RestartSessionFile(url: state.session) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return RestartSessionFile(url: RestartSessionFile.location(appSupport: support, appName: winMuxAppName, explicitConfigPath: serverArgs.configLocation))
    }

    var canCapture: Bool {
        !isUnitTest && !serverArgs.isReadOnly && isWinMuxRuntimeReady && !AppShutdownCoordinator.shared.isShuttingDown &&
            TrayMenuModel.shared.isEnabled && canObserveSession
    }

    private var canObserveSession: Bool {
        guard sessionIsActive, AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return false }
        return app.bundleIdentifier != lockScreenAppBundleId
    }

    func observeSession() {
        guard sessionObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for (name, active) in [(NSWorkspace.sessionDidResignActiveNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, true)] {
            sessionObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.sessionIsActive = active
                    if active {
                        if let self { self.retryDeadline = self.now().addingTimeInterval(self.discoveryInterval) }
                        scheduleRefreshSession(.globalObserver("sessionUnlocked"))
                    }
                }
            })
        }
    }

    @discardableResult func load() -> Bool {
        guard !serverArgs.isReadOnly else { lastRestore = "Read-only mode"; return false }
        do {
            guard let snapshot = try file.read() else { return false }
            prepare(snapshot)
            return true
        } catch RestartSessionFileError.previousBoot {
            lastRestore = "Previous macOS session; only still-open windows can be restored"
        } catch {
            allowsSaving = false
            lastRestore = error.localizedDescription
            NSLog("WinMux session: %@", error.localizedDescription)
        }
        return false
    }

    func prepare(_ snapshot: RestartSessionSnapshot) {
        pending = snapshot
        retryDeadline = now().addingTimeInterval(discoveryInterval)
        restoredIds = []
        restoredWorkspaces = []
        cancelledWorkspaces = []
        restoredFocus = false
        restoreRestartMetadata(snapshot)
        if BrowserNativeManagement.lease != nil, let surfaces = snapshot.surfaces {
            BrowserWorkspaceController.shared.restorePlacementSnapshot(surfaces)
        }
        lastRestore = "Waiting for window discovery"
    }

    func claims(_ window: Window) -> Bool {
        guard let snapshot = pending else { return false }
        return matchingWindows(in: snapshot).contains { saved, candidate in
            candidate === window && snapshot.world.workspaces.contains {
                !cancelledWorkspaces.contains($0.name) && collectFrozenWindows($0)[saved] != nil
            }
        }
    }

    private func matchingWindows(in snapshot: RestartSessionSnapshot) -> [UInt32: Window] {
        let windows = isUnitTest ? Workspace.all.flatMap(\.allLeafWindowsRecursive) : MacWindow.allWindows.map { $0 as Window }
        var matches: [UInt32: Window] = [:]
        let boot = currentBootSession()
        let records = snapshot.windows ?? []
        // Prefer a whole native group over a former tab that has since detached.
        // Runtime member IDs are scoped by boot and process launch identity;
        // relaunch descriptors must be unique on both sides.
        for record in records where record.nativeTabWindowIDs != nil {
            let runtime = windows.filter { window in
                guard let group = window.nativeTabGroup, snapshot.bootSession == boot,
                      RestartWindowIdentity(window.app) == record.identity else { return false }
                return !group.memberWindowIDs.isDisjoint(with: record.nativeTabWindowIDs ?? [])
            }
            if runtime.count == 1, let candidate = runtime.first, !matches.values.contains(candidate),
               records.filter({ saved in
                   saved.identity == record.identity && !(candidate.nativeTabGroup?.memberWindowIDs
                       .isDisjoint(with: saved.nativeTabWindowIDs ?? []) ?? true)
               }).count == 1 {
                matches[record.id] = candidate
                continue
            }
            guard let titles = record.nativeTabTitles, titles.count > 1, titles.allSatisfy({ !$0.isEmpty }),
                  let bundle = record.identity.bundleId,
                  records.filter({ $0.identity.bundleId == bundle && $0.nativeTabTitles == titles }).count == 1 else { continue }
            let candidates = windows.filter {
                $0.app.rawAppBundleId == bundle && $0.nativeTabGroup?.titles.sorted() == titles &&
                    !matches.values.contains($0)
            }
            if candidates.count == 1 { matches[record.id] = candidates[0] }
        }
        for window in windows where !matches.values.contains(window) &&
            snapshot.matches(windowId: window.windowId, identity: RestartWindowIdentity(window.app), boot: boot) && matches[window.windowId] == nil {
            matches[window.windowId] = window
        }
        // Previously restored surface bindings survive title changes and later
        // discovery passes. A numeric window ID is never used across boots.
        for record in records where restoredIds.contains(record.id) {
            if let surface = record.surfaceID, let window = Window.get(bySurfaceID: surface) { matches[record.id] = window }
        }
        for record in records where matches[record.id] == nil && record.nativeTabTitles == nil {
            guard let bundle = record.identity.bundleId, !bundle.isEmpty,
                  let title = record.title, !title.isEmpty,
                  records.filter({ $0.identity.bundleId == bundle && $0.title == title }).count == 1 else { continue }
            let candidates = windows.filter {
                $0.app.rawAppBundleId == bundle && cachedWindowTitle(for: $0) == title &&
                    !matches.values.contains($0) &&
                    (snapshot.bootSession != boot || RestartWindowIdentity($0.app) != record.identity)
            }
            if candidates.count == 1 { matches[record.id] = candidates[0] }
        }
        return matches
    }

    func retainsWorkspace(_ name: String) -> Bool {
        pending?.world.workspaces.contains { $0.name == name && !cancelledWorkspaces.contains(name) } == true
    }

    func restoreAfterDiscovery() async throws {
        guard let snapshot = pending, !restoring else { return }
        guard isUnitTest || canObserveSession else {
            retryDeadline = now().addingTimeInterval(discoveryInterval)
            lastRestore = "Waiting for the macOS session to unlock"
            return
        }
        restoring = true
        defer { restoring = false }
        let windows = isUnitTest ? Workspace.all.flatMap(\.allLeafWindowsRecursive) : MacWindow.allWindows.map { $0 as Window }
        let descriptorBundles = Set((snapshot.windows ?? []).filter { $0.title?.isEmpty == false }.compactMap { $0.identity.bundleId })
        await withTaskGroup(of: Void.self) { group in
            for window in windows where cachedWindowTitle(for: window) == nil &&
                window.app.rawAppBundleId.map(descriptorBundles.contains) == true {
                group.addTask { @Sendable @MainActor in _ = await getCachedWindowTitle(window) }
            }
            await group.waitForAll()
        }
        let bindings = matchingWindows(in: snapshot)
        let matched = Set(bindings.keys)
        for workspace in snapshot.world.workspaces where !cancelledWorkspaces.contains(workspace.name) {
            let ids = Set(collectFrozenWindows(workspace).keys).intersection(matched)
            guard !restoredWorkspaces.contains(workspace.name) || !ids.isSubset(of: restoredIds) else { continue }
            // Publish each workspace's identities immediately before binding
            // its tree. Other workspaces must not appear to own live pins in
            // the wrong space while a floating-window AX write suspends us.
            for record in snapshot.windows ?? [] where ids.contains(record.id) {
                if let surface = record.surfaceID { bindings[record.id]?.restoreSurfaceID(surface) }
            }
            try await restoreRestartWorkspace(workspace, matchedIds: ids, records: snapshot.windows ?? [], bindings: bindings)
            restoredWorkspaces.insert(workspace.name)
        }
        if restoredWorkspaces.count > 0 && !restoredFocus {
            restoredFocus = true
            restoreRestartFocus(snapshot, matchedIds: matched, excluding: cancelledWorkspaces, bindings: bindings)
        }
        restoredIds.formUnion(matched)
        matchedCount = restoredIds.count
        unmatchedCount = snapshot.world.windowIds.subtracting(restoredIds).count
        let waitingForApp = snapshot.windows?.contains { record in
            !restoredIds.contains(record.id) && snapshot.world.workspaces.contains {
                !cancelledWorkspaces.contains($0.name) && collectFrozenWindows($0)[record.id] != nil
            } && (isAppStillRunning(record.identity) ||
                (snapshot.bootSession != currentBootSession() && record.title?.isEmpty == false))
        } ?? false
        if waitingForApp && now() < retryDeadline {
            lastRestore = "Restored \(matchedCount); waiting for \(unmatchedCount) windows"
            scheduleRetry()
        } else {
            lastRestore = "Restored \(matchedCount); skipped \(unmatchedCount) missing or changed windows"
            pending = nil
            retryTask?.cancel()
            retryTask = nil
            BrowserWorkspaceController.shared.finishNativeRestoration(excluding: Set(bindings.values.map(\.surfaceID)))
            syncClosedWindowsCacheToCurrentWorld()
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            scheduleRefreshSession(.globalObserver("sessionRestore"))
        }
    }

    func workspaceSignatures() -> [String: WorkspaceRestoreRevision] {
        guard pending != nil else { return [:] }
        return Dictionary(uniqueKeysWithValues: Workspace.all.map { workspace in
            (workspace.name, WorkspaceRestoreRevision(workspace))
        })
    }

    func cancelChangedWorkspaces(since before: [String: WorkspaceRestoreRevision]) {
        guard pending != nil else { return }
        let after = workspaceSignatures()
        for name in Set(before.keys).union(after.keys) where before[name] != after[name] { cancelledWorkspaces.insert(name) }
    }

    func cancelRestoreForInteraction(windowId: UInt32) {
        guard let snapshot = pending, let window = Window.get(byId: windowId), let name = window.nodeWorkspace?.name else { return }
        cancelledWorkspaces.insert(name)
        let savedIDs = Set(matchingWindows(in: snapshot).filter { $0.value === window }.keys)
        for workspace in snapshot.world.workspaces where !savedIDs.isDisjoint(with: collectFrozenWindows(workspace).keys) {
            cancelledWorkspaces.insert(workspace.name)
        }
    }

    func checkpoint() {
        guard canCapture, pending == nil, allowsSaving, saveTask == nil else { return }
        guard RestartSessionRevision() != lastSavedInputs else { return }
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            guard self.canCapture else { self.saveTask = nil; return }
            let attempted = RestartSessionRevision()
            if attempted != self.lastSavedInputs { await self.save()?.value }
            self.saveTask = nil
            // An edit arriving during disk I/O must not be lost behind the
            // single in-flight checkpoint. Failed unchanged saves retry on the
            // next request, rather than spinning on a broken destination.
            if RestartSessionRevision() != attempted { self.checkpoint() }
        }
    }

    func flushForQuit() -> Task<Void, Never>? {
        saveTask?.cancel()
        saveTask = nil
        guard !isUnitTest, !serverArgs.isReadOnly, isWinMuxRuntimeReady, TrayMenuModel.shared.isEnabled,
              canObserveSession else { return nil }
        return save()
    }

    private func save() -> Task<Void, Never>? {
        guard pending == nil, allowsSaving else { return nil }
        // Capture synchronously before any cleanup or refresh can change the live tree.
        let snapshot = RestartSessionSnapshot.capture()
        let inputs = RestartSessionRevision()
        let file = file
        saveRevision += 1
        let revision = saveRevision
        return Task { @MainActor [weak self, writer] in
            do {
                let result = try await writer.write(snapshot, to: file, revision: revision)
                guard let self, self.saveRevision == revision, let result else { return }
                self.lastSavedInputs = inputs
                self.lastSave = "\(result.snapshot.savedAt.formatted(.iso8601)); \(result.snapshot.world.windowIds.count) windows"
            } catch {
                guard let self, self.saveRevision == revision else { return }
                self.lastSave = "Failed: \(error.localizedDescription)"
                NSLog("WinMux session save failed: %@", error.localizedDescription)
            }
        }
    }
}

@MainActor func persistFrozenWorldForRestartIfPossible() -> Task<Void, Never>? { RestartSessionController.shared.flushForQuit() }
@MainActor @discardableResult func loadPersistedFrozenWorldForStartupIfPresent() -> Bool { RestartSessionController.shared.load() }

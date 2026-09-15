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
    private var previousSnapshot: RestartSessionSnapshot?
    private var allowsSaving = true
    private var restoring = false
    private var sessionIsActive = true
    private var sessionObservers: [NSObjectProtocol] = []
    private let fileOverride: RestartSessionFile?
    private let isAppStillRunning: (RestartWindowIdentity) -> Bool

    init(file: RestartSessionFile? = nil, isAppStillRunning: @escaping (RestartWindowIdentity) -> Bool = { identity in
        guard let app = NSRunningApplication(processIdentifier: identity.pid) else { return false }
        return app.bundleIdentifier == identity.bundleId && app.launchDate == identity.launchDate
    }) {
        fileOverride = file
        self.isAppStillRunning = isAppStillRunning
    }

    var file: RestartSessionFile {
        if let fileOverride { return fileOverride }
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
                        self?.retryDeadline = .now.addingTimeInterval(10)
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
        retryDeadline = .now.addingTimeInterval(10)
        restoredIds = []
        restoredWorkspaces = []
        cancelledWorkspaces = []
        restoreRestartMetadata(snapshot)
        lastRestore = "Waiting for window discovery"
    }

    func claims(_ window: Window) -> Bool {
        guard let snapshot = pending else { return false }
        return snapshot.matches(windowId: window.windowId, identity: RestartWindowIdentity(window.app), boot: currentBootSession()) &&
            snapshot.world.workspaces.contains { !cancelledWorkspaces.contains($0.name) && collectFrozenWindows($0)[window.windowId] != nil }
    }

    func retainsWorkspace(_ name: String) -> Bool {
        pending?.world.workspaces.contains { $0.name == name && !cancelledWorkspaces.contains(name) } == true
    }

    func restoreAfterDiscovery() async throws {
        guard let snapshot = pending, !restoring else { return }
        guard isUnitTest || canObserveSession else {
            retryDeadline = .now.addingTimeInterval(10)
            lastRestore = "Waiting for the macOS session to unlock"
            return
        }
        restoring = true
        defer { restoring = false }
        let matched = snapshot.world.windowIds.filter { id in
            Window.get(byId: id).map { snapshot.matches(windowId: id, identity: RestartWindowIdentity($0.app), boot: currentBootSession()) } ?? false
        }
        for workspace in snapshot.world.workspaces where !cancelledWorkspaces.contains(workspace.name) {
            let ids = Set(collectFrozenWindows(workspace).keys).intersection(matched)
            guard !restoredWorkspaces.contains(workspace.name) || !ids.isSubset(of: restoredIds) else { continue }
            try await restoreRestartWorkspace(workspace, matchedIds: ids, records: snapshot.windows ?? [])
            restoredWorkspaces.insert(workspace.name)
        }
        if restoredWorkspaces.count > 0 && restoredIds.isEmpty {
            restoreRestartFocus(snapshot, matchedIds: matched, excluding: cancelledWorkspaces)
        }
        restoredIds.formUnion(matched)
        matchedCount = restoredIds.count
        unmatchedCount = snapshot.world.windowIds.subtracting(restoredIds).count
        let waitingForApp = snapshot.windows?.contains { record in
            !restoredIds.contains(record.id) && isAppStillRunning(record.identity)
        } ?? false
        if waitingForApp && Date.now < retryDeadline {
            lastRestore = "Restored \(matchedCount); waiting for \(unmatchedCount) windows"
            scheduleRetry()
        } else {
            lastRestore = "Restored \(matchedCount); skipped \(unmatchedCount) missing or changed windows"
            pending = nil
            retryTask?.cancel()
            retryTask = nil
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

    func workspaceSignatures() -> [String: FrozenWorkspace] {
        guard pending != nil else { return [:] }
        return Dictionary(uniqueKeysWithValues: Workspace.all.map { workspace in
            (workspace.name, FrozenWorkspace(workspace))
        })
    }

    func cancelChangedWorkspaces(since before: [String: FrozenWorkspace]) {
        guard pending != nil else { return }
        let after = workspaceSignatures()
        for name in Set(before.keys).union(after.keys) where before[name] != after[name] { cancelledWorkspaces.insert(name) }
    }

    func cancelRestoreForInteraction(windowId: UInt32) {
        guard pending != nil, let name = Window.get(byId: windowId)?.nodeWorkspace?.name else { return }
        cancelledWorkspaces.insert(name)
    }

    func checkpoint() {
        guard canCapture, pending == nil, allowsSaving, saveTask == nil else { return }
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            guard self.canCapture else { return }
            self.save()
        }
    }

    func flushForQuit() {
        saveTask?.cancel()
        saveTask = nil
        guard !isUnitTest, !serverArgs.isReadOnly, isWinMuxRuntimeReady, TrayMenuModel.shared.isEnabled,
              canObserveSession else { return }
        save()
    }

    private func save() {
        guard pending == nil, allowsSaving else { return }
        do {
            let snapshot = RestartSessionSnapshot.capture()
            guard previousSnapshot.map({ snapshot.hasSameContent(as: $0) }) != true else { return }
            try file.write(snapshot)
            previousSnapshot = snapshot
            lastSave = "\(snapshot.savedAt.formatted(.iso8601)); \(snapshot.world.windowIds.count) windows"
        } catch {
            lastSave = "Failed: \(error.localizedDescription)"
            NSLog("WinMux session save failed: %@", error.localizedDescription)
        }
    }
}

@MainActor func persistFrozenWorldForRestartIfPossible() { RestartSessionController.shared.flushForQuit() }
@MainActor @discardableResult func loadPersistedFrozenWorldForStartupIfPresent() -> Bool { RestartSessionController.shared.load() }

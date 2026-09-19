import Foundation

private struct CachedWindowTitle {
    let owner: ObjectIdentifier
    let title: String?
    let fetchedAt: Date
}

private struct PendingWindowTitle {
    let owner: ObjectIdentifier
    let id: UUID
    let task: Task<String?, Never>
}

private struct PendingWindowTitleRefresh {
    let owner: ObjectIdentifier
    let id: UUID
    let task: Task<Void, Never>
}

private let cachedWindowTitleMaxAge: TimeInterval = 5
@MainActor private var cachedWindowTitles: [UInt32: CachedWindowTitle] = [:]
@MainActor private var pendingWindowTitles: [UInt32: PendingWindowTitle] = [:]
@MainActor private var titleCacheGeneration: UInt64 = 0
@MainActor private var backgroundTitleRefreshes: [UInt32: PendingWindowTitleRefresh] = [:]
@MainActor private var backgroundTitlePublication: Task<Void, Never>?
@MainActor private var titlePublicationNeeded = false
@MainActor private var titlePublicationOverrideForTests: (@MainActor () async -> Void)?

@MainActor
func resetCachedWindowTitles() {
    titleCacheGeneration &+= 1
    cachedWindowTitles = [:]
    for request in pendingWindowTitles.values { request.task.cancel() }
    pendingWindowTitles = [:]
    for refresh in backgroundTitleRefreshes.values { refresh.task.cancel() }
    backgroundTitleRefreshes = [:]
    backgroundTitlePublication?.cancel()
    backgroundTitlePublication = nil
    titlePublicationNeeded = false
    titlePublicationOverrideForTests = nil
}

@MainActor
func cachedWindowTitle(for window: Window) -> String? {
    guard let cached = cachedWindowTitles[window.windowId], cached.owner == ObjectIdentifier(window) else { return nil }
    return cached.title
}

@MainActor
func pruneCachedWindowTitles() {
    cachedWindowTitles = cachedWindowTitles.filter { id, entry in
        Window.get(byId: id).map { ObjectIdentifier($0) == entry.owner } == true
    }
    for (id, refresh) in backgroundTitleRefreshes where Window.get(byId: id).map({ ObjectIdentifier($0) }) != refresh.owner {
        refresh.task.cancel()
        backgroundTitleRefreshes.removeValue(forKey: id)
    }
    for (id, request) in pendingWindowTitles where Window.get(byId: id).map({ ObjectIdentifier($0) }) != request.owner {
        request.task.cancel()
        pendingWindowTitles.removeValue(forKey: id)
    }
}

@MainActor
func getCachedWindowTitle(
    _ window: Window,
    maxAge: TimeInterval = cachedWindowTitleMaxAge,
    now: Date = .now,
) async -> String? {
    let owner = ObjectIdentifier(window)
    if let cached = cachedWindowTitles[window.windowId], cached.owner == owner,
       now.timeIntervalSince(cached.fetchedAt) < maxAge { return cached.title }

    let generation = titleCacheGeneration
    let request: PendingWindowTitle
    if let existing = pendingWindowTitles[window.windowId], existing.owner == owner {
        request = existing
    } else {
        pendingWindowTitles[window.windowId]?.task.cancel()
        request = PendingWindowTitle(owner: owner, id: UUID(), task: Task { @MainActor in
            try? await window.title
        })
        pendingWindowTitles[window.windowId] = request
    }
    let raw = await request.task.value
    guard generation == titleCacheGeneration, !Task.isCancelled,
          Window.get(byId: window.windowId) === window else { return nil }
    // Another consumer may already have committed this shared request.
    guard pendingWindowTitles[window.windowId]?.id == request.id else { return cachedWindowTitle(for: window) }
    pendingWindowTitles.removeValue(forKey: window.windowId)
    let title = raw?.trimmingCharacters(in: .whitespacesAndNewlines).takeIf { !$0.isEmpty }
        ?? cachedWindowTitle(for: window)
    cachedWindowTitles[window.windowId] = CachedWindowTitle(owner: owner, title: title, fetchedAt: now)
    return title
}

/// Always returns immediately. Callers use the app name until the first title arrives.
@MainActor
func getSessionWindowTitle(_ window: Window, now: Date = .now) -> String? {
    if let cached = cachedWindowTitles[window.windowId], cached.owner == ObjectIdentifier(window) {
        if now.timeIntervalSince(cached.fetchedAt) >= cachedWindowTitleMaxAge {
            scheduleBackgroundWindowTitleRefresh(window)
        }
        return cached.title
    }
    scheduleBackgroundWindowTitleRefresh(window)
    return nil
}

@MainActor
private func scheduleBackgroundWindowTitleRefresh(_ window: Window) {
    let windowId = window.windowId
    let owner = ObjectIdentifier(window)
    if backgroundTitleRefreshes[windowId]?.owner == owner { return }
    backgroundTitleRefreshes[windowId]?.task.cancel()
    let id = UUID()
    let generation = titleCacheGeneration
    let task = Task { @MainActor in
        let before = cachedWindowTitle(for: window)
        let after = await getCachedWindowTitle(window)
        guard !Task.isCancelled, generation == titleCacheGeneration,
              backgroundTitleRefreshes[windowId]?.id == id else { return }
        backgroundTitleRefreshes.removeValue(forKey: windowId)
        if before != after { scheduleBackgroundTitlePublication() }
    }
    backgroundTitleRefreshes[windowId] = PendingWindowTitleRefresh(owner: owner, id: id, task: task)
}

@MainActor
private func scheduleBackgroundTitlePublication() {
    titlePublicationNeeded = true
    guard backgroundTitlePublication == nil else { return }
    let generation = titleCacheGeneration
    backgroundTitlePublication = Task { @MainActor in
        defer {
            if generation == titleCacheGeneration { backgroundTitlePublication = nil }
        }
        while titlePublicationNeeded {
            // Coalesce completions for one frame without waiting for an unrelated slow AX app.
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, generation == titleCacheGeneration else { return }
            titlePublicationNeeded = false
            if let titlePublicationOverrideForTests {
                await titlePublicationOverrideForTests()
            } else {
                await updateWorkspaceSidebarModel()
                await updateWindowTabModel()
            }
        }
    }
}

@MainActor
func setWindowTitlePublicationOverrideForTests(_ override: (@MainActor () async -> Void)?) {
    titlePublicationOverrideForTests = override
}

@MainActor
func waitForBackgroundWindowTitlesForTests() async {
    // Publication can request more titles; drain both kinds of work until quiet.
    for _ in 0 ..< 100 {
        let tasks = backgroundTitleRefreshes.values.map(\.task)
        let publication = backgroundTitlePublication
        if tasks.isEmpty && publication == nil { return }
        for task in tasks { await task.value }
        await publication?.value
    }
}

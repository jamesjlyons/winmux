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

private let cachedWindowTitleMaxAge: TimeInterval = 5
@MainActor private var cachedWindowTitles: [UInt32: CachedWindowTitle] = [:]
@MainActor private var pendingWindowTitles: [UInt32: PendingWindowTitle] = [:]
@MainActor private var titleCacheGeneration: UInt64 = 0
@MainActor private var pendingTitleRefreshWindowIds: Set<UInt32> = []
@MainActor private var backgroundTitleRefreshTask: Task<Void, Never>?

@MainActor
func resetCachedWindowTitles() {
    titleCacheGeneration &+= 1
    cachedWindowTitles = [:]
    for request in pendingWindowTitles.values { request.task.cancel() }
    pendingWindowTitles = [:]
    pendingTitleRefreshWindowIds = []
    backgroundTitleRefreshTask?.cancel()
    backgroundTitleRefreshTask = nil
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
            scheduleBackgroundWindowTitleRefresh(windowId: window.windowId)
        }
        return cached.title
    }
    scheduleBackgroundWindowTitleRefresh(windowId: window.windowId)
    return nil
}

@MainActor
private func scheduleBackgroundWindowTitleRefresh(windowId: UInt32) {
    pendingTitleRefreshWindowIds.insert(windowId)
    guard backgroundTitleRefreshTask == nil else { return }
    backgroundTitleRefreshTask = Task { @MainActor in
        var didAnyTitleChange = false
        while !pendingTitleRefreshWindowIds.isEmpty, !Task.isCancelled {
            let batch = pendingTitleRefreshWindowIds
            pendingTitleRefreshWindowIds = []
            await withTaskGroup(of: Bool.self) { group in
                for windowId in batch {
                    guard let window = Window.get(byId: windowId) else { continue }
                    group.addTask { @Sendable @MainActor in
                        let before = cachedWindowTitle(for: window)
                        let after = await getCachedWindowTitle(window)
                        return before != after
                    }
                }
                for await changed in group where changed { didAnyTitleChange = true }
            }
            guard !Task.isCancelled else { return }
        }
        guard !Task.isCancelled else { return }
        backgroundTitleRefreshTask = nil
        if didAnyTitleChange {
            await updateWorkspaceSidebarModel()
            await updateWindowTabModel()
        }
    }
}

@MainActor
func waitForBackgroundWindowTitlesForTests() async {
    await backgroundTitleRefreshTask?.value
}

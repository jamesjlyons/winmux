import Common
import Collections
import Foundation
import Network

/// One writer per client keeps events ordered and prevents a stopped reader
/// from retaining a new suspended send task for every focus or binding event.
@MainActor
final class EventSubscription {
    let events: Set<ServerEventType>
    private let capacity: Int
    private let write: @MainActor (ServerEvent) async -> Bool
    private let cancelTransport: @MainActor () -> Void
    private let onClose: @MainActor () -> Void
    private var queue: Deque<ServerEvent> = []
    private var task: Task<Void, Never>?
    private var isWriting = false
    private(set) var isClosed = false
    var bufferedEventCount: Int { queue.count + (isWriting ? 1 : 0) }

    init(events: Set<ServerEventType>, capacity: Int = 128,
         write: @escaping @MainActor (ServerEvent) async -> Bool,
         cancelTransport: @escaping @MainActor () -> Void,
         onClose: @escaping @MainActor () -> Void) {
        precondition(capacity > 0)
        self.events = events
        self.capacity = capacity
        self.write = write
        self.cancelTransport = cancelTransport
        self.onClose = onClose
    }

    func enqueue(_ event: ServerEvent) {
        guard !isClosed, events.contains(event.eventType) else { return }
        guard bufferedEventCount < capacity else {
            // Dropping arbitrary events would silently corrupt the client's
            // stream. Close only the lagging client so it can reconnect.
            close()
            return
        }
        queue.append(event)
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drain()
        }
    }

    private func drain() async {
        defer { task = nil }
        while !Task.isCancelled, !isClosed, let event = queue.popFirst() {
            isWriting = true
            let succeeded = await write(event)
            isWriting = false
            if !succeeded { close(); return }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        queue.removeAll()
        isWriting = false
        task?.cancel()
        // Task cancellation alone cannot release NWConnection's suspended
        // contentProcessed continuation. Cancel the actual socket as well.
        cancelTransport()
        onClose()
    }

    func waitUntilIdle() async { await task?.value }
}

@MainActor private var subscribers: [UniqueToken: EventSubscription] = [:]

@MainActor
func handleSubscribeAndWaitTillError(_ connection: NWConnection, _ args: SubscribeCmdArgs) async {
    let id = UniqueToken()
    let subscriber = EventSubscription(events: args.events,
        write: { await connection.writeAtomic($0, jsonEncoder).error == nil },
        cancelTransport: { connection.cancel() },
        onClose: { subscribers.removeValue(forKey: id) })
    subscribers[id] = subscriber
    defer { subscriber.close() }
    if args.sendInitial {
        let f = focus
        for eventType in args.events {
            let event: ServerEvent
            switch eventType {
                case .focusChanged:
                    event = .focusChanged(windowId: f.windowOrNil?.windowId, workspace: f.workspace.name)
                case .workspaceChanged:
                    event = .workspaceChanged(workspace: f.workspace.name, prevWorkspace: f.workspace.name)
                case .modeChanged:
                    event = .modeChanged(mode: activeMode)
                case .focusedMonitorChanged:
                    event = .focusedMonitorChanged(
                        workspace: f.workspace.name,
                        monitorId_oneBased: f.workspace.workspaceMonitor.monitorId_oneBased ?? 0,
                    )
                case .windowDetected, .bindingTriggered: continue
            }
            subscriber.enqueue(event)
        }
    }

    // Keep connection alive - wait for client to disconnect
    await connection.readTillError()
}

private let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    return e
}()

@MainActor
func broadcastEvent(_ event: ServerEvent) {
    for subscriber in subscribers.values { subscriber.enqueue(event) }
}

import AppKit

/// Used only on the owning app's AX thread. CFEqual, never a hash or a title,
/// associates the native tab bar across changes of its containing window.
final class NativeTabAccessibility {
    private var elements: [(UUID, AXUIElement)] = []
    private(set) var registry = NativeTabRegistry()
    private var observers: [UUID: Any] = [:]
    private var standalone: Set<UInt32> = []
    private var readDeadline = Date.distantFuture
    private let readTimeout: Float = 0.05

    func observe(_ window: AXUIElement, id: UInt32) {
        readDeadline = Date().addingTimeInterval(0.15)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &raw) == .success,
              let children = raw as? [AXUIElement] else { return }
        var found = false
        var complete = true
        for child in children {
            guard let role = string(child, kAXRoleAttribute) else { complete = false; continue }
            guard role == kAXTabGroupRole else { continue }
            found = true
            var rawTabs: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXTabsAttribute as CFString, &rawTabs) == .success,
                  let tabs = rawTabs as? [AXUIElement], !tabs.isEmpty,
                  tabs.allSatisfy({ string($0, kAXSubroleAttribute) == "AXTabButton" }) else { continue }
            let identity: UUID
            if let existing = elements.first(where: { CFEqual($0.1, child) }) { identity = existing.0 }
            else { identity = UUID(); elements.append((identity, child)) }
            standalone.remove(id)
            registry.observe(group: identity, selected: id, titles: tabs.map { string($0, kAXTitleAttribute) ?? "" })
            return
        }
        if !found && complete { standalone.insert(id) }
    }

    func refreshKnownGroups() -> [(UInt32, AXUIElement)] {
        readDeadline = Date().addingTimeInterval(0.15)
        var result: [(UInt32, AXUIElement)] = []
        for (identity, element) in elements {
            guard Date() < readDeadline else { break }
            AXUIElementSetMessagingTimeout(element, readTimeout)
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &raw) == .success,
                  let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }
            let window = raw as! AXUIElement
            AXUIElementSetMessagingTimeout(window, readTimeout)
            guard let id = window.containingWindowId() else { continue }
            var rawTabs: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXTabsAttribute as CFString, &rawTabs) == .success,
                  let tabs = rawTabs as? [AXUIElement], !tabs.isEmpty else { continue }
            standalone.remove(id)
            registry.observe(group: identity, selected: id, titles: tabs.map { string($0, kAXTitleAttribute) ?? "" })
            result.append((id, window))
        }
        return result
    }

    func updateObservers(_ make: (AXUIElement) throws -> Any) rethrows {
        for (id, element) in elements where observers[id] == nil { observers[id] = try make(element) }
        observers = observers.filter { registry.groups[$0.key] != nil }
    }

    func retainAlive(_ ids: Set<UInt32>) {
        registry.retainAlive(ids)
        for id in standalone.intersection(ids).sorted() { registry.observeStandalone(id) }
        standalone.removeAll()
        elements.removeAll { registry.groups[$0.0] == nil }
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? {
        guard Date() < readDeadline else { return nil }
        AXUIElementSetMessagingTimeout(element, readTimeout)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else { return nil }
        return raw as? String
    }
}

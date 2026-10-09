import AppKit
import Common
import SwiftUI

struct WorkspaceSidebarProjectSwipeScrollCapture: NSViewRepresentable {
    let isEnabled: Bool
    let onChanged: (CGFloat, CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.view = view
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        if isEnabled {
            context.coordinator.installMonitor()
        } else {
            context.coordinator.removeMonitor()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var isEnabled = false
        var onChanged: ((CGFloat, CGFloat) -> Void)?
        var onEnded: ((CGFloat, CGFloat) -> Void)?
        var monitor: Any?
        var gesture = WorkspaceSidebarProjectScrollGesture()
        var endWorkItem: DispatchWorkItem?
        var trackpadScrollGate = TrackpadSidebarScrollGate()

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            resetAccumulatedScroll()
        }

        func resetAccumulatedScroll() {
            endWorkItem?.cancel()
            endWorkItem = nil
            gesture = WorkspaceSidebarProjectScrollGesture()
        }

        func handle(_ event: NSEvent) -> NSEvent? {
            if let view, let window = view.window, event.window === window,
               view.bounds.contains(view.convert(event.locationInWindow, from: nil)),
               trackpadScrollGate.shouldSuppress(owned: !TrackpadNavigationController.shared.ownedDevices.isEmpty,
                   phase: event.phase, momentum: event.momentumPhase)
            {
                if gesture.isLocked { onEnded?(0, 0) }
                resetAccumulatedScroll()
                return nil
            }
            if !gesture.isLocked && (!gesture.suppressMomentum || event.momentumPhase.isEmpty) && WorkspaceSidebarProjectScrollRegion.contains(event) {
                resetAccumulatedScroll()
                return event
            }
            guard isEnabled,
                  !isWorkspaceSidebarDragInProgress(),
                  event.hasPreciseScrollingDeltas,
                  let view,
                  let window = view.window,
                  event.window === window
            else {
                resetIfNeededForExternalEvent(event)
                return event
            }
            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) || gesture.isLocked else {
                resetIfNeededForExternalEvent(event)
                return event
            }
            let update = gesture.update(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                phase: event.phase, momentum: event.momentumPhase)
            if gesture.needsEndTimer { scheduleEndTimer() }
            else {
                endWorkItem?.cancel()
                endWorkItem = nil
            }
            return deliver(update) ? nil : event
        }

        func resetIfNeededForExternalEvent(_ event: NSEvent) {
            guard gesture.isLocked,
                  event.phase.contains(.ended) || event.phase.contains(.cancelled)
            else {
                return
            }
            _ = deliver(gesture.finish(cancelled: event.phase.contains(.cancelled)))
        }

        func scheduleEndTimer() {
            endWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.finishLockedSwipe()
            }
            endWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
        }

        func finishLockedSwipe() {
            endWorkItem?.cancel()
            endWorkItem = nil
            guard gesture.needsEndTimer else { return }
            _ = deliver(gesture.finish())
        }

        func deliver(_ update: WorkspaceSidebarProjectScrollGesture.Update) -> Bool {
            switch update {
            case .passThrough: return false
            case .consumed: return true
            case let .changed(horizontal, vertical): onChanged?(horizontal, vertical)
            case let .ended(horizontal, vertical): onEnded?(horizontal, vertical)
            }
            return true
        }
    }
}

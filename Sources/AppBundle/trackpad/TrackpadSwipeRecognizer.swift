import Foundation

struct TrackpadContact: Equatable, Sendable {
    let id: Int32
    let x: Double
    let y: Double
}

struct TrackpadFrame: Sendable {
    let device: UInt
    let timestamp: Double
    let contacts: [TrackpadContact]
    var buttonDown = false

    var isValid: Bool {
        timestamp.isFinite && contacts.count <= 16 && Set(contacts.map(\.id)).count == contacts.count &&
            contacts.allSatisfy { $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }
    }
}

enum TrackpadSwipeDirection: Equatable, Sendable { case left, right }

enum TrackpadGestureEvent: Equatable, Sendable {
    case began(UInt)
    case committed(UInt, TrackpadSwipeDirection)
    case cancelled(UInt)
    case ended(UInt)
}

/// Pure, per-device state. A contact sequence can produce at most one commit.
/// Cancelled and committed sequences stay latched until every finger lifts.
struct TrackpadSwipeRecognizer: Sendable {
    static let minimumTravel = 0.15
    static let horizontalRatio = 1.8
    static let stableDuration = 0.04
    static let maximumDuration = 1.5
    static let staleInterval = 0.25

    private struct Stream: Sendable {
        var touching = false
        var lastTimestamp: Double?
        var firstTouch: Double?
        var landingContacts: [Int32: TrackpadContact] = [:]
        var rejected = false
        var began = false
        var committed = false
        var origin: [TrackpadContact] = []
        var startTime = 0.0
    }

    private var streams: [UInt: Stream] = [:]

    mutating func observe(_ frame: TrackpadFrame) -> [TrackpadGestureEvent] {
        var stream = streams[frame.device] ?? Stream()
        var events: [TrackpadGestureEvent] = []
        defer { streams[frame.device] = stream }

        func reject(_ stream: inout Stream, device: UInt) {
            if stream.began && !stream.rejected && !stream.committed { events.append(.cancelled(device)) }
            stream.rejected = true
        }

        guard frame.isValid else {
            reject(&stream, device: frame.device)
            return events
        }
        if let last = stream.lastTimestamp, frame.timestamp < last || frame.timestamp - last > Self.staleInterval {
            if stream.touching { reject(&stream, device: frame.device) }
        }
        stream.lastTimestamp = frame.timestamp
        stream.touching = !frame.contacts.isEmpty
        if frame.contacts.isEmpty {
            if stream.began { events.append(.ended(frame.device)) }
            stream = Stream(lastTimestamp: frame.timestamp)
            return events
        }

        // Simultaneous use of two trackpads must not send two navigation actions.
        for other in Array(streams.keys) where other != frame.device && streams[other]?.touching == true {
            if var otherStream = streams[other] {
                reject(&otherStream, device: other)
                streams[other] = otherStream
            }
            reject(&stream, device: frame.device)
        }
        if frame.buttonDown || frame.contacts.count > 3 { reject(&stream, device: frame.device) }
        guard !stream.rejected, !stream.committed else { return events }

        if !stream.began {
            if stream.firstTouch == nil { stream.firstTouch = frame.timestamp }
            // Allow staggered landing, but don't turn an ongoing two-finger
            // scroll into a tab swipe merely because a third finger arrives.
            for contact in frame.contacts {
                if let initial = stream.landingContacts[contact.id],
                   hypot(contact.x - initial.x, contact.y - initial.y) > 0.03
                {
                    reject(&stream, device: frame.device)
                }
                if stream.landingContacts[contact.id] == nil { stream.landingContacts[contact.id] = contact }
            }
            guard !stream.rejected else { return events }
            if frame.timestamp - (stream.firstTouch ?? frame.timestamp) > 0.15 {
                reject(&stream, device: frame.device)
                return events
            }
            guard frame.contacts.count == 3 else { return events }
            stream.began = true
            stream.origin = frame.contacts
            stream.startTime = frame.timestamp
            events.append(.began(frame.device))
            return events
        }

        guard Set(stream.origin.map(\.id)) == Set(frame.contacts.map(\.id)),
              frame.timestamp - stream.startTime <= Self.maximumDuration
        else {
            reject(&stream, device: frame.device)
            return events
        }
        let dx = (frame.contacts.reduce(0) { $0 + $1.x } - stream.origin.reduce(0) { $0 + $1.x }) / 3
        let dy = (frame.contacts.reduce(0) { $0 + $1.y } - stream.origin.reduce(0) { $0 + $1.y }) / 3
        guard max(abs(dx), abs(dy)) >= Self.minimumTravel else { return events }
        guard abs(dx) >= Self.minimumTravel, abs(dx) >= abs(dy) * Self.horizontalRatio else {
            reject(&stream, device: frame.device)
            return events
        }
        guard frame.timestamp - stream.startTime >= Self.stableDuration else { return events }
        stream.committed = true
        events.append(.committed(frame.device, dx < 0 ? .left : .right))
        return events
    }

    mutating func expire(device: UInt) -> [TrackpadGestureEvent] {
        guard var stream = streams[device], stream.touching else { return [] }
        let shouldNotify = stream.began && !stream.rejected && !stream.committed
        stream.rejected = true
        streams[device] = stream
        return shouldNotify ? [.cancelled(device)] : []
    }
}

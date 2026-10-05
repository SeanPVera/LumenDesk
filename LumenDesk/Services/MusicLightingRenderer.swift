import Foundation

struct MusicRenderCommand: Equatable {
    let fixtureID: String
    let transport: MusicTransportKind
    let states: [MusicLightingState]
    let sequenceNumber: UInt64
}

/// Coalesces vendor-neutral frames independently per fixture and enforces a
/// transport-specific update ceiling. A slower LAN bulb never blocks a faster
/// real-time segment stream.
final class MusicLightingRenderer {
    private struct PendingFrame {
        let transport: MusicTransportKind
        let states: [MusicLightingState]
        let sequenceNumber: UInt64
        let timestamp: TimeInterval
    }

    private var pendingByFixture: [String: PendingFrame] = [:]
    struct Diagnostics {
        var generatedFrames = 0
        var coalescedStates = 0
        var rejectedStates = 0
        var commandsHandedOff = 0 // not UDP receipt or visible output
    }
    private(set) var diagnostics = Diagnostics()
    private var latestSequence: [String: UInt64] = [:]
    static let maximumFrameAge: TimeInterval = 0.25
    /// How early a handoff may land against its slot. The render clock ticks
    /// every 50 ms with up to 10 ms of timer tolerance, and a repeating timer
    /// snaps back to its schedule, so a late tick is followed by a short gap.
    /// Comparing raw gaps against the ceiling dropped that next frame, and a
    /// 60 ms ceiling against 50 ms ticks sent on only every other tick.
    static let pacingTolerance: TimeInterval = 0.015
    /// Each fixture's next slot. Slots advance by the transport's interval
    /// from the previous slot, so the average rate holds at the ceiling while
    /// single handoffs absorb render-clock jitter.
    private var nextDueAt: [String: TimeInterval] = [:]

    func enqueue(
        _ frame: MusicLightingFrame,
        fixtures: [MusicFixtureDescriptor],
        at timestamp: TimeInterval
    ) -> [MusicRenderCommand] {
        diagnostics.generatedFrames += 1
        // A duplicated light ID (a hand-edited import) must not trap here.
        let fixtureByID = Dictionary(fixtures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let grouped = Dictionary(grouping: frame.states, by: \.fixtureID)
        for (fixtureID, states) in grouped {
            guard let fixture = fixtureByID[fixtureID] else { continue }
            guard timestamp - frame.timestamp <= Self.maximumFrameAge,
                  latestSequence[fixtureID].map({ frame.sequenceNumber > $0 }) ?? true else {
                diagnostics.rejectedStates += 1
                continue
            }
            latestSequence[fixtureID] = frame.sequenceNumber
            if pendingByFixture[fixtureID] != nil { diagnostics.coalescedStates += 1 }
            pendingByFixture[fixtureID] = PendingFrame(
                transport: fixture.transport,
                states: states.sorted { ($0.segmentID ?? -1) < ($1.segmentID ?? -1) },
                sequenceNumber: frame.sequenceNumber,
                timestamp: frame.timestamp
            )
        }
        return flush(fixtures: fixtures, at: timestamp)
    }

    func flush(fixtures: [MusicFixtureDescriptor], at timestamp: TimeInterval) -> [MusicRenderCommand] {
        for (id, pending) in pendingByFixture where timestamp - pending.timestamp > Self.maximumFrameAge {
            pendingByFixture.removeValue(forKey: id)
            diagnostics.rejectedStates += 1
        }
        let availableIDs = Set(fixtures.map(\.id))
        var commands: [MusicRenderCommand] = []
        for fixtureID in pendingByFixture.keys.sorted() where availableIDs.contains(fixtureID) {
            guard let pending = pendingByFixture[fixtureID] else { continue }
            let interval = Self.minimumInterval(for: pending.transport)
            let tolerance = Self.pacingTolerance
            if let due = nextDueAt[fixtureID], timestamp + tolerance + 0.000_001 < due {
                continue
            }
            // A slot taken late moves the schedule forward instead of banking
            // credit for a burst of catch-up handoffs, so two handoffs are
            // never closer than the interval less twice the tolerance.
            nextDueAt[fixtureID] = max(nextDueAt[fixtureID] ?? timestamp, timestamp - tolerance) + interval
            pendingByFixture.removeValue(forKey: fixtureID)
            diagnostics.commandsHandedOff += 1
            commands.append(MusicRenderCommand(
                fixtureID: fixtureID,
                transport: pending.transport,
                states: pending.states,
                sequenceNumber: pending.sequenceNumber
            ))
        }
        return commands
    }

    func reset(fixtureIDs: Set<String>? = nil) {
        guard let fixtureIDs else {
            pendingByFixture.removeAll(keepingCapacity: true)
            nextDueAt.removeAll(keepingCapacity: true)
            latestSequence.removeAll(keepingCapacity: true)
            return
        }
        for id in fixtureIDs {
            pendingByFixture.removeValue(forKey: id)
            nextDueAt.removeValue(forKey: id)
            latestSequence.removeValue(forKey: id)
        }
    }

    static func minimumInterval(for transport: MusicTransportKind) -> TimeInterval {
        switch transport {
        case .goveeRealtimeSegments: return 0.05  // 20 fps volatile stream
        case .lifxLAN: return 0.06                 // combined HSBK packet
        case .nanoleafLAN: return 0.2             // whole-controller HTTP updates
        case .goveeLAN: return 0.1                 // ordinary LAN JSON ceiling
        case .nanoleafStream: return NanoleafStreamPacket.minimumFrameInterval // Nanoleaf's 10 Hz limit
        }
    }
}

/// Aggregate-only transport instrumentation. Local socket submission is not
/// acknowledgement, delivery, or visible response. No audio or frame history.
final class MusicDispatchMetrics {
    struct Snapshot {
        var submitted = 0
        var failed = 0
        var expired = 0
        var maximumQueueAge: TimeInterval = 0
    }
    private let lock = NSLock()
    private var value = Snapshot()
    func record(age: TimeInterval, failed: Bool = false, expired: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        value.maximumQueueAge = max(value.maximumQueueAge, max(0, age))
        if expired { value.expired += 1 }
        else if failed { value.failed += 1 }
        else { value.submitted += 1 }
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

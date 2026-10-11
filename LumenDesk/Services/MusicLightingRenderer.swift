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
    // Fixture membership and deterministic dispatch order change with the
    // room, not with the audio. Retain them across frame enqueues and flushes.
    private var cachedFixtures: [MusicFixtureDescriptor] = []
    private var transportsByFixture: [String: MusicTransportKind] = [:]
    private var lastTransportByFixture: [String: MusicTransportKind] = [:]
    private var orderedFixtureIDs: [String] = []
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
        updateFixtures(fixtures)
        let grouped = Dictionary(grouping: frame.states, by: \.fixtureID)
        for (fixtureID, states) in grouped {
            guard let transport = transportsByFixture[fixtureID] else { continue }
            guard timestamp - frame.timestamp <= Self.maximumFrameAge,
                  latestSequence[fixtureID].map({ frame.sequenceNumber > $0 }) ?? true else {
                diagnostics.rejectedStates += 1
                continue
            }
            latestSequence[fixtureID] = frame.sequenceNumber
            if pendingByFixture[fixtureID] != nil { diagnostics.coalescedStates += 1 }
            pendingByFixture[fixtureID] = PendingFrame(
                transport: transport,
                states: Self.orderedStates(states),
                sequenceNumber: frame.sequenceNumber,
                timestamp: frame.timestamp
            )
        }
        return flush(at: timestamp)
    }

    func flush(fixtures: [MusicFixtureDescriptor], at timestamp: TimeInterval) -> [MusicRenderCommand] {
        updateFixtures(fixtures)
        return flush(at: timestamp)
    }

    private func flush(at timestamp: TimeInterval) -> [MusicRenderCommand] {
        guard !pendingByFixture.isEmpty else { return [] }
        // A renderer can be shared by independent room sessions. Expire every
        // pending fixture, even when this flush receives only one room's list.
        for (id, pending) in pendingByFixture where timestamp - pending.timestamp > Self.maximumFrameAge {
            pendingByFixture.removeValue(forKey: id)
            diagnostics.rejectedStates += 1
        }
        var commands: [MusicRenderCommand] = []
        commands.reserveCapacity(pendingByFixture.count)
        for fixtureID in orderedFixtureIDs {
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

    private func updateFixtures(_ fixtures: [MusicFixtureDescriptor]) {
        guard cachedFixtures != fixtures else { return }
        cachedFixtures = fixtures
        var transports: [String: MusicTransportKind] = [:]
        transports.reserveCapacity(fixtures.count)
        // A duplicated light ID in a hand-edited import must not trap here.
        for fixture in fixtures where transports[fixture.id] == nil {
            transports[fixture.id] = fixture.transport
        }
        // Lists may represent different room sessions. An absent ID therefore
        // retains its own pacing slot; only an actual transport change revokes
        // that fixture's queued output and transport-specific schedule.
        for (id, transport) in transports {
            if let previous = lastTransportByFixture[id], previous != transport {
                pendingByFixture.removeValue(forKey: id)
                nextDueAt.removeValue(forKey: id)
                latestSequence.removeValue(forKey: id)
            }
            lastTransportByFixture[id] = transport
        }
        transportsByFixture = transports
        orderedFixtureIDs = transports.keys.sorted()
    }

    private static func orderedStates(_ states: [MusicLightingState]) -> [MusicLightingState] {
        // Choreography already emits ordered segments. Preserve its array
        // unless an imported or external frame actually needs sorting.
        guard states.count > 1 else { return states }
        for index in 1..<states.count {
            if (states[index - 1].segmentID ?? -1) > (states[index].segmentID ?? -1) {
                return states.sorted { ($0.segmentID ?? -1) < ($1.segmentID ?? -1) }
            }
        }
        return states
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

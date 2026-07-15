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
    }

    private var pendingByFixture: [String: PendingFrame] = [:]
    private var lastSentAt: [String: TimeInterval] = [:]

    func enqueue(
        _ frame: MusicLightingFrame,
        fixtures: [MusicFixtureDescriptor],
        at timestamp: TimeInterval
    ) -> [MusicRenderCommand] {
        let fixtureByID = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.id, $0) })
        let grouped = Dictionary(grouping: frame.states, by: \.fixtureID)
        for (fixtureID, states) in grouped {
            guard let fixture = fixtureByID[fixtureID] else { continue }
            pendingByFixture[fixtureID] = PendingFrame(
                transport: fixture.transport,
                states: states.sorted { ($0.segmentID ?? -1) < ($1.segmentID ?? -1) },
                sequenceNumber: frame.sequenceNumber
            )
        }
        return flush(fixtures: fixtures, at: timestamp)
    }

    func flush(fixtures: [MusicFixtureDescriptor], at timestamp: TimeInterval) -> [MusicRenderCommand] {
        let availableIDs = Set(fixtures.map(\.id))
        var commands: [MusicRenderCommand] = []
        for fixtureID in pendingByFixture.keys.sorted() where availableIDs.contains(fixtureID) {
            guard let pending = pendingByFixture[fixtureID] else { continue }
            let interval = Self.minimumInterval(for: pending.transport)
            if let last = lastSentAt[fixtureID], timestamp - last + 0.000_001 < interval {
                continue
            }
            pendingByFixture.removeValue(forKey: fixtureID)
            lastSentAt[fixtureID] = timestamp
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
            lastSentAt.removeAll(keepingCapacity: true)
            return
        }
        for id in fixtureIDs {
            pendingByFixture.removeValue(forKey: id)
            lastSentAt.removeValue(forKey: id)
        }
    }

    static func minimumInterval(for transport: MusicTransportKind) -> TimeInterval {
        switch transport {
        case .goveeRealtimeSegments: return 0.04  // 25 fps volatile stream
        case .lifxLAN: return 0.06                 // combined HSBK packet
        case .goveeLAN: return 0.1                 // ordinary LAN JSON ceiling
        }
    }
}

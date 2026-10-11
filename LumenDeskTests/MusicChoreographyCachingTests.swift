import XCTest
@testable import LumenDesk

final class MusicChoreographyCachingTests: XCTestCase {
    private var snapshot: AudioReactiveSnapshot {
        AudioReactiveSnapshot(
            level: 0.7, bass: 0.5, energy: 0.7, confidence: 1,
            tempo: 120, beatInterval: 0.5, beatConfidence: 1,
            beatReferenceTime: 100, isTempoLocked: true,
            metre: 4, feltInterval: 0.5, sourceDescription: "Test"
        )
    }

    private var configuration: MusicModeConfiguration {
        var value = MusicModeConfiguration.configuration(for: .soundcheck)
        value.palette = [MusicPaletteColor(0xFF0000), MusicPaletteColor(0x0000FF)]
        value.movementAmount = 0
        value.movementSpeed = 0
        value.stereoImage = 0
        value.beatSensitivity = 0
        value.colorChangeIntensity = 1
        value.phraseAware = false
        return value
    }

    func testLiveTopologyChangesReorderAndExcludeTargets() {
        let engine = MusicChoreographyEngine()
        let fixtures = [
            MusicFixtureDescriptor(id: "a", label: "A", transport: .lifxLAN),
            MusicFixtureDescriptor(id: "b", label: "B", transport: .lifxLAN),
            MusicFixtureDescriptor(id: "c", label: "C", transport: .lifxLAN)
        ]
        var topology = FixtureTopology()
        let first = engine.makeFrame(snapshot: snapshot, configuration: configuration,
            topology: topology, fixtures: fixtures, timestamp: 100, sequenceNumber: 1)
        XCTAssertEqual(first.states.map(\.fixtureID), ["a", "b", "c"])

        topology.fixtureOrder = ["c", "a", "b"]
        topology.excludedFixtureIDs = ["a"]
        let changed = engine.makeFrame(snapshot: snapshot, configuration: configuration,
            topology: topology, fixtures: fixtures, timestamp: 100.05, sequenceNumber: 2)
        XCTAssertEqual(changed.states.map(\.fixtureID), ["c", "b"])

        topology.excludedFixtureIDs = ["a", "b", "c"]
        let empty = engine.makeFrame(snapshot: snapshot, configuration: configuration,
            topology: topology, fixtures: fixtures, timestamp: 100.10, sequenceNumber: 3)
        XCTAssertTrue(empty.states.isEmpty)

        topology.excludedFixtureIDs = []
        let restored = engine.makeFrame(snapshot: snapshot, configuration: configuration,
            topology: topology, fixtures: fixtures, timestamp: 100.15, sequenceNumber: 4)
        XCTAssertEqual(restored.states.map(\.fixtureID), ["c", "a", "b"])
    }

    func testLiveSegmentPlacementAndCountChangesReachTheGradient() {
        let engine = MusicChoreographyEngine()
        let forward = MusicFixtureDescriptor(id: "wall", label: "Wall", transport: .nanoleafStream,
            segmentCount: 4, segmentPositions: [0, 0.25, 0.75, 1])
        let first = engine.makeFrame(snapshot: snapshot, configuration: configuration,
            topology: FixtureTopology(), fixtures: [forward], timestamp: 100, sequenceNumber: 1)
        let reverse = MusicFixtureDescriptor(id: "wall", label: "Wall", transport: .nanoleafStream,
            segmentCount: 4, segmentPositions: [1, 0.75, 0.25, 0])
        let changed = engine.makeFrame(snapshot: snapshot, configuration: configuration,
            topology: FixtureTopology(), fixtures: [reverse], timestamp: 100.05, sequenceNumber: 2)
        XCTAssertEqual(changed.states.map(\.hue), Array(first.states.map(\.hue).reversed()))

        var circular = FixtureTopology()
        circular.layout = .circular
        let wrapped = engine.makeFrame(snapshot: snapshot, configuration: configuration,
            topology: circular, fixtures: [reverse], timestamp: 100.10, sequenceNumber: 3)
        XCTAssertNotEqual(wrapped.states.map(\.hue), changed.states.map(\.hue))

        let smaller = MusicFixtureDescriptor(id: "wall", label: "Wall", transport: .nanoleafStream,
            segmentCount: 2)
        let resized = engine.makeFrame(snapshot: snapshot, configuration: configuration,
            topology: circular, fixtures: [smaller], timestamp: 100.15, sequenceNumber: 4)
        XCTAssertEqual(resized.states.map(\.segmentID), [0, 1])
    }

    func testRenamingAnAutomaticRoleChangesItsBrightness() throws {
        let changedEngine = MusicChoreographyEngine()
        let unchangedEngine = MusicChoreographyEngine()
        let original = MusicFixtureDescriptor(id: "bulb", label: "Front", transport: .lifxLAN)
        for engine in [changedEngine, unchangedEngine] {
            _ = engine.makeFrame(snapshot: snapshot, configuration: configuration,
                topology: FixtureTopology(), fixtures: [original], timestamp: 100, sequenceNumber: 1)
        }
        let renamed = MusicFixtureDescriptor(id: "bulb", label: "Rear", transport: .lifxLAN)
        let changed = changedEngine.makeFrame(snapshot: snapshot, configuration: configuration,
            topology: FixtureTopology(), fixtures: [renamed], timestamp: 100.05, sequenceNumber: 2)
        let unchanged = unchangedEngine.makeFrame(snapshot: snapshot, configuration: configuration,
            topology: FixtureTopology(), fixtures: [original], timestamp: 100.05, sequenceNumber: 2)
        XCTAssertLessThan(try XCTUnwrap(changed.states.first).brightness,
                          try XCTUnwrap(unchanged.states.first).brightness)

        let excluded = MusicFixtureDescriptor(id: "bulb", label: "Rear", transport: .lifxLAN, role: .off)
        XCTAssertTrue(changedEngine.makeFrame(snapshot: snapshot, configuration: configuration,
            topology: FixtureTopology(), fixtures: [excluded], timestamp: 100.10, sequenceNumber: 3).states.isEmpty)
    }

    func testPaletteEditsAndEmptyPaletteFallbackReachTheNextFrame() throws {
        let engine = MusicChoreographyEngine()
        let fixture = MusicFixtureDescriptor(id: "bulb", label: "Bulb", transport: .lifxLAN)
        var config = configuration
        config.colorChangeIntensity = 0
        config.palette = [MusicPaletteColor(0xFF0000)]
        let red = engine.makeFrame(snapshot: snapshot, configuration: config,
            topology: FixtureTopology(), fixtures: [fixture], timestamp: 100, sequenceNumber: 1)
        XCTAssertEqual(try XCTUnwrap(red.states.first).hue, 0, accuracy: 0.000_001)

        config.palette = [MusicPaletteColor(0x0000FF)]
        let blue = engine.makeFrame(snapshot: snapshot, configuration: config,
            topology: FixtureTopology(), fixtures: [fixture], timestamp: 100.05, sequenceNumber: 2)
        XCTAssertEqual(try XCTUnwrap(blue.states.first).hue, 2.0 / 3, accuracy: 0.000_001)

        config.palette = []
        let fallback = engine.makeFrame(snapshot: snapshot, configuration: config,
            topology: FixtureTopology(), fixtures: [fixture], timestamp: 100.10, sequenceNumber: 3)
        let reference = MusicChoreographyEngine().makeFrame(snapshot: snapshot, configuration: config,
            topology: FixtureTopology(), fixtures: [fixture], timestamp: 100.10, sequenceNumber: 3)
        XCTAssertEqual(fallback.states.map(\.hue), reference.states.map(\.hue))
        XCTAssertEqual(fallback.states.map(\.saturation), reference.states.map(\.saturation))
    }

    func testResetProducesTheSameFrameAsANewEngine() {
        let engine = MusicChoreographyEngine()
        let fixtures = [MusicFixtureDescriptor(id: "strip", label: "Strip",
            transport: .goveeRealtimeSegments, segmentCount: 8)]
        for index in 0..<20 {
            _ = engine.makeFrame(snapshot: snapshot, configuration: configuration,
                topology: FixtureTopology(), fixtures: fixtures,
                timestamp: 100 + Double(index) * 0.05, sequenceNumber: UInt64(index))
        }
        engine.reset()
        let reset = engine.makeFrame(snapshot: snapshot, configuration: configuration,
            topology: FixtureTopology(), fixtures: fixtures, timestamp: 100, sequenceNumber: 1)
        let fresh = MusicChoreographyEngine().makeFrame(snapshot: snapshot, configuration: configuration,
            topology: FixtureTopology(), fixtures: fixtures, timestamp: 100, sequenceNumber: 1)
        XCTAssertEqual(reset, fresh)
    }
}

final class MusicRendererCachingTests: XCTestCase {
    private func frame(_ sequence: UInt64, at time: TimeInterval, fixtureID: String = "bulb",
                       segmentIDs: [Int?] = [nil]) -> MusicLightingFrame {
        MusicLightingFrame(
            states: segmentIDs.map {
                MusicLightingState(fixtureID: fixtureID, segmentID: $0, hue: 0.2,
                    saturation: 1, brightness: 0.5, transitionDuration: 0.09)
            },
            timestamp: time, sequenceNumber: sequence, sustainedEnergyEvent: false, flashApplied: false
        )
    }

    func testInterleavedRoomFixturesKeepIndependentPacingAndPendingFrames() {
        let renderer = MusicLightingRenderer()
        let first = MusicFixtureDescriptor(id: "first", label: "First", transport: .goveeLAN)
        let second = MusicFixtureDescriptor(id: "second", label: "Second", transport: .goveeLAN)
        XCTAssertEqual(renderer.enqueue(frame(1, at: 100, fixtureID: "first"), fixtures: [first], at: 100).count, 1)
        XCTAssertEqual(renderer.enqueue(frame(1, at: 100.01, fixtureID: "second"), fixtures: [second], at: 100.01).count, 1)
        XCTAssertTrue(renderer.enqueue(frame(2, at: 100.02, fixtureID: "first"), fixtures: [first], at: 100.02).isEmpty)
        XCTAssertTrue(renderer.enqueue(frame(2, at: 100.03, fixtureID: "second"), fixtures: [second], at: 100.03).isEmpty)
        XCTAssertEqual(renderer.flush(fixtures: [first], at: 100.1).first?.sequenceNumber, 2)
        XCTAssertEqual(renderer.flush(fixtures: [second], at: 100.11).first?.sequenceNumber, 2)
    }

    func testUnavailableFixturesExpireWithoutReplayingOldAccents() {
        let renderer = MusicLightingRenderer()
        let fixture = MusicFixtureDescriptor(id: "bulb", label: "Bulb", transport: .goveeLAN)
        _ = renderer.enqueue(frame(1, at: 100), fixtures: [fixture], at: 100)
        XCTAssertTrue(renderer.enqueue(frame(2, at: 100.01), fixtures: [fixture], at: 100.01).isEmpty)
        XCTAssertTrue(renderer.flush(fixtures: [], at: 100.30).isEmpty)
        XCTAssertTrue(renderer.flush(fixtures: [fixture], at: 100.31).isEmpty)
        XCTAssertEqual(renderer.diagnostics.rejectedStates, 1)
    }

    func testTransportChangeRevokesPendingFrameAndUsesNewCeiling() throws {
        let renderer = MusicLightingRenderer()
        let original = MusicFixtureDescriptor(id: "bulb", label: "Bulb", transport: .goveeLAN)
        let changed = MusicFixtureDescriptor(id: "bulb", label: "Bulb", transport: .lifxLAN)
        _ = renderer.enqueue(frame(1, at: 100), fixtures: [original], at: 100)
        XCTAssertTrue(renderer.enqueue(frame(2, at: 100.01), fixtures: [original], at: 100.01).isEmpty)
        XCTAssertTrue(renderer.flush(fixtures: [changed], at: 100.1).isEmpty)
        let command = try XCTUnwrap(renderer.enqueue(frame(3, at: 100.11), fixtures: [changed], at: 100.11).first)
        XCTAssertEqual(command.transport, .lifxLAN)
        XCTAssertTrue(renderer.enqueue(frame(4, at: 100.12), fixtures: [changed], at: 100.12).isEmpty)
        XCTAssertEqual(renderer.flush(fixtures: [changed], at: 100.17).first?.sequenceNumber, 4)
    }

    func testOrderedAndUnorderedSegmentFramesReachTransportInOrder() throws {
        let renderer = MusicLightingRenderer()
        let fixture = MusicFixtureDescriptor(id: "strip", label: "Strip", transport: .goveeRealtimeSegments, segmentCount: 4)
        let ordered = try XCTUnwrap(renderer.enqueue(frame(1, at: 100, fixtureID: "strip", segmentIDs: [0, 1, 2, 3]),
            fixtures: [fixture], at: 100).first)
        XCTAssertEqual(ordered.states.map(\.segmentID), [0, 1, 2, 3])
        let reordered = try XCTUnwrap(renderer.enqueue(frame(2, at: 100.05, fixtureID: "strip", segmentIDs: [3, 1, 0, 2]),
            fixtures: [fixture], at: 100.05).first)
        XCTAssertEqual(reordered.states.map(\.segmentID), [0, 1, 2, 3])
        // Duplicate descriptors preserve the first transport and never trap.
        let duplicate = MusicFixtureDescriptor(id: "strip", label: "Duplicate", transport: .nanoleafLAN)
        let deduplicated = try XCTUnwrap(renderer.enqueue(frame(3, at: 100.1, fixtureID: "strip"),
            fixtures: [fixture, duplicate], at: 100.1).first)
        XCTAssertEqual(deduplicated.transport, .goveeRealtimeSegments)
    }
}

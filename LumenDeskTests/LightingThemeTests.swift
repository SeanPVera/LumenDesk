import SwiftUI
import XCTest
@testable import LumenDesk

/// Catalog integrity, palette maths, and the planner that decides what each
/// fixture in a room is sent. `ThemePlanner` is deliberately pure, so every
/// capability mix — one bulb, several bulbs, a Govee strip, a Luna matrix, a
/// zone-limited lamp, and all of them at once — is exercised here without a
/// socket, a device, or a main-actor hop.
final class LightingThemeTests: XCTestCase {

    // MARK: - Fixtures used across the planner tests

    private func bulb(_ id: String, kelvin: Int = 3_500) -> ThemeFixture {
        ThemeFixture(id: id, capability: .solid, kelvin: kelvin)
    }

    /// A 15-segment COB strip: the common blending RGBIC case.
    private func strip(_ id: String, count: Int = 15, gradient: Bool = true) -> ThemeFixture {
        ThemeFixture(id: id, capability: .segments(count: count, gradient: gradient,
                                                   simultaneousZoneLimit: nil))
    }

    /// The H60B0 uplighter's shape: three zones, only two of which light.
    private func uplighter(_ id: String, preferred: [Int] = []) -> ThemeFixture {
        ThemeFixture(id: id,
                     capability: .segments(count: 3, gradient: false, simultaneousZoneLimit: 2),
                     preferredZones: preferred)
    }

    /// Luna reports a 5x6 matrix and lights 26 of those 30 cells.
    private func luna(_ id: String) -> ThemeFixture {
        ThemeFixture(id: id, capability: .matrix(productID: 219, width: 5, height: 6))
    }

    private func theme(_ id: String) throws -> LightingTheme {
        try XCTUnwrap(LightingCatalog.theme(withID: id), "missing theme \(id)")
    }

    // MARK: - Catalog integrity

    func testCatalogCarriesFortyEightUniquelyIdentifiedThemes() {
        let themes = LightingCatalog.themes
        XCTAssertEqual(themes.count, 48)
        XCTAssertEqual(Set(themes.map(\.id)).count, 48)
        XCTAssertEqual(Set(themes.map(\.name)).count, 48)
    }

    /// The original eighteen keep their identifiers, palettes, and brightness,
    /// so a favourite, a saved intent card, or a menu item still resolves.
    func testOriginalThemeIdentifiersAndPalettesAreUnchanged() throws {
        let original: [String: (colors: [UInt], brightness: Double)] = [
            "aurora": ([0x38E8D4, 0x6D7CFF, 0xB65CFF, 0x2EA9FF], 0.72),
            "afterglow": ([0xFFB36B, 0xFF6F61, 0xF24B88, 0x7B4BD4], 0.64),
            "tidepool": ([0x43E6D1, 0x27B9E8, 0x246BCE, 0x18438E], 0.68),
            "forest-bath": ([0x294F35, 0x3E8E58, 0x79C267, 0xD2C66D], 0.58),
            "wildflowers": ([0xFF5D6C, 0xB779FF, 0xFFD45A, 0x568CFF, 0xFF91C8], 0.76),
            "moon-garden": ([0xC7D5FF, 0x8299E8, 0x4D56A8, 0x8C68C8], 0.38),
            "ember": ([0x7D1D18, 0xD64724, 0xFF8A32, 0xFFC45B], 0.52),
            "candy-cloud": ([0xFF9EBB, 0x8FD8FF, 0xD5A6FF, 0xFFD0E5], 0.62),
            "synthwave": ([0xFF2E9A, 0x8A35FF, 0x1B8CFF, 0x24104F], 0.82),
            "arcade": ([0x00E5FF, 0x8CFF4D, 0xFF3B9D, 0xFFD43B], 0.86),
            "festival": ([0xD93A3A, 0xFFB52E, 0x2CAB6F, 0x8E44AD], 0.78),
            "ice-cream": ([0xA7E8A1, 0xFFD27D, 0xFF7BA8, 0x83B6FF], 0.72),
            "deep-work": ([0x3157C8, 0x397ED1, 0x4CB6C4], 0.66),
            "reading-nook": ([0xFFB45C, 0xFFD08A, 0xE58B3F], 0.58),
            "creative-spark": ([0xFF665A, 0xFFC83D, 0x2FD6C5, 0x6878FF], 0.78),
            "calm": ([0x9B8FD2, 0x7187B5, 0xC58FA8], 0.36),
            "desert": ([0xC75B3A, 0xD9A66F, 0x82936F, 0x3FA7A3], 0.64),
            "galaxy": ([0xEF4FA6, 0x8A4FFF, 0x3A75E8, 0x17123F], 0.68)
        ]
        for (id, expected) in original {
            let theme = try self.theme(id)
            XCTAssertEqual(theme.colors.map(\.hex), expected.colors, "palette changed for \(id)")
            XCTAssertEqual(theme.brightness, expected.brightness, accuracy: 0.0001, "brightness changed for \(id)")
        }
    }

    func testThirtyNewThemesWereAddedAcrossSixMoodFamilies() {
        let originals: Set<String> = [
            "aurora", "afterglow", "tidepool", "forest-bath", "wildflowers", "moon-garden",
            "ember", "candy-cloud", "synthwave", "arcade", "festival", "ice-cream",
            "deep-work", "reading-nook", "creative-spark", "calm", "desert", "galaxy"
        ]
        let added = LightingCatalog.themes.filter { !originals.contains($0.id) }
        XCTAssertEqual(added.count, 30)

        // Warm, natural, jewel, nightlife, dreamy, and everyday each get five.
        let families: [LightingTheme.Category] = [.warmth, .jewel, .nightlife, .dreamy, .everyday]
        for family in families {
            XCTAssertEqual(added.filter { $0.category == family }.count, 5,
                           "\(family.rawValue) should carry five new themes")
        }
        XCTAssertEqual(added.filter { $0.category == .nature }.count, 5,
                       "five new natural themes join the existing Nature mood")
    }

    func testEveryThemeIsDescribedAndPalettedForARoom() {
        for theme in LightingCatalog.themes {
            XCTAssertFalse(theme.name.isEmpty, "\(theme.id) has no name")
            XCTAssertFalse(theme.summary.isEmpty, "\(theme.id) has no summary")
            XCTAssertFalse(theme.icon.isEmpty, "\(theme.id) has no icon")
            XCTAssertTrue((3...5).contains(theme.colors.count),
                          "\(theme.id) has \(theme.colors.count) colours; three to five keeps a room legible")
            XCTAssertTrue((0.05...1.0).contains(theme.brightness), "\(theme.id) brightness out of range")
        }
    }

    func testNoTwoThemesShipTheSamePalette() {
        var seen: [Set<UInt>: String] = [:]
        for theme in LightingCatalog.themes {
            let key = Set(theme.colors.map(\.hex))
            if let clash = seen[key] {
                XCTFail("\(theme.id) duplicates \(clash)")
            }
            seen[key] = theme.id
        }
    }

    /// Under an even wash every fixture holds the first colour, so that colour
    /// has to be the palette's brightest — otherwise the room emits noticeably
    /// less than the theme's brightness says it will.
    func testWashThemesLeadWithTheirBrightestColour() {
        for theme in LightingCatalog.themes where theme.distribution == .wash {
            let levels = theme.colors.map(\.tone.level)
            let peak = levels.max() ?? 0
            XCTAssertGreaterThanOrEqual(levels[0] / peak, 0.85,
                                        "\(theme.id) washes the room with a colour dimmer than its own palette")
        }
    }

    // MARK: - Tone maths

    func testPaletteToneRoundTripsThroughItsOwnHex() {
        for hex: UInt in [0x000000, 0xFFFFFF, 0xFF0000, 0x12D9E8, 0x4A2340, 0x8A7560, 0xF7FAFD] {
            let tone = PaletteTone(hex: hex)
            XCTAssertEqual(tone.hex(atLevel: tone.level), UInt32(hex), "round trip failed for \(String(hex, radix: 16))")
        }
    }

    func testNormalisedTonesKeepInternalContrastWithoutGoingDark() throws {
        // Pocket Galaxy is anchored on nebula pink with a midnight shadow: the
        // shadow has to stay a shadow, and still emit something.
        let galaxy = try theme("galaxy")
        let tones = galaxy.normalizedTones
        XCTAssertEqual(tones.map(\.level).max() ?? 0, 1.0, accuracy: 0.001)
        XCTAssertLessThan(tones[3].level, tones[0].level, "midnight should sit under nebula pink")
        for theme in LightingCatalog.themes {
            for tone in theme.normalizedTones {
                XCTAssertGreaterThanOrEqual(tone.level, 0.2, "\(theme.id) has an entry that emits nothing")
                XCTAssertLessThanOrEqual(tone.level, 1.0)
            }
        }
    }

    func testBlendHoldsHueWhenOneEndIsAchromatic() {
        let white = PaletteTone(hex: 0xF7FAFD)   // saturation ~0.02
        let orange = PaletteTone(hex: 0xFF7A1F)
        let middle = PaletteTone.blend(white, orange, fraction: 0.5)
        XCTAssertEqual(middle.hue, orange.hue, accuracy: 0.001,
                       "a ramp into near-white must not detour through hues the palette never had")
        XCTAssertEqual(middle.saturation, (white.saturation + orange.saturation) / 2, accuracy: 0.001)
    }

    // MARK: - Distribution rules

    func testScatteredNeverRepeatsANeighbour() {
        for count in 2...8 {
            let sequence = (0..<60).map { ThemeDistribution.scattered.paletteIndex(position: $0, count: count) }
            for (a, b) in zip(sequence, sequence.dropFirst()) {
                XCTAssertNotEqual(a, b, "two neighbours share a colour at palette size \(count)")
            }
            XCTAssertEqual(Set(sequence).count, count, "palette size \(count) never uses every entry")
        }
    }

    func testAnchoredKeepsTheKeyOnMostFixtures() {
        let keyed = (0..<24).filter { ThemeDistribution.anchored.paletteIndex(position: $0, count: 4) == 0 }
        XCTAssertGreaterThanOrEqual(Double(keyed.count) / 24, 0.6)
        // Two lights still show two colours rather than a matched pair.
        XCTAssertEqual(ThemeDistribution.anchored.paletteIndex(position: 0, count: 4), 0)
        XCTAssertEqual(ThemeDistribution.anchored.paletteIndex(position: 1, count: 4), 1)
    }

    func testWashPutsTheKeyOnEveryFixtureAndAlternatingCycles() {
        for position in 0..<12 {
            XCTAssertEqual(ThemeDistribution.wash.paletteIndex(position: position, count: 4), 0)
            XCTAssertEqual(ThemeDistribution.alternating.paletteIndex(position: position, count: 4), position % 4)
        }
    }

    func testDistributionSharesSumToOneAndKeepEveryColourVisible() {
        for theme in LightingCatalog.themes {
            let shares = theme.distributionShares()
            XCTAssertEqual(shares.count, theme.colors.count, "\(theme.id)")
            XCTAssertEqual(shares.map(\.share).reduce(0, +), 1.0, accuracy: 0.0001, "\(theme.id)")
            for entry in shares {
                XCTAssertGreaterThan(entry.share, 0.01, "\(theme.id) hides a palette entry entirely")
            }
        }
        // An anchored theme has to read as one colour plus accents.
        let anchored = LightingCatalog.themes.first { $0.distribution == .anchored && $0.colors.count == 4 }
        XCTAssertGreaterThan(anchored?.distributionShares().first?.share ?? 0, 0.4)
    }

    // MARK: - One colour-capable bulb

    func testALoneBulbHoldsTheKeyColourAtTheThemesOwnBrightness() throws {
        // Emerald Study is anchored on a deep emerald that is far from the
        // palette's brightest entry; a single bulb should still light the room
        // at 46%, not at 46% of the emerald's own darkness.
        let emerald = try theme("emerald-study")
        let plan = ThemePlanner.plan(emerald, fixtures: [bulb("solo")])
        let fixture = try XCTUnwrap(plan.fixtures.first)

        XCTAssertEqual(fixture.adaptation, .solidOnly)
        XCTAssertEqual(fixture.brightness, emerald.brightness, accuracy: 0.0001)
        XCTAssertEqual(fixture.tone.hue, emerald.keyTone.hue, accuracy: 0.001)
        XCTAssertEqual(fixture.tone.saturation, emerald.keyTone.saturation, accuracy: 0.001)
        XCTAssertNil(fixture.segments)
        XCTAssertNil(fixture.matrix)
        XCTAssertNil(plan.adaptationSummary, "a room of one bulb is not an adaptation worth reporting")
    }

    func testEveryThemeLightsALoneBulbAtItsStatedBrightness() throws {
        for theme in LightingCatalog.themes {
            let plan = ThemePlanner.plan(theme, fixtures: [bulb("solo")])
            let fixture = try XCTUnwrap(plan.fixtures.first, theme.id)
            XCTAssertEqual(fixture.brightness, theme.brightness, accuracy: 0.0001, theme.id)
            XCTAssertGreaterThan(fixture.brightness, 0, theme.id)
        }
    }

    // MARK: - Several ordinary bulbs

    func testSeveralBulbsSpreadThePaletteRatherThanRepeatingOneColour() throws {
        let tokyo = try theme("tokyo-rain")   // scattered, four colours
        let ids = (0..<6).map { bulb("bulb-\($0)") }
        let plan = ThemePlanner.plan(tokyo, fixtures: ids)

        XCTAssertEqual(plan.fixtures.count, 6)
        let hues = Set(plan.fixtures.map { Int(($0.tone.hue * 360).rounded()) })
        XCTAssertGreaterThanOrEqual(hues.count, 3, "a scattered theme over six bulbs should show most of its palette")
        for (a, b) in zip(plan.fixtures, plan.fixtures.dropFirst()) {
            XCTAssertNotEqual(a.tone, b.tone, "neighbouring bulbs should not match under a scattered theme")
        }
    }

    func testAGradientThemeRampsAcrossBulbsFromFirstColourToLast() throws {
        let sapphire = try theme("sapphire-hour")
        let plan = ThemePlanner.plan(sapphire, fixtures: (0..<4).map { bulb("bulb-\($0)") })
        let tones = sapphire.normalizedTones

        XCTAssertEqual(plan.fixtures.first?.tone.saturation ?? 0, tones.first?.saturation ?? -1, accuracy: 0.01)
        XCTAssertEqual(plan.fixtures.last?.tone.saturation ?? 0, tones.last?.saturation ?? -1, accuracy: 0.01)
        // Sapphire Hour climbs toward a platinum highlight, so saturation falls.
        let saturations = plan.fixtures.map(\.tone.saturation)
        XCTAssertGreaterThan(saturations[0], saturations[3])
    }

    /// A dark palette entry has to arrive as full chroma plus a low brightness.
    /// Sending the authored hex instead lands differently on each brand: LIFX
    /// ignores how dark it was, Govee dims by it twice.
    func testDarkPaletteEntriesBecomeFullChromaPlusLowBrightness() throws {
        let galaxy = try theme("galaxy")
        // Anchored places its third accent at the eighth slot, so the midnight
        // shadow only lands in a room big enough to reach it.
        let plan = ThemePlanner.plan(galaxy, fixtures: (0..<8).map { bulb("bulb-\($0)") })
        let midnight = try XCTUnwrap(plan.fixtures.min { $0.brightness < $1.brightness })

        XCTAssertLessThan(midnight.brightness, galaxy.brightness * 0.5, "the midnight anchor should burn low")
        XCTAssertGreaterThan(midnight.brightness, 0.02, "and still emit")
        let rgb = midnight.tone.rgb(atLevel: 1)
        XCTAssertEqual(max(rgb.red, max(rgb.green, rgb.blue)), 1.0, accuracy: 0.001,
                       "chroma travels at full value; level rides the brightness channel")
    }

    // MARK: - Govee segments

    func testAStripCarriesTheWholePaletteAndBlendsOnlyWhenTheThemeWantsIt() throws {
        let glacier = try theme("glacier-melt")           // gradient
        let acid = try theme("acid-house")                // alternating

        let ramped = ThemePlanner.plan(glacier, fixtures: [strip("strip")])
        let segments = try XCTUnwrap(ramped.fixtures.first?.segments)
        XCTAssertEqual(segments.segmentCount, 15)
        XCTAssertTrue(segments.gradient, "a ramp should let the hardware blend")
        XCTAssertTrue(segments.isActive)
        XCTAssertEqual(ramped.fixtures.first?.adaptation, .spatial)
        XCTAssertGreaterThan(Set(segments.colors.map(\.packetKey)).count, 4,
                             "a fifteen-segment ramp should be more than a couple of colours")

        let blocked = ThemePlanner.plan(acid, fixtures: [strip("strip")])
        let crisp = try XCTUnwrap(blocked.fixtures.first?.segments)
        XCTAssertFalse(crisp.gradient, "alternating blocks lose their point if the hardware smears them")
        XCTAssertEqual(Set(crisp.colors.map(\.packetKey)).count, 4)
    }

    /// A 200-bead string light would otherwise turn a smooth ramp into 200 LAN
    /// packets on the durable write path.
    func testLongStripsQuantiseTheRampIntoABoundedPacketBatch() throws {
        let cocoa = try theme("cocoa-rose")
        let plan = ThemePlanner.plan(cocoa, fixtures: [strip("string", count: 200, gradient: false)])
        let segments = try XCTUnwrap(plan.fixtures.first?.segments)

        XCTAssertEqual(segments.segmentCount, 200)
        XCTAssertLessThanOrEqual(segments.colorGroups.count, ThemePlanner.maximumGradientStops)
        XCTAssertGreaterThan(segments.colorGroups.count, 4, "still recognisably a ramp")
        XCTAssertTrue(segments.colors.allSatisfy(\.isOn))
    }

    func testTwoIdenticalStripsDoNotComeOutAsCopies() throws {
        let last = try theme("last-call")   // scattered
        let plan = ThemePlanner.plan(last, fixtures: [strip("a"), strip("b")])
        let first = try XCTUnwrap(plan.fixtures.first?.segments)
        let second = try XCTUnwrap(plan.fixtures.last?.segments)
        XCTAssertNotEqual(first.colors.map(\.packetKey), second.colors.map(\.packetKey))
    }

    func testSegmentBrightnessCarriesThePaletteEntrysOwnLevel() throws {
        let nightlight = try theme("nightlight")
        let plan = ThemePlanner.plan(nightlight, fixtures: [strip("strip")])
        let segments = try XCTUnwrap(plan.fixtures.first?.segments)
        let levels = Set(segments.colors.map { Int(($0.brightness * 100).rounded()) })

        XCTAssertGreaterThan(levels.count, 1, "an anchored palette with a shadow should vary along the strip")
        XCTAssertTrue(segments.colors.allSatisfy { $0.brightness >= 0.2 },
                      "no segment should be asked to emit nothing")
        XCTAssertEqual(plan.fixtures.first?.brightness ?? 0, nightlight.brightness, accuracy: 0.0001,
                       "the fixture's own brightness stays the theme's")
    }

    // MARK: - LIFX matrices

    func testLunaPaintsItsTwentySixZonesAndLeavesTheCornersAlone() throws {
        let amethyst = try theme("amethyst-court")
        let plan = ThemePlanner.plan(amethyst, fixtures: [luna("luna")])
        let matrix = try XCTUnwrap(plan.fixtures.first?.matrix)

        XCTAssertEqual(matrix.zoneCount, 26)
        XCTAssertEqual(plan.fixtures.first?.adaptation, .spatial)
        for zone in matrix.activeZoneIndices {
            XCTAssertGreaterThan(matrix.colors[zone].brightness, 0, "zone \(zone) was left dark")
        }
        let corners = [0, 4, 25, 29]
        for corner in corners {
            XCTAssertEqual(matrix.colors[corner].brightness, 0,
                           "cell \(corner) is outside Luna's diffuser and is the firmware's to own")
        }
        XCTAssertEqual(matrix.colors.count, 64, "Set64 always transports 64 values")
    }

    func testMatrixZonesFoldTheThemeBrightnessIntoTheirOwnChannel() throws {
        let ruby = try theme("ruby-velvet")
        let plan = ThemePlanner.plan(ruby, fixtures: [luna("luna")])
        let matrix = try XCTUnwrap(plan.fixtures.first?.matrix)
        let brightest = matrix.activeZoneIndices.map { Double(matrix.colors[$0].brightness) / 65_535 }.max() ?? 0

        XCTAssertEqual(brightest, ruby.brightness, accuracy: 0.01,
                       "the brightest zone should burn at the theme's brightness, no more")
    }

    // MARK: - Fixtures that cannot run every zone

    func testAZoneLimitedLampLightsOnlyWhatItCanShow() throws {
        let brass = try theme("brass-smoke")
        let plan = ThemePlanner.plan(brass, fixtures: [uplighter("lamp")])
        let fixture = try XCTUnwrap(plan.fixtures.first)
        let segments = try XCTUnwrap(fixture.segments)

        XCTAssertEqual(fixture.adaptation, .zoneLimited(lit: 2, of: 3))
        XCTAssertEqual(segments.poweredCount, 2)
        XCTAssertEqual(segments.poweredSegments, [0, 1])
        XCTAssertEqual(plan.adaptationSummary, "one fixture lights 2 of its 3 zones.")
    }

    func testAZoneLimitedLampKeepsTheZonesTheUserAlreadyHasLit() throws {
        let brass = try theme("brass-smoke")
        let plan = ThemePlanner.plan(brass, fixtures: [uplighter("lamp", preferred: [2, 0])])
        let segments = try XCTUnwrap(plan.fixtures.first?.segments)

        XCTAssertEqual(segments.poweredSegments, [0, 2],
                       "a theme should not move which zones of a lamp are running")
    }

    // MARK: - Mixed-capability groups

    func testAMixedRoomPlansEveryFixtureAndSaysWhatEachCouldShow() throws {
        let kelp = try theme("kelp-forest")
        let fixtures = [bulb("bulb-1"), strip("strip-1"), luna("luna-1"), bulb("bulb-2"), uplighter("lamp-1")]
        let plan = ThemePlanner.plan(kelp, fixtures: fixtures)

        XCTAssertEqual(plan.fixtures.count, 5)
        XCTAssertEqual(plan.fixtures.map(\.fixtureID), fixtures.map(\.id), "order is the room's order")
        XCTAssertEqual(plan.solidCount, 2)
        XCTAssertEqual(plan.spatialCount, 2)
        XCTAssertEqual(plan.zoneLimitedCount, 1)

        let summary = try XCTUnwrap(plan.adaptationSummary)
        XCTAssertTrue(summary.contains("2 single-colour lights hold one palette colour each"), summary)
        XCTAssertTrue(summary.contains("lights 2 of its 3 zones"), summary)

        XCTAssertNil(plan.fixtures[0].segments)
        XCTAssertNotNil(plan.fixtures[1].segments)
        XCTAssertNotNil(plan.fixtures[2].matrix)
        XCTAssertNil(plan.fixtures[2].segments)
    }

    func testAnAllSolidRoomReportsNoAdaptationAtAll() throws {
        let supper = try theme("supper-table")
        let plan = ThemePlanner.plan(supper, fixtures: (0..<5).map { bulb("bulb-\($0)") })
        XCTAssertNil(plan.adaptationSummary, "a room of ordinary bulbs is a normal room, not a downgrade")
    }

    func testEveryThemeProducesASendablePlanForEveryCapabilityMix() {
        let rooms: [[ThemeFixture]] = [
            [bulb("only")],
            (0..<2).map { bulb("b\($0)") },
            (0..<7).map { bulb("b\($0)") },
            [strip("cob", count: 15), strip("neon", count: 20, gradient: true)],
            [strip("string", count: 200, gradient: false)],
            [luna("luna")],
            [uplighter("lamp")],
            [bulb("b"), strip("s"), luna("l"), uplighter("u")]
        ]
        for theme in LightingCatalog.themes {
            for room in rooms {
                let plan = ThemePlanner.plan(theme, fixtures: room)
                XCTAssertEqual(plan.fixtures.count, room.count, "\(theme.id)")
                for fixture in plan.fixtures {
                    XCTAssertTrue(fixture.brightness.isFinite && fixture.brightness > 0 && fixture.brightness <= 1,
                                  "\(theme.id)/\(fixture.fixtureID) brightness \(fixture.brightness)")
                    XCTAssertTrue(fixture.tone.hue >= 0 && fixture.tone.hue <= 1, "\(theme.id)")
                    XCTAssertTrue((1_500...9_000).contains(fixture.kelvin), "\(theme.id) kelvin \(fixture.kelvin)")
                    if let segments = fixture.segments {
                        XCTAssertFalse(segments.isFullyDark, "\(theme.id)/\(fixture.fixtureID) would light nothing")
                        XCTAssertTrue(segments.colors.allSatisfy { $0.brightness > 0 }, "\(theme.id)")
                    }
                    if let matrix = fixture.matrix {
                        XCTAssertTrue(matrix.activeZoneIndices.allSatisfy { matrix.colors[$0].brightness > 0 },
                                      "\(theme.id) left a Luna zone dark")
                    }
                }
            }
        }
    }

    func testAnEmptyRoomPlansNothingRatherThanCrashing() throws {
        let plan = ThemePlanner.plan(try theme("aurora"), fixtures: [])
        XCTAssertTrue(plan.fixtures.isEmpty)
        XCTAssertNil(plan.adaptationSummary)
    }

    // MARK: - White points for near-white themes

    func testNearWhiteThemesCarryAWhitePointSoLIFXRendersThemAsAuthored() throws {
        // Below the saturation floor, a LIFX bulb renders from kelvin rather
        // than hue, so a warm everyday theme has to say which white it means.
        let warm = try theme("kitchen-noon")
        let cool = try theme("morning-desk")
        let warmPlan = ThemePlanner.plan(warm, fixtures: [bulb("b", kelvin: 6_500)])
        let coolPlan = ThemePlanner.plan(cool, fixtures: [bulb("b", kelvin: 2_200)])

        XCTAssertLessThanOrEqual(try XCTUnwrap(warmPlan.fixtures.first).kelvin, 3_200)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(coolPlan.fixtures.first).kelvin, 5_000)
    }

    func testSaturatedThemesLeaveTheBulbsWhitePointAlone() throws {
        let acid = try theme("acid-house")
        let plan = ThemePlanner.plan(acid, fixtures: [bulb("b", kelvin: 4_321)])
        XCTAssertEqual(try XCTUnwrap(plan.fixtures.first).kelvin, 4_321,
                       "kelvin is ignored by firmware at high saturation; don't churn the user's setting")
    }

    // MARK: - Scene capture and restore

    /// Scenes store hue, saturation, and brightness separately, and restore by
    /// rebuilding the colour at full value. A theme that splits chroma from
    /// level the same way survives capture and restore unchanged.
    func testThemeColoursSurviveASceneSnapshotRoundTrip() throws {
        for id in ["mulled-wine", "tokyo-rain", "sea-glass", "emerald-study", "galaxy"] {
            let theme = try self.theme(id)
            let plan = ThemePlanner.plan(theme, fixtures: (0..<4).map { bulb("b\($0)") })
            for fixture in plan.fixtures {
                let captured = fixture.tone.displayColor.hsbComponents
                let snapshot = DeviceSnapshot(isOn: true, brightness: fixture.brightness,
                                              hue: captured.h, saturation: captured.s,
                                              kelvin: fixture.kelvin)
                // What capture reads back is the tone itself: sRGB in, sRGB out.
                XCTAssertEqual(captured.s, fixture.tone.saturation, accuracy: 0.01, "\(id) saturation lost on capture")
                if fixture.tone.saturation > 0.05 {
                    XCTAssertEqual(captured.h, fixture.tone.hue, accuracy: 0.01, "\(id) hue lost on capture")
                }
                XCTAssertEqual(snapshot.brightness, fixture.brightness, accuracy: 0.0001, "\(id) brightness drifted")

                // And restore rebuilds chroma at full value the way applyScene
                // does. The looser tolerance here is for the platform's own HSB
                // initialiser, not for the theme maths.
                let restored = Color(hue: snapshot.hue, saturation: snapshot.saturation, brightness: 1).hsbComponents
                XCTAssertEqual(restored.s, fixture.tone.saturation, accuracy: 0.03, "\(id) saturation drifted")
                if fixture.tone.saturation > 0.05 {
                    XCTAssertEqual(restored.h, fixture.tone.hue, accuracy: 0.03, "\(id) hue drifted")
                }
                XCTAssertEqual(restored.b, 1.0, accuracy: 0.03, "restore rebuilds chroma at full value")
            }
        }
    }

    // MARK: - Music Mode palettes

    func testEveryCatalogThemeIsSelectableAsAMusicPalette() {
        for theme in LightingCatalog.themes {
            var configuration = MusicModeConfiguration.configuration(for: .balanced)
            configuration.selectPalette(theme.id)
            XCTAssertEqual(configuration.palette, theme.musicPalette, theme.id)
            XCTAssertEqual(configuration.paletteIdentity, theme.id, theme.id)
            XCTAssertEqual(configuration.preset, .custom, theme.id)
        }
    }

    /// The one rule that matters most here: a palette is colour and nothing
    /// else. Choosing a theme must never be a back door to flashing light.
    func testSelectingAPaletteNeverTouchesFlashSettings() {
        for theme in LightingCatalog.themes {
            var safe = MusicModeConfiguration.configuration(for: .ambient)
            safe.photosensitivitySafeMode = true
            safe.allowsFlashes = false
            safe.flashIntensity = 0
            safe.maximumFlashFrequency = 0
            safe.selectPalette(theme.id)

            XCTAssertTrue(safe.photosensitivitySafeMode, theme.id)
            XCTAssertFalse(safe.allowsFlashes, theme.id)
            XCTAssertEqual(safe.flashIntensity, 0, theme.id)
            XCTAssertEqual(safe.maximumFlashFrequency, 0, theme.id)

            // And a user who already opted in keeps their own limits.
            var opted = MusicModeConfiguration.configuration(for: .concert)
            opted.photosensitivitySafeMode = false
            opted.allowsFlashes = true
            opted.flashIntensity = 0.5
            opted.maximumFlashFrequency = 2
            let before = opted
            opted.selectPalette(theme.id)

            XCTAssertEqual(opted.allowsFlashes, before.allowsFlashes, theme.id)
            XCTAssertEqual(opted.flashIntensity, before.flashIntensity, theme.id)
            XCTAssertEqual(opted.maximumFlashFrequency, before.maximumFlashFrequency, theme.id)
            XCTAssertEqual(opted.photosensitivitySafeMode, before.photosensitivitySafeMode, theme.id)
        }
    }

    func testSelectingAPaletteLeavesTimingAndMovementToThePreset() {
        var configuration = MusicModeConfiguration.configuration(for: .cinematic)
        let before = configuration
        configuration.selectPalette("chrome-bass")

        XCTAssertEqual(configuration.movementAmount, before.movementAmount)
        XCTAssertEqual(configuration.movementSpeed, before.movementSpeed)
        XCTAssertEqual(configuration.movementDirection, before.movementDirection)
        XCTAssertEqual(configuration.beatSensitivity, before.beatSensitivity)
        XCTAssertEqual(configuration.effectIntensity, before.effectIntensity)
        XCTAssertEqual(configuration.colorChangeIntensity, before.colorChangeIntensity)
        XCTAssertEqual(configuration.masterBrightness, before.masterBrightness)
    }

    func testTheBuiltInAndLegacyPalettesStillResolve() {
        for entry in MusicModeConfiguration.builtInPalettes {
            var configuration = MusicModeConfiguration()
            configuration.selectPalette(entry.id)
            XCTAssertEqual(configuration.paletteIdentity, entry.id)
        }
        // Saved archives that carry the old Aurora palette by value now resolve
        // to the Aurora Veil theme, whose colours are identical.
        var legacy = MusicModeConfiguration()
        legacy.palette = MusicModeConfiguration.auroraPalette
        XCTAssertEqual(legacy.paletteIdentity, "aurora")
    }

    func testAHandEditedPaletteReportsItselfAsCustom() {
        var configuration = MusicModeConfiguration()
        configuration.palette = [MusicPaletteColor(0x010203), MusicPaletteColor(0x040506)]
        XCTAssertEqual(configuration.paletteIdentity, "custom")

        // An unknown selector is a no-op rather than a way to lose the palette.
        let before = configuration.palette
        configuration.selectPalette("not-a-theme")
        XCTAssertEqual(configuration.palette, before)
    }

    func testMusicPalettesKeepEachThemesChroma() {
        for theme in LightingCatalog.themes {
            XCTAssertEqual(theme.musicPalette.count, theme.colors.count, theme.id)
            for (entry, swatch) in zip(theme.musicPalette, theme.colors) {
                XCTAssertEqual(UInt(entry.hex), swatch.hex, theme.id)
            }
        }
    }

    func testNoTwoThemesCollideAsMusicPalettes() {
        var seen: [[UInt32]: String] = [:]
        for theme in LightingCatalog.themes {
            let key = theme.musicPalette.map(\.hex)
            if let clash = seen[key] { XCTFail("\(theme.id) and \(clash) are the same music palette") }
            seen[key] = theme.id
        }
    }
}

import Foundation

// MARK: - Room planning
//
// Plan puts the room at the centre of the screen. Discovery hands the app a
// vendor, a model, an address, and whatever name someone typed into a phone
// app two years ago. It never says what rooms exist, which fixture is in
// which, where those rooms sit relative to each other, or where a lamp stands
// inside one.
//
// This file answers the first and third of those, and supplies the defaults
// for the fourth. The second one no algorithm can answer, so the interface
// flashes the bulb and asks.
//
// Everything here is pure: no SwiftUI, no LightManager, no device access. It
// takes values and returns values, which is what makes it testable.

// MARK: - Geometry

/// Where a room's block sits on the plan board, measured in whole grid cells
/// with the origin at the top-leading corner.
///
/// Whole cells rather than free coordinates, because the board is a seating
/// chart. Free placement invites people to fiddle towards an accuracy the
/// model does not have, and snapping keeps two blocks from ending up three
/// points apart and looking like a rendering fault.
struct RoomPlanFrame: Codable, Equatable, Hashable {
    var column: Int
    var row: Int
    var width: Int
    var height: Int

    init(column: Int, row: Int, width: Int = 1, height: Int = 1) {
        self.column = column
        self.row = row
        self.width = max(1, width)
        self.height = max(1, height)
    }

    var maxColumn: Int { column + width }
    var maxRow: Int { row + height }

    func intersects(_ other: RoomPlanFrame) -> Bool {
        column < other.maxColumn && maxColumn > other.column &&
        row < other.maxRow && maxRow > other.row
    }
}

/// Where a fixture stands inside its room's block, as a fraction of the block
/// in each axis. Fractions rather than points so a block can be resized
/// without the lamps inside it sliding out of the room.
struct PlanAnchor: Codable, Equatable, Hashable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = min(0.94, max(0.06, x))
        self.y = min(0.94, max(0.06, y))
    }
}

// MARK: - Layout

/// Auto-layout and validity rules for the plan board.
enum PlanLayout {

    /// The board is a fixed six columns wide and grows downward. Width is
    /// bounded by the window; height can scroll.
    static let columns = 6
    /// Never present a board shorter than this, so a two-room home still
    /// reads as a plan rather than as a pair of buttons.
    static let minimumRows = 4

    /// A room's default footprint. Area tracks fixture count, so the board
    /// carries information before anyone has touched it: a four-lamp living
    /// room is visibly bigger than a one-lamp hallway.
    static func defaultSpan(fixtureCount: Int) -> (width: Int, height: Int) {
        switch fixtureCount {
        case ...1:  return (1, 1)
        case 2...3: return (2, 1)
        case 4...6: return (2, 2)
        default:    return (3, 2)
        }
    }

    /// Lay every room out from scratch, largest first, packed into the first
    /// free space that fits.
    ///
    /// Deterministic for a given input: the same rooms in the same order
    /// always produce the same board, so a plan does not rearrange itself
    /// between launches. That stability is the entire premise of the
    /// direction — a kitchen that moves is a kitchen you have to re-learn.
    static func autoArrange(_ rooms: [(id: UUID, fixtureCount: Int)]) -> [UUID: RoomPlanFrame] {
        // Sort by size descending, breaking ties by the caller's order so the
        // result never depends on Dictionary or Set iteration order.
        let ordered = rooms.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.fixtureCount != rhs.element.fixtureCount {
                    return lhs.element.fixtureCount > rhs.element.fixtureCount
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        var frames: [UUID: RoomPlanFrame] = [:]
        var placed: [RoomPlanFrame] = []

        for room in ordered {
            let span = defaultSpan(fixtureCount: room.fixtureCount)
            let frame = firstFreeFrame(width: span.width, height: span.height, among: placed)
                ?? firstFreeFrame(width: 1, height: 1, among: placed)
                ?? RoomPlanFrame(column: 0, row: nextEmptyRow(after: placed))
            frames[room.id] = frame
            placed.append(frame)
        }
        return frames
    }

    /// Scans left to right, top to bottom, for the first space the footprint
    /// fits in. The board is unbounded downward, so this only returns nil if
    /// the footprint is wider than the board.
    static func firstFreeFrame(width: Int, height: Int,
                               among placed: [RoomPlanFrame]) -> RoomPlanFrame? {
        guard width <= columns else { return nil }
        let searchRows = (placed.map(\.maxRow).max() ?? 0) + height
        for row in 0...max(0, searchRows) {
            for column in 0...(columns - width) {
                let candidate = RoomPlanFrame(column: column, row: row, width: width, height: height)
                if !placed.contains(where: { $0.intersects(candidate) }) { return candidate }
            }
        }
        return nil
    }

    private static func nextEmptyRow(after placed: [RoomPlanFrame]) -> Int {
        (placed.map(\.maxRow).max() ?? 0)
    }

    /// Whether a frame may be committed for `roomID`.
    ///
    /// A drop that would overlap is refused rather than resolved. Silently
    /// reflowing a board somebody arranged by hand destroys the spatial
    /// memory the whole direction is selling, so the interface says no and
    /// leaves the block where it was.
    static func canPlace(_ frame: RoomPlanFrame,
                         for roomID: UUID,
                         among frames: [UUID: RoomPlanFrame]) -> Bool {
        guard frame.column >= 0, frame.row >= 0,
              frame.width >= 1, frame.height >= 1,
              frame.maxColumn <= columns else { return false }
        for (otherID, other) in frames where otherID != roomID {
            if other.intersects(frame) { return false }
        }
        return true
    }

    /// How tall the board has to be drawn to hold everything on it.
    static func rowCount(for frames: [UUID: RoomPlanFrame]) -> Int {
        max(minimumRows, frames.values.map(\.maxRow).max() ?? 0)
    }

    /// Where a room's fixtures stand before anyone drags one.
    ///
    /// Spread along the width and alternated between two depth bands, so two
    /// lamps never sit on top of each other and their pools stay legible.
    /// Deterministic by index for the same reason the board is: the dots have
    /// to be in the same place tomorrow.
    static func defaultAnchors(count: Int) -> [PlanAnchor] {
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            PlanAnchor(x: Double(index + 1) / Double(count + 1),
                       y: index.isMultiple(of: 2) ? 0.38 : 0.64)
        }
    }
}

// MARK: - Name parsing

/// Reads the room out of a fixture's name, when there is one to read.
///
/// Most people already typed a room into their vendor app: "Kitchen Counter
/// L", "Bed Left", "TV Backlight". Sorting those automatically is the
/// difference between a setup that takes one minute and one that takes ten,
/// and a wrong guess costs a single tap to reject.
enum RoomNameParser {

    /// Rooms in match order. The first room with a matching token wins, so
    /// more specific rooms come before more general ones.
    static let vocabulary: [(room: String, tokens: [String])] = [
        ("Kitchen",     ["kitchen", "counter", "cabinet", "pantry", "island", "stove", "fridge"]),
        ("Living Room", ["living", "lounge", "tv", "sofa", "couch", "family", "sitting", "media"]),
        ("Bedroom",     ["bed", "bedroom", "nightstand", "headboard", "master"]),
        ("Office",      ["office", "desk", "study", "monitor", "key light", "keylight", "workstation"]),
        ("Bathroom",    ["bath", "shower", "vanity", "mirror", "ensuite"]),
        ("Dining",      ["dining", "dinner"]),
        ("Hallway",     ["hall", "corridor", "entry", "foyer", "stairs", "landing"]),
        ("Outdoor",     ["outdoor", "patio", "deck", "porch", "garden", "yard", "balcony", "eave"]),
        ("Garage",      ["garage", "workshop", "shed"]),
        ("Nursery",     ["nursery", "baby", "kids", "playroom"])
    ]

    struct Candidate: Equatable {
        let room: String
        /// The token that matched, so the interface can show its reasoning
        /// instead of asking to be trusted.
        let token: String
    }

    /// The room a name suggests, with the token that suggested it.
    static func candidate(for name: String) -> Candidate? {
        let normalized = normalize(name)
        guard !normalized.isEmpty else { return nil }
        let words = normalized.split(separator: " ").map(String.init)

        for entry in vocabulary {
            for token in entry.tokens where matches(token: token, words: words, phrase: normalized) {
                return Candidate(room: entry.room, token: token)
            }
        }
        return nil
    }

    /// Lowercased, with every non-alphanumeric run collapsed to a single
    /// space, so "Kitchen-Counter_L" and "Kitchen Counter L" read alike.
    static func normalize(_ name: String) -> String {
        let scalars = name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    /// Multi-word tokens match the phrase. Single words match a whole word,
    /// or a prefix of one when the token is long enough to be safe — "bed"
    /// should catch "bedroom", while "tv" must never catch a model number
    /// that happens to contain those letters.
    private static func matches(token: String, words: [String], phrase: String) -> Bool {
        if token.contains(" ") { return phrase.contains(token) }
        if words.contains(token) { return true }
        guard token.count >= 3 else { return false }
        return words.contains { $0.count > token.count && $0.hasPrefix(token) }
    }

    /// A room the parser is proposing, with the fixtures that landed in it.
    struct Proposal: Equatable {
        var name: String
        var token: String
        var lightIDs: [String]
    }

    /// Group fixtures into proposed rooms by name.
    ///
    /// A token that would produce a room of one is deliberately discarded: a
    /// fixture called "Closet" is not evidence that a Closet room exists, and
    /// "no guess" is a better answer than a room the user has to go and
    /// delete. Those fixtures fall through to the identify flash instead,
    /// which is where the real answer lives anyway.
    static func proposals(for lights: [(id: String, name: String)],
                          minimumMembers: Int = 2) -> [Proposal] {
        var order: [String] = []
        var byRoom: [String: Proposal] = [:]

        for light in lights {
            guard let candidate = candidate(for: light.name) else { continue }
            if byRoom[candidate.room] == nil {
                order.append(candidate.room)
                byRoom[candidate.room] = Proposal(name: candidate.room,
                                                  token: candidate.token,
                                                  lightIDs: [])
            }
            byRoom[candidate.room]?.lightIDs.append(light.id)
        }

        return order.compactMap { room in
            guard let proposal = byRoom[room],
                  proposal.lightIDs.count >= minimumMembers else { return nil }
            return proposal
        }
    }
}

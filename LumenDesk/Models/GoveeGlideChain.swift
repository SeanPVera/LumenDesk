import Foundation
import CoreGraphics

// MARK: - Govee Glide (H6062) bar layout
//
// The Glide kit is straight bars and corner pieces clicked together in any
// order and chained from one controller. The controller doesn't report the
// arrangement over LAN (its status reply has no layout field, and Govee's
// own platform API only lists segment indices), so the person declares it
// once and LumenDesk keeps it per light.
//
// Piece sizes come from SignalRGB's Govee direct-connect H6062 component
// map (fu-raz/signalrgb-govee-direct-connect, Components/H6062-*.json):
// 9 LEDs per straight bar, 3 per corner, numbered along the chain.
// The controller's 28 LAN segments (0–27, as Govee's platform API reports
// for this model) are spread along those LEDs in chain order, so painting
// a piece writes the real segments that cover it.

enum GlidePiece: String, Codable, Equatable, CaseIterable {
    case bar
    case cornerLeft
    case cornerRight

    var ledCount: Int {
        switch self {
        case .bar: return GlideChain.ledsPerBar
        case .cornerLeft, .cornerRight: return GlideChain.ledsPerCorner
        }
    }

    var isCorner: Bool { self != .bar }

    var shortName: String {
        switch self {
        case .bar: return "Bar"
        case .cornerLeft: return "Corner ↰"
        case .cornerRight: return "Corner ↱"
        }
    }
}

struct GlideChain: Codable, Equatable {
    static let ledsPerBar = 9
    static let ledsPerCorner = 3

    var pieces: [GlidePiece]

    /// The 6 + 1 kit: six bars with the corner after the third (an L).
    static let kitSixPlusOne = GlideChain(pieces: [.bar, .bar, .bar, .cornerRight, .bar, .bar, .bar])
    /// The 8 + 4 kit as a closed-looking frame: two bars per side.
    static let kitEightPlusFour = GlideChain(pieces: [.bar, .bar, .cornerRight, .bar, .bar, .cornerRight,
                                                      .bar, .bar, .cornerRight, .bar, .bar, .cornerRight])

    var ledCount: Int { pieces.reduce(0) { $0 + $1.ledCount } }
    var barCount: Int { pieces.filter { !$0.isCorner }.count }

    /// Display label: "Bar 2", "Corner 1".
    func label(_ index: Int) -> String {
        guard pieces.indices.contains(index) else { return "" }
        let piece = pieces[index]
        let ordinal = pieces[...index].filter { $0.isCorner == piece.isCorner }.count
        return piece.isCorner ? "Corner \(ordinal)" : "Bar \(ordinal)"
    }

    /// The controller segments covering each piece, in chain order. Each
    /// piece gets the segments whose span overlaps its LEDs the most, so
    /// every segment belongs to exactly one piece and pieces never overlap.
    /// With fewer segments than pieces some pieces get none.
    func segmentRanges(segmentCount: Int) -> [Range<Int>] {
        let leds = ledCount
        guard segmentCount > 0, leds > 0 else { return pieces.map { _ in 0..<0 } }
        // Segment s covers LEDs [s·N/Z, (s+1)·N/Z); assign it to the piece
        // containing its midpoint.
        var starts: [Int] = []
        var acc = 0
        for piece in pieces { starts.append(acc); acc += piece.ledCount }
        var owner = [Int](repeating: 0, count: segmentCount)
        for s in 0..<segmentCount {
            let mid = (Double(s) + 0.5) * Double(leds) / Double(segmentCount)
            var index = 0
            for (i, start) in starts.enumerated() where Double(start) <= mid { index = i }
            owner[s] = index
        }
        return pieces.indices.map { piece in
            let owned = owner.indices.filter { owner[$0] == piece }
            guard let first = owned.first, let last = owned.last else { return 0..<0 }
            return first..<(last + 1)
        }
    }

    /// Pieces as drawable rectangles in unit space (a bar is 1 long). The
    /// chain starts at the controller heading right; a corner turns the
    /// heading 90° left or right. Returns each piece's start and end point.
    func geometry() -> [(start: CGPoint, end: CGPoint)] {
        var point = CGPoint.zero
        var heading = CGVector(dx: 1, dy: 0)
        var result: [(CGPoint, CGPoint)] = []
        for piece in pieces {
            let length: CGFloat = piece.isCorner ? 0.34 : 1
            switch piece {
            case .bar:
                let end = CGPoint(x: point.x + heading.dx * length, y: point.y + heading.dy * length)
                result.append((point, end))
                point = end
            case .cornerLeft, .cornerRight:
                // Half the corner along the old heading, half along the new.
                let half = length / 2
                let mid = CGPoint(x: point.x + heading.dx * half, y: point.y + heading.dy * half)
                // Screen coordinates: y grows downward, so "left" is −90°.
                heading = piece == .cornerLeft
                    ? CGVector(dx: heading.dy, dy: -heading.dx)
                    : CGVector(dx: -heading.dy, dy: heading.dx)
                let end = CGPoint(x: mid.x + heading.dx * half, y: mid.y + heading.dy * half)
                result.append((point, end))
                point = end
            }
        }
        return result
    }
}

/// Where each Glide light's declared layout is kept (per light, on this Mac).
enum GlideChainStore {
    static func key(for deviceID: String) -> String { "LumenDesk.glideChain.\(deviceID)" }

    static func load(deviceID: String, defaults: UserDefaults = .standard) -> GlideChain? {
        guard let data = defaults.data(forKey: key(for: deviceID)) else { return nil }
        return try? JSONDecoder().decode(GlideChain.self, from: data)
    }

    static func save(_ chain: GlideChain?, deviceID: String, defaults: UserDefaults = .standard) {
        guard let chain, let data = try? JSONEncoder().encode(chain) else {
            defaults.removeObject(forKey: key(for: deviceID))
            return
        }
        defaults.set(data, forKey: key(for: deviceID))
    }
}

// MARK: - White point mixed from RGB

enum KelvinRGB {
    /// sRGB approximation of a black-body white point (Tanner Helland's fit),
    /// 0…1 per channel. Used for fixtures whose LEDs are RGB only, so a white
    /// point has to be mixed from colour.
    static func components(_ kelvin: Int) -> (red: Double, green: Double, blue: Double) {
        let temperature = Double(min(40_000, max(1_000, kelvin))) / 100
        func clamp(_ value: Double) -> Double { min(255, max(0, value)) / 255 }
        let red = temperature <= 66 ? 255 : 329.698727446 * pow(temperature - 60, -0.1332047592)
        let green = temperature <= 66
            ? 99.4708025861 * log(temperature) - 161.1195681661
            : 288.1221695283 * pow(temperature - 60, -0.0755148492)
        let blue = temperature >= 66 ? 255
            : (temperature <= 19 ? 0 : 138.5177312231 * log(temperature - 10) - 305.0447927307)
        return (clamp(red), clamp(green), clamp(blue))
    }

    /// The white point in `range` whose mixed RGB is closest to the given
    /// colour (chromaticity only, so a dim white still reads as its Kelvin).
    /// Used where a fixture takes Kelvin only, such as the H60B0 down light.
    static func nearestKelvin(red: Double, green: Double, blue: Double,
                              in range: ClosedRange<Int> = 2_700...6_500) -> Int {
        let peak = max(red, green, blue, 0.0001)
        let target = (red / peak, green / peak, blue / peak)
        var best = range.lowerBound
        var bestDistance = Double.greatestFiniteMagnitude
        for kelvin in stride(from: range.lowerBound, through: range.upperBound, by: 100) {
            let c = components(kelvin)
            let cPeak = max(c.red, c.green, c.blue, 0.0001)
            let d = pow(c.red / cPeak - target.0, 2) + pow(c.green / cPeak - target.1, 2)
                + pow(c.blue / cPeak - target.2, 2)
            if d < bestDistance { bestDistance = d; best = kelvin }
        }
        return best
    }
}

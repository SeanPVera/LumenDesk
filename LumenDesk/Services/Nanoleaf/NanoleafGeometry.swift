import Foundation

/// A point in one of the three spaces the Shapes editor works in: the
/// controller's layout space, the wall view, or the canvas on screen. The
/// type is shared; which space a value is in is always named at the call.
struct NanoleafPoint: Equatable, Hashable, Codable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

// MARK: - Panel outlines

enum NanoleafGeometry {
    /// A light panel's outline in the controller's layout space (y up),
    /// counter-clockwise. Nil for anything that is not a Shapes light panel.
    ///
    /// The vertex convention is the one Nanoleaf's own plugin SDK draws with.
    /// Linking its `libPluginUtilities` and reading back the vertices its
    /// `Triangle` computes gives, at orientation 0, vertices at 90°, 210° and
    /// 330° (one pointing straight up, base along the x-axis); `o` turns that
    /// counter-clockwise, as the OpenAPI documents. Hexagons at orientation 0
    /// put vertices on the ±x axis. Both conventions were checked against
    /// layouts real controllers reported: two mini triangles at o = 0 and
    /// o = 60 sat 38.1 units apart along a 30° edge normal (two inradii of a
    /// 67-unit triangle is 38.7), and a hexagon beside a mini triangle sat
    /// 77.0 apart along −30° (apothem 58.0 plus inradius 19.3). Under any other
    /// vertex convention those shared edges do not line up.
    static func outline(of panel: NanoleafPanel) -> [NanoleafPoint]? {
        guard let side = panel.kind.sideLength else { return nil }
        let center = NanoleafPoint(panel.x, panel.y)
        switch panel.kind {
        case .hexagon:
            return polygon(center: center, circumradius: side,
                           firstVertexDegrees: panel.orientation, count: 6)
        case .triangle, .miniTriangle:
            return polygon(center: center, circumradius: side / 3.0.squareRoot(),
                           firstVertexDegrees: panel.orientation + 90, count: 3)
        default:
            return nil
        }
    }

    /// Distance from a panel's centroid to the middle of each edge.
    static func inradius(of kind: NanoleafShapeKind) -> Double? {
        guard let side = kind.sideLength else { return nil }
        switch kind {
        case .hexagon: return side * 3.0.squareRoot() / 2
        case .triangle, .miniTriangle: return side / (2 * 3.0.squareRoot())
        default: return nil
        }
    }

    /// Size of the marker drawn for a reference-only entry such as the
    /// controller. These entries have no documented outline, so they are
    /// drawn as small circles rather than guessed shapes.
    static func markerRadius(for kind: NanoleafShapeKind) -> Double {
        kind == .controller ? 12 : 16
    }

    static func polygon(center: NanoleafPoint, circumradius: Double,
                        firstVertexDegrees: Double, count: Int) -> [NanoleafPoint] {
        (0..<count).map { index in
            let degrees = firstVertexDegrees + Double(index) * 360 / Double(count)
            let radians = degrees * .pi / 180
            return NanoleafPoint(center.x + circumradius * cos(radians),
                                 center.y + circumradius * sin(radians))
        }
    }

    /// Whether a convex, counter-clockwise polygon contains a point. Points
    /// on an edge count as inside, so a click exactly on a seam still lands.
    static func convexPolygon(_ polygon: [NanoleafPoint], contains point: NanoleafPoint,
                              tolerance: Double = 1e-9) -> Bool {
        guard polygon.count >= 3 else { return false }
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            let length = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
            if cross < -tolerance * max(1, length) { return false }
        }
        return true
    }

    /// Every point the arrangement occupies in layout space: panel outlines
    /// plus a square around each reference marker.
    static func footprint(of layout: NanoleafLayout) -> [NanoleafPoint] {
        layout.panels.flatMap { entry -> [NanoleafPoint] in
            if let outline = outline(of: entry) { return outline }
            let radius = markerRadius(for: entry.kind)
            return [NanoleafPoint(entry.x - radius, entry.y - radius),
                    NanoleafPoint(entry.x + radius, entry.y + radius),
                    NanoleafPoint(entry.x - radius, entry.y + radius),
                    NanoleafPoint(entry.x + radius, entry.y - radius)]
        }
    }

    /// The centre the wall view rotates about: the middle of the layout's
    /// bounding box. Any fixed point would do for drawing, because the canvas
    /// re-centres; it has to be fixed so spatial effects do not drift when
    /// the orientation changes.
    static func pivot(of layout: NanoleafLayout) -> NanoleafPoint {
        let points = footprint(of: layout)
        guard let first = points.first else { return NanoleafPoint(0, 0) }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return NanoleafPoint((minX + maxX) / 2, (minY + maxY) / 2)
    }
}

// MARK: - Wall view

/// The controller's layout space turned into the wall view: rotated
/// clockwise by the global orientation about a fixed pivot, y still up.
///
/// Clockwise is Nanoleaf's convention, measured rather than assumed. The
/// official plugin SDK lays effects out as the user sees them by calling
/// `rotateAuroraPanels(layout, &layout->globalOrientation)`; run against its
/// shipped library, that call moves (100, 0) to (0, −100) for 90°. Hyperion's
/// Nanoleaf driver independently negates the reported value before rotating
/// for the same reason. The raw layout itself never changes with orientation.
struct NanoleafWallTransform: Equatable {
    let rotationDegrees: Double
    let pivot: NanoleafPoint

    init(rotationDegrees: Double, pivot: NanoleafPoint) {
        self.rotationDegrees = NanoleafOrientation.normalized(rotationDegrees)
        self.pivot = pivot
    }

    init(layout: NanoleafLayout, rotationDegrees: Double) {
        self.init(rotationDegrees: rotationDegrees, pivot: NanoleafGeometry.pivot(of: layout))
    }

    private var radians: Double { rotationDegrees * .pi / 180 }

    func wall(fromRaw point: NanoleafPoint) -> NanoleafPoint {
        let dx = point.x - pivot.x
        let dy = point.y - pivot.y
        let c = cos(radians), s = sin(radians)
        return NanoleafPoint(dx * c + dy * s, -dx * s + dy * c)
    }

    func raw(fromWall point: NanoleafPoint) -> NanoleafPoint {
        let c = cos(radians), s = sin(radians)
        return NanoleafPoint(point.x * c - point.y * s + pivot.x,
                             point.x * s + point.y * c + pivot.y)
    }
}

// MARK: - Canvas

/// How the wall view lands on a canvas of a given size: uniformly scaled,
/// centred, and flipped so screen y points down. Drawing, hit testing and
/// marquee selection all go through this one mapping, so a panel is always
/// selected where it is drawn, at any orientation.
struct NanoleafCanvasMapping: Equatable {
    enum Fit {
        /// Fill the canvas with the arrangement as currently rotated.
        case tight
        /// Fit the circle the arrangement sweeps through, so the drawing
        /// keeps one size while it is being rotated.
        case rotationStable
    }

    let wall: NanoleafWallTransform
    let scale: Double
    /// Screen position of the wall-view origin.
    let origin: NanoleafPoint

    init(layout: NanoleafLayout, rotationDegrees: Double, width: Double, height: Double,
         inset: Double = 24, fit: Fit = .tight) {
        let wall = NanoleafWallTransform(layout: layout, rotationDegrees: rotationDegrees)
        self.wall = wall
        let points = NanoleafGeometry.footprint(of: layout).map(wall.wall(fromRaw:))
        let availableWidth = max(1, width - inset * 2)
        let availableHeight = max(1, height - inset * 2)
        guard let first = points.first else {
            scale = 1
            origin = NanoleafPoint(width / 2, height / 2)
            return
        }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let center: NanoleafPoint
        switch fit {
        case .tight:
            let spanX = max(1, maxX - minX), spanY = max(1, maxY - minY)
            scale = min(availableWidth / spanX, availableHeight / spanY)
            center = NanoleafPoint((minX + maxX) / 2, (minY + maxY) / 2)
        case .rotationStable:
            // The pivot is the wall origin, so the swept circle is centred there.
            let radius = max(1, points.map { ($0.x * $0.x + $0.y * $0.y).squareRoot() }.max() ?? 1)
            scale = min(availableWidth, availableHeight) / (radius * 2)
            center = NanoleafPoint(0, 0)
        }
        origin = NanoleafPoint(width / 2 - center.x * scale, height / 2 + center.y * scale)
    }

    func screen(fromWall point: NanoleafPoint) -> NanoleafPoint {
        NanoleafPoint(origin.x + point.x * scale, origin.y - point.y * scale)
    }

    func wall(fromScreen point: NanoleafPoint) -> NanoleafPoint {
        NanoleafPoint((point.x - origin.x) / scale, (origin.y - point.y) / scale)
    }

    func screen(fromRaw point: NanoleafPoint) -> NanoleafPoint {
        screen(fromWall: wall.wall(fromRaw: point))
    }

    func raw(fromScreen point: NanoleafPoint) -> NanoleafPoint {
        wall.raw(fromWall: wall(fromScreen: point))
    }

    func screenOutline(of panel: NanoleafPanel) -> [NanoleafPoint]? {
        NanoleafGeometry.outline(of: panel)?.map(screen(fromRaw:))
    }

    func screenCenter(of panel: NanoleafPanel) -> NanoleafPoint {
        screen(fromRaw: NanoleafPoint(panel.x, panel.y))
    }

    /// The light panel under a screen point, found by testing the point in
    /// layout space against each outline. When a point sits on a shared edge
    /// the nearer centroid wins, so the answer is stable.
    func panelID(atScreen point: NanoleafPoint, in layout: NanoleafLayout) -> Int? {
        let target = raw(fromScreen: point)
        var best: (id: Int, distance: Double)?
        for panel in layout.panels where panel.isPaintable {
            guard let outline = NanoleafGeometry.outline(of: panel),
                  NanoleafGeometry.convexPolygon(outline, contains: target) else { continue }
            let dx = panel.x - target.x, dy = panel.y - target.y
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance || (distance == best!.distance && panel.panelID < best!.id) {
                best = (panel.panelID, distance)
            }
        }
        return best?.id
    }

    /// Light panels whose centre falls inside a screen rectangle, for
    /// drag-to-select. Corners may be given in any order.
    func panelIDs(inScreenRectFrom a: NanoleafPoint, to b: NanoleafPoint, in layout: NanoleafLayout) -> [Int] {
        let minX = min(a.x, b.x), maxX = max(a.x, b.x)
        let minY = min(a.y, b.y), maxY = max(a.y, b.y)
        return layout.paintablePanels.filter { panel in
            let center = screenCenter(of: panel)
            return center.x >= minX && center.x <= maxX && center.y >= minY && center.y <= maxY
        }.map(\.panelID)
    }
}

// MARK: - Spatial positions

/// The direction a spatial effect travels across the wall view.
enum NanoleafSpatialAxis: String, Codable, CaseIterable, Identifiable {
    case leftToRight
    case topToBottom
    case clockwise
    case outward

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftToRight: return "Left to right"
        case .topToBottom: return "Top to bottom"
        case .clockwise: return "Clockwise"
        case .outward: return "Centre outward"
        }
    }
}

struct NanoleafSpatialPosition: Equatable {
    let panelID: Int
    /// 0…1 along the axis. Circular positions wrap: 0 and 1 are the same place.
    let position: Double
}

extension NanoleafLayout {
    /// Light panels placed along an axis of the wall view, as the user
    /// oriented it, ordered by position then panel ID. This is what makes a
    /// "left to right" effect travel left to right on the wall rather than
    /// in whatever order the controller happened to list its panels.
    func spatialPositions(rotationDegrees: Double, axis: NanoleafSpatialAxis) -> [NanoleafSpatialPosition] {
        let panels = paintablePanels
        guard !panels.isEmpty else { return [] }
        let wall = NanoleafWallTransform(layout: self, rotationDegrees: rotationDegrees)
        let centers = panels.map { (id: $0.panelID, point: wall.wall(fromRaw: NanoleafPoint($0.x, $0.y))) }
        let meanX = centers.reduce(0) { $0 + $1.point.x } / Double(centers.count)
        let meanY = centers.reduce(0) { $0 + $1.point.y } / Double(centers.count)
        let xs = centers.map(\.point.x), ys = centers.map(\.point.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let maxDistance = centers.map { hypot($0.point.x - meanX, $0.point.y - meanY) }.max() ?? 0

        func position(_ point: NanoleafPoint) -> Double {
            switch axis {
            case .leftToRight:
                return maxX - minX < 0.5 ? 0.5 : (point.x - minX) / (maxX - minX)
            case .topToBottom:
                return maxY - minY < 0.5 ? 0.5 : (maxY - point.y) / (maxY - minY)
            case .clockwise:
                // Angle from twelve o'clock, increasing clockwise on the wall.
                let dx = point.x - meanX, dy = point.y - meanY
                guard hypot(dx, dy) > 0.5 else { return 0 }
                let angle = atan2(dx, dy)
                return (angle < 0 ? angle + 2 * .pi : angle) / (2 * .pi)
            case .outward:
                return maxDistance < 0.5 ? 0 : hypot(point.x - meanX, point.y - meanY) / maxDistance
            }
        }

        return centers
            .map { NanoleafSpatialPosition(panelID: $0.id, position: min(1, max(0, position($0.point)))) }
            .sorted { $0.position == $1.position ? $0.panelID < $1.panelID : $0.position < $1.position }
    }
}

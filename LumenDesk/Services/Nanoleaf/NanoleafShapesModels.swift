import Foundation

// MARK: - What the wall is showing

/// LumenDesk's account of a Shapes wall's output, with where that account
/// comes from. The editor draws from this, so it must never claim more than
/// the controller has told it.
enum NanoleafOutputState: Equatable {
    /// Nothing read from the controller yet.
    case unknown
    case off
    /// Universal colour: every panel the same hue and saturation.
    case solid
    /// Colour temperature: every panel the same white.
    case white
    /// A scene stored on the controller is selected.
    case nativeEffect(name: String)
    /// LumenDesk's own static layout. `confirmed` means the controller
    /// reported the static mode after LumenDesk sent it; it is not evidence
    /// of what a person saw.
    case design(confirmed: Bool)
    /// The editor's temporary preview is on the wall.
    case preview
    /// LumenDesk is streaming live frames (music, effects, screen mirror).
    case stream(owner: String)
    /// A mode LumenDesk did not set, such as a temporary scene from the
    /// Nanoleaf app, or another program's static layout or stream.
    case external(String)

    /// Whether per-panel colours of this output can be known without
    /// guessing.
    var panelColorsAreKnown: Bool {
        switch self {
        case .design, .preview, .stream, .off, .solid, .white: return true
        case .unknown, .nativeEffect, .external: return false
        }
    }

    var summary: String {
        switch self {
        case .unknown: return "Not read from the controller yet"
        case .off: return "Off"
        case .solid: return "One colour across the wall"
        case .white: return "White across the wall"
        case .nativeEffect(let name): return "Controller scene \u{201C}\(name)\u{201D}"
        case .design(let confirmed): return confirmed ? "LumenDesk design, reported by the controller" : "LumenDesk design, sent"
        case .preview: return "Editor preview"
        case .stream: return "Live output from LumenDesk"
        case .external(let detail): return detail
        }
    }

    /// Reads the controller's own report. `claim` is what LumenDesk last
    /// put on the wall, so a static mode can be attributed to it.
    static func reported(isOn: Bool, colorMode: String, selectedEffect: String,
                         effectsList: [String], claim: NanoleafOutputClaim?) -> NanoleafOutputState {
        guard isOn else { return .off }
        switch colorMode {
        case "hs": return .solid
        case "ct": return .white
        default: break
        }
        switch selectedEffect {
        case "*Static*":
            switch claim {
            case .design: return .design(confirmed: true)
            case .preview: return .preview
            default: return .external("A static layout LumenDesk did not send")
            }
        case "*ExtControl*":
            if case .stream(let owner) = claim { return .stream(owner: owner) }
            return .external("Another program is streaming to the wall")
        case "*Dynamic*":
            return .external("A temporary animated scene from another app")
        case "*Solid*":
            return .solid
        default:
            if effectsList.contains(selectedEffect) { return .nativeEffect(name: selectedEffect) }
            if case .stream(let owner) = claim { return .stream(owner: owner) }
            return .external("A mode LumenDesk does not recognise")
        }
    }
}

/// What LumenDesk itself last put on a wall.
enum NanoleafOutputClaim: Equatable {
    case design
    case preview
    case stream(owner: String)
}

// MARK: - Orientation

/// The controller's global orientation as LumenDesk tracks it: what the
/// controller last reported, and a write that has not been read back yet.
struct NanoleafOrientationState: Equatable {
    enum Status: Equatable {
        case unknown
        case confirmed(Int)
        case pending(requested: Int)
        /// The controller accepted the write but read back another value.
        case differs(requested: Int, reported: Int)
        case failed(requested: Int, reason: String)
    }

    private(set) var reported: Int?
    private(set) var requested: Int?
    private(set) var accepted = false
    private(set) var failure: String?
    /// The request and the reading that disagreed with it. Shown only while
    /// the controller still reports that reading, so a later change made in
    /// another app is not blamed on the old request.
    private var mismatchRequested: Int?
    private var mismatchReported: Int?

    var status: Status {
        if let requested {
            if let failure { return .failed(requested: requested, reason: failure) }
            return .pending(requested: requested)
        }
        if let asked = mismatchRequested, let got = mismatchReported, reported == got {
            return .differs(requested: asked, reported: got)
        }
        if let reported { return .confirmed(reported) }
        return .unknown
    }

    mutating func request(_ degrees: Int) {
        requested = NanoleafOrientation.normalized(degrees)
        accepted = false
        failure = nil
        mismatchRequested = nil
        mismatchReported = nil
    }

    /// The controller answered the write with a success status. The next
    /// reading settles it.
    mutating func writeAccepted() {
        guard requested != nil else { return }
        accepted = true
    }

    mutating func writeFailed(_ reason: String) {
        guard requested != nil else { return }
        failure = reason
    }

    /// A reading from the controller. Before the write is accepted a
    /// reading may predate it, so only a match settles it early; after
    /// acceptance, whatever the controller reports is the answer.
    mutating func read(_ degrees: Int?) {
        reported = degrees
        guard let requested, failure == nil else { return }
        if degrees == requested {
            self.requested = nil
            accepted = false
        } else if accepted {
            mismatchRequested = requested
            mismatchReported = degrees
            self.requested = nil
            accepted = false
        }
    }

    var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    /// One line for diagnostics and assistive technology. Says where the
    /// number came from, because a value typed in is not a value applied.
    var summary: String {
        switch status {
        case .unknown: return "Not reported by the controller"
        case .confirmed(let degrees): return "\(degrees)° · read back from the controller"
        case .pending(let requested): return "\(requested)° requested · waiting for the controller to confirm"
        case .differs(let requested, let reported):
            return "\(reported)° reported · the controller did not keep the requested \(requested)°"
        case .failed(let requested, let reason): return "\(requested)° not applied · \(reason)"
        }
    }

    /// Dismisses a failed write so the controller's value shows again.
    mutating func clearFailure() {
        guard failure != nil else { return }
        requested = nil
        failure = nil
        accepted = false
    }
}

// MARK: - Editing

/// One editing session on one wall: a draft design, its history, and the
/// panel selection. Pure state; transport and ownership live elsewhere.
struct NanoleafEditingSession: Equatable {
    enum Origin: Equatable {
        /// Continuing the design LumenDesk last applied.
        case appliedDesign
        /// Starting from one colour on every panel, because the wall was
        /// animating and its per-panel colours could not be read.
        case uniform(NanoleafPanelColor)
        case savedDesign(String)
        /// Imported from a static scene stored on the controller.
        case controllerScene(String)
    }

    static let historyLimit = 100

    private(set) var draft: NanoleafPanelDesign
    private(set) var undoStack: [NanoleafPanelDesign] = []
    private(set) var redoStack: [NanoleafPanelDesign] = []
    /// What "unapplied changes" is measured against.
    private(set) var baseline: NanoleafPanelDesign
    private var continuousBase: NanoleafPanelDesign?
    var selection: Set<Int> = []
    let origin: Origin

    init(draft: NanoleafPanelDesign, origin: Origin, baseline: NanoleafPanelDesign? = nil) {
        self.draft = draft
        self.origin = origin
        self.baseline = baseline ?? draft
    }

    var canUndo: Bool { !undoStack.isEmpty || (continuousBase.map { $0 != draft } ?? false) }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasUnappliedChanges: Bool { draft != baseline }

    /// Applies one edit as one undo step. An edit that changes nothing is
    /// not recorded.
    mutating func edit(_ change: (inout NanoleafPanelDesign) -> Void) {
        var next = draft
        change(&next)
        guard next != draft else { return }
        if continuousBase == nil {
            push(draft)
            redoStack.removeAll()
        }
        draft = next
    }

    /// Brackets a slider drag or picker session so the whole gesture is one
    /// undo step.
    mutating func beginContinuousEdit() {
        guard continuousBase == nil else { return }
        continuousBase = draft
    }

    mutating func endContinuousEdit() {
        guard let base = continuousBase else { return }
        continuousBase = nil
        if base != draft {
            push(base)
            redoStack.removeAll()
        }
    }

    mutating func undo() {
        endContinuousEdit()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(draft)
        draft = previous
    }

    mutating func redo() {
        endContinuousEdit()
        guard let next = redoStack.popLast() else { return }
        push(draft)
        draft = next
    }

    /// Replaces the whole draft, e.g. loading a saved design, as one step.
    mutating func replaceDraft(_ design: NanoleafPanelDesign) {
        edit { $0 = design }
    }

    /// Records that the draft is now what the wall should keep showing.
    mutating func markApplied() {
        endContinuousEdit()
        baseline = draft
    }

    /// Drops selected panels the wall no longer has. Returns what was
    /// dropped so the editor can say so.
    @discardableResult
    mutating func reconcileSelection(with layout: NanoleafLayout) -> [Int] {
        let dropped = selection.subtracting(layout.paintableIDs)
        selection.subtract(dropped)
        return dropped.sorted()
    }

    /// The panels an edit targets: the selection, or every panel when
    /// nothing is selected, so a tool never silently does nothing.
    func targets(in layout: NanoleafLayout) -> Set<Int> {
        let selected = selection.intersection(layout.paintableIDs)
        return selected.isEmpty ? layout.paintableIDs : selected
    }

    private mutating func push(_ design: NanoleafPanelDesign) {
        undoStack.append(design)
        if undoStack.count > Self.historyLimit { undoStack.removeFirst(undoStack.count - Self.historyLimit) }
    }
}

// MARK: - Library

/// A design kept in LumenDesk for reuse. It remembers which controller it
/// was made for; applying it elsewhere is refused, because panel IDs are
/// only meaningful on the controller that assigned them.
struct NanoleafSavedDesign: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let deviceID: String
    var design: NanoleafPanelDesign
    let createdAt: Date

    init(id: UUID = UUID(), name: String, deviceID: String, design: NanoleafPanelDesign, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.deviceID = deviceID
        self.design = design
        self.createdAt = createdAt
    }
}

/// A named set of panels on one wall, for selecting the same shapes again.
struct NanoleafPanelGroup: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var panelIDs: [Int]

    init(id: UUID = UUID(), name: String, panelIDs: [Int]) {
        self.id = id
        self.name = name
        self.panelIDs = Array(Set(panelIDs)).sorted()
    }
}

// MARK: - Navigation and building designs

enum NanoleafDirection: CaseIterable {
    case up, down, left, right

    /// Unit vector in the wall view (y up).
    var vector: NanoleafPoint {
        switch self {
        case .up: return NanoleafPoint(0, 1)
        case .down: return NanoleafPoint(0, -1)
        case .left: return NanoleafPoint(-1, 0)
        case .right: return NanoleafPoint(1, 0)
        }
    }
}

extension NanoleafLayout {
    /// The nearest light panel from `panelID` in a direction on the wall as
    /// the user oriented it, for arrow-key navigation. Candidates must lie
    /// within 60° of the direction; the closest wins, weighted toward those
    /// straight ahead.
    func neighbor(of panelID: Int, toward direction: NanoleafDirection, rotationDegrees: Double) -> Int? {
        guard let origin = panel(withID: panelID) else { return paintablePanels.first?.panelID }
        let wall = NanoleafWallTransform(layout: self, rotationDegrees: rotationDegrees)
        let start = wall.wall(fromRaw: NanoleafPoint(origin.x, origin.y))
        let axis = direction.vector
        var best: (id: Int, score: Double)?
        for panel in paintablePanels where panel.panelID != panelID {
            let point = wall.wall(fromRaw: NanoleafPoint(panel.x, panel.y))
            let dx = point.x - start.x, dy = point.y - start.y
            let distance = hypot(dx, dy)
            guard distance > 0.5 else { continue }
            let alignment = (dx * axis.x + dy * axis.y) / distance
            guard alignment >= 0.5 else { continue } // within 60°
            let score = distance * (2 - alignment)
            if best == nil || score < best!.score || (score == best!.score && panel.panelID < best!.id) {
                best = (panel.panelID, score)
            }
        }
        return best?.id
    }
}

enum NanoleafDesignBuilder {
    /// A colour ramp across the chosen panels, in the order they sit on the
    /// wall along `axis`. Interpolates output RGB, so the ramp looks like what
    /// the swatches at each end show.
    static func gradient(from start: NanoleafPanelColor, to end: NanoleafPanelColor,
                         panels: Set<Int>, layout: NanoleafLayout,
                         rotationDegrees: Double, axis: NanoleafSpatialAxis) -> [Int: NanoleafPanelColor] {
        let placed = layout.spatialPositions(rotationDegrees: rotationDegrees, axis: axis)
            .filter { panels.contains($0.panelID) }
        guard !placed.isEmpty else { return [:] }
        let low = placed.map(\.position).min() ?? 0
        let high = placed.map(\.position).max() ?? 1
        let a = start.rgb, b = end.rgb
        var result: [Int: NanoleafPanelColor] = [:]
        for entry in placed {
            let t = high - low < 1e-9 ? 0 : (entry.position - low) / (high - low)
            func mix(_ x: UInt8, _ y: UInt8) -> UInt8 {
                UInt8(min(255, max(0, (Double(x) + (Double(y) - Double(x)) * t).rounded())))
            }
            result[entry.panelID] = NanoleafPanelColor(rgb: NanoleafRGB(red: mix(a.red, b.red),
                                                                        green: mix(a.green, b.green),
                                                                        blue: mix(a.blue, b.blue)))
        }
        return result
    }

    /// Spreads tones across the wall in spatial order: the first tone lands
    /// on the first panel along `axis`. Tone level becomes each panel's
    /// intensity; the theme's overall brightness belongs on the controller's
    /// master brightness, never folded in here.
    static func design(tones: [(hue: Double, saturation: Double, level: Double)], layout: NanoleafLayout,
                       rotationDegrees: Double, axis: NanoleafSpatialAxis = .leftToRight) -> NanoleafPanelDesign {
        let placed = layout.spatialPositions(rotationDegrees: rotationDegrees, axis: axis)
        guard !tones.isEmpty else { return NanoleafPanelDesign() }
        var colors: [Int: NanoleafPanelColor] = [:]
        for (index, entry) in placed.enumerated() {
            let tone = tones[min(index, tones.count - 1)]
            colors[entry.panelID] = NanoleafPanelColor(hue: tone.hue, saturation: tone.saturation, intensity: tone.level)
        }
        return NanoleafPanelDesign(colors: colors)
    }

    /// A design from the colours a stored static scene settles on.
    static func design(staticColors: [Int: NanoleafRGB]) -> NanoleafPanelDesign {
        NanoleafPanelDesign(colors: staticColors.mapValues { NanoleafPanelColor(rgb: $0) })
    }
}

// MARK: - Demo wall

/// The simulated Shapes wall Demo Mode uses: five hexagons in a zigzag, a
/// large triangle hanging from the middle one, four mini triangles and the
/// controller. It tiles like a real wall — every neighbour sits on a shared
/// edge (the large triangle on an edge midpoint, as the hardware joins) —
/// so the editor, hit testing and spatial effects behave as they would on
/// hardware. Panel IDs are deliberately scattered, as controllers assign them.
enum NanoleafShapesDemo {
    static let deviceName = "Studio Shapes"

    static let arrangement = NanoleafArrangement(
        layout: NanoleafLayout(panels: [
            NanoleafPanel(panelID: 13487, x: 0, y: 0, orientation: 0, shapeCode: 7),
            NanoleafPanel(panelID: 5120, x: 100.5, y: 58.02, orientation: 0, shapeCode: 7),
            NanoleafPanel(panelID: 60255, x: 201, y: 0, orientation: 0, shapeCode: 7),
            NanoleafPanel(panelID: 29031, x: 301.5, y: 58.02, orientation: 0, shapeCode: 7),
            NanoleafPanel(panelID: 44810, x: 402, y: 0, orientation: 0, shapeCode: 7),
            NanoleafPanel(panelID: 8841, x: 201, y: -96.7, orientation: 60, shapeCode: 8),
            NanoleafPanel(panelID: 17230, x: -67, y: -38.68, orientation: 0, shapeCode: 9),
            NanoleafPanel(panelID: 38112, x: 469, y: -38.68, orientation: 0, shapeCode: 9),
            NanoleafPanel(panelID: 51347, x: 301.5, y: 135.38, orientation: 0, shapeCode: 9),
            NanoleafPanel(panelID: 2765, x: 100.5, y: 135.38, orientation: 0, shapeCode: 9),
            NanoleafPanel(panelID: 0, x: -58.9, y: 34, orientation: 60, shapeCode: 12)
        ], reportedPanelCount: 11, legacySideLength: 0),
        orientation: .reported(value: 0, minimum: 0, maximum: 360)
    )

    /// A dusk ramp across the wall, dimmer at the ends.
    static var design: NanoleafPanelDesign {
        let layout = arrangement.layout
        let warm = NanoleafPanelColor(hex: "#FF6A2B")!
        let cool = NanoleafPanelColor(hex: "#6B3CFF")!
        var design = NanoleafPanelDesign(colors: NanoleafDesignBuilder.gradient(
            from: warm, to: cool, panels: layout.paintableIDs, layout: layout,
            rotationDegrees: 0, axis: .leftToRight))
        design.setIntensity(0.55, panels: [17230, 38112])
        return design
    }
}

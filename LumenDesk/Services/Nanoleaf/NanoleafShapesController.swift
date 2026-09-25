import Foundation
import Combine

/// Shapes-specific state for every paired wall — arrangement, orientation,
/// LumenDesk designs, editing sessions and who owns the live output — and
/// the one place editor intents become client requests.
///
/// LightManager keeps device lifecycle, undo, scenes and the effect runs, and
/// calls in here for anything panel-shaped. Nothing here imports SwiftUI, and
/// nothing reaches the network while `isLive` is false (Demo Mode).
@MainActor
final class NanoleafShapesController: ObservableObject {
    /// Everything read from, or claimed on, one wall.
    struct Wall: Equatable {
        var arrangement: NanoleafArrangement?
        /// Set when the latest reading could not be trusted; `arrangement`
        /// then keeps the last layout that could.
        var topologyProblem: NanoleafTopologyProblem?
        var lastChange: NanoleafTopologyChange?
        var readAt: Date?
        var orientation = NanoleafOrientationState()
        var output: NanoleafOutputState = .unknown
        var claim: NanoleafOutputClaim?
        /// True from claiming the wall until the controller acknowledges the
        /// write. Every request to a controller runs through one ordered lane,
        /// so a reading that arrives before the acknowledgement was taken
        /// before the write and cannot contradict the claim.
        var awaitingWrite = false
        /// Colours LumenDesk last sent, per panel, whatever the path.
        var lastSent: [Int: NanoleafRGB] = [:]
        var lastSentAt: Date?
        var effectsList: [String] = []
        var firmware: String?
        var lastFailure: String?
        var touchedPanel: Int?
        var touchedAt: Date?
    }

    enum LibraryState: Equatable {
        case loading
        case loaded([NanoleafEffectDefinition], [NanoleafPluginDescription])
        case failed(String)
    }

    /// Everything that survives a relaunch.
    struct Snapshot: Equatable {
        var designs: [String: NanoleafPanelDesign] = [:]
        var savedDesigns: [NanoleafSavedDesign] = []
        var groups: [String: [NanoleafPanelGroup]] = [:]
        var arrangements: [String: NanoleafArrangement] = [:]
    }

    struct PreviewOrigin: Equatable {
        let output: NanoleafOutputState
        let claim: NanoleafOutputClaim?
    }

    /// Everything, including what LumenDesk has claimed on each wall and any
    /// open editing session. Demo Mode sets this aside and puts it back, so
    /// a visit to the demo never changes what LumenDesk knows about a real
    /// wall. A relaunch uses `Snapshot` instead: claims on a wall cannot be
    /// trusted across one.
    struct WorkspaceSnapshot {
        var persisted = Snapshot()
        var walls: [String: Wall] = [:]
        var sessions: [String: NanoleafEditingSession] = [:]
        var previewing: Set<String> = []
        var previewOrigins: [String: PreviewOrigin] = [:]
    }

    @Published private(set) var walls: [String: Wall] = [:]
    /// The design LumenDesk last applied to each wall. Whether it is still
    /// on the wall is `showingDesign(for:)`.
    @Published private(set) var designs: [String: NanoleafPanelDesign] = [:]
    @Published private(set) var savedDesigns: [NanoleafSavedDesign] = []
    @Published private(set) var groups: [String: [NanoleafPanelGroup]] = [:]
    @Published private(set) var sessions: [String: NanoleafEditingSession] = [:]
    /// Walls whose editing session is shown on the wall as it is edited.
    @Published private(set) var previewing: Set<String> = []
    @Published private(set) var libraries: [String: LibraryState] = [:]
    @Published private(set) var streams: [String: NanoleafStreamStatus] = [:]

    private let client: NanoleafClient
    private let now: () -> Date
    /// False in Demo Mode: intents are simulated and nothing is sent.
    var isLive: () -> Bool = { true }
    var persist: () -> Void = {}
    /// Puts a wall's solid colour or white back, for ending a preview that
    /// replaced one. LightManager owns those commands.
    var restoreWholeWall: (String) -> Void = { _ in }
    /// What the wall showed before a preview began, so cancelling can put
    /// it back while LumenDesk still owns the output.
    private var previewOrigins: [String: PreviewOrigin] = [:]
    private var orientationDeadlines: [String: Task<Void, Never>] = [:]
    /// Every panel colour streamed under the wall's current stream claim. A
    /// show can stream ten frames a second to every wall; views redraw from
    /// `lastSent`, which takes this in at most four times a second.
    private var streamed: [String: [Int: NanoleafRGB]] = [:]
    private static let streamPublishInterval: TimeInterval = 0.25

    init(client: NanoleafClient, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.now = now
    }

    static func serial(for deviceID: String) -> String? {
        deviceID.hasPrefix("nanoleaf:") ? String(deviceID.dropFirst("nanoleaf:".count)) : nil
    }

    private func liveSerial(_ deviceID: String) -> String? {
        guard isLive() else { return nil }
        return Self.serial(for: deviceID)
    }

    /// Whether a write sent now will be acknowledged or fail, as opposed to
    /// being dropped unsent, which would leave `awaitingWrite` set forever.
    private func expectsAcknowledgement(_ serial: String?) -> Bool {
        guard let serial else { return false }
        return client.canSend(serial)
    }

    func wall(_ deviceID: String) -> Wall { walls[deviceID] ?? Wall() }
    func arrangement(_ deviceID: String) -> NanoleafArrangement? { walls[deviceID]?.arrangement }
    func layout(_ deviceID: String) -> NanoleafLayout? { walls[deviceID]?.arrangement?.layout }

    /// The wall view's rotation: a pending orientation write while one is in
    /// flight, otherwise what the controller reported, otherwise 0.
    func displayOrientation(_ deviceID: String) -> Int {
        let state = wall(deviceID).orientation
        if case .pending(let requested) = state.status { return requested }
        if case .failed = state.status { return state.reported ?? 0 }
        return state.reported ?? walls[deviceID]?.arrangement?.globalOrientation ?? 0
    }

    // MARK: Persistence and Demo Mode

    func snapshot() -> Snapshot {
        Snapshot(designs: designs, savedDesigns: savedDesigns, groups: groups,
                 arrangements: walls.compactMapValues(\.arrangement))
    }

    /// Replaces everything persisted, e.g. at launch, on import, or when
    /// Demo Mode swaps workspaces. Live claims, sessions and previews are
    /// dropped: they belonged to the workspace being left.
    func restore(_ snapshot: Snapshot) {
        designs = snapshot.designs
        savedDesigns = snapshot.savedDesigns
        groups = snapshot.groups
        var next: [String: Wall] = [:]
        for (deviceID, arrangement) in snapshot.arrangements {
            var wall = Wall()
            wall.arrangement = arrangement
            wall.orientation.read(arrangement.globalOrientation)
            next[deviceID] = wall
        }
        walls = next
        sessions = [:]
        previewing = []
        previewOrigins = [:]
        libraries = [:]
        streams = [:]
        orientationDeadlines.values.forEach { $0.cancel() }
        orientationDeadlines = [:]
        streamed = [:]
    }

    func workspaceSnapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(persisted: snapshot(), walls: walls, sessions: sessions,
                          previewing: previewing, previewOrigins: previewOrigins)
    }

    func restoreWorkspace(_ workspace: WorkspaceSnapshot) {
        restore(workspace.persisted)
        for (deviceID, wall) in workspace.walls { walls[deviceID] = wall }
        sessions = workspace.sessions
        previewing = workspace.previewing
        previewOrigins = workspace.previewOrigins
        for deviceID in Array(walls.keys) {
            // Streams belonged to the workspace being left; the client ended
            // them when it paused, so none is live any more.
            if case .stream = walls[deviceID]?.claim { walls[deviceID]?.claim = nil }
            // Pausing dropped any write still queued, so no acknowledgement
            // is coming: the next reading decides.
            walls[deviceID]?.awaitingWrite = false
        }
        streamed = [:]
    }

    /// Takes in an imported configuration. Saved designs and groups are the
    /// file's. A wall showing LumenDesk's design keeps that design, and a
    /// wall this install has read keeps its layout: what a controller shows
    /// and reports outranks a file.
    func importSnapshot(_ snapshot: Snapshot) {
        savedDesigns = snapshot.savedDesigns
        groups = snapshot.groups
        var nextDesigns = snapshot.designs
        for (deviceID, wall) in walls where wall.claim == .design {
            nextDesigns[deviceID] = designs[deviceID]
        }
        designs = nextDesigns
        for (deviceID, arrangement) in snapshot.arrangements where walls[deviceID]?.arrangement == nil {
            var wall = self.wall(deviceID)
            wall.arrangement = arrangement
            wall.orientation.read(arrangement.globalOrientation)
            walls[deviceID] = wall
        }
        persist()
    }

    /// A wall already showing `design`, as a simulated controller would
    /// report it. Demo Mode starts its Shapes wall from this.
    static func simulatedWall(_ arrangement: NanoleafArrangement, showing design: NanoleafPanelDesign,
                              effects: [String] = []) -> Wall {
        var wall = Wall()
        wall.arrangement = arrangement
        wall.orientation.read(arrangement.globalOrientation)
        wall.claim = .design
        wall.output = .design(confirmed: true)
        wall.effectsList = effects
        wall.lastSent = Dictionary(design.frames(for: arrangement.layout, transition: 0).map { ($0.panelID, $0.rgb) },
                                   uniquingKeysWith: { _, new in new })
        return wall
    }

    // MARK: Readings from the controller

    /// Takes in a reading. Returns the owner of a live stream that the
    /// reading shows was superseded — another app took the wall — so the
    /// show feeding it can let that wall go instead of fighting for it.
    @discardableResult
    func didRead(deviceID: String, info: NanoleafInfo) -> String? {
        var wall = self.wall(deviceID)
        let previousArrangement = wall.arrangement
        switch info.topology {
        case .success(let arrangement):
            let change = NanoleafTopologyChange.between(wall.arrangement?.layout, arrangement.layout)
            if !change.isEmpty { wall.lastChange = change }
            wall.arrangement = arrangement
            wall.topologyProblem = nil
            if var session = sessions[deviceID] {
                session.reconcileSelection(with: arrangement.layout)
                sessions[deviceID] = session
            }
        case .failure(let problem):
            wall.topologyProblem = problem
        }
        wall.readAt = now()
        wall.firmware = info.firmwareVersion ?? wall.firmware
        wall.effectsList = info.effects.effectsList
        wall.orientation.read(wall.arrangement?.globalOrientation)
        if case .pending = wall.orientation.status {} else {
            orientationDeadlines.removeValue(forKey: deviceID)?.cancel()
        }
        let output = NanoleafOutputState.reported(isOn: info.state.on.value, colorMode: info.state.colorMode,
                                                  selectedEffect: info.selectedEffectName,
                                                  effectsList: info.effects.effectsList, claim: wall.claim)
        var releasedStream: String?
        let agreesWithClaim: Bool
        switch output {
        case .design, .preview, .stream, .off: agreesWithClaim = true
        default: agreesWithClaim = wall.claim == nil
        }
        if !agreesWithClaim && wall.awaitingWrite {
            // Taken before LumenDesk's write landed: says nothing about it.
        } else {
            wall.output = output
            if !agreesWithClaim {
                // Something else is on the wall now. Whatever LumenDesk
                // claimed is no longer showing, a cancelled preview must not
                // undo a choice made after it, and a stream must stop.
                if case .stream(let owner) = wall.claim {
                    releasedStream = owner
                    streamed.removeValue(forKey: deviceID)
                    if let serial = liveSerial(deviceID) { client.stopStream(serial, owner: owner) }
                }
                wall.claim = nil
                previewing.remove(deviceID)
                previewOrigins.removeValue(forKey: deviceID)
            }
        }
        walls[deviceID] = wall
        // The last trusted layout is kept across launches so the editor can
        // draw the wall before the controller answers.
        if wall.arrangement != previousArrangement { persist() }
        return releasedStream
    }

    func didFail(deviceID: String, operation: NanoleafOperation, error: NanoleafError) {
        var wall = self.wall(deviceID)
        switch operation {
        case .orientation:
            wall.orientation.writeFailed(error.localizedDescription)
            orientationDeadlines.removeValue(forKey: deviceID)?.cancel()
        case .panelDisplay:
            wall.lastFailure = error.localizedDescription
            if wall.claim == .design || wall.claim == .preview { wall.output = .unknown }
        default:
            wall.lastFailure = error.localizedDescription
        }
        // A failed state, effect or panel write aborts the rest of that
        // command, and a revoked credential drops everything queued: no
        // acknowledgement is coming, so the next reading decides.
        if [.state, .effect, .panelDisplay].contains(operation) || error == .pairingRequired {
            wall.awaitingWrite = false
        }
        walls[deviceID] = wall
    }

    func didAccept(deviceID: String, operation: NanoleafOperation) {
        var wall = self.wall(deviceID)
        switch operation {
        case .orientation:
            wall.orientation.writeAccepted()
        case .panelDisplay:
            if wall.claim == .design || wall.claim == .preview { wall.awaitingWrite = false }
        default:
            return
        }
        walls[deviceID] = wall
    }

    func didChangeStream(deviceID: String, status: NanoleafStreamStatus) {
        streams[deviceID] = status
        guard case .stream(let owner) = walls[deviceID]?.claim else { return }
        switch status {
        case .streaming(let streaming) where streaming == owner:
            walls[deviceID]?.awaitingWrite = false
        case .idle:
            walls[deviceID]?.claim = nil
            walls[deviceID]?.awaitingWrite = false
        case .failed(let failed, _) where failed == owner:
            walls[deviceID]?.awaitingWrite = false
        default:
            break
        }
    }

    /// Events are hints; the reading that follows is the truth.
    func handle(deviceID: String, event: NanoleafEvent) {
        switch event {
        case .touch(let gesture, let panelID):
            guard gesture == .singleTap || gesture == .doubleTap, let panelID else { return }
            walls[deviceID, default: Wall()].touchedPanel = panelID
            walls[deviceID, default: Wall()].touchedAt = now()
        case .stateChanged, .layoutChanged, .effectChanged:
            if let serial = liveSerial(deviceID) { client.refresh(serial) }
        }
    }

    // MARK: Orientation

    /// Writes the global orientation and waits for the controller to report
    /// it back. In Demo Mode the simulated wall simply takes the value.
    func requestOrientation(_ degrees: Int, for deviceID: String) {
        guard let arrangement = arrangement(deviceID) else { return }
        let value = NanoleafOrientation.writableValue(degrees, range: arrangement.orientation.range)
        var wall = self.wall(deviceID)
        wall.orientation.request(value)
        guard let serial = liveSerial(deviceID) else {
            var simulated = arrangement
            simulated.orientation = .reported(value: value, minimum: 0, maximum: 360)
            wall.arrangement = simulated
            wall.orientation.writeAccepted()
            wall.orientation.read(value)
            walls[deviceID] = wall
            persist()
            return
        }
        walls[deviceID] = wall
        client.setOrientation(serial, degrees: value)
        orientationDeadlines[deviceID]?.cancel()
        orientationDeadlines[deviceID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self, case .pending = self.wall(deviceID).orientation.status else { return }
            self.walls[deviceID]?.orientation.writeFailed("The controller did not report the new orientation.")
        }
    }

    func dismissOrientationFailure(_ deviceID: String) {
        walls[deviceID]?.orientation.clearFailure()
    }

    // MARK: What LumenDesk shows

    /// The applied design, when it is what the wall is showing now.
    func showingDesign(for deviceID: String) -> NanoleafPanelDesign? {
        guard walls[deviceID]?.claim == .design else { return nil }
        return designs[deviceID]
    }

    /// Makes `design` the wall's LumenDesk-owned output and sends it. The
    /// frame covers every light panel on the wall; panels the design does
    /// not cover go out black, and panels the wall no longer has are not sent.
    @discardableResult
    func show(_ design: NanoleafPanelDesign, on deviceID: String, transition: Int = 3) -> NanoleafDesignReconciliation? {
        designs[deviceID] = design
        persist()
        endPreviewTracking(deviceID)
        endSimulatedStream(deviceID)
        var wall = self.wall(deviceID)
        wall.claim = .design
        guard let layout = wall.arrangement?.layout else {
            walls[deviceID] = wall
            return nil
        }
        let frames = design.frames(for: layout, transition: transition)
        wall.lastSent = Dictionary(frames.map { ($0.panelID, $0.rgb) }, uniquingKeysWith: { _, new in new })
        wall.lastSentAt = now()
        let serial = liveSerial(deviceID)
        // A simulated wall shows what it is sent; a real one is confirmed
        // only by reading it back.
        wall.output = .design(confirmed: serial == nil)
        wall.lastFailure = nil
        wall.awaitingWrite = expectsAcknowledgement(serial)
        walls[deviceID] = wall
        if let serial { client.displayPanels(serial, frames: frames) }
        return design.reconciliation(against: layout)
    }

    /// Something other than a LumenDesk design is now on the wall because
    /// LumenDesk itself sent it (a colour, white, or a stored scene). The
    /// applied design is kept for re-applying but no longer counts as shown.
    func outputReplaced(_ deviceID: String, by output: NanoleafOutputState) {
        endPreviewTracking(deviceID)
        endSimulatedStream(deviceID)
        var wall = self.wall(deviceID)
        wall.claim = nil
        wall.awaitingWrite = false
        wall.output = output
        walls[deviceID] = wall
    }

    // MARK: Editing sessions

    func session(_ deviceID: String) -> NanoleafEditingSession? { sessions[deviceID] }

    /// Starts editing. Continuing the applied design needs no choice; any
    /// other start is explicit, because an animated wall's per-panel colours
    /// cannot be read and must not be invented.
    func beginSession(_ deviceID: String, origin: NanoleafEditingSession.Origin, design: NanoleafPanelDesign) {
        guard let layout = layout(deviceID) else { return }
        var draft = design
        // Cover every panel so the draft states each panel's colour.
        for id in layout.paintableIDs where draft[id] == nil { draft.paint(.black, panels: [id]) }
        sessions[deviceID] = NanoleafEditingSession(draft: draft, origin: origin,
                                                    baseline: origin == .appliedDesign ? draft : nil)
    }

    /// Where an editing session can start without guessing.
    func canContinueAppliedDesign(_ deviceID: String) -> Bool {
        showingDesign(for: deviceID) != nil
    }

    func edit(_ deviceID: String, _ change: (inout NanoleafEditingSession) -> Void) {
        guard var session = sessions[deviceID] else { return }
        let before = session.draft
        change(&session)
        sessions[deviceID] = session
        if session.draft != before, previewing.contains(deviceID) { sendPreview(deviceID) }
    }

    /// Shows the draft on the wall as it is edited. The preview is a
    /// temporary display; only Apply makes it the wall's design.
    func setPreviewing(_ on: Bool, for deviceID: String) {
        guard sessions[deviceID] != nil else { return }
        if on {
            guard !previewing.contains(deviceID) else { return }
            let wall = self.wall(deviceID)
            previewOrigins[deviceID] = PreviewOrigin(output: wall.output, claim: wall.claim)
            previewing.insert(deviceID)
            sendPreview(deviceID)
        } else {
            _ = endPreview(deviceID, restore: true)
        }
    }

    private func sendPreview(_ deviceID: String) {
        guard let session = sessions[deviceID], let layout = layout(deviceID) else { return }
        endSimulatedStream(deviceID)
        let frames = session.draft.frames(for: layout, transition: 1)
        var wall = self.wall(deviceID)
        wall.claim = .preview
        wall.output = .preview
        wall.lastSent = Dictionary(frames.map { ($0.panelID, $0.rgb) }, uniquingKeysWith: { _, new in new })
        wall.lastSentAt = now()
        let serial = liveSerial(deviceID)
        wall.awaitingWrite = expectsAcknowledgement(serial)
        walls[deviceID] = wall
        if let serial { client.displayPanels(serial, frames: frames, refresh: false) }
    }

    /// Ends a preview. With `restore`, puts back what was showing before it,
    /// but only while the preview is still what LumenDesk owns: a choice
    /// made in another app after the preview began is never overwritten.
    /// Returns a sentence when the earlier output cannot be put back.
    @discardableResult
    func endPreview(_ deviceID: String, restore: Bool) -> String? {
        guard previewing.contains(deviceID) else { return nil }
        previewing.remove(deviceID)
        let origin = previewOrigins.removeValue(forKey: deviceID)
        guard restore, walls[deviceID]?.claim == .preview, let origin else { return nil }
        let serial = liveSerial(deviceID)
        switch origin.output {
        case .design:
            if let design = designs[deviceID] { show(design, on: deviceID) }
        case .nativeEffect(let name):
            walls[deviceID]?.claim = nil
            walls[deviceID]?.output = .nativeEffect(name: name)
            if let serial { client.selectEffect(serial, name: name) }
        case .solid, .white:
            walls[deviceID]?.claim = nil
            walls[deviceID]?.output = origin.output
            restoreWholeWall(deviceID)
        case .off:
            walls[deviceID]?.claim = nil
        case .unknown, .external, .preview, .stream:
            walls[deviceID]?.claim = nil
            return "The wall was playing an animation LumenDesk cannot read back, so the preview stays until you choose a scene or apply a design."
        }
        return nil
    }

    private func endPreviewTracking(_ deviceID: String) {
        previewing.remove(deviceID)
        previewOrigins.removeValue(forKey: deviceID)
    }

    /// A real client ends its stream when any other output is sent and says
    /// so; a simulated wall has no client, so the same happens here.
    private func endSimulatedStream(_ deviceID: String) {
        guard !isLive(), case .stream = walls[deviceID]?.claim else { return }
        streams[deviceID] = .idle
        streamed.removeValue(forKey: deviceID)
    }

    /// Closes the session. The draft is discarded; any preview on the wall is
    /// ended and, where possible, the earlier output restored.
    @discardableResult
    func endSession(_ deviceID: String) -> String? {
        let message = endPreview(deviceID, restore: true)
        sessions.removeValue(forKey: deviceID)
        return message
    }

    /// Marks the session's draft applied after LightManager has shown it.
    func markApplied(_ deviceID: String) {
        guard var session = sessions[deviceID] else { return }
        session.markApplied()
        sessions[deviceID] = session
    }

    // MARK: Identification

    /// Breathes one panel for four seconds; the controller then restores
    /// whatever it was showing by itself.
    func identifyPanel(_ panelID: Int, on deviceID: String) {
        guard let layout = layout(deviceID), layout.paintableIDs.contains(panelID),
              let serial = liveSerial(deviceID) else { return }
        client.identifyPanel(serial, panelID: panelID, layout: layout)
    }

    func identifyWall(_ deviceID: String) {
        guard let serial = liveSerial(deviceID) else { return }
        client.identifyController(serial)
    }

    // MARK: Library and stored scenes

    func loadLibrary(_ deviceID: String) async {
        guard let serial = liveSerial(deviceID) else {
            libraries[deviceID] = .failed("Stored scenes are read from a real controller. Leave Demo Mode to browse them.")
            return
        }
        libraries[deviceID] = .loading
        do {
            let effects = try await client.effectLibrary(serial)
            let plugins = (try? await client.plugins(serial)) ?? []
            libraries[deviceID] = .loaded(effects, plugins)
        } catch {
            libraries[deviceID] = .failed((error as? NanoleafError ?? .unavailable).localizedDescription)
        }
    }

    func definition(named name: String, on deviceID: String) -> NanoleafEffectDefinition? {
        guard case .loaded(let effects, _) = libraries[deviceID] else { return nil }
        return effects.first { $0.name == name }
    }

    func previewEffect(_ definition: NanoleafEffectDefinition, on deviceID: String) async throws {
        guard let serial = liveSerial(deviceID) else { throw NanoleafError.unavailable }
        outputReplaced(deviceID, by: .external("Previewing an edited scene"))
        try await client.previewEffect(serial, definition)
    }

    func saveEffect(_ definition: NanoleafEffectDefinition, as name: String, on deviceID: String,
                    allowOverwrite: Bool) async throws {
        guard let serial = liveSerial(deviceID) else { throw NanoleafError.unavailable }
        try await client.saveEffect(serial, definition, name: name, allowOverwrite: allowOverwrite)
        await loadLibrary(deviceID)
    }

    /// Stores a design on the controller as a named static scene, so it
    /// keeps working without LumenDesk. Returns whether reading it back
    /// matched what was sent.
    func saveToController(_ design: NanoleafPanelDesign, as name: String, on deviceID: String,
                          allowOverwrite: Bool) async throws -> Bool {
        guard let serial = liveSerial(deviceID), let layout = layout(deviceID) else { throw NanoleafError.unavailable }
        let verified = try await client.saveStaticDesign(serial, name: name,
                                                         frames: design.frames(for: layout, transition: 5),
                                                         allowOverwrite: allowOverwrite)
        if case .loaded = libraries[deviceID] { await loadLibrary(deviceID) }
        return verified
    }

    // MARK: Saved designs and groups

    @discardableResult
    func saveDesign(_ design: NanoleafPanelDesign, named name: String, for deviceID: String) -> NanoleafSavedDesign? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let saved = NanoleafSavedDesign(name: trimmed, deviceID: deviceID, design: design, createdAt: now())
        savedDesigns.append(saved)
        persist()
        return saved
    }

    func deleteSavedDesign(_ id: UUID) {
        savedDesigns.removeAll { $0.id == id }
        persist()
    }

    func savedDesigns(for deviceID: String) -> [NanoleafSavedDesign] {
        savedDesigns.filter { $0.deviceID == deviceID }
    }

    func saveGroup(named name: String, panelIDs: Set<Int>, for deviceID: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !panelIDs.isEmpty else { return }
        groups[deviceID, default: []].append(NanoleafPanelGroup(name: trimmed, panelIDs: Array(panelIDs)))
        persist()
    }

    func deleteGroup(_ id: UUID, for deviceID: String) {
        groups[deviceID]?.removeAll { $0.id == id }
        persist()
    }

    // MARK: Live output

    /// Whether this wall has light panels a live stream can address. A
    /// failed stream does not count against it: every show tries afresh.
    func canStream(_ deviceID: String) -> Bool {
        !(layout(deviceID)?.paintablePanels.isEmpty ?? true)
    }

    /// True once `owner`'s stream failed to open. Its frames go nowhere, so
    /// the show falls back to whole-wall colour for this wall.
    func streamFailed(_ deviceID: String, owner: String) -> Bool {
        if case .failed(let failed, _) = streams[deviceID] ?? .idle { return failed == owner }
        return false
    }

    func beginStream(_ deviceID: String, owner: String) {
        endPreviewTracking(deviceID)
        walls[deviceID, default: Wall()].claim = .stream(owner: owner)
        streamed[deviceID] = [:]
        guard let serial = liveSerial(deviceID) else {
            streams[deviceID] = .streaming(owner: owner)
            return
        }
        // Starting again for the owner already streaming keeps that stream,
        // and no new acknowledgement comes for it.
        let alreadyOpen = client.streamStatus(serial) == .streaming(owner: owner)
        walls[deviceID]?.awaitingWrite = expectsAcknowledgement(serial) && !alreadyOpen
        client.startStream(serial, owner: owner)
    }

    func submit(_ frames: [NanoleafPanelFrame], to deviceID: String, owner: String) {
        guard case .stream(let claimed) = walls[deviceID]?.claim, claimed == owner else { return }
        for frame in frames { streamed[deviceID, default: [:]][frame.panelID] = frame.rgb }
        let time = now()
        let current = wall(deviceID)
        if current.output != .stream(owner: owner) || current.lastSentAt.map({ time.timeIntervalSince($0) >= Self.streamPublishInterval }) ?? true {
            var wall = current
            wall.lastSent.merge(streamed[deviceID] ?? [:]) { _, new in new }
            wall.lastSentAt = time
            wall.output = .stream(owner: owner)
            walls[deviceID] = wall
        }
        if let serial = liveSerial(deviceID) { client.submitStreamFrame(serial, owner: owner, frames: frames) }
    }

    /// What `owner` last streamed to the wall, panel by panel, as a design:
    /// how a show that ends without restoring leaves its final look behind
    /// as a static layout LumenDesk can account for.
    func lastStreamedDesign(_ deviceID: String, owner: String) -> NanoleafPanelDesign? {
        guard case .stream(let claimed) = walls[deviceID]?.claim, claimed == owner,
              let layout = layout(deviceID) else { return nil }
        let onWall = (streamed[deviceID] ?? [:]).filter { layout.paintableIDs.contains($0.key) }
        guard !onWall.isEmpty else { return nil }
        return NanoleafDesignBuilder.design(staticColors: onWall)
    }

    /// Ends one owner's stream. A newer owner's stream is left alone.
    func endStream(_ deviceID: String, owner: String) {
        guard case .stream(let claimed) = walls[deviceID]?.claim, claimed == owner else { return }
        walls[deviceID]?.claim = nil
        walls[deviceID]?.awaitingWrite = false
        streamed.removeValue(forKey: deviceID)
        if let serial = liveSerial(deviceID) {
            client.stopStream(serial, owner: owner)
        } else {
            streams[deviceID] = .idle
        }
    }

    func streamMetrics(_ deviceID: String) -> NanoleafStreamMetrics? {
        guard let serial = Self.serial(for: deviceID) else { return nil }
        return client.streamMetrics(serial)
    }
}

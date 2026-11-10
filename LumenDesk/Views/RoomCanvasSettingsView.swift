import SwiftUI
import Foundation
import UniformTypeIdentifiers

struct RoomLookBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// The Settings tabs, in the artboard's order.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case livePrivacy = "Live privacy"
    case backup = "Backup"
    case sampleRoom = "Sample Room"
    case network = "Network"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .livePrivacy: return "hand.raised"
        case .backup: return "externaldrive"
        case .sampleRoom: return "testtube.2"
        case .network: return "network"
        }
    }
}

/// Polar Settings. In the macOS Settings scene (⌘,) it uses the system's
/// toolbar tabs; shown as a sheet or on iOS it draws the same tabs as a
/// pill bar, as on the artboard.
struct RoomCanvasSettingsView: View {
    enum Style { case toolbarTabs, pillTabs }

    @EnvironmentObject private var manager: LightManager
    @AppStorage(AppPreferenceKey.quietInterface) private var quietInterface = false
    @AppStorage(AppPreferenceKey.confirmationPolicy) private var confirmationPolicy = ConfirmationPolicy.balanced.rawValue
    @AppStorage(AppPreferenceKey.audioPrivacyAcknowledged) private var audioAcknowledged = false
    @State private var backupDocument: RoomLookBackupDocument = RoomLookBackupDocument()
    @State private var exportingBackup: Bool = false
    @State private var importingBackup: Bool = false
    @State private var backupStatus: String? = nil
    @State private var tab: SettingsTab
    @State private var pairingNanoleaf = false
    @Environment(\.dismiss) private var dismiss
    let style: Style
    let showsDone: Bool

    init(style: Style = .pillTabs, initialTab: SettingsTab = .general, showsDone: Bool = false) {
        self.style = style
        self.showsDone = showsDone
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        Group {
            if style == .toolbarTabs {
                TabView(selection: $tab) {
                    ForEach(SettingsTab.allCases) { item in
                        page(item)
                            .tabItem { Label(item.rawValue, systemImage: item.symbol) }
                            .tag(item)
                    }
                }
                .frame(width: 560, height: 440)
            } else {
                VStack(spacing: 0) {
                    pillBar
                    page(tab)
                }
            }
        }
        .background(Polar.stage)
        .foregroundStyle(Polar.chalk)
        .font(.polarUI(13))
        .navigationTitle("Settings")
        .sheet(isPresented: $pairingNanoleaf) {
            NanoleafPairingView().environmentObject(manager)
        }
        .fileExporter(
            isPresented: $exportingBackup,
            document: backupDocument,
            contentType: .json,
            defaultFilename: "LumenDesk-Rooms-and-Looks"
        ) { result in
            switch result {
            case .success(let url):
                backupStatus = "Saved \(url.lastPathComponent)"
            case .failure(let error):
                reportDocumentError(error, action: "Backup")
            }
        }
        .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                restoreBackup(from: url)
            case .failure(let error):
                reportDocumentError(error, action: "Restore")
            }
        }
    }

    private var pillBar: some View {
        HStack(spacing: 6) {
            ForEach(SettingsTab.allCases) { item in
                Button(item.rawValue) { tab = item }
                    .buttonStyle(PolarButtonStyle(kind: tab == item ? .prominent : .quiet, compact: true))
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            if showsDone {
                Button("Done") { dismiss() }
                    .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
                    .keyboardShortcut(.cancelAction)
                    .padding(.trailing, 12)
            }
        }
        .padding(.vertical, 10)
        .background(Polar.desk)
        .overlay(alignment: .bottom) { Rectangle().fill(Polar.ruleSoft).frame(height: 1) }
    }

    private func page(_ item: SettingsTab) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PolarSpacing.md) {
                Text(item.rawValue)
                    .font(.polarDisplay(22, weight: .bold))
                switch item {
                case .general: generalPage
                case .livePrivacy: livePrivacyPage
                case .backup: backupPage
                case .sampleRoom: sampleRoomPage
                case .network: networkPage
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.horizontal, PolarSpacing.lg)
            .padding(.vertical, PolarSpacing.lg)
            .frame(maxWidth: .infinity)
        }
        .background(Polar.stage)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .polarPanel(fill: Polar.desk, radius: Polar.radiusCard, padding: 14)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.polarUI(11))
            .foregroundStyle(Polar.meter)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Pages

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: PolarSpacing.sm) {
            card {
                HStack {
                    Text("Confirmation policy")
                    Spacer()
                    Picker("Confirmation policy", selection: $confirmationPolicy) {
                        ForEach(ConfirmationPolicy.allCases) { policy in
                            Text(policy.title).tag(policy.rawValue)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                HStack {
                    Text("Quiet interface")
                    Spacer()
                    Toggle("Quiet interface", isOn: $quietInterface)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(Polar.accent)
                }
                footnote("Reduces decorative motion. System accessibility settings remain authoritative.")
            }
            HStack(spacing: 4) {
                footnote("Local-first \u{00B7} no vendor cloud accounts. Keyboard:")
                Text("\u{2318},")
                    .font(.polarMono(10, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Polar.raised))
            }
        }
    }

    private var livePrivacyPage: some View {
        VStack(alignment: .leading, spacing: PolarSpacing.sm) {
            card {
                HStack {
                    Text("I understand local audio analysis")
                    Spacer()
                    Toggle("I understand local audio analysis", isOn: $audioAcknowledged)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(Polar.accent)
                }
                footnote("Live analyzes audio on this device and does not keep recordings. macOS may ask for Screen & System Audio Recording access; iPhone and iPad may ask for the microphone.")
                Button("Open Privacy Settings") {
                    PlatformOpener.openSettings(macPane: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                }
                .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
            }
        }
    }

    private var backupPage: some View {
        VStack(alignment: .leading, spacing: PolarSpacing.sm) {
            card {
                HStack(spacing: 10) {
                    Button("Back Up\u{2026}") { prepareBackup() }
                        .buttonStyle(PolarButtonStyle(kind: .prominent, compact: true))
                    Button("Restore\u{2026}") { importingBackup = true }
                        .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
                }
                footnote("Exports a portable JSON backup of rooms, Looks, light names, favorites and spatial layouts. Restoring asks before replacing anything.")
                if let backupStatus {
                    Label(backupStatus, systemImage: "checkmark.circle")
                        .font(.polarUI(11, weight: .semibold))
                        .foregroundStyle(Polar.mint)
                }
            }
        }
    }

    private var sampleRoomPage: some View {
        VStack(alignment: .leading, spacing: PolarSpacing.sm) {
            card {
                if manager.isDemoMode {
                    Label("No physical lights are being controlled", systemImage: "checkmark.shield")
                        .foregroundStyle(Polar.mint)
                    HStack(spacing: 10) {
                        Button("Reset Sample Room") { manager.resetDemoMode() }
                            .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
                        Button("Return to live rooms") { manager.exitDemoMode() }
                            .buttonStyle(PolarButtonStyle(kind: .prominent, compact: true))
                    }
                } else {
                    Button("Open Sample Room") { manager.enterDemoMode() }
                        .buttonStyle(PolarButtonStyle(kind: .prominent, compact: true))
                    footnote("The Sample Room is isolated from discovered lights and saved rooms.")
                }
            }
        }
    }

    private var networkPage: some View {
        VStack(alignment: .leading, spacing: PolarSpacing.sm) {
            card {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(manager.isScanning ? manager.scanPhase : "\(manager.devices.count) lights answering")
                        Text(brandSummary)
                            .font(.polarMono(11))
                            .foregroundStyle(Polar.meter)
                    }
                    Spacer()
                    Button("Refresh network") { manager.scan() }
                        .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
                        .disabled(manager.isScanning || manager.isDemoMode)
                }
                HStack {
                    Text("Nanoleaf controllers")
                    Spacer()
                    Button("Pair Nanoleaf\u{2026}") { pairingNanoleaf = true }
                        .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
                        .disabled(manager.isDemoMode)
                }
                if manager.isDemoMode {
                    footnote("Sample Room is open, so LumenDesk isn't talking to the network.")
                }
            }
            if !manager.devices.isEmpty {
                card {
                    ForEach(manager.devices) { device in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(device.isStale ? Polar.attention : Polar.mint)
                                .frame(width: 7, height: 7)
                            Text(device.label).lineLimit(1)
                            Spacer()
                            Text(device.address)
                                .font(.polarMono(11))
                                .foregroundStyle(Polar.meter)
                        }
                    }
                }
            }
            footnote("LumenDesk talks to LIFX, Govee and Nanoleaf directly on your local network. There's no bridge or cloud account.")
        }
    }

    private var brandSummary: String {
        let counts = Dictionary(grouping: manager.devices, by: \.brand).mapValues(\.count)
        return [LightDevice.Brand.lifx, .govee, .nanoleaf]
            .map { "\($0.displayName) \(counts[$0] ?? 0)" }
            .joined(separator: " \u{00B7} ")
    }

    private func prepareBackup() {
        guard let data = manager.exportConfigurationData() else {
            manager.publishError("Backup failed — LumenDesk could not encode the current Rooms & Looks configuration.")
            return
        }
        backupDocument = RoomLookBackupDocument(data: data)
        backupStatus = nil
        exportingBackup = true
    }

    private func restoreBackup(from url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            backupStatus = nil
            manager.requestConfigurationImport(data, fileName: url.lastPathComponent)
        } catch {
            manager.publishError("Restore failed — could not read “\(url.lastPathComponent)”: \(error.localizedDescription)")
        }
    }

    private func reportDocumentError(_ error: Error, action: String) {
        let cocoaError = error as NSError
        guard cocoaError.domain != NSCocoaErrorDomain || cocoaError.code != NSUserCancelledError else { return }
        manager.publishError("\(action) failed — \(error.localizedDescription)")
    }
}

// MARK: - Add lights

/// The three steps of Polar "Add lights".
enum AddLightsStep: Int, CaseIterable, Identifiable {
    case discover
    case place
    case verify
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .discover: return "Scan LAN"
        case .place: return "Place in a room"
        case .verify: return "Verify"
        }
    }

    /// "Step 1 of 3 · Scan LAN"
    var caption: String { "Step \(rawValue + 1) of \(Self.allCases.count) \u{00B7} \(title)" }
}

enum RoomCommissioningProgress {
    static func canContinueFromFind(selectedCount: Int, discoveredCount: Int) -> Bool {
        discoveredCount == 0 || selectedCount > 0
    }
}

/// Polar Add lights: 1 scan the LAN and pick lights (Nanoleaf controllers
/// pair from here), 2 place them in a room, 3 verify each one answers.
struct AddOrRepairRoomView: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedRoomID: UUID?
    let onFinish: () -> Void
    var initialStep: AddLightsStep = .discover
    @State private var step: AddLightsStep = .discover
    @State private var selectedIDs: Set<String> = []
    @State private var targetRoomID: UUID? = nil
    @State private var newRoomName: String = ""
    @State private var pairingCandidate: NanoleafCandidate? = nil
    @State private var showingManualPairing: Bool = false
    @State private var manualPairingHost: String = ""
    /// Step 2 canvas selection. Kept apart from `selectedIDs` (the lights
    /// being added), so clicking an orb never drops it from the add list.
    @State private var placementSelection: Set<String> = []
    @State private var fixtureNameDrafts: [String: String] = [:]
    @State private var started = false

    private var targetRoom: Room? {
        manager.rooms.first { $0.id == targetRoomID }
    }

    private var placementLights: [LightDevice] {
        guard let targetRoom else { return [] }
        let placed = manager.devices(in: targetRoom)
        let placedIDs = Set(placed.map(\.id))
        return placed + manager.devices.filter {
            selectedIDs.contains($0.id) && !placedIDs.contains($0.id)
        }
    }

    /// Nanoleaf controllers seen on the network that no light stands for yet.
    private var unpairedControllers: [NanoleafCandidate] {
        let known = Set(manager.devices.filter { $0.brand == .nanoleaf }.map(\.address))
        return manager.nanoleafCandidates.filter { !known.contains($0.endpoint.host) }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                Group {
                    switch step {
                    case .discover: discoverStep
                    case .place: placeStep
                    case .verify: verifyStep
                    }
                }
                .padding(PolarSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            footer
        }
        .background(Polar.stage)
        .foregroundStyle(Polar.chalk)
        .font(.polarUI(13))
        .sheetFrame(minWidth: 680, idealWidth: 820, minHeight: 520, idealHeight: 640)
        .sheet(item: $pairingCandidate) { candidate in
            NanoleafPairingView(candidate: candidate, preferredRoomID: selectedRoomID) { id in
                selectedIDs.insert(id)
            }
            .environmentObject(manager)
        }
        .sheet(isPresented: $showingManualPairing) {
            NanoleafPairingView(preferredRoomID: selectedRoomID, onPaired: { id in
                selectedIDs.insert(id)
            }, initialHost: manualPairingHost)
            .environmentObject(manager)
        }
        .onAppear {
            guard !started else { return }
            started = true
            step = initialStep
            if targetRoomID == nil { targetRoomID = selectedRoomID ?? manager.rooms.first?.id }
            if step == .discover { manager.scan() }
        }
        .onDisappear { manager.endSustainedIdentify() }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: PolarSpacing.sm) {
            Text(step.caption)
                .font(.polarUI(12, weight: .semibold))
                .foregroundStyle(Polar.meter)
            HStack(spacing: 4) {
                ForEach(AddLightsStep.allCases) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Polar.accent : Polar.raised)
                        .frame(width: 22, height: 4)
                }
            }
            .accessibilityHidden(true)
            Spacer()
            Button {
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, PolarSpacing.lg)
        .padding(.vertical, 12)
        .background(Polar.desk)
        .overlay(alignment: .bottom) { Rectangle().fill(Polar.ruleSoft).frame(height: 1) }
    }

    private var footer: some View {
        HStack(spacing: PolarSpacing.sm) {
            if step != .discover {
                Button("Back") {
                    manager.endSustainedIdentify()
                    step = AddLightsStep(rawValue: step.rawValue - 1) ?? .discover
                }
                .buttonStyle(PolarButtonStyle(kind: .quiet))
            }
            Text(footerNote)
                .font(.polarUI(12))
                .foregroundStyle(Polar.meter)
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(PolarButtonStyle(kind: .quiet))
            Button(primaryButtonTitle) { advance() }
                .buttonStyle(PolarButtonStyle(kind: .prominent))
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdvance)
        }
        .padding(PolarSpacing.md)
        .background(Polar.desk)
        .overlay(alignment: .top) { Rectangle().fill(Polar.ruleSoft).frame(height: 1) }
    }

    // MARK: Step 1 · Scan LAN

    private var discoverStep: some View {
        VStack(alignment: .leading, spacing: PolarSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(manager.isDemoMode
                     ? "LIFX \u{00B7} Govee \u{00B7} Nanoleaf in the Sample Room. Nothing here reaches a real light."
                     : "LIFX \u{00B7} Govee \u{00B7} Nanoleaf on this Mac\u{2019}s network.")
                    .font(.polarUI(13))
                    .foregroundStyle(Polar.meter)
                Spacer()
                Button {
                    manager.scan()
                } label: {
                    Label(manager.isScanning ? manager.scanPhase : "Scan again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
                .disabled(manager.isScanning)
                Button("Pair Nanoleaf by address\u{2026}") {
                    manualPairingHost = ""
                    showingManualPairing = true
                }
                    .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
            }

            if manager.devices.isEmpty && unpairedControllers.isEmpty {
                emptyDiscovery
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(manager.devices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { Rectangle().fill(Polar.ruleSoft).frame(height: 1) }
                        discoveryRow(device)
                    }
                    ForEach(unpairedControllers) { candidate in
                        Rectangle().fill(Polar.ruleSoft).frame(height: 1)
                        controllerRow(candidate)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Polar.radiusCard, style: .continuous).fill(Polar.desk))
                .overlay(RoundedRectangle(cornerRadius: Polar.radiusCard, style: .continuous)
                    .stroke(Polar.ruleSoft, lineWidth: 1))
            }

            Text("Lights not showing? Switch them on at the wall and keep this Mac on the same Wi\u{2011}Fi. Some managed networks block discovery replies; a missing light isn\u{2019}t proof it\u{2019}s offline.")
                .font(.polarUI(11))
                .foregroundStyle(Polar.meter)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func roomName(for device: LightDevice) -> String? {
        manager.rooms.first { $0.lightIDs.contains(device.id) }?.name
    }

    private func modelLine(_ device: LightDevice) -> String {
        let line = LightPageModel.resolve(device).modelLine
        let model = line.isEmpty
            ? [device.brand.displayName, device.sku].compactMap { $0 }.joined(separator: " ")
            : line.components(separatedBy: " \u{00B7} ").prefix(2).joined(separator: " \u{00B7} ")
        if device.needsNanoleafPairing { return "\(model) \u{00B7} needs pair" }
        if let room = roomName(for: device) { return "\(model) \u{00B7} \(room)" }
        return model
    }

    private func discoveryRow(_ device: LightDevice) -> some View {
        let selected = selectedIDs.contains(device.id)
        return HStack(spacing: 12) {
            GlowingOrb(color: device.color, level: device.brightness, isOn: device.isOn,
                       silhouette: LightPageModel.resolve(device).silhouette, size: 26, stale: device.isStale)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.label).font(.polarUI(13, weight: .semibold))
                Text(modelLine(device))
                    .font(.polarUI(11))
                    .foregroundStyle(Polar.meter)
                    .lineLimit(1)
            }
            Spacer()
            if device.isStale {
                Label("No reply", systemImage: "wifi.slash")
                    .font(.polarMono(11))
                    .foregroundStyle(Polar.attention)
            }
            Button {
                manager.identify(device)
            } label: {
                Image(systemName: "wand.and.rays")
            }
            .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
            .help("Identify \u{2014} flash this light, then restore it")
            .accessibilityLabel("Identify \(device.label)")
            .disabled(device.isStale)
            if device.needsNanoleafPairing {
                Button("Pair\u{2026}") {
                    pairingCandidate = manager.nanoleafCandidates.first { $0.endpoint.host == device.address }
                    if pairingCandidate == nil {
                        manualPairingHost = device.address
                        showingManualPairing = true
                    }
                }
                .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
            } else {
                Button(selected ? "Added" : "Add") {
                    if selected { selectedIDs.remove(device.id) } else { selectedIDs.insert(device.id) }
                }
                .buttonStyle(PolarButtonStyle(kind: selected ? .selected : .prominent, compact: true))
                .frame(minWidth: 64)
                .accessibilityValue(selected ? "Added" : "Not added")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func controllerRow(_ candidate: NanoleafCandidate) -> some View {
        HStack(spacing: 12) {
            GlowingOrb(color: Polar.chalk, level: 0.5, isOn: false, silhouette: .panels, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name).font(.polarUI(13, weight: .semibold))
                Text("Nanoleaf\(candidate.model.map { " \($0)" } ?? "") \u{00B7} needs pair")
                    .font(.polarUI(11))
                    .foregroundStyle(Polar.meter)
            }
            Spacer()
            Button("Pair\u{2026}") { pairingCandidate = candidate }
                .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyDiscovery: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Polar.meter)
            Text("No lights have answered yet")
                .font(.polarDisplay(18, weight: .bold))
            Text("Keep this open for a few seconds. You can continue with an empty room, or explore the isolated Sample Room.")
                .font(.polarUI(12))
                .foregroundStyle(Polar.meter)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button("Scan again") { manager.scan() }
                    .buttonStyle(PolarButtonStyle(kind: .quiet))
                    .disabled(manager.isScanning)
                Button("Open Sample Room") { openSampleRoom() }
                    .buttonStyle(PolarButtonStyle(kind: .prominent))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .polarPanel(padding: 0)
    }

    // MARK: Step 2 · Place

    private var placeStep: some View {
        VStack(alignment: .leading, spacing: PolarSpacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Which room are they in?")
                    .font(.polarDisplay(20, weight: .bold))
                Text("Pick a room, then drag each orb roughly to where the light sits. Placement is a memory aid, not a floor plan.")
                    .font(.polarUI(12))
                    .foregroundStyle(Polar.meter)
            }
            FlowChips(items: manager.rooms.map { ($0.id, $0.name) }, selected: targetRoomID) { id in
                targetRoomID = id
            }
            HStack(spacing: 8) {
                TextField("New room name", text: $newRoomName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit(createRoom)
                Button("Create room") { createRoom() }
                    .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
                    .disabled(newRoomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let targetRoom {
                DirectionARoomField(
                    room: targetRoom,
                    lights: placementLights,
                    selection: $placementSelection
                )
                .frame(height: 320)
            } else {
                Text("Choose or create the room these lights belong to.")
                    .font(.polarUI(13))
                    .foregroundStyle(Polar.meter)
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .polarPanel()
            }
        }
    }

    // MARK: Step 3 · Verify

    private var verifyStep: some View {
        VStack(alignment: .leading, spacing: PolarSpacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Check each light answers")
                    .font(.polarDisplay(20, weight: .bold))
                Text("Identify flashes a light and puts it back. Rename anything whose name won\u{2019}t make sense in the room.")
                    .font(.polarUI(12))
                    .foregroundStyle(Polar.meter)
            }
            if let targetRoom {
                VStack(spacing: 8) {
                    ForEach(manager.devices(in: targetRoom)) { device in
                        verifyRow(device)
                    }
                }
            }
        }
    }

    private func verifyRow(_ device: LightDevice) -> some View {
        let status = RoomCanvasStatus.resolve([device], manager: manager)
        return HStack(spacing: 12) {
            GlowingOrb(color: device.color, level: device.brightness, isOn: device.isOn,
                       silhouette: LightPageModel.resolve(device).silhouette, size: 24, stale: device.isStale)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Light name", text: fixtureNameBinding(device))
                    .textFieldStyle(.plain)
                    .font(.polarUI(13, weight: .semibold))
                    .onSubmit { saveFixtureName(device) }
                Text(device.isStale ? "No reply \u{00B7} check power and Wi\u{2011}Fi" : "\(status.title) \u{00B7} \(device.address)")
                    .font(.polarMono(11))
                    .foregroundStyle(device.isStale ? Polar.attention : status.color)
                if let warning = manager.duplicateNameMessage(fixtureNameDrafts[device.id] ?? device.label,
                                                              excludingDeviceID: device.id) {
                    Text(warning).font(.polarUI(11)).foregroundStyle(Polar.pending)
                }
            }
            Spacer()
            if fixtureNameHasChanges(device) {
                Button("Save name") { saveFixtureName(device) }
                    .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
            }
            if device.isStale {
                Button("Retry") { manager.scan() }
                    .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
            } else {
                Button("Identify") { manager.identify(device) }
                    .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Polar.desk))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Polar.ruleSoft, lineWidth: 1))
    }

    // MARK: Flow

    private var canAdvance: Bool {
        switch step {
        case .discover:
            return RoomCommissioningProgress.canContinueFromFind(
                selectedCount: selectedIDs.count,
                discoveredCount: manager.devices.count
            )
        case .place: return targetRoomID != nil
        case .verify: return true
        }
    }

    private var primaryButtonTitle: String {
        switch step {
        case .discover: return manager.devices.isEmpty ? "Continue without lights" : "Continue"
        case .place: return "Continue"
        case .verify: return "Open room"
        }
    }

    private var footerNote: String {
        switch step {
        case .discover:
            return manager.devices.isEmpty
                ? "Lights can be added later"
                : "\(selectedIDs.count) light\(selectedIDs.count == 1 ? "" : "s") to add"
        case .place: return targetRoom?.name ?? "Choose a room"
        case .verify: return "Best-effort confirmation from the lights themselves"
        }
    }

    private func advance() {
        switch step {
        case .discover:
            manager.endSustainedIdentify()
            if targetRoomID == nil { targetRoomID = selectedRoomID ?? manager.rooms.first?.id }
            step = .place
        case .place:
            guard let targetRoomID else { return }
            if let targetRoom {
                let defaults = PlanLayout.defaultAnchors(count: placementLights.count)
                for (index, device) in placementLights.enumerated() {
                    guard targetRoom.fixtureAnchors[device.id] == nil,
                          defaults.indices.contains(index) else { continue }
                    manager.setPlanAnchor(defaults[index], for: device.id, in: targetRoomID)
                }
            }
            manager.assign(lightIDs: selectedIDs, toRoom: targetRoomID)
            manager.ensurePlanLayout()
            selectedRoomID = targetRoomID
            step = .verify
        case .verify:
            onFinish()
            dismiss()
        }
    }

    private func createRoom() {
        guard let id = manager.addRoom(named: newRoomName) else { return }
        targetRoomID = id
        newRoomName = ""
    }

    private func openSampleRoom() {
        manager.endSustainedIdentify()
        manager.enterDemoMode()
        selectedRoomID = manager.rooms.first?.id
        onFinish()
        dismiss()
    }

    private func fixtureNameBinding(_ device: LightDevice) -> Binding<String> {
        Binding(
            get: { fixtureNameDrafts[device.id] ?? device.label },
            set: { fixtureNameDrafts[device.id] = $0 }
        )
    }

    private func fixtureNameHasChanges(_ device: LightDevice) -> Bool {
        guard let draft = fixtureNameDrafts[device.id] else { return false }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines) != device.label
    }

    private func saveFixtureName(_ device: LightDevice) {
        let draft = fixtureNameDrafts[device.id] ?? device.label
        manager.setCustomName(device.id, name: draft)
        fixtureNameDrafts[device.id] = device.label
    }
}

// MARK: - Contextual capability editor

struct ContextualFixtureEditor: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var device: LightDevice

    var body: some View {
        NavigationStack {
            // Every light now opens its own Polar light page, which picks
            // the controls for the exact model (see `LightPageModel`).
            LightPageView(device: device, close: { dismiss() })
                .sheetFrame(minWidth: 760, idealWidth: 1040, minHeight: 600, idealHeight: 800)
                .navigationTitle(device.label)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .font(LumenType.body())
        .foregroundStyle(Lumen.graphite)
    }
}

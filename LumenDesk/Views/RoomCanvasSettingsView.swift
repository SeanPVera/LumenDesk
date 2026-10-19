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

struct RoomCanvasSettingsView: View {
    @EnvironmentObject private var manager: LightManager
    @AppStorage(AppPreferenceKey.quietInterface) private var quietInterface = false
    @AppStorage(AppPreferenceKey.confirmationPolicy) private var confirmationPolicy = ConfirmationPolicy.balanced.rawValue
    @AppStorage(AppPreferenceKey.audioPrivacyAcknowledged) private var audioAcknowledged = false
    @State private var backupDocument = RoomLookBackupDocument()
    @State private var exportingBackup = false
    @State private var importingBackup = false
    @State private var backupStatus: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("SETTINGS")
                        .font(LumenType.instrumentLabel(size: 10))
                        .tracking(1.4)
                        .foregroundStyle(Lumen.ember)
                    Text("Room Canvas")
                        .font(LumenType.display(size: 30, weight: .bold))
                    Text("A small set of preferences for immediate, local room control.")
                        .font(LumenType.body(size: 13))
                        .foregroundStyle(Lumen.meter)
                }

                settingsSection("Interaction", symbol: "hand.tap") {
                    Picker("Confirmation", selection: $confirmationPolicy) {
                        ForEach(ConfirmationPolicy.allCases) { policy in
                            Text(policy.title).tag(policy.rawValue)
                        }
                    }
                    Toggle("Quiet interface", isOn: $quietInterface)
                    Text("Quiet interface reduces decorative motion. System accessibility settings remain authoritative.")
                        .font(LumenType.body(size: 11))
                        .foregroundStyle(Lumen.meter)
                }

                settingsSection("Live privacy", symbol: "hand.raised") {
                    Toggle("I understand local audio analysis", isOn: $audioAcknowledged)
                    Text("Live analyzes audio on this device and does not retain recordings. macOS may request Screen & System Audio Recording access; iPhone and iPad may request microphone access.")
                        .font(LumenType.body(size: 11))
                        .foregroundStyle(Lumen.meter)
                    Button("Open Privacy Settings") {
                        PlatformOpener.openSettings(macPane: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                    }
                }

                settingsSection("Rooms & Looks backup", symbol: "externaldrive") {
                    HStack(spacing: 10) {
                        Button("Back Up…") { prepareBackup() }
                            .buttonStyle(.borderedProminent)
                            .tint(Lumen.ember)
                        Button("Restore…") { importingBackup = true }
                            .buttonStyle(.bordered)
                    }
                    Text("Exports a portable JSON backup of rooms, Looks, fixture names, favorites, and supported spatial layouts. Restoring asks before replacing the current configuration.")
                        .font(LumenType.body(size: 11))
                        .foregroundStyle(Lumen.meter)
                    if let backupStatus {
                        Label(backupStatus, systemImage: "checkmark.circle")
                            .font(LumenType.body(size: 11, weight: .semibold))
                            .foregroundStyle(Lumen.verdigris)
                    }
                }

                settingsSection("Sample Room", symbol: "testtube.2") {
                    if manager.isDemoMode {
                        Label("No physical fixtures are being controlled", systemImage: "checkmark.shield")
                            .foregroundStyle(Lumen.verdigris)
                        HStack {
                            Button("Reset Sample Room") { manager.resetDemoMode() }
                            Button("Return to live rooms") { manager.exitDemoMode() }
                                .buttonStyle(.borderedProminent)
                                .tint(Lumen.ember)
                        }
                    } else {
                        Button("Open Sample Room") { manager.enterDemoMode() }
                            .buttonStyle(.borderedProminent)
                            .tint(Lumen.ember)
                        Text("The sample workspace is isolated from discovered fixtures and saved rooms.")
                            .font(LumenType.body(size: 11))
                            .foregroundStyle(Lumen.meter)
                    }
                }

            }
            .frame(maxWidth: 720)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Lumen.canvas)
        .foregroundStyle(Lumen.graphite)
        .font(LumenType.body())
        .navigationTitle("Settings")
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

    private func settingsSection<Content: View>(_ title: String, symbol: String,
                                                @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(Lumen.ember)
                Text(title).font(LumenType.display(size: 19, weight: .bold))
                Rectangle().fill(Lumen.rule).frame(height: 1)
            }
            content()
        }
        .padding(17)
        .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Lumen.rule, lineWidth: 1))
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

// MARK: - Add or repair

private enum AddRepairStep: Int, CaseIterable, Identifiable {
    case prepare
    case find
    case place
    case verify
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .prepare: return "Prepare"
        case .find: return "Find"
        case .place: return "Place"
        case .verify: return "Verify"
        }
    }
}

enum RoomCommissioningProgress {
    static func canContinueFromFind(selectedCount: Int, discoveredCount: Int) -> Bool {
        discoveredCount == 0 || selectedCount > 0
    }
}

struct AddOrRepairRoomView: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedRoomID: UUID?
    let onFinish: () -> Void
    @State private var step: AddRepairStep = .prepare
    @State private var selectedIDs: Set<String> = []
    @State private var targetRoomID: UUID?
    @State private var newRoomName = ""
    @State private var showingManualPairing = false
    @State private var fixtureNameDrafts: [String: String] = [:]

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stepRail
                Divider().overlay(Lumen.rule)
                ScrollView {
                    Group {
                        switch step {
                        case .prepare: prepareStep
                        case .find: findStep
                        case .place: placeStep
                        case .verify: verifyStep
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                Divider().overlay(Lumen.rule)
                footer
            }
            .background(Lumen.canvas)
            .navigationTitle("Add or repair room")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .font(LumenType.body())
        .foregroundStyle(Lumen.graphite)
        .sheetFrame(minWidth: 680, idealWidth: 920, minHeight: 590, idealHeight: 720)
        .sheet(isPresented: $showingManualPairing) {
            NanoleafPairingView().environmentObject(manager)
        }
        .onDisappear { manager.endSustainedIdentify() }
    }

    private var stepRail: some View {
        HStack(spacing: 0) {
            ForEach(AddRepairStep.allCases) { item in
                HStack(spacing: 7) {
                    ZStack {
                        Circle()
                            .fill(item.rawValue <= step.rawValue ? Lumen.ember : Lumen.graphite.opacity(0.11))
                            .frame(width: 24, height: 24)
                        if item.rawValue < step.rawValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Lumen.canvas)
                        } else {
                            Text("\(item.rawValue + 1)")
                                .font(LumenType.readout(size: 10, weight: .semibold))
                                .foregroundStyle(item == step ? Lumen.canvas : Lumen.graphite)
                        }
                    }
                    Text(item.title)
                        .font(LumenType.body(size: 12, weight: item == step ? .semibold : .regular))
                    if item != .verify {
                        Rectangle().fill(Lumen.rule).frame(height: 1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Lumen.floor)
    }

    private var prepareStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeading(
                "Make the fixtures visible",
                "Turn the lights on at the wall and keep this device on the same local network. LumenDesk talks directly to each fixture; there is no bridge service to configure."
            )
            HStack(alignment: .top, spacing: 14) {
                instructionCard(number: "1", title: "Power", text: "Switch on every fixture you want to place.")
                instructionCard(number: "2", title: "Network", text: "Join the Wi‑Fi network the fixtures use.")
                instructionCard(number: "3", title: "Permission", text: "Allow Local Network access when iOS asks.")
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("iPhone and iPad discovery limit", systemImage: "iphone.and.arrow.forward")
                    .font(LumenType.body(size: 13, weight: .semibold))
                Text("iOS can withhold multicast discovery until Local Network permission is granted, and some managed networks block broadcast replies entirely. A missing result does not prove the fixture is offline. Rescan, pair a Nanoleaf by address, or use the vendor app to repair Wi‑Fi before trying again.")
                    .font(LumenType.body(size: 12))
                    .foregroundStyle(Lumen.meter)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(Lumen.warn.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
        }
    }

    private var findStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeading(
                "Find and identify",
                "Select the fixtures that belong together. Identify flashes one fixture and restores its exact opening state."
            )
            HStack {
                Button {
                    manager.scan()
                } label: {
                    Label(manager.isScanning ? manager.scanPhase : "Scan again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(Lumen.ember)
                .disabled(manager.isScanning)
                Button("Pair Nanoleaf by address") { showingManualPairing = true }
                    .buttonStyle(.bordered)
                Spacer()
                Text("\(selectedIDs.count) selected")
                    .font(LumenType.readout(size: 12))
                    .foregroundStyle(Lumen.meter)
            }

            if manager.devices.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 30, weight: .light))
                    Text("No fixtures have answered yet")
                        .font(LumenType.display(size: 20, weight: .bold))
                    Text("Keep the scan open for five seconds. If discovery stays unavailable, continue with an empty room or explore the isolated Sample Room; you can add fixtures later.")
                        .font(LumenType.body(size: 12))
                        .foregroundStyle(Lumen.meter)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        Button("Scan again") { manager.scan() }
                            .buttonStyle(.bordered)
                            .disabled(manager.isScanning)
                        Button("Open Sample Room") { openSampleRoom() }
                            .buttonStyle(.borderedProminent)
                            .tint(Lumen.ember)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(32)
                .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 12))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(manager.devices) { device in
                        discoveryCard(device)
                    }
                }
            }
        }
    }

    private func discoveryCard(_ device: LightDevice) -> some View {
        let selected = selectedIDs.contains(device.id)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                if selected { selectedIDs.remove(device.id) }
                else { selectedIDs.insert(device.id) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(selected ? Lumen.ember : Lumen.graphite)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.label)
                            .font(LumenType.body(size: 13, weight: .semibold))
                        Text("\(device.brand.displayName) · \(device.address)")
                            .font(LumenType.body(size: 10))
                            .foregroundStyle(Lumen.meter)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: device.isStale ? "wifi.slash" : "wifi")
                        .foregroundStyle(device.isStale ? Lumen.fail : Lumen.verdigris)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button("Identify") { manager.identify(device) }
                .buttonStyle(.bordered)
                .disabled(device.isStale)

            HStack(spacing: 8) {
                TextField("Fixture name", text: fixtureNameBinding(device))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveFixtureName(device) }
                Button("Save name") { saveFixtureName(device) }
                    .buttonStyle(.bordered)
                    .disabled(!fixtureNameHasChanges(device))
            }
            if let warning = manager.duplicateNameMessage(
                fixtureNameDrafts[device.id] ?? device.label,
                excludingDeviceID: device.id
            ) {
                Text(warning)
                    .font(LumenType.body(size: 10))
                    .foregroundStyle(Lumen.warn)
            }
        }
        .padding(13)
        .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(selected ? Lumen.ember : Lumen.rule, lineWidth: selected ? 2 : 1)
        )
    }

    private var placeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeading(
                "Place on the canvas",
                "Choose a room, then drag the selected fixtures toward where they sit. Placement is a memory aid, not a calibrated floor plan."
            )

            HStack(spacing: 10) {
                Picker("Room", selection: $targetRoomID) {
                    Text("Choose a room").tag(Optional<UUID>.none)
                    ForEach(manager.rooms) { room in
                        Text(room.name).tag(Optional(room.id))
                    }
                }
                .frame(maxWidth: 260)
                TextField("New room name", text: $newRoomName)
                    .textFieldStyle(.roundedBorder)
                Button("Create") { createRoom() }
                    .buttonStyle(.bordered)
                    .disabled(newRoomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let targetRoom {
                DirectionARoomField(
                    room: targetRoom,
                    lights: placementLights,
                    selection: $selectedIDs
                )
                .frame(height: 360)
            } else {
                Text("Choose or create the room that contains these fixtures.")
                    .font(LumenType.body(size: 13))
                    .foregroundStyle(Lumen.meter)
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var verifyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeading(
                "Verify the room",
                "The room is ready when every fixture answers and appears where you expect it. Failures stay beside the fixture so repair remains local."
            )
            if let targetRoom {
                ForEach(manager.devices(in: targetRoom)) { device in
                    HStack(spacing: 12) {
                        Image(systemName: RoomCanvasStatus.resolve([device], manager: manager).symbol)
                            .foregroundStyle(RoomCanvasStatus.resolve([device], manager: manager).color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.label).font(LumenType.body(size: 13, weight: .semibold))
                            Text(device.isStale ? "No reply · check power and Wi‑Fi" : "Responded at \(device.address)")
                                .font(LumenType.body(size: 11))
                                .foregroundStyle(Lumen.meter)
                        }
                        Spacer()
                        if device.isStale {
                            Button("Retry") { manager.scan() }.buttonStyle(.bordered)
                        } else {
                            Button("Identify") { manager.identify(device) }.buttonStyle(.bordered)
                        }
                    }
                    .padding(13)
                    .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if step != .prepare {
                Button("Back") {
                    manager.endSustainedIdentify()
                    step = AddRepairStep(rawValue: step.rawValue - 1) ?? .prepare
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            Text(footerNote)
                .font(LumenType.body(size: 11))
                .foregroundStyle(Lumen.meter)
            Button(primaryButtonTitle) { advance() }
                .buttonStyle(.borderedProminent)
                .tint(Lumen.ember)
                .disabled(!canAdvance)
        }
        .padding(16)
        .background(Lumen.floor)
    }

    private var canAdvance: Bool {
        switch step {
        case .prepare: return true
        case .find:
            return RoomCommissioningProgress.canContinueFromFind(
                selectedCount: selectedIDs.count,
                discoveredCount: manager.devices.count
            )
        case .place: return targetRoomID != nil
        case .verify: return true
        }
    }

    private var primaryButtonTitle: String {
        if step == .verify { return "Open room" }
        if step == .find, manager.devices.isEmpty { return "Continue without fixtures" }
        return "Continue"
    }

    private var footerNote: String {
        switch step {
        case .prepare: return "Discovery begins in the foreground"
        case .find:
            return manager.devices.isEmpty
                ? "Fixtures can be added later"
                : "\(selectedIDs.count) fixture\(selectedIDs.count == 1 ? "" : "s") to place"
        case .place: return targetRoom?.name ?? "Choose a room"
        case .verify: return "Best-effort confirmation from physical fixtures"
        }
    }

    private func advance() {
        switch step {
        case .prepare:
            manager.scan()
            step = .find
        case .find:
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

    private func stepHeading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(LumenType.display(size: 28, weight: .bold))
            Text(subtitle)
                .font(LumenType.body(size: 13))
                .foregroundStyle(Lumen.meter)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 680, alignment: .leading)
        }
    }

    private func instructionCard(number: String, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(number)
                .font(LumenType.readout(size: 11, weight: .semibold))
                .foregroundStyle(Lumen.canvas)
                .frame(width: 25, height: 25)
                .background(Lumen.graphite, in: Circle())
            Text(title).font(LumenType.display(size: 18, weight: .bold))
            Text(text)
                .font(LumenType.body(size: 12))
                .foregroundStyle(Lumen.meter)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Lumen.rule, lineWidth: 1))
    }
}

// MARK: - Contextual capability editor

struct ContextualFixtureEditor: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var device: LightDevice

    var body: some View {
        NavigationStack {
            Group {
                if device.brand == .nanoleaf {
                    NanoleafShapesStudio(device: device, shapes: manager.shapes, presentation: .sheet)
                } else if device.isLIFXLuna {
                    LIFXLunaEditorView(device: device)
                } else if manager.segmentStudioProfile(for: device) != nil {
                    GoveeSegmentEditorView(device: device)
                } else {
                    BasicFixtureEditor(device: device)
                }
            }
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

private struct BasicFixtureEditor: View {
    @EnvironmentObject private var manager: LightManager
    @ObservedObject var device: LightDevice

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(device.isOn ? device.color : Lumen.rule)
                        .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.brand.displayName)
                            .font(LumenType.body(size: 13, weight: .semibold))
                        RoomCanvasStatusBadge(
                            status: RoomCanvasStatus.resolve([device], manager: manager),
                            compact: true
                        )
                    }
                    Spacer()
                    Toggle("Power", isOn: Binding(
                        get: { device.isOn },
                        set: { manager.setPower(device, on: $0) }
                    ))
                    .toggleStyle(.switch)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Brightness")
                        Spacer()
                        Text("\(Int(device.brightness * 100))%")
                            .font(LumenType.readout(size: 12))
                    }
                    Slider(value: Binding(
                        get: { device.brightness },
                        set: { manager.setBrightness(deviceIDs: [device.id], value: $0) }
                    ), in: 0.01...1)
                }

                ColorPicker("Output colour", selection: Binding(
                    get: { device.color },
                    set: { manager.setColor(device, color: $0) }
                ), supportsOpacity: false)

                HStack {
                    Button("Identify") { manager.identify(device) }
                    if device.isStale || manager.commandState(for: device.id).phase == .failed {
                        Button("Retry") { manager.retry(device) }
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(22)
        }
        .background(Lumen.canvas)
    }
}

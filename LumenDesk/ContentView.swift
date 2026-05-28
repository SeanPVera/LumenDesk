import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: LightManager

    @State private var showingNewRoom: Bool = false
    @State private var newRoomName: String = ""
    @State private var setupChecks: Set<Int> = []
    @State private var showingScenes: Bool = false

    @State private var searchText: String = ""
    @FocusState private var searchFocused: Bool
    @State private var showOnlyOn: Bool = false

    @State private var selectionMode: Bool = false
    @State private var selectedIDs: Set<String> = []

    private let gridThreshold: CGFloat = 780

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header

                if manager.devices.isEmpty {
                    emptyState
                } else {
                    if !manager.favoriteDevices.isEmpty {
                        FavoritesStripView()
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    }

                    GeometryReader { proxy in
                        if proxy.size.width >= gridThreshold {
                            gridLayout
                        } else {
                            listLayout
                        }
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .background(findShortcutButton)
            .sheet(isPresented: $showingNewRoom) { newRoomSheet }
            .sheet(isPresented: $showingScenes) {
                ScenesView().environmentObject(manager)
            }

            if selectionMode && !selectedIDs.isEmpty {
                BulkActionBar(selectedIDs: $selectedIDs, selectionMode: $selectionMode)
                    .padding(.bottom, manager.commandError == nil ? 16 : 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let error = manager.commandError {
                CommandToastView(
                    message: error,
                    undoAction: manager.commandErrorUndo,
                    dismiss: { manager.commandError = nil }
                )
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.25), value: manager.commandError)
        .animation(.spring(duration: 0.25), value: selectionMode)
    }

    private var findShortcutButton: some View {
        Button { searchFocused = true } label: { EmptyView() }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .disabled(manager.devices.isEmpty)
    }

    // MARK: - Mood-ring

    /// Aggregate colour of all currently-on lights: hue/saturation averaged,
    /// brightness proportional to how many lights are on. Falls back to warm
    /// yellow when nothing is on (classic "off" bulb look).
    private var moodColor: Color {
        let on = manager.devices.filter { $0.isOn }
        guard !on.isEmpty else { return .yellow }
        let hsbs = on.map { $0.color.hsbComponents }
        let avgH = hsbs.reduce(0.0) { $0 + $1.h } / Double(on.count)
        let avgS = hsbs.reduce(0.0) { $0 + $1.s } / Double(on.count)
        let avgB = on.reduce(0.0) { $0 + $1.brightness } / Double(on.count)
        return Color(hue: avgH, saturation: avgS, brightness: max(0.5, avgB))
    }

    private var moodGlowRadius: CGFloat {
        let fraction = Double(manager.devices.filter { $0.isOn }.count) /
                       max(1, Double(manager.devices.count))
        return CGFloat(fraction * 12)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "lightbulb.fill")
                    .font(.title2)
                    .foregroundStyle(moodColor)
                    .shadow(color: moodColor.opacity(0.6), radius: moodGlowRadius)
                    .animation(.easeInOut(duration: 0.6), value: moodColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LumenDesk").font(.title3.weight(.semibold))
                    Text(headerSubtitle)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if manager.isScanning {
                    ProgressView().controlSize(.small)
                }
                if !manager.devices.isEmpty {
                    Button {
                        selectionMode.toggle()
                        if !selectionMode { selectedIDs.removeAll() }
                    } label: {
                        Label(selectionMode ? "Done" : "Select",
                              systemImage: selectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .help(selectionMode ? "Exit selection mode" : "Select multiple lights for bulk actions")
                }
                Button { showingScenes = true } label: {
                    Label("Scenes", systemImage: "wand.and.stars")
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .help("Save and recall lighting scenes (⇧⌘S)")
                Button {
                    newRoomName = ""
                    showingNewRoom = true
                } label: {
                    Label("New Room", systemImage: "rectangle.stack.badge.plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                Button { manager.scan() } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if !manager.devices.isEmpty {
                Divider()
                HStack(spacing: 10) {
                    Toggle("", isOn: globalPowerBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .help("Toggle all lights on or off (⇧⌘P)")
                        .accessibilityLabel("All lights power")
                        .accessibilityHint("Toggles every discovered light")
                    Image(systemName: "sun.min").foregroundStyle(.secondary).font(.caption)
                        .accessibilityHidden(true)
                    Slider(value: globalBrightnessBinding, in: 0...1)
                        .disabled(manager.devices.allSatisfy { !$0.isOn })
                        .accessibilityLabel("Global brightness")
                        .accessibilityValue("\(Int(globalBrightnessBinding.wrappedValue * 100)) percent")
                    Image(systemName: "sun.max").foregroundStyle(.secondary).font(.caption)
                        .accessibilityHidden(true)
                    Text("All Lights")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()
                searchBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .background(.regularMaterial)
        .overlay(Divider(), alignment: .bottom)
    }

    private var headerSubtitle: String {
        if !manager.statusMessage.isEmpty { return manager.statusMessage }
        if selectionMode {
            return selectedIDs.isEmpty
                ? "Select lights to act on them in bulk"
                : "\(selectedIDs.count) of \(manager.devices.count) selected"
        }
        if showOnlyOn {
            let onCount = manager.devices.filter { $0.isOn }.count
            return "\(onCount) light\(onCount == 1 ? "" : "s") on"
        }
        return "\(manager.devices.count) light\(manager.devices.count == 1 ? "" : "s") on this network"
    }

    // MARK: - Search bar (with on-only filter toggle)

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Search lights or rooms", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(searchFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: searchFocused ? 1.5 : 0.5)
            )

            // "On only" filter chip
            Toggle(isOn: $showOnlyOn) {
                Label("On only", systemImage: "lightbulb.fill")
                    .font(.caption.weight(.medium))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .tint(.yellow)
            .help("Show only lights that are currently on")
            .accessibilityLabel("Filter to on lights only")
        }
    }

    // MARK: - Layout

    private var visibleRooms: [Room] {
        manager.rooms.filter { room in
            let matchesSearch = manager.room(room, matchesQuery: searchText)
            guard matchesSearch else { return false }
            if showOnlyOn {
                return manager.devices(in: room).contains { $0.isOn }
            }
            return true
        }
    }

    private var visibleUnassigned: [LightDevice] {
        manager.unassignedDevices.filter { device in
            let matchesSearch = manager.device(device, matchesQuery: searchText)
            guard matchesSearch else { return false }
            if showOnlyOn { return device.isOn }
            return true
        }
    }

    private var listLayout: some View {
        List {
            ForEach(visibleRooms) { room in
                RoomSectionView(
                    room: room,
                    searchQuery: searchText,
                    showOnlyOn: showOnlyOn,
                    selectionMode: selectionMode,
                    selectedIDs: selectedIDs,
                    onToggleSelection: toggleSelection
                )
                .listRowInsets(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .onMove { offsets, destination in
                guard searchText.isEmpty else { return }
                manager.moveRooms(from: offsets, to: destination)
            }

            unassignedSection
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var gridLayout: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ],
                alignment: .leading,
                spacing: 18
            ) {
                ForEach(visibleRooms) { room in
                    RoomSectionView(
                        room: room,
                        searchQuery: searchText,
                        showOnlyOn: showOnlyOn,
                        selectionMode: selectionMode,
                        selectedIDs: selectedIDs,
                        onToggleSelection: toggleSelection
                    )
                }
                if !visibleUnassigned.isEmpty {
                    unassignedGridSection
                }
            }
            .padding(16)
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    // MARK: - Unassigned section

    @ViewBuilder
    private var unassignedSection: some View {
        if !visibleUnassigned.isEmpty {
            unassignedContent
                .listRowInsets(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var unassignedGridSection: some View {
        if !visibleUnassigned.isEmpty { unassignedContent }
    }

    private var unassignedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(manager.rooms.isEmpty ? "All Lights" : "Unassigned")
                    .font(.headline)
                Text("\(visibleUnassigned.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Spacer()
            }
            VStack(spacing: 10) {
                ForEach(visibleUnassigned) { device in
                    LightRowView(
                        device: device,
                        selectionMode: selectionMode,
                        selected: selectedIDs.contains(device.id),
                        onToggleSelection: { toggleSelection(device.id) }
                    )
                    .draggable(device.id)
                }
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { manager.assign(lightID: id, toRoom: nil) }
            return true
        }
    }

    // MARK: - Header bindings

    private var globalPowerBinding: Binding<Bool> {
        Binding(
            get: { !manager.devices.isEmpty && manager.devices.allSatisfy { $0.isOn } },
            set: { manager.setAllPower(on: $0) }
        )
    }

    private var globalBrightnessBinding: Binding<Double> {
        Binding(
            get: {
                let on = manager.devices.filter { $0.isOn }
                guard !on.isEmpty else { return 1.0 }
                return on.reduce(0) { $0 + $1.brightness } / Double(on.count)
            },
            set: { manager.setAllBrightness($0) }
        )
    }

    // MARK: - New room sheet

    private var newRoomSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Room").font(.title3.weight(.semibold))
            Text("Group lights from any brand into a single custom room.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Room name (e.g. \u{201C}Living Room\u{201D})", text: $newRoomName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createRoom)
            HStack {
                Spacer()
                Button("Cancel") { showingNewRoom = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: createRoom)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newRoomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func createRoom() {
        let trimmed = newRoomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manager.createRoom(name: trimmed)
        showingNewRoom = false
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "lightbulb.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No lights found yet").font(.headline)
            Text("Run through this checklist, then scan again.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                setupStep(0,
                          "Mac and bulbs on the same Wi-Fi",
                          "Both must be on the same network and subnet \u{2014} check your router if unsure.")
                setupStep(1,
                          "Govee: \u{201C}LAN Control\u{201D} enabled",
                          "Govee Home app \u{2192} Devices \u{2192} [bulb] \u{2192} Settings \u{2192} LAN Control.")
                setupStep(2,
                          "LIFX: bulbs powered and paired",
                          "Confirm each bulb is on and set up in the LIFX app.")
            }
            .frame(maxWidth: 440)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            Button("Scan Now") { manager.scan() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func setupStep(_ index: Int, _ title: String, _ detail: String) -> some View {
        let checked = setupChecks.contains(index)
        return Button {
            if checked { setupChecks.remove(index) } else { setupChecks.insert(index) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Toast

struct CommandToastView: View {
    let message: String
    var undoAction: (() -> Void)? = nil
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 0)
            if let undo = undoAction {
                Button("Undo") { undo() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Undo last action")
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .frame(maxWidth: 420)
    }
}

// MARK: - Bulk action bar

struct BulkActionBar: View {
    @EnvironmentObject var manager: LightManager
    @Binding var selectedIDs: Set<String>
    @Binding var selectionMode: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("\(selectedIDs.count) selected")
                .font(.callout.weight(.medium))
                .accessibilityLabel("\(selectedIDs.count) light\(selectedIDs.count == 1 ? "" : "s") selected")

            Divider().frame(height: 16).accessibilityHidden(true)

            Button("Turn On") { manager.setPower(deviceIDs: selectedIDs, on: true) }
                .accessibilityHint("Turns on \(selectedIDs.count) selected light\(selectedIDs.count == 1 ? "" : "s")")
            Button("Turn Off") { manager.setPower(deviceIDs: selectedIDs, on: false) }
                .accessibilityHint("Turns off \(selectedIDs.count) selected light\(selectedIDs.count == 1 ? "" : "s")")

            Menu("Move to\u{2026}") {
                Button("Unassigned") {
                    manager.assign(lightIDs: selectedIDs, toRoom: nil)
                    exitSelection()
                }
                if !manager.rooms.isEmpty {
                    Divider()
                    ForEach(manager.rooms) { room in
                        Button(room.name) {
                            manager.assign(lightIDs: selectedIDs, toRoom: room.id)
                            exitSelection()
                        }
                    }
                }
            }
            .fixedSize()

            Menu("Brightness") {
                Button("100%") { manager.setBrightness(deviceIDs: selectedIDs, value: 1.0) }
                Button("75%")  { manager.setBrightness(deviceIDs: selectedIDs, value: 0.75) }
                Button("50%")  { manager.setBrightness(deviceIDs: selectedIDs, value: 0.5) }
                Button("25%")  { manager.setBrightness(deviceIDs: selectedIDs, value: 0.25) }
                Button("10%")  { manager.setBrightness(deviceIDs: selectedIDs, value: 0.1) }
            }
            .fixedSize()

            Spacer(minLength: 8)

            Button("Done") { exitSelection() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .frame(maxWidth: 640)
    }

    private func exitSelection() {
        selectedIDs.removeAll()
        selectionMode = false
    }
}

#Preview {
    ContentView()
        .environmentObject(LightManager())
        .frame(width: 640, height: 480)
}

import SwiftUI

struct RoomSectionView: View {
    @EnvironmentObject var manager: LightManager
    let room: Room
    var searchQuery: String = ""
    var showOnlyOn: Bool = false
    var selectionMode: Bool = false
    var selectedIDs: Set<String> = []
    var onToggleSelection: ((String) -> Void)? = nil

    @State private var renaming: Bool = false
    @State private var draftName: String = ""
    @State private var showingSchedules: Bool = false
    @FocusState private var nameFieldFocused: Bool

    private var isExpanded: Bool { manager.isRoomExpanded(room.id) }
    private var allLights: [LightDevice] { manager.devices(in: room) }

    private var visibleLights: [LightDevice] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        var lights: [LightDevice]
        if trimmed.isEmpty {
            lights = allLights
        } else if room.name.lowercased().contains(trimmed.lowercased()) {
            lights = allLights
        } else {
            lights = allLights.filter { manager.device($0, matchesQuery: trimmed) }
        }
        if showOnlyOn { lights = lights.filter { $0.isOn } }
        return lights
    }

    // MARK: - Power state across all lights in the room

    private enum PowerState { case allOn, allOff, mixed }
    private var roomPowerState: PowerState {
        guard !allLights.isEmpty else { return .allOff }
        if allLights.allSatisfy({ $0.isOn }) { return .allOn }
        if allLights.allSatisfy({ !$0.isOn }) { return .allOff }
        return .mixed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isExpanded {
                if visibleLights.isEmpty {
                    Text(searchQuery.isEmpty && !showOnlyOn
                         ? "No lights in this room yet. Use a light\u{2019}s menu to move it here."
                         : "No lights match \u{201C}\(searchQuery.isEmpty ? "on" : searchQuery)\u{201D}.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                        .accessibilityLabel(searchQuery.isEmpty
                                            ? "No lights in \(room.name) yet"
                                            : "No lights match \(searchQuery) in \(room.name)")
                } else {
                    if visibleLights.count > 1 {
                        masterBrightnessRow
                    }
                    VStack(spacing: 10) {
                        ForEach(visibleLights) { device in
                            LightRowView(
                                device: device,
                                selectionMode: selectionMode,
                                selected: selectedIDs.contains(device.id),
                                onToggleSelection: { onToggleSelection?(device.id) }
                            )
                            .draggable(device.id)
                        }
                    }
                }
            }
        }
        // Accept light IDs dropped from other rooms or the unassigned bucket.
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { manager.assign(lightID: id, toRoom: room.id) }
            return !ids.isEmpty
        }
        .sheet(isPresented: $showingSchedules) {
            ScheduleEditorView(room: room)
                .environmentObject(manager)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                manager.toggleRoomExpansion(room.id)
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(room.name)" : "Expand \(room.name)")

            Button {
                manager.toggleFavoriteRoom(room.id)
            } label: {
                Image(systemName: manager.isFavoriteRoom(room.id) ? "star.fill" : "star")
                    .foregroundStyle(manager.isFavoriteRoom(room.id) ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help(manager.isFavoriteRoom(room.id) ? "Unpin room from favorites" : "Pin room to favorites")

            if renaming {
                HStack(spacing: 4) {
                    TextField("Room name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .focused($nameFieldFocused)
                        .onSubmit(commitRename)
                        .onExitCommand(perform: cancelRename)
                    Button(action: cancelRename) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel (Esc)")
                }
            } else {
                Text(room.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(room.name)
            }

            // Total count badge
            Text("\(allLights.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .accessibilityLabel("\(allLights.count) light\(allLights.count == 1 ? "" : "s")")

            // "X on" count (only when at least one is on)
            let onCount = allLights.filter { $0.isOn }.count
            if onCount > 0 && onCount < allLights.count {
                Text("\(onCount) on")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.yellow.opacity(0.15)))
                    .accessibilityLabel("\(onCount) of \(allLights.count) on")
            } else if onCount == allLights.count && onCount > 0 {
                Text("all on")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.yellow.opacity(0.15)))
                    .accessibilityHidden(true)
            }

            if !allLights.isEmpty {
                Text(roomSummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(dominantRoomColor.opacity(0.12)))
                    .help("Average brightness and dominant room color")
            }

            if manager.schedules(for: room.id).contains(where: { $0.isEnabled }) {
                Image(systemName: "clock.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue.opacity(0.8))
                    .help("This room has active schedules")
                    .accessibilityLabel("Has active schedules")
            }

            Spacer()

            if !allLights.isEmpty && !selectionMode {
                masterPowerToggle
            }

            Menu {
                Button("Rename\u{2026}") { beginRename() }
                Button("Edit Schedules\u{2026}") { showingSchedules = true }
                Button("Move Up") { manager.moveRoom(room.id, by: -1) }
                Button("Move Down") { manager.moveRoom(room.id, by: 1) }
                Divider()
                Button("Delete Room", role: .destructive) { manager.deleteRoom(room.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .contentShape(Rectangle())
    }

    private var roomSummary: String {
        let on = allLights.filter { $0.isOn }
        guard !on.isEmpty else { return "off" }
        let avg = on.reduce(0) { $0 + $1.brightness } / Double(on.count)
        return "\(Int(avg * 100))% · \(dominantColorName)"
    }

    private var dominantRoomColor: Color {
        let on = allLights.filter { $0.isOn }
        guard !on.isEmpty else { return .secondary }
        let hsb = on.map { $0.color.hsbComponents }
        let h = hsb.reduce(0) { $0 + $1.h } / Double(on.count)
        let s = hsb.reduce(0) { $0 + $1.s } / Double(on.count)
        return Color(hue: h, saturation: s, brightness: 0.9)
    }

    private var dominantColorName: String {
        let h = dominantRoomColor.hsbComponents.h
        switch h {
        case 0..<0.08, 0.92...1: return "red"
        case 0.08..<0.17: return "warm"
        case 0.17..<0.42: return "green"
        case 0.42..<0.72: return "blue"
        default: return "purple"
        }
    }

    // MARK: - Tri-state power toggle

    @ViewBuilder
    private var masterPowerToggle: some View {
        switch roomPowerState {
        case .allOn:
            Toggle("", isOn: masterPowerBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help("Turn off all lights in \(room.name)")
                .accessibilityLabel("All lights in \(room.name) on")
        case .allOff:
            Toggle("", isOn: masterPowerBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help("Turn on all lights in \(room.name)")
                .accessibilityLabel("All lights in \(room.name) off")
        case .mixed:
            Button {
                // Tap when mixed: turn all ON (clarifies state, then user can toggle off)
                manager.setPower(in: room, on: true)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 38, height: 22)
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                        .frame(width: 38, height: 22)
                    Rectangle()
                        .fill(Color.secondary)
                        .frame(width: 10, height: 2)
                        .cornerRadius(1)
                }
            }
            .buttonStyle(.plain)
            .help("Some lights on \u{2014} tap to turn all on")
            .accessibilityLabel("Mixed power in \(room.name) \u{2014} tap to turn all on")
        }
    }

    // MARK: - Master brightness row

    private var masterBrightnessRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.min").foregroundStyle(.tertiary).font(.caption)
                .accessibilityHidden(true)
            Slider(value: masterBrightnessBinding, in: 0...1)
                .disabled(selectionMode || allLights.allSatisfy { !$0.isOn })
                .accessibilityLabel("\(room.name) brightness")
                .accessibilityValue("\(Int(masterBrightnessBinding.wrappedValue * 100)) percent")
            Image(systemName: "sun.max").foregroundStyle(.tertiary).font(.caption)
                .accessibilityHidden(true)
            Text("\(Int(masterBrightnessBinding.wrappedValue * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Bindings

    private var masterPowerBinding: Binding<Bool> {
        Binding(
            get: { roomPowerState == .allOn },
            set: { manager.setPower(in: room, on: $0) }
        )
    }

    private var masterBrightnessBinding: Binding<Double> {
        Binding(
            get: {
                let on = allLights.filter { $0.isOn }
                guard !on.isEmpty else { return 1.0 }
                return on.reduce(0) { $0 + $1.brightness } / Double(on.count)
            },
            set: { manager.setBrightness(in: room, value: $0) }
        )
    }

    // MARK: - Rename helpers

    private func beginRename() {
        draftName = room.name
        renaming = true
        DispatchQueue.main.async { nameFieldFocused = true }
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { manager.renameRoom(room.id, to: trimmed) }
        renaming = false
    }

    private func cancelRename() {
        draftName = room.name
        renaming = false
    }
}

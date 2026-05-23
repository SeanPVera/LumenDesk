import SwiftUI

/// A collapsible section that lists the lights belonging to a user-defined room.
/// Rename / delete / reorder controls live in a context menu on the header so
/// the UI stays uncluttered when the user is just adjusting lights.
struct RoomSectionView: View {
    @EnvironmentObject var manager: LightManager
    let room: Room
    var searchQuery: String = ""
    var selectionMode: Bool = false
    var selectedIDs: Set<String> = []
    var onToggleSelection: ((String) -> Void)? = nil

    @State private var isExpanded: Bool = true
    @State private var renaming: Bool = false
    @State private var draftName: String = ""
    @State private var showingSchedules: Bool = false
    @FocusState private var nameFieldFocused: Bool

    private var allLights: [LightDevice] { manager.devices(in: room) }

    /// Lights to actually render, filtered by the current search query. A room
    /// whose own name matches the query shows all of its lights.
    private var visibleLights: [LightDevice] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return allLights }
        if room.name.lowercased().contains(trimmed.lowercased()) { return allLights }
        return allLights.filter { manager.device($0, matchesQuery: trimmed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isExpanded {
                if visibleLights.isEmpty {
                    Text(searchQuery.isEmpty
                         ? "No lights in this room yet. Use a light's menu to move it here."
                         : "No lights match "\(searchQuery)".")
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
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingSchedules) {
            ScheduleEditorView(room: room)
                .environmentObject(manager)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(room.name)" : "Expand \(room.name)")

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

            Text("\(allLights.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .accessibilityLabel("\(allLights.count) light\(allLights.count == 1 ? "" : "s")")

            if manager.schedules(for: room.id).contains(where: { $0.isEnabled }) {
                Image(systemName: "clock.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue.opacity(0.8))
                    .help("This room has active schedules")
                    .accessibilityLabel("Has active schedules")
            }

            Spacer()

            if !allLights.isEmpty && !selectionMode {
                Toggle("", isOn: masterPowerBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .help("Toggle all lights in \(room.name)")
                    .accessibilityLabel("All lights in \(room.name)")
            }

            Menu {
                Button("Rename…") { beginRename() }
                Button("Edit Schedules…") { showingSchedules = true }
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
            Text("All")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Bindings

    private var masterPowerBinding: Binding<Bool> {
        Binding(
            get: { !allLights.isEmpty && allLights.allSatisfy { $0.isOn } },
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
        // Defer so the field exists before we move focus into it.
        DispatchQueue.main.async { nameFieldFocused = true }
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            manager.renameRoom(room.id, to: trimmed)
        }
        renaming = false
    }

    private func cancelRename() {
        draftName = room.name
        renaming = false
    }
}

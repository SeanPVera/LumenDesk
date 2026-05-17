import SwiftUI

/// A collapsible section that lists the lights belonging to a user-defined room.
/// Rename / delete / reorder controls live in a context menu on the header so
/// the UI stays uncluttered when the user is just adjusting lights.
struct RoomSectionView: View {
    @EnvironmentObject var manager: LightManager
    let room: Room
    @State private var isExpanded: Bool = true
    @State private var renaming: Bool = false
    @State private var draftName: String = ""
    @FocusState private var nameFieldFocused: Bool

    private var lights: [LightDevice] { manager.devices(in: room) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isExpanded {
                if lights.isEmpty {
                    Text("No lights in this room yet. Use a light's menu to move it here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                } else {
                    if lights.count > 1 {
                        masterBrightnessRow
                    }
                    VStack(spacing: 10) {
                        ForEach(lights) { device in
                            LightRowView(device: device)
                        }
                    }
                }
            }
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

            Text("\(lights.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))

            Spacer()

            if !lights.isEmpty {
                Toggle("", isOn: masterPowerBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .help("Toggle all lights in \(room.name)")
            }

            Menu {
                Button("Rename…") { beginRename() }
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
            Slider(value: masterBrightnessBinding, in: 0...1)
                .disabled(lights.allSatisfy { !$0.isOn })
            Image(systemName: "sun.max").foregroundStyle(.tertiary).font(.caption)
            Text("All")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Bindings

    private var masterPowerBinding: Binding<Bool> {
        Binding(
            get: { !lights.isEmpty && lights.allSatisfy { $0.isOn } },
            set: { manager.setPower(in: room, on: $0) }
        )
    }

    private var masterBrightnessBinding: Binding<Double> {
        Binding(
            get: {
                let on = lights.filter { $0.isOn }
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

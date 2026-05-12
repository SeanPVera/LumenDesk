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
                TextField("Room name", text: $draftName, onCommit: commitRename)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            } else {
                Text(room.name)
                    .font(.headline)
            }

            Text("\(lights.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))

            Spacer()

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
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .fixedSize()
        }
        .contentShape(Rectangle())
    }

    private func beginRename() {
        draftName = room.name
        renaming = true
    }

    private func commitRename() {
        manager.renameRoom(room.id, to: draftName)
        renaming = false
    }
}

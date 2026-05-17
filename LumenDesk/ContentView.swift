import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: LightManager
    @State private var showingNewRoom: Bool = false
    @State private var newRoomName: String = ""
    @State private var setupChecks: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            header

            if manager.devices.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(manager.rooms) { room in
                            RoomSectionView(room: room)
                        }

                        unassignedSection
                    }
                    .padding(16)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingNewRoom) { newRoomSheet }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .font(.title2)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("LumenDesk").font(.title3.weight(.semibold))
                Text(manager.statusMessage.isEmpty
                     ? "\(manager.devices.count) light\(manager.devices.count == 1 ? "" : "s") on this network"
                     : manager.statusMessage)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if manager.isScanning {
                ProgressView().controlSize(.small)
            }
            Button {
                newRoomName = ""
                showingNewRoom = true
            } label: {
                Label("New Room", systemImage: "rectangle.stack.badge.plus")
            }
            Button {
                manager.scan()
            } label: {
                Label("Scan", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(Divider(), alignment: .bottom)
    }

    @ViewBuilder
    private var unassignedSection: some View {
        let unassigned = manager.unassignedDevices
        if !unassigned.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(manager.rooms.isEmpty ? "All Lights" : "Unassigned")
                        .font(.headline)
                    Text("\(unassigned.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    Spacer()
                }
                VStack(spacing: 10) {
                    ForEach(unassigned) { device in
                        LightRowView(device: device)
                    }
                }
            }
        }
    }

    private var newRoomSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Room").font(.title3.weight(.semibold))
            Text("Group lights from any brand into a single custom room.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Room name (e.g. “Living Room”)", text: $newRoomName)
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
                          "Both must be on the same network and subnet — check your router if unsure.")
                setupStep(1,
                          "Govee: “LAN Control” enabled",
                          "Govee Home app → Devices → [bulb] → Settings → LAN Control.")
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

#Preview {
    ContentView()
        .environmentObject(LightManager())
        .frame(width: 640, height: 480)
}

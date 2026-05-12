import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: LightManager
    @State private var showingNewRoom: Bool = false
    @State private var newRoomName: String = ""

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
        .background(Color.windowBackground)
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
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "lightbulb.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No lights found yet").font(.headline)
            Text(“Make sure this device is on the same Wi-Fi network as your bulbs. For Govee, enable “LAN Control” for each bulb in the Govee Home app.”)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Scan again") { manager.scan() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#Preview {
    ContentView()
        .environmentObject(LightManager())
        .frame(width: 640, height: 480)
}

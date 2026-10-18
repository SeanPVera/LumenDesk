#if os(macOS)
import SwiftUI
import AppKit

/// Direction A keeps the menu bar intentionally narrow: choose one room,
/// change its immediate output, or recall one of its Looks. Commissioning,
/// diagnostics, and composition stay in the full Room Canvas.
struct MenuBarPopoverView: View {
    @EnvironmentObject private var manager: LightManager
    @AppStorage("LumenDesk.menuBarRoom.v2") private var selectedRoomValue = ""
    @AppStorage(AppPreferenceKey.roomCanvasOpenRequest) private var openRoomRequest = ""

    private var room: Room? {
        if let id = UUID(uuidString: selectedRoomValue),
           let match = manager.rooms.first(where: { $0.id == id }) {
            return match
        }
        return manager.rooms.first
    }

    private var lights: [LightDevice] {
        guard let room else { return [] }
        return manager.devices(in: room)
    }

    private var roomLooks: [LightingScene] {
        let ids = Set(lights.map(\.id))
        return manager.scenes.filter { !Set($0.snapshots.keys).isDisjoint(with: ids) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let room {
                roomControl(room)
            } else {
                emptyState
            }
        }
        .frame(width: 300)
        .font(LumenType.body())
        .foregroundStyle(Lumen.graphite)
        .background(Lumen.canvas)
        .onAppear { selectFirstRoomIfNeeded() }
        .managedActionConfirmations(manager)
    }

    private var header: some View {
        HStack(spacing: 9) {
            LumenMark(size: 19)
            VStack(alignment: .leading, spacing: 1) {
                Text("LumenDesk")
                    .font(LumenType.display(size: 16, weight: .bold))
                Text("Quick room action")
                    .font(LumenType.body(size: 10))
                    .foregroundStyle(Lumen.meter)
            }
            Spacer()
            if manager.isScanning {
                ProgressView().controlSize(.small)
            } else {
                Button { manager.scan() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Find fixtures")
            }
            Button(action: openMainWindow) {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.borderless)
            .help("Open Room Canvas")
        }
        .padding(14)
        .background(Lumen.floor)
    }

    private func roomControl(_ room: Room) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Room", selection: $selectedRoomValue) {
                ForEach(manager.rooms) { item in
                    Text(item.name).tag(item.id.uuidString)
                }
            }
            .pickerStyle(.menu)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.name)
                        .font(LumenType.display(size: 22, weight: .bold))
                    Text("\(lights.filter(\.isOn).count) of \(lights.count) on")
                        .font(LumenType.body(size: 11))
                        .foregroundStyle(Lumen.meter)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { !lights.isEmpty && lights.allSatisfy(\.isOn) },
                    set: { manager.setPower(in: room, on: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(lights.isEmpty)
                .accessibilityLabel("Power for \(room.name)")
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Brightness")
                    Spacer()
                    Text("\(Int(averageBrightness * 100))%")
                        .font(LumenType.readout(size: 11))
                }
                Slider(value: Binding(
                    get: { averageBrightness },
                    set: { manager.setBrightness(in: room, value: $0) }
                ), in: 0.01...1)
                .disabled(lights.isEmpty)
            }

            if let activeEffectID = manager.activeEffects[.room(room.id)] ?? manager.activeEffects[.all] {
                let effectName = activeEffectID == "music-pulse"
                    ? "Live Show (\(manager.musicModeConfiguration.preset.displayName))"
                    : (LightingCatalog.effects.first(where: { $0.id == activeEffectID })?.name ?? "Ambient effect")
                HStack(spacing: 8) {
                    Image(systemName: activeEffectID == "music-pulse" ? "waveform" : "sparkles")
                        .foregroundStyle(Lumen.verdigris)
                    Text(effectName)
                        .font(LumenType.body(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Button("Stop") {
                        if manager.activeEffects[.room(room.id)] != nil {
                            manager.stopEffect(scope: .room(room.id))
                        } else {
                            manager.stopEffect(scope: .all)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Lumen.ruleSoft, lineWidth: 1)
                )
            }

            if !roomLooks.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Looks")
                        .font(LumenType.instrumentLabel(size: 10))
                        .foregroundStyle(Lumen.meter)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(roomLooks) { look in
                                Button(look.name) {
                                    manager.applyLook(look, deviceIDs: Set(lights.map(\.id)))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }

            Button("Open \(room.name) in Room Canvas", action: openMainWindow)
                .buttonStyle(.borderedProminent)
                .tint(Lumen.ember)
                .frame(maxWidth: .infinity)
        }
        .padding(14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.dashed")
                .font(.system(size: 28, weight: .light))
            Text("No room yet")
                .font(LumenType.display(size: 19, weight: .bold))
            Button("Open Room Canvas", action: openMainWindow)
                .buttonStyle(.borderedProminent)
                .tint(Lumen.ember)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }

    private var averageBrightness: Double {
        guard !lights.isEmpty else { return 0 }
        return lights.reduce(0) { $0 + $1.brightness } / Double(lights.count)
    }

    private func selectFirstRoomIfNeeded() {
        guard let room else { selectedRoomValue = ""; return }
        if selectedRoomValue != room.id.uuidString { selectedRoomValue = room.id.uuidString }
    }

    private func openMainWindow() {
        // The menu-bar scene and the window own independent view state. Hand
        // the chosen room across explicitly before activating the window; the
        // Room Canvas consumes and clears this request.
        openRoomRequest = room?.id.uuidString ?? ""
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
    }
}
#endif

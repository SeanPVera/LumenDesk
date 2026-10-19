#if os(macOS)
import SwiftUI
import AppKit

/// Live Room Companion in the macOS menu bar: choose a room, adjust master
/// brightness and white point, start or stop Live Music Mode with real-time
/// tempo/spectral telemetry, or recall built-in and saved Looks.
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

    private var lightIDs: Set<String> {
        Set(lights.map(\.id))
    }

    private var roomLooks: [LightingScene] {
        manager.scenes.filter { !Set($0.snapshots.keys).isDisjoint(with: lightIDs) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Lumen.rule)
            if let room {
                roomControl(room)
            } else {
                emptyState
            }
        }
        .frame(width: 320)
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
                HStack(spacing: 6) {
                    Text("LumenDesk")
                        .font(LumenType.display(size: 16, weight: .bold))
                    if manager.isDemoMode {
                        Text("SAMPLE")
                            .font(LumenType.instrumentLabel(size: 8))
                            .tracking(0.8)
                            .foregroundStyle(Lumen.verdigris)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Lumen.verdigris.opacity(0.14), in: Capsule(style: .continuous))
                    }
                }
                Text("Live room companion")
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
                    .accessibilityLabel("Find fixtures")
            }
            Button(action: openMainWindow) {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.borderless)
            .help("Open Room Canvas")
            .accessibilityLabel("Open Room Canvas")
        }
        .padding(14)
        .background(Lumen.floor)
    }

    private func roomControl(_ room: Room) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            if manager.rooms.count > 1 {
                Picker("Room", selection: $selectedRoomValue) {
                    ForEach(manager.rooms) { item in
                        Text(item.name).tag(item.id.uuidString)
                    }
                }
                .pickerStyle(.menu)
            }

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

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Brightness")
                            .font(LumenType.body(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(Int((averageBrightness * 100).rounded()))%")
                            .font(LumenType.readout(size: 11))
                            .foregroundStyle(Lumen.meter)
                    }
                    Slider(value: Binding(
                        get: { averageBrightness },
                        set: { manager.setBrightness(in: room, value: $0) }
                    ), in: 0.01...1)
                    .disabled(lights.isEmpty)
                    .accessibilityLabel("Room brightness")
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("White point")
                            .font(LumenType.body(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(averageKelvin) K")
                            .font(LumenType.readout(size: 11))
                            .foregroundStyle(Lumen.meter)
                    }
                    Slider(value: Binding(
                        get: { Double(averageKelvin) },
                        set: { manager.setKelvin(deviceIDs: lightIDs, kelvin: Int($0.rounded())) }
                    ), in: 2_000...6_500)
                    .disabled(lights.isEmpty)
                    .accessibilityLabel("Room white point")
                }
            }

            liveCompanionBar(for: room)

            VStack(alignment: .leading, spacing: 7) {
                Text("QUICK LOOKS")
                    .font(LumenType.instrumentLabel(size: 9))
                    .tracking(1.1)
                    .foregroundStyle(Lumen.meter)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(RoomLookTemplate.everyday) { template in
                            Button {
                                guard let theme = LightingCatalog.theme(withID: template.themeID) else { return }
                                manager.applyTheme(theme, deviceIDs: lightIDs, in: .room(room.id))
                            } label: {
                                Label(template.name, systemImage: template.symbol)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        ForEach(roomLooks) { look in
                            Button {
                                manager.applyLook(look, deviceIDs: lightIDs)
                            } label: {
                                HStack(spacing: 5) {
                                    menuBarLookPalette(look)
                                    Text(look.name).lineLimit(1)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
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

    @ViewBuilder
    private func liveCompanionBar(for room: Room) -> some View {
        let roomScope = LightScope.room(room.id)
        if let activeEffectID = manager.activeEffects[roomScope] ?? manager.activeEffects[.all] {
            let isMusic = activeEffectID == "music-pulse"
            let snap = manager.musicModeController.latestSnapshot
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Lumen.ember)
                        .frame(width: 7, height: 7)
                    Text(isMusic
                         ? "LIVE · \(Int(snap.tempo.rounded())) BPM · \(max(1, snap.metre))/4"
                         : (LightingCatalog.effects.first(where: { $0.id == activeEffectID })?.name ?? "Ambient effect"))
                        .font(LumenType.readout(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Button("Stop") {
                        if manager.activeEffects[roomScope] != nil {
                            manager.stopEffect(scope: roomScope)
                        } else {
                            manager.stopEffect(scope: .all)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                if isMusic {
                    HStack(spacing: 8) {
                        menuBandBar("LOW", value: snap.bass, color: Lumen.ember)
                        menuBandBar("MID", value: snap.mids, color: Lumen.ochre)
                        menuBandBar("HIGH", value: snap.highs, color: Lumen.verdigris)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Lumen.ember.opacity(0.35), lineWidth: 1)
            )
        } else {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(Lumen.meter)
                Text("Live audio-reactive show")
                    .font(LumenType.body(size: 11, weight: .semibold))
                Spacer()
                Button("Start Live") {
                    var config = manager.musicModeConfiguration
                    config.restorePreviousState = true
                    config.usesSyntheticDemoPattern = manager.isDemoMode
                    manager.startMusicMode(configuration: config, scope: roomScope)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(lights.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Lumen.ruleSoft, lineWidth: 1)
            )
        }
    }

    private func menuBandBar(_ label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(LumenType.instrumentLabel(size: 8))
                .foregroundStyle(Lumen.meter)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Lumen.ruleSoft)
                    Capsule()
                        .fill(color)
                        .frame(width: max(2, geo.size.width * min(1, max(0, value))))
                }
            }
            .frame(height: 4)
        }
    }

    private func menuBarLookPalette(_ look: LightingScene) -> some View {
        let snapshots = Array(look.snapshots.values).prefix(3)
        return HStack(spacing: 2) {
            ForEach(snapshots.indices, id: \.self) { idx in
                let snap = snapshots[idx]
                Circle()
                    .fill(snap.isOn
                          ? Color(hue: snap.hue, saturation: snap.saturation, brightness: max(0.15, snap.brightness))
                          : Lumen.graphite.opacity(0.2))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
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

    private var averageKelvin: Int {
        guard !lights.isEmpty else { return 3_500 }
        return lights.reduce(0) { $0 + $1.kelvin } / lights.count
    }

    private func selectFirstRoomIfNeeded() {
        guard let room else { selectedRoomValue = ""; return }
        if selectedRoomValue != room.id.uuidString { selectedRoomValue = room.id.uuidString }
    }

    private func openMainWindow() {
        openRoomRequest = room?.id.uuidString ?? ""
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
    }
}
#endif

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Pure rules for the menu bar companion, kept outside the view so they are
/// unit-tested without a window.
enum MenuBarCompanion {
    /// Looks that reach this room, most relevant first: the Look applied
    /// last (if it is one of them), then newest first.
    static func recentLooks(_ scenes: [LightingScene], roomLightIDs: Set<String>,
                            lastAppliedID: UUID?, limit: Int = 4) -> [LightingScene] {
        let reaching = scenes.filter { !Set($0.snapshots.keys).isDisjoint(with: roomLightIDs) }
        let ordered = reaching.sorted { a, b in
            if a.id == lastAppliedID { return b.id != lastAppliedID }
            if b.id == lastAppliedID { return false }
            return a.createdAt > b.createdAt
        }
        return Array(ordered.prefix(max(0, limit)))
    }

    /// "3 of 5 on", "All 5 on", "All off", "No lights yet".
    static func powerSummary(on: Int, total: Int) -> String {
        guard total > 0 else { return "No lights yet" }
        if on == 0 { return "All off" }
        if on == total { return total == 1 ? "On" : "All \(total) on" }
        return "\(on) of \(total) on"
    }
}

#if os(macOS)
/// Polar menu bar companion: switch rooms, turn a room on or off, set its
/// brightness and white point, start or stop Live, recall recent Looks and
/// open the app. Everything here calls the same `LightManager` actions as
/// the main window; Sample Room never reaches the network.
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

    private var lightIDs: Set<String> { Set(lights.map(\.id)) }
    private var litCount: Int { lights.filter(\.isOn).count }

    private var recentLooks: [LightingScene] {
        MenuBarCompanion.recentLooks(manager.scenes, roomLightIDs: lightIDs,
                                     lastAppliedID: manager.lastSceneResult?.scene.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Polar.ruleSoft).frame(height: 1)
            if let room {
                VStack(alignment: .leading, spacing: PolarSpacing.sm) {
                    if manager.rooms.count > 1 { roomSwitcher(selected: room) }
                    roomCard(room)
                    liveBar(for: room)
                    looksSection(room)
                }
                .padding(PolarSpacing.md)
            } else {
                emptyState
            }
            Rectangle().fill(Polar.ruleSoft).frame(height: 1)
            footer
        }
        .frame(width: 340)
        .font(.polarUI(13))
        .foregroundStyle(Polar.chalk)
        .background(Polar.deck)
        .onAppear { selectFirstRoomIfNeeded() }
        .managedActionConfirmations(manager)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            LumenHexMark(size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("LumenDesk")
                    .font(.polarDisplay(15, weight: .bold))
                Text("Live room companion")
                    .font(.polarUI(11))
                    .foregroundStyle(Polar.meter)
            }
            if manager.isDemoMode {
                Text("SAMPLE")
                    .font(.polarMono(10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Polar.amber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(Capsule().stroke(Polar.amber.opacity(0.7), lineWidth: 1))
                    .accessibilityLabel("Sample Room")
            }
            Spacer(minLength: 4)
            Group {
                if manager.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button { manager.scan() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh network")
                        .accessibilityLabel("Refresh network")
                }
            }
            .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
        }
        .padding(.horizontal, PolarSpacing.md)
        .padding(.vertical, PolarSpacing.sm)
        .background(Polar.desk)
    }

    // MARK: Rooms

    private func roomSwitcher(selected: Room) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(manager.rooms.enumerated()), id: \.element.id) { index, item in
                    let chosen = item.id == selected.id
                    Button {
                        selectedRoomValue = item.id.uuidString
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Polar.roomTint(index)).frame(width: 7, height: 7)
                            Text(item.name).lineLimit(1)
                        }
                    }
                    .buttonStyle(PolarButtonStyle(kind: chosen ? .selected : .quiet, compact: true))
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
        }
        .accessibilityLabel("Rooms")
    }

    private func roomCard(_ room: Room) -> some View {
        VStack(alignment: .leading, spacing: PolarSpacing.sm) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.name)
                        .font(.polarDisplay(20, weight: .bold))
                        .lineLimit(1)
                    Text(MenuBarCompanion.powerSummary(on: litCount, total: lights.count))
                        .font(.polarMono(11))
                        .foregroundStyle(litCount > 0 ? Polar.mint : Polar.meter)
                }
                Spacer()
                Toggle("Room power", isOn: Binding(
                    get: { litCount > 0 },
                    set: { manager.setPower(in: room, on: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Polar.accent)
                .disabled(lights.isEmpty)
                .accessibilityLabel("Power for \(room.name)")
            }

            if !lights.isEmpty {
                orbRow
            }

            InstrumentSlider(
                title: "Brightness",
                value: Binding(
                    get: { averageBrightness },
                    set: { manager.setBrightness(in: room, value: $0) }
                ),
                range: 0.01...1
            )
            .disabled(lights.isEmpty)

            InstrumentSlider(
                title: "White point",
                value: Binding(
                    get: { Double(averageKelvin) },
                    set: { manager.setKelvin(deviceIDs: lightIDs, kelvin: Int($0.rounded())) }
                ),
                range: 2_000...6_500,
                step: 100,
                fill: [Polar.amber, Color(hex: 0xFFF1DC), Color(hex: 0xDDE8FF)],
                readout: { "\(Int(($0 / 100).rounded()) * 100) K" }
            )
            .disabled(lights.isEmpty)
        }
        .polarPanel(fill: Polar.desk, glow: litCount > 0 ? glowColor : nil, padding: PolarSpacing.md)
    }

    /// Up to eight orbs in the lights' current colours; the rest are counted.
    private var orbRow: some View {
        HStack(spacing: 10) {
            ForEach(lights.prefix(8)) { light in
                GlowingOrb(color: light.color, level: light.brightness, isOn: light.isOn,
                           silhouette: LightPageModel.resolve(light).silhouette,
                           size: 20, stale: light.isStale)
                    .frame(width: 26, height: 30)
                    .help(light.label)
            }
            if lights.count > 8 {
                Text("+\(lights.count - 8)")
                    .font(.polarMono(11))
                    .foregroundStyle(Polar.meter)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 34)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(litCount) of \(lights.count) lights on")
    }

    // MARK: Live

    @ViewBuilder
    private func liveBar(for room: Room) -> some View {
        let roomScope = LightScope.room(room.id)
        if let activeEffectID = manager.activeEffects[roomScope] ?? manager.activeEffects[.all] {
            let isMusic = activeEffectID == "music-pulse"
            let snap = manager.musicModeController.latestSnapshot
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(Polar.mint).frame(width: 8, height: 8)
                        .shadow(color: Polar.mint.opacity(0.8), radius: 4)
                    Text(isMusic
                         ? "LIVE · \(Int(snap.tempo.rounded())) BPM"
                         : (LightingCatalog.effects.first(where: { $0.id == activeEffectID })?.name ?? "Ambient effect"))
                        .font(.polarMono(12, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Button("Stop") {
                        if manager.activeEffects[roomScope] != nil {
                            manager.stopEffect(scope: roomScope)
                        } else {
                            manager.stopEffect(scope: .all)
                        }
                    }
                    .buttonStyle(PolarButtonStyle(kind: .danger, compact: true))
                }
                if isMusic {
                    HStack(spacing: 8) {
                        bandBar("LOW", value: snap.bass, color: Polar.coral)
                        bandBar("MID", value: snap.mids, color: Polar.amber)
                        bandBar("HIGH", value: snap.highs, color: Polar.mint)
                    }
                }
            }
            .padding(PolarSpacing.sm)
            .background(Polar.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: Polar.radiusCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Polar.radiusCard, style: .continuous)
                .stroke(Polar.mint.opacity(0.4), lineWidth: 1))
        } else {
            Button {
                var config = manager.musicModeConfiguration
                config.restorePreviousState = true
                config.usesSyntheticDemoPattern = manager.isDemoMode
                manager.startMusicMode(configuration: config, scope: roomScope)
            } label: {
                Label("Start Live", systemImage: "waveform")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PolarButtonStyle(kind: .prominent))
            .disabled(lights.isEmpty)
            .help("Audio-reactive show in \(room.name). Stop restores the room.")
        }
    }

    private func bandBar(_ label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.polarMono(9))
                .foregroundStyle(Polar.meter)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Polar.ruleSoft)
                    Capsule()
                        .fill(color)
                        .frame(width: max(2, geo.size.width * min(1, max(0, value))))
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: Looks

    private func looksSection(_ room: Room) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PolarSectionLabel(recentLooks.isEmpty ? "Quick looks" : "Recent looks")
            if recentLooks.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(RoomLookTemplate.everyday) { template in
                        Button {
                            guard let theme = LightingCatalog.theme(withID: template.themeID) else { return }
                            manager.applyTheme(theme, deviceIDs: lightIDs, in: .room(room.id))
                        } label: {
                            Label(template.name, systemImage: template.symbol)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
                        .disabled(lights.isEmpty)
                    }
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(recentLooks) { look in
                        Button {
                            manager.applyLook(look, deviceIDs: lightIDs)
                        } label: {
                            HStack(spacing: 10) {
                                LookSwatchDots(look: look)
                                    .frame(width: 34, alignment: .leading)
                                Text(look.name)
                                    .font(.polarUI(13, weight: .medium))
                                    .lineLimit(1)
                                Spacer()
                                if look.id == manager.lastSceneResult?.scene.id {
                                    Text("LAST")
                                        .font(.polarMono(9, weight: .bold))
                                        .foregroundStyle(Polar.mint)
                                }
                                Image(systemName: "play.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Polar.meter)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Polar.raised.opacity(0.55),
                                        in: RoundedRectangle(cornerRadius: Polar.radiusSmall, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Apply \u{201C}\(look.name)\u{201D} to \(room.name)")
                        .accessibilityLabel("Apply \(look.name)")
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                manager.setAllPower(on: false)
            } label: {
                Label("All off", systemImage: "power")
            }
            .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
            .disabled(manager.devices.isEmpty)
            .help("Turn every light off (⇧⌘O)")
            Spacer()
            Button(action: openMainWindow) {
                Label("Open LumenDesk", systemImage: "macwindow")
            }
            .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
            .foregroundStyle(Polar.select)
        }
        .padding(.horizontal, PolarSpacing.md)
        .padding(.vertical, PolarSpacing.sm)
        .background(Polar.desk)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.dashed")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Polar.meter)
            Text("No room yet")
                .font(.polarDisplay(18, weight: .bold))
            Text("Add lights in LumenDesk to control them from here.")
                .font(.polarUI(12))
                .foregroundStyle(Polar.meter)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }

    // MARK: Helpers

    private var glowColor: Color {
        lights.first(where: \.isOn)?.color ?? Polar.accent
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

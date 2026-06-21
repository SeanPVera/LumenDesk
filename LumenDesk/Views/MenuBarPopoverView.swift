#if os(macOS)
import SwiftUI
import AppKit

/// Compact popover shown in the macOS menu bar. Exposes master room toggles so
/// the user can control their lights without switching to the main window.
struct MenuBarPopoverView: View {
    @EnvironmentObject var manager: LightManager
    @AppStorage(AppPreferenceKey.menuBarScope) private var scopeRaw = MenuBarScope.activeRooms.rawValue
    @AppStorage(AppPreferenceKey.showMenuBarUrgentOnly) private var urgentOnly = false

    private var visibleRooms: [Room] {
        let scope = MenuBarScope(rawValue: scopeRaw) ?? .activeRooms
        let scoped: [Room]
        switch scope {
        case .favorites: scoped = manager.rooms.filter { manager.isFavoriteRoom($0.id) }
        case .activeRooms: scoped = manager.rooms.filter { manager.devices(in: $0).contains(where: { $0.isOn || $0.isStale || manager.commandPendingIDs.contains($0.id) }) }
        case .allRooms: scoped = manager.rooms
        }
        guard urgentOnly else { return scoped }
        return scoped.filter { manager.devices(in: $0).contains(where: { $0.isStale || manager.commandPendingIDs.contains($0.id) }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            menuBarHeader
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    emergencyRow
                    if !manager.favoriteScenes.isEmpty {
                        favoriteScenesRow
                        Divider().padding(.horizontal, 12)
                    }
                    globalRow
                    if !manager.rooms.isEmpty || !manager.unassignedDevices.isEmpty {
                        Divider().padding(.horizontal, 12)
                    }
                    ForEach(visibleRooms) { room in
                        roomRow(room)
                        Divider().padding(.horizontal, 12)
                    }
                    if !manager.unassignedDevices.isEmpty {
                        unassignedRow
                    }
                }
            }
            .frame(maxHeight: 340)
        }
        .frame(width: 280)
        .background(LumenBackground(glow: false))
    }

    private var emergencyRow: some View {
        HStack(spacing: 8) {
            Button {
                manager.setAllPower(on: false)
            } label: {
                Label("All Off", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(manager.devices.isEmpty)
            ForEach([0.1, 0.3, 0.6, 1.0], id: \.self) { value in
                Button("\(Int(value * 100))%") { manager.setAllBrightness(value) }
                    .controlSize(.mini)
                    .disabled(manager.devices.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var favoriteScenesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Favorite Scenes").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(manager.favoriteScenes) { scene in
                        Button(scene.name) { manager.applyScene(scene) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var menuBarHeader: some View {
        HStack {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(Lumen.brandGradient)
                .font(.caption)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("LumenDesk").font(.caption.weight(.semibold))
                if manager.isDemoMode { Text("SAFE DEMO").font(.system(size: 8, weight: .bold)).foregroundStyle(.orange) }
            }
            Spacer()
            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
            } label: { Image(systemName: "macwindow") }
            .buttonStyle(.borderless).help("Resume in LumenDesk")
            if manager.isScanning {
                ProgressView().controlSize(.mini)
            } else {
                Button {
                    manager.scan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Scan for lights")
                .accessibilityLabel("Scan for lights")
            }
            if !manager.commandPendingIDs.isEmpty { Label("\(manager.commandPendingIDs.count)", systemImage: "arrow.up.circle").font(.caption2).help("Commands in progress") }
            Text("\(manager.devices.count) light\(manager.devices.count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(manager.devices.count) light\(manager.devices.count == 1 ? "" : "s") found")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var globalRow: some View {
        HStack(spacing: 10) {
            Text("All Lights")
                .font(.callout.weight(.medium))
            Spacer()
            Toggle("", isOn: Binding(
                get: { !manager.devices.isEmpty && manager.devices.allSatisfy { $0.isOn } },
                set: { manager.setAllPower(on: $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .tint(Lumen.pink)
            .disabled(manager.devices.isEmpty)
            .accessibilityLabel("All lights power")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func roomRow(_ room: Room) -> some View {
        let lights = manager.devices(in: room)
        let onCount = lights.filter { $0.isOn }.count
        let brightnessBinding = Binding<Double>(
            get: {
                let on = lights.filter { $0.isOn }
                guard !on.isEmpty else { return 1.0 }
                return on.reduce(0) { $0 + $1.brightness } / Double(on.count)
            },
            set: { manager.setBrightness(in: room, value: $0) }
        )
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(room.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(lights.isEmpty ? "No lights" : "\(onCount) of \(lights.count) on")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { !lights.isEmpty && lights.allSatisfy { $0.isOn } },
                    set: { manager.setPower(in: room, on: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .tint(Lumen.pink)
                .disabled(lights.isEmpty)
                .accessibilityLabel("\(room.name) power, \(onCount) of \(lights.count) on")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if onCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "sun.min").foregroundStyle(.tertiary).font(.caption2)
                        .accessibilityHidden(true)
                    Slider(value: brightnessBinding, in: 0...1)
                        .controlSize(.mini)
                        .accessibilityLabel("\(room.name) brightness")
                        .accessibilityValue("\(Int(brightnessBinding.wrappedValue * 100)) percent")
                    Image(systemName: "sun.max").foregroundStyle(.tertiary).font(.caption2)
                        .accessibilityHidden(true)
                    Text("\(Int(brightnessBinding.wrappedValue * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
        }
    }

    private var unassignedRow: some View {
        let lights = manager.unassignedDevices
        let onCount = lights.filter { $0.isOn }.count
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Unassigned")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(onCount) of \(lights.count) on")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { !lights.isEmpty && lights.allSatisfy { $0.isOn } },
                set: { on in manager.setPower(deviceIDs: Set(lights.map { $0.id }), on: on) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .tint(Lumen.pink)
            .disabled(lights.isEmpty)
            .accessibilityLabel("Unassigned lights power")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Unassigned, \(onCount) of \(lights.count) on")
    }
}
#endif

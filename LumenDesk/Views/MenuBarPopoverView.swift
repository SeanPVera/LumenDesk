import SwiftUI

/// Compact popover shown in the macOS menu bar. Exposes master room toggles so
/// the user can control their lights without switching to the main window.
struct MenuBarPopoverView: View {
    @EnvironmentObject var manager: LightManager

    var body: some View {
        VStack(spacing: 0) {
            menuBarHeader
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    globalRow
                    if !manager.rooms.isEmpty || !manager.unassignedDevices.isEmpty {
                        Divider().padding(.horizontal, 12)
                    }
                    ForEach(manager.rooms) { room in
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
    }

    private var menuBarHeader: some View {
        HStack {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
                .accessibilityHidden(true)
            Text("LumenDesk")
                .font(.caption.weight(.semibold))
            Spacer()
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
            .disabled(manager.devices.isEmpty)
            .accessibilityLabel("All lights power")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func roomRow(_ room: Room) -> some View {
        let lights = manager.devices(in: room)
        let onCount = lights.filter { $0.isOn }.count
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(room.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("\(onCount) of \(lights.count) on")
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
            .disabled(lights.isEmpty)
            .accessibilityLabel("\(room.name) power, \(onCount) of \(lights.count) on")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Unassigned, \(onCount) of \(lights.count) on")
    }
}

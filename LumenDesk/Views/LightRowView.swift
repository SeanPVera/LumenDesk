import SwiftUI

struct LightRowView: View {
    @EnvironmentObject var manager: LightManager
    @ObservedObject var device: LightDevice

    private var brightnessBinding: Binding<Double> {
        Binding(get: { device.brightness },
                set: { manager.setBrightness(device, value: $0) })
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { device.color },
                set: { manager.setColor(device, color: $0) })
    }

    private var powerBinding: Binding<Bool> {
        Binding(get: { device.isOn },
                set: { manager.setPower(device, on: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Circle()
                    .fill(device.isOn ? device.color : Color.gray.opacity(0.35))
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(.secondary.opacity(0.4), lineWidth: 1))
                    .overlay(alignment: .bottomTrailing) {
                        if device.isStale {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .background(
                                    Circle()
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                        .frame(width: 13, height: 13)
                                )
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(device.name)
                    HStack(spacing: 6) {
                        Text(device.brand.displayName)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(device.brand.tint.opacity(0.18))
                            .foregroundStyle(device.brand.tint)
                            .clipShape(Capsule())
                        Text(device.address)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Toggle("", isOn: powerBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(Self.colorSwatches, id: \.label) { swatch in
                        swatchButton(swatch)
                    }
                    Spacer(minLength: 0)
                    ColorPicker("", selection: colorBinding, supportsOpacity: false)
                        .labelsHidden()
                        .disabled(!device.isOn)
                }

                HStack(spacing: 10) {
                    Image(systemName: "sun.min").foregroundStyle(.secondary)
                    Slider(value: brightnessBinding, in: 0...1)
                        .disabled(!device.isOn)
                    Image(systemName: "sun.max").foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(device.isStale ? Color.orange.opacity(0.5) : Color(nsColor: .separatorColor),
                        lineWidth: device.isStale ? 1 : 0.5)
        )
        .opacity(device.isStale ? 0.6 : 1)
        .help(device.isStale
              ? "Not responding — last seen \(device.lastSeen.formatted(.relative(presentation: .named))). Check the bulb's power and network."
              : "")
        .contextMenu { roomMenuContents }
    }

    // MARK: - Color swatches

    private static let colorSwatches: [(label: String, color: Color)] = [
        ("Warm White",  Color(red: 1.0,  green: 0.64, blue: 0.25)),
        ("Neutral",     Color(red: 1.0,  green: 0.87, blue: 0.67)),
        ("Daylight",    Color(red: 0.93, green: 0.95, blue: 1.0)),
        ("Red",         Color(hue: 0,    saturation: 1, brightness: 1)),
        ("Orange",      Color(hue: 0.08, saturation: 1, brightness: 1)),
        ("Green",       Color(hue: 0.35, saturation: 1, brightness: 1)),
        ("Blue",        Color(hue: 0.62, saturation: 1, brightness: 1)),
        ("Purple",      Color(hue: 0.77, saturation: 1, brightness: 1)),
    ]

    private func swatchButton(_ swatch: (label: String, color: Color)) -> some View {
        Button {
            manager.setColor(device, color: swatch.color)
        } label: {
            Circle()
                .fill(swatch.color)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(!device.isOn)
        .help(swatch.label)
    }

    @ViewBuilder
    private var roomMenuContents: some View {
        let currentRoom = manager.room(forLightID: device.id)

        Menu("Move to Room") {
            Button {
                manager.assign(lightID: device.id, toRoom: nil)
            } label: {
                if currentRoom == nil {
                    Label("Unassigned", systemImage: "checkmark")
                } else {
                    Text("Unassigned")
                }
            }
            if !manager.rooms.isEmpty {
                Divider()
                ForEach(manager.rooms) { room in
                    Button {
                        manager.assign(lightID: device.id, toRoom: room.id)
                    } label: {
                        if currentRoom?.id == room.id {
                            Label(room.name, systemImage: "checkmark")
                        } else {
                            Text(room.name)
                        }
                    }
                }
            }
        }

        if let room = currentRoom {
            Divider()
            Button("Move Up in \(room.name)") {
                manager.moveLight(device.id, in: room.id, by: -1)
            }
            Button("Move Down in \(room.name)") {
                manager.moveLight(device.id, in: room.id, by: 1)
            }
        }
    }
}

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

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.headline)
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

            HStack(spacing: 10) {
                Image(systemName: "sun.min").foregroundStyle(.secondary)
                Slider(value: brightnessBinding, in: 0...1)
                    .disabled(!device.isOn)
                Image(systemName: "sun.max").foregroundStyle(.secondary)

                ColorPicker("", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .disabled(!device.isOn)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator, lineWidth: 0.5)
        )
        .contextMenu { roomMenuContents }
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

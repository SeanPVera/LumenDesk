import SwiftUI

struct LightRowView: View {
    @EnvironmentObject var manager: LightManager
    @ObservedObject var device: LightDevice

    var selectionMode: Bool = false
    var selected: Bool = false
    var onToggleSelection: (() -> Void)? = nil

    @State private var renamingName: Bool = false
    @State private var nameDraft: String = ""
    @FocusState private var nameFocused: Bool
    @State private var colorMode: LightColorMode = .color

    private enum LightColorMode: String, CaseIterable {
        case color = "Color"
        case white = "White"
    }

    private var brightnessBinding: Binding<Double> {
        Binding(get: { device.brightness },
                set: { manager.setBrightness(device, value: $0) })
    }

    private var kelvinBinding: Binding<Double> {
        Binding(get: { Double(device.kelvin) },
                set: { manager.setKelvin(device, kelvin: Int($0)) })
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { device.color },
                set: { manager.setColor(device, color: $0) })
    }

    private var powerBinding: Binding<Bool> {
        Binding(get: { device.isOn },
                set: { manager.setPower(device, on: $0) })
    }

    private var controlsDisabled: Bool { selectionMode || !device.isOn }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if selectionMode {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                }

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
                                .accessibilityLabel("Device may be offline")
                        }
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if manager.isFavorite(device.id) {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                                .accessibilityLabel("Favorite")
                        }
                        if renamingName {
                            TextField("Name", text: $nameDraft)
                                .textFieldStyle(.roundedBorder)
                                .font(.headline)
                                .focused($nameFocused)
                                .onSubmit(commitRename)
                                .onExitCommand(cancelRename)
                                .frame(maxWidth: 200)
                        } else {
                            Text(device.label)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(device.label)
                                .onTapGesture(count: 2) {
                                    guard !selectionMode else { return }
                                    beginRename()
                                }
                        }
                    }
                    HStack(spacing: 6) {
                        Text(device.brand.displayName)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(device.brand.tint.opacity(0.18))
                            .foregroundStyle(device.brand.tint)
                            .clipShape(Capsule())
                            .accessibilityHidden(true)
                        Text(device.address)
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        if manager.commandPendingIDs.contains(device.id) {
                            ProgressView().controlSize(.mini)
                                .help("Waiting for bulb confirmation")
                        }
                    }
                    Text(device.isStale ? "Last seen \(device.lastSeen.formatted(.relative(presentation: .named)))" : "Confirmed \(device.lastSeen.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(device.isStale ? .orange : .tertiary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    [device.label,
                     manager.isFavorite(device.id) ? "Favorite" : nil,
                     device.isStale ? "may be offline" : nil]
                        .compactMap { $0 }.joined(separator: ", ")
                )

                Spacer()

                Toggle("", isOn: powerBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(selectionMode)
                    .accessibilityLabel(device.isOn ? "Turn off \(device.label)" : "Turn on \(device.label)")
            }

            VStack(spacing: 6) {
                Picker("Light mode", selection: $colorMode) {
                    ForEach(LightColorMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(selectionMode || !device.isOn)
                .accessibilityLabel("\(device.label) light mode")

                if colorMode == .color {
                    HStack(spacing: 6) {
                        ForEach(Self.colorSwatches, id: \.label) { swatch in
                            swatchButton(swatch)
                        }
                        Spacer(minLength: 0)
                        ColorPicker("", selection: colorBinding, supportsOpacity: false)
                            .labelsHidden()
                            .disabled(controlsDisabled)
                            .accessibilityLabel("\(device.label) color")
                    }
                }

                HStack(spacing: 10) {
                    Image(systemName: "sun.min").foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Slider(value: brightnessBinding, in: 0...1)
                        .disabled(controlsDisabled)
                        .accessibilityLabel("\(device.label) brightness")
                        .accessibilityValue("\(Int(device.brightness * 100)) percent")
                    Image(systemName: "sun.max").foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }

                if colorMode == .white {
                    // Colour-temperature slider — relevant when using white-light mode.
                    HStack(spacing: 10) {
                        Image(systemName: "thermometer.low")
                            .foregroundStyle(.orange.opacity(0.7))
                            .font(.caption)
                            .accessibilityHidden(true)
                        Slider(value: kelvinBinding, in: 2500...9000, step: 100)
                            .disabled(controlsDisabled)
                            .accessibilityLabel("\(device.label) colour temperature")
                            .accessibilityValue("\(device.kelvin) Kelvin")
                        Image(systemName: "thermometer.high")
                            .foregroundStyle(.blue.opacity(0.7))
                            .font(.caption)
                            .accessibilityHidden(true)
                        Text("\(device.kelvin)K")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .accessibilityElement(children: selectionMode ? .ignore : .contain)
        .accessibilityLabel(selectionMode
            ? "\(device.label)\(selected ? ", selected" : "")"
            : "")
        .accessibilityAddTraits(selectionMode ? .isButton : [])
        .accessibilityHint(selectionMode ? "Double-tap to toggle selection" : "")
        .accessibilityAction(.default) { if selectionMode { onToggleSelection?() } }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .opacity(device.isStale ? 0.6 : 1)
        .help(device.isStale
              ? "Not responding \u{2014} last seen \(device.lastSeen.formatted(.relative(presentation: .named))). Check the bulb\u{2019}s power and network."
              : "")
        .overlay {
            if selectionMode {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onToggleSelection?() }
            }
        }
        .contextMenu {
            if !selectionMode { roomMenuContents }
        }
    }

    private var borderColor: Color {
        if selected { return Color.accentColor }
        if device.isStale { return Color.orange.opacity(0.5) }
        return Color(nsColor: .separatorColor)
    }

    private var borderWidth: CGFloat {
        if selected { return 2 }
        if device.isStale { return 1 }
        return 0.5
    }

    // MARK: - Inline rename

    private func beginRename() {
        nameDraft = device.label
        renamingName = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        manager.setCustomName(device.id, name: trimmed)
        renamingName = false
    }

    private func cancelRename() {
        renamingName = false
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
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .disabled(controlsDisabled)
        .help(swatch.label)
        .accessibilityLabel(swatch.label)
    }

    // MARK: - Context menu

    @ViewBuilder
    private var roomMenuContents: some View {
        let currentRoom = manager.room(forLightID: device.id)

        Button {
            manager.toggleFavorite(device.id)
        } label: {
            if manager.isFavorite(device.id) {
                Label("Remove from Favorites", systemImage: "star.slash")
            } else {
                Label("Add to Favorites", systemImage: "star")
            }
        }

        Button("Rename\u{2026}") { beginRename() }

        Divider()

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
            Button("Move Up in \(room.name)") { manager.moveLight(device.id, in: room.id, by: -1) }
            Button("Move Down in \(room.name)") { manager.moveLight(device.id, in: room.id, by: 1) }
        }
    }
}

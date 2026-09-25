import SwiftUI

/// Scenes stored on a Shapes controller: play them, start painting from a
/// static one, or edit a motion's colours and options and save the result
/// under a new name. Nothing here deletes a scene, and a save that would
/// replace one needs its own confirmation.
struct NanoleafSceneLibrary: View {
    @EnvironmentObject private var manager: LightManager
    @ObservedObject var device: LightDevice
    @ObservedObject var shapes: NanoleafShapesController
    /// Starts an edit from a static scene's panel colours.
    let onPaintFrom: ([Int: NanoleafRGB], String) -> Void

    @State private var expanded = false
    @State private var editing: NanoleafEffectDefinition?

    private var ownedByShow: Bool { manager.animatingEffect(for: device.id) != nil }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                content
                Text("LumenDesk never deletes scenes on the controller, and replaces one only after you confirm it by name.")
                    .font(.caption).foregroundStyle(Lumen.meter)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
        } label: {
            Text("Scenes on the controller").font(.headline)
        }
        .onChange(of: expanded) { open in
            if open, shapes.libraries[device.id] == nil { load() }
        }
        .sheet(item: $editing) { definition in
            NanoleafEffectEditor(
                definition: definition,
                plugin: plugin(for: definition),
                preview: { try await shapes.previewEffect($0, on: device.id) },
                save: { try await shapes.saveEffect($0, as: $1, on: device.id, allowOverwrite: $2) }
            )
        }
    }

    @ViewBuilder private var content: some View {
        switch shapes.libraries[device.id] {
        case nil:
            Button("Read scenes from the controller") { load() }
                .buttonStyle(LumenSecondaryButtonStyle(compact: true))
        case .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading scenes\u{2026}").font(.callout) }
        case .failed(let reason):
            Text(reason).font(.callout).foregroundStyle(Lumen.meter)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { load() }
                .buttonStyle(LumenSecondaryButtonStyle(compact: true))
                .disabled(manager.isDemoMode)
        case .loaded(let effects, _):
            if effects.isEmpty {
                Text("The controller has no stored scenes.").font(.callout).foregroundStyle(Lumen.meter)
            }
            ForEach(effects) { effect in row(effect) }
            Button("Refresh list") { load() }
                .buttonStyle(LumenSecondaryButtonStyle(compact: true))
        }
    }

    private func row(_ effect: NanoleafEffectDefinition) -> some View {
        let playing = shapes.wall(device.id).output == .nativeEffect(name: effect.name)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(effect.name).font(.callout.weight(playing ? .semibold : .regular))
                Text(effect.category.displayName).font(.caption).foregroundStyle(Lumen.meter)
                if playing { Label("Playing", systemImage: "play.fill").font(.caption).foregroundStyle(Lumen.chalk) }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("Play") { manager.selectNanoleafEffect(device, name: effect.name) }
                    .disabled(ownedByShow || device.isStale || !device.nanoleafEffects.contains(effect.name))
                if let colors = effect.staticColors {
                    Button("Paint from this") { onPaintFrom(colors, effect.name) }
                        .disabled(ownedByShow)
                }
                if effect.hasEditableParameters {
                    Button("Edit colours and motion\u{2026}") { editing = effect }
                        .disabled(ownedByShow || device.isStale)
                }
            }
            .buttonStyle(LumenSecondaryButtonStyle(compact: true))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func load() {
        Task { await shapes.loadLibrary(device.id) }
    }

    private func plugin(for definition: NanoleafEffectDefinition) -> NanoleafPluginDescription? {
        guard case .loaded(_, let plugins) = shapes.libraries[device.id] else { return nil }
        return plugins.first { $0.uuid == definition.pluginUUID }
    }
}

/// Edits a stored motion's palette and options, previews the result on the
/// wall without storing it, and saves it under a name.
struct NanoleafEffectEditor: View {
    @Environment(\.dismiss) private var dismiss
    let plugin: NanoleafPluginDescription?
    let preview: (NanoleafEffectDefinition) async throws -> Void
    let save: (NanoleafEffectDefinition, String, Bool) async throws -> Void

    @State private var definition: NanoleafEffectDefinition
    @State private var name: String
    @State private var status: String?
    @State private var busy = false
    @State private var confirmingReplace = false

    init(definition: NanoleafEffectDefinition, plugin: NanoleafPluginDescription?,
         preview: @escaping (NanoleafEffectDefinition) async throws -> Void,
         save: @escaping (NanoleafEffectDefinition, String, Bool) async throws -> Void) {
        self.plugin = plugin
        self.preview = preview
        self.save = save
        _definition = State(initialValue: definition)
        _name = State(initialValue: "\(definition.name) (edited)")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Edit \u{201C}\(definition.name)\u{201D}").font(LumenType.display(size: 17))
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                if let plugin {
                    Text("\(plugin.name)\(plugin.description.map { " \u{00B7} \($0)" } ?? "")")
                        .font(.caption).foregroundStyle(Lumen.meter)
                }
                paletteEditor
                optionsEditor
                Divider()
                HStack(spacing: 8) {
                    Button("Preview on the wall") { run { try await preview(definition); status = "Previewing. The stored scene is unchanged." } }
                        .buttonStyle(LumenSecondaryButtonStyle(compact: true))
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 8) {
                    TextField("New scene name", text: $name).textFieldStyle(.roundedBorder)
                    Button("Save as a scene on the controller") { saveScene(overwrite: false) }
                        .buttonStyle(LumenPrimaryButtonStyle())
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if busy { ProgressView().controlSize(.small) }
                if let status { Text(status).font(.callout).foregroundStyle(Lumen.meter).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(20)
        }
        .sheetFrame(minWidth: 480, idealWidth: 560, minHeight: 460, idealHeight: 640)
        .background(Lumen.stage)
        .confirmationDialog("\u{201C}\(name)\u{201D} is already on the controller.", isPresented: $confirmingReplace,
                            titleVisibility: .visible) {
            Button("Replace it", role: .destructive) { saveScene(overwrite: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replacing overwrites that scene. Choose another name to keep both.")
        }
    }

    private var paletteEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Colours").font(.headline)
            ForEach(Array(definition.palette.indices), id: \.self) { index in
                HStack(spacing: 10) {
                    ColorPicker("Colour \(index + 1)", selection: paletteBinding(index), supportsOpacity: false)
                    Button {
                        definition.palette.remove(at: index)
                    } label: { Image(systemName: "minus.circle").accessibilityLabel("Remove colour \(index + 1)") }
                    .buttonStyle(.plain)
                    .disabled(definition.palette.count <= 1)
                }
            }
            Button("Add colour") {
                definition.palette.append(definition.palette.last ?? NanoleafPaletteColor(hue: 0, saturation: 100, brightness: 100))
            }
            .buttonStyle(LumenSecondaryButtonStyle(compact: true))
            .disabled(definition.palette.count >= 16)
        }
    }

    private var optionsEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !definition.options.isEmpty { Text("Motion").font(.headline) }
            ForEach(Array(definition.options.indices), id: \.self) { index in
                optionControl(index)
            }
        }
    }

    @ViewBuilder private func optionControl(_ index: Int) -> some View {
        let option = definition.options[index]
        let spec = plugin?.options.first { $0.name == option.name }
        let label = NanoleafPluginDescription.label(for: option.name)
        switch option.value {
        case .bool(let value):
            Toggle(label, isOn: Binding(get: { value }, set: { definition.options[index].value = .bool($0) }))
        case .string(let value):
            if let choices = spec?.choices, !choices.isEmpty {
                Picker(label, selection: Binding(get: { value }, set: { definition.options[index].value = .string($0) })) {
                    ForEach(choices, id: \.self) { Text($0).tag($0) }
                }
            } else {
                LabeledContent(label, value: value)
            }
        case .int(let value):
            if let low = spec?.minValue, let high = spec?.maxValue, high > low {
                LumenFader(label: label, value: Binding(get: { Double(value) },
                                                        set: { definition.options[index].value = .int(Int($0.rounded())) }),
                           range: low...high, step: 1, format: { "\(Int($0.rounded()))" })
            } else {
                Stepper("\(label): \(value)", value: Binding(get: { value }, set: { definition.options[index].value = .int($0) }))
            }
        case .double(let value):
            if let low = spec?.minValue, let high = spec?.maxValue, high > low {
                LumenFader(label: label, value: Binding(get: { value }, set: { definition.options[index].value = .double($0) }),
                           range: low...high, format: { String(format: "%.1f", $0) })
            } else {
                LabeledContent(label, value: option.value.displayText)
            }
        }
    }

    private func paletteBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: {
                guard definition.palette.indices.contains(index) else { return .white }
                let entry = definition.palette[index]
                return Color(hue: Double(entry.hue) / 360, saturation: Double(entry.saturation) / 100,
                             brightness: Double(entry.brightness) / 100)
            },
            set: { color in
                guard definition.palette.indices.contains(index) else { return }
                let hsb = color.hsbComponents
                definition.palette[index].hue = min(359, Int((hsb.h * 360).rounded()))
                definition.palette[index].saturation = Int((hsb.s * 100).rounded())
                definition.palette[index].brightness = Int((hsb.b * 100).rounded())
            })
    }

    private func saveScene(overwrite: Bool) {
        let target = name
        run {
            do {
                try await save(definition, target, overwrite)
                status = "Saved \u{201C}\(target.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D} on the controller."
            } catch NanoleafError.nameConflict {
                confirmingReplace = true
            }
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await work() } catch {
                status = (error as? NanoleafError ?? .unavailable).localizedDescription
            }
        }
    }
}

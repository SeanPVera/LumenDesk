import SwiftUI
import Foundation

private enum LookBrush: String, CaseIterable, Identifiable {
    case spatialWash = "Spatial wash"
    case gradient = "Gradient"
    case exactFixture = "Exact fixture"
    var id: String { rawValue }

    var distribution: ThemeDistribution {
        switch self {
        case .spatialWash: return .wash
        case .gradient: return .gradient
        case .exactFixture: return .alternating
        }
    }

    var summary: String {
        switch self {
        case .spatialWash: return "One key colour fills the room; spatial fixtures hold a quiet secondary tone."
        case .gradient: return "The palette travels through fixture order and across supported surfaces."
        case .exactFixture: return "Choose the exact palette colour each selected fixture should hold."
        }
    }
}

private enum LookComposerScope: String, CaseIterable, Identifiable {
    case room = "Whole room"
    case selection = "Selected fixtures"
    var id: String { rawValue }
}

private struct ComposerPalette: Identifiable {
    let id: String
    let name: String
    let theme: LightingTheme

    static let choices: [ComposerPalette] = {
        var values: [ComposerPalette] = []
        values.append(ComposerPalette(
            id: "ember-moss",
            name: "Ember & Moss",
            theme: LightingTheme(
                id: "direction-a-ember-moss",
                name: "Ember & Moss",
                summary: "Warm ember settles into moss and verdigris across the room.",
                category: .nature,
                icon: "leaf.fill",
                colors: [0xEF5F4F, 0xF2A65A, 0x66704A, 0x35A982].map(CatalogColor.init),
                brightness: 0.62,
                distribution: .gradient
            )
        ))
        var seenIDs: Set<String> = ["ember-moss", "direction-a-ember-moss"]
        for theme in LightingCatalog.themes where !seenIDs.contains(theme.id) {
            seenIDs.insert(theme.id)
            values.append(ComposerPalette(id: theme.id, name: theme.name, theme: theme))
        }
        return values
    }()
}

struct LookComposerView: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    let room: Room
    let initialSelection: Set<String>
    @State private var paletteID = ComposerPalette.choices.first?.id ?? "ember-moss"
    @State private var selectedCategory: LightingTheme.Category? = nil
    @State private var brush: LookBrush = .gradient
    @State private var spatialField: SpatialFieldVector = .themeDefault
    @State private var customBrightness: Double = 0.62
    @State private var scope: LookComposerScope
    @State private var lookName = "Ember & Moss"
    @State private var transitionSeconds = 1.8
    @State private var exactAssignments: [String: Int] = [:]

    init(room: Room, initialSelection: Set<String>) {
        self.room = room
        self.initialSelection = initialSelection
        _scope = State(initialValue: initialSelection.isEmpty ? .room : .selection)
    }

    private var currentRoom: Room { manager.rooms.first(where: { $0.id == room.id }) ?? room }
    private var roomIDs: Set<String> { Set(currentRoom.lightIDs) }
    private var targetIDs: Set<String> {
        if scope == .selection {
            return RoomWorkspaceSelection.targets(
                selected: initialSelection,
                available: currentRoom.lightIDs
            )
        }
        return roomIDs
    }
    private var selectedPalette: ComposerPalette {
        ComposerPalette.choices.first(where: { $0.id == paletteID }) ?? ComposerPalette.choices[0]
    }
    private var filteredPalettes: [ComposerPalette] {
        guard let selectedCategory else { return ComposerPalette.choices }
        return ComposerPalette.choices.filter { $0.theme.category == selectedCategory }
    }
    private var orderedTargetLights: [LightDevice] {
        manager.devices(in: currentRoom).filter { targetIDs.contains($0.id) }
    }
    private var paletteAssignments: [String: Int]? {
        guard brush == .exactFixture else { return nil }
        return Dictionary(uniqueKeysWithValues: orderedTargetLights.map { light in
            (light.id, exactAssignment(for: light))
        })
    }
    private var authoredTheme: LightingTheme {
        let source = selectedPalette.theme
        return LightingTheme(
            id: "\(source.id)-\(brush.id)",
            name: source.name,
            summary: source.summary,
            category: source.category,
            icon: source.icon,
            colors: source.colors,
            brightness: customBrightness,
            distribution: brush.distribution
        )
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    if geometry.size.width >= 850 {
                        HStack(alignment: .top, spacing: 24) {
                            previewColumn.frame(maxWidth: .infinity)
                            inspector.frame(width: 330)
                        }
                        .padding(24)
                    } else {
                        VStack(alignment: .leading, spacing: 22) {
                            previewColumn
                            inspector
                        }
                        .padding(20)
                    }
                }
            }
            .background(Lumen.canvas)
            .navigationTitle("Look Composer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        manager.stopSceneRehearsal(restore: true)
                        dismiss()
                    }
                }
            }
        }
        .font(LumenType.body())
        .foregroundStyle(Lumen.graphite)
        .sheetFrame(minWidth: 680, idealWidth: 1040, minHeight: 620, idealHeight: 780)
        .onAppear {
            customBrightness = selectedPalette.theme.brightness
            synchronizeExactAssignments()
        }
        .onChange(of: paletteID) { _ in
            lookName = selectedPalette.name
            customBrightness = selectedPalette.theme.brightness
            synchronizeExactAssignments()
        }
        .onChange(of: scope) { _ in synchronizeExactAssignments() }
        .onChange(of: brush) { _ in synchronizeExactAssignments() }
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("PALETTE · \(ComposerPalette.choices.count) CURATED")
                        .font(LumenType.instrumentLabel(size: 10))
                        .tracking(1.2)
                        .foregroundStyle(Lumen.meter)
                    Spacer()
                    Text(selectedPalette.theme.category.rawValue)
                        .font(LumenType.instrumentLabel(size: 10))
                        .foregroundStyle(Lumen.verdigris)
                }
                Text(selectedPalette.name)
                    .font(LumenType.display(size: 30, weight: .bold))
                Text(selectedPalette.theme.summary)
                    .font(LumenType.body(size: 13))
                    .foregroundStyle(Lumen.meter)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        selectedCategory = nil
                    } label: {
                        Text("All (\(ComposerPalette.choices.count))")
                            .font(LumenType.body(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                selectedCategory == nil ? Lumen.graphite : Lumen.floor,
                                in: Capsule(style: .continuous)
                            )
                            .foregroundStyle(selectedCategory == nil ? Lumen.canvas : Lumen.graphite)
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(selectedCategory == nil ? Color.clear : Lumen.rule, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    ForEach(LightingTheme.Category.allCases, id: \.self) { category in
                        Button {
                            selectedCategory = category
                        } label: {
                            Text(category.rawValue)
                                .font(LumenType.body(size: 11, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    selectedCategory == category ? Lumen.graphite : Lumen.floor,
                                    in: Capsule(style: .continuous)
                                )
                                .foregroundStyle(selectedCategory == category ? Lumen.canvas : Lumen.graphite)
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(selectedCategory == category ? Color.clear : Lumen.rule, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(filteredPalettes) { palette in
                        Button {
                            paletteID = palette.id
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 0) {
                                    ForEach(palette.theme.colors.indices, id: \.self) { index in
                                        Rectangle().fill(palette.theme.colors[index].color)
                                    }
                                }
                                .frame(width: 124, height: 34)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                Text(palette.name)
                                    .font(LumenType.body(size: 11, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .padding(9)
                            .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(paletteID == palette.id ? Lumen.ember : Lumen.rule,
                                            lineWidth: paletteID == palette.id ? 2 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("Brush")
                    .font(LumenType.body(size: 13, weight: .semibold))
                Picker("Brush", selection: $brush) {
                    ForEach(LookBrush.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(brush.summary)
                    .font(LumenType.body(size: 12))
                    .foregroundStyle(Lumen.meter)
            }

            if brush != .exactFixture {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("2D Spatial Field")
                            .font(LumenType.body(size: 13, weight: .semibold))
                        Spacer()
                        Label(spatialField.displayName, systemImage: spatialField.icon)
                            .font(LumenType.instrumentLabel(size: 10))
                            .foregroundStyle(Lumen.verdigris)
                    }
                    Picker("2D Spatial Field", selection: $spatialField) {
                        ForEach(SpatialFieldVector.allCases) { vector in
                            Text(vector.shortLabel).tag(vector)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(spatialField.summary)
                        .font(LumenType.body(size: 12))
                        .foregroundStyle(Lumen.meter)
                }
            }

            exactAssignmentEditor

            ComposerRoomPreview(
                room: currentRoom,
                lights: manager.devices(in: currentRoom),
                targetIDs: targetIDs,
                theme: authoredTheme,
                paletteAssignments: paletteAssignments,
                spatialField: spatialField
            )
            .frame(minHeight: 300)

            ambientEffectsSection
        }
    }

    private var ambientEffectsSection: some View {
        let roomScope: LightScope = .room(currentRoom.id)
        let activeEffectID = manager.activeEffects[roomScope]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AMBIENT MOTION EFFECTS")
                        .font(LumenType.instrumentLabel(size: 10))
                        .tracking(1.2)
                        .foregroundStyle(Lumen.meter)
                    Text("Continuous generative motion across \(currentRoom.name)")
                        .font(LumenType.body(size: 12))
                        .foregroundStyle(Lumen.meter)
                }
                Spacer()
                if let activeEffectID, activeEffectID != "music-pulse" {
                    Button("Stop Motion") {
                        manager.stopEffect(scope: roomScope, restore: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(LightingCatalog.effects) { effect in
                        let isActive = activeEffectID == effect.id
                        Button {
                            if isActive {
                                manager.stopEffect(scope: roomScope, restore: true)
                            } else {
                                manager.startEffect(effect, scope: roomScope)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Image(systemName: effect.icon)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(isActive ? Lumen.ember : Lumen.graphite)
                                    Text(effect.name)
                                        .font(LumenType.body(size: 12, weight: .semibold))
                                        .lineLimit(1)
                                }
                                HStack(spacing: 0) {
                                    ForEach(effect.colors.indices, id: \.self) { index in
                                        Rectangle().fill(effect.colors[index].color)
                                    }
                                }
                                .frame(width: 132, height: 14)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                Text(effect.summary)
                                    .font(LumenType.body(size: 10))
                                    .foregroundStyle(Lumen.meter)
                                    .lineLimit(2)
                                    .frame(width: 132, alignment: .leading)
                            }
                            .padding(10)
                            .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(isActive ? Lumen.ember : Lumen.rule, lineWidth: isActive ? 2 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .background(Lumen.deck.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var exactAssignmentEditor: some View {
        if brush == .exactFixture {
            VStack(alignment: .leading, spacing: 10) {
                Text("Fixture assignments")
                    .font(LumenType.body(size: 13, weight: .semibold))
                Text("Each fixture keeps the chosen swatch. Addressable strips, matrices, and panels repeat it across their surface.")
                    .font(LumenType.body(size: 11))
                    .foregroundStyle(Lumen.meter)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(orderedTargetLights) { light in
                    HStack(spacing: 10) {
                        Text(light.label)
                            .font(LumenType.body(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 7) {
                            ForEach(selectedPalette.theme.colors.indices, id: \.self) { index in
                                Button {
                                    exactAssignments[light.id] = index
                                } label: {
                                    Circle()
                                        .fill(selectedPalette.theme.colors[index].color)
                                        .frame(width: 22, height: 22)
                                        .padding(3)
                                        .overlay(
                                            Circle()
                                                .stroke(
                                                    exactAssignment(for: light) == index
                                                        ? Lumen.graphite : Color.clear,
                                                    lineWidth: 2
                                                )
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Assign palette colour \(index + 1) to \(light.label)")
                                .accessibilityAddTraits(
                                    exactAssignment(for: light) == index ? .isSelected : []
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Lumen.rule, lineWidth: 1))
                }
            }
            .padding(14)
            .background(Lumen.deck.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Look details")
                .font(LumenType.display(size: 22, weight: .bold))
            VStack(alignment: .leading, spacing: 7) {
                Text("Look name").font(LumenType.instrumentLabel(size: 10)).foregroundStyle(Lumen.meter)
                TextField("Look name", text: $lookName).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Scope").font(LumenType.instrumentLabel(size: 10)).foregroundStyle(Lumen.meter)
                Picker("Scope", selection: $scope) {
                    ForEach(LookComposerScope.allCases) { entry in
                        Text(entry.rawValue).tag(entry)
                    }
                }
                .pickerStyle(.segmented)
                Text("\(targetIDs.count) of \(roomIDs.count) fixtures")
                    .font(LumenType.readout(size: 11))
                    .foregroundStyle(Lumen.meter)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Room level").font(LumenType.body(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(Int((customBrightness * 100).rounded()))%")
                        .font(LumenType.readout(size: 12))
                }
                Slider(value: $customBrightness, in: 0.05...1.0)
                    .tint(Lumen.ember)
                    .accessibilityLabel("Room level")
                    .accessibilityValue("\(Int((customBrightness * 100).rounded())) percent")
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Adaptation")
                    .font(LumenType.instrumentLabel(size: 10))
                    .foregroundStyle(Lumen.meter)
                Text(manager.lookAdaptationSummary(
                    authoredTheme,
                    deviceIDs: targetIDs,
                    in: .room(currentRoom.id),
                    paletteAssignments: paletteAssignments,
                    spatialField: spatialField
                )
                     ?? "Every selected fixture can carry this composition directly.")
                    .font(LumenType.body(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Lumen.verdigris.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Transition").font(LumenType.body(size: 13, weight: .semibold))
                    Spacer()
                    Text(String(format: "%.1f seconds", transitionSeconds))
                        .font(LumenType.readout(size: 12))
                }
                Slider(value: $transitionSeconds, in: 0.2...5, step: 0.1)
                Text("Ease · device-native where supported")
                    .font(LumenType.body(size: 11))
                    .foregroundStyle(Lumen.meter)
            }

            HStack(spacing: 9) {
                Button("Restore before preview") {
                    manager.stopSceneRehearsal(restore: true)
                }
                .buttonStyle(.bordered)
                .disabled(manager.rehearsalSceneID == nil)
                Button("Preview") {
                    manager.startLookPreview(
                        authoredTheme,
                        deviceIDs: targetIDs,
                        in: .room(currentRoom.id),
                        paletteAssignments: paletteAssignments,
                        spatialField: spatialField,
                        transitionDuration: transitionSeconds
                    )
                }
                .buttonStyle(.bordered)
            }

            Button(action: save) {
                Label("Save Look", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Lumen.ember)
            .disabled(lookName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || targetIDs.isEmpty)

            RoomCanvasStatusBadge(status: manager.rehearsalSceneID == nil ? .confirmed : .pending)
        }
        .padding(18)
        .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Lumen.rule, lineWidth: 1))
    }

    private func save() {
        if manager.rehearsalSceneID != nil {
            manager.startLookPreview(
                authoredTheme,
                deviceIDs: targetIDs,
                in: .room(currentRoom.id),
                paletteAssignments: paletteAssignments,
                spatialField: spatialField,
                transitionDuration: transitionSeconds
            )
            manager.stopSceneRehearsal(restore: false)
            _ = manager.captureLook(name: lookName, deviceIDs: targetIDs)
        } else {
            _ = manager.saveLookFromPlan(
                name: lookName,
                theme: authoredTheme,
                deviceIDs: targetIDs,
                in: .room(currentRoom.id),
                paletteAssignments: paletteAssignments,
                spatialField: spatialField
            )
        }
        dismiss()
    }

    private func exactAssignment(for light: LightDevice) -> Int {
        let count = selectedPalette.theme.colors.count
        guard count > 0 else { return 0 }
        let fallback = orderedTargetLights.firstIndex(where: { $0.id == light.id }) ?? 0
        return min(count - 1, max(0, exactAssignments[light.id] ?? fallback % count))
    }

    private func synchronizeExactAssignments() {
        let count = selectedPalette.theme.colors.count
        guard count > 0 else {
            exactAssignments = [:]
            return
        }
        var updated: [String: Int] = [:]
        for (index, light) in orderedTargetLights.enumerated() {
            let existing = exactAssignments[light.id] ?? index % count
            updated[light.id] = min(count - 1, max(0, existing))
        }
        exactAssignments = updated
    }
}

private struct ComposerRoomPreview: View {
    @EnvironmentObject private var manager: LightManager
    let room: Room
    let lights: [LightDevice]
    let targetIDs: Set<String>
    let theme: LightingTheme
    let paletteAssignments: [String: Int]?
    let spatialField: SpatialFieldVector

    private var plans: [String: ThemeFixturePlan] {
        let fixtures = lights.filter { targetIDs.contains($0.id) }.map {
            ThemeFixture(
                id: $0.id,
                capability: manager.themeCapability(for: $0),
                kelvin: $0.kelvin,
                anchor: manager.planAnchor(for: $0.id, in: room)
            )
        }
        let plan: ThemePlan
        if let paletteAssignments {
            plan = ThemePlanner.planExact(
                theme,
                fixtures: fixtures,
                paletteIndices: paletteAssignments
            )
        } else {
            plan = ThemePlanner.plan(theme, fixtures: fixtures, spatialField: spatialField)
        }
        return Dictionary(uniqueKeysWithValues: plan.fixtures.map { ($0.fixtureID, $0) })
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Lumen.floor)
                spatialPreviewWash
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                RoundedRectangle(cornerRadius: 18).stroke(Lumen.graphite, lineWidth: 3)

                if paletteAssignments == nil {
                    VStack {
                        HStack(spacing: 5) {
                            Image(systemName: spatialField.icon)
                                .font(.system(size: 10, weight: .semibold))
                            Text(spatialField.displayName.uppercased())
                                .font(LumenType.instrumentLabel(size: 9))
                                .tracking(0.9)
                            Spacer()
                        }
                        .foregroundStyle(Lumen.graphite.opacity(0.62))
                        Spacer()
                    }
                    .padding(12)
                    .allowsHitTesting(false)
                }

                ForEach(lights) { light in
                    let anchor = manager.planAnchor(for: light.id, in: room)
                    let plan = plans[light.id]
                    VStack(spacing: 4) {
                        Circle()
                            .fill(plan?.tone.emittedColor(scaledBy: plan?.brightness ?? 0) ?? Lumen.graphite.opacity(0.12))
                            .frame(width: 34, height: 34)
                            .shadow(color: plan?.tone.displayColor.opacity(0.45) ?? .clear, radius: 14)
                        Text(light.label)
                            .font(LumenType.body(size: 10, weight: .semibold))
                            .lineLimit(1)
                    }
                    .opacity(targetIDs.contains(light.id) ? 1 : 0.32)
                    .position(
                        x: 45 + (geometry.size.width - 90) * anchor.x,
                        y: 35 + (geometry.size.height - 70) * anchor.y
                    )
                }
            }
        }
        .accessibilityLabel("Preview of \(theme.name) in \(room.name)")
    }

    @ViewBuilder
    private var spatialPreviewWash: some View {
        let colors = theme.colors.map { $0.color.opacity(0.24 * max(0.25, theme.brightness)) }
        if colors.isEmpty {
            EmptyView()
        } else if paletteAssignments != nil {
            LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                .opacity(0.45)
        } else {
            switch spatialField {
            case .themeDefault, .westToEast:
                LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
            case .northToSouth:
                LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            case .diagonalSweep:
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            case .radialCenter:
                RadialGradient(colors: colors, center: .center, startRadius: 8, endRadius: 150)
            }
        }
    }
}

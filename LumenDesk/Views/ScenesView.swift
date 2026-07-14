import SwiftUI

struct ScenesView: View {
    private enum LibrarySection: String, CaseIterable, Identifiable {
        case scenes = "My Scenes"
        case themes = "Themes"
        case effects = "Effects"
        var id: String { rawValue }
    }

    @EnvironmentObject var manager: LightManager
    @Environment(\.dismiss) private var dismiss

    @State private var section: LibrarySection = .themes
    @State private var scope: LightScope = .all
    @State private var newSceneName = ""
    @State private var renamingID: UUID?
    @State private var renameDraft = ""
    @State private var searchText = ""
    @State private var themeCategory: LightingTheme.Category?
    @State private var previewScene: LightingScene?
    @State private var editingScene: LightingScene?
    @State private var pendingAudioEffect: LightingEffect?
    @FocusState private var renameFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 218), spacing: 12)]

    private var visibleScenes: [LightingScene] {
        guard !normalizedSearch.isEmpty else { return manager.scenes }
        return manager.scenes.filter { $0.name.localizedCaseInsensitiveContains(normalizedSearch) }
    }

    private var visibleThemes: [LightingTheme] {
        LightingCatalog.themes.filter { theme in
            (themeCategory == nil || theme.category == themeCategory) &&
            (normalizedSearch.isEmpty || theme.name.localizedCaseInsensitiveContains(normalizedSearch) || theme.summary.localizedCaseInsensitiveContains(normalizedSearch))
        }
    }

    private var visibleEffects: [LightingEffect] {
        guard !normalizedSearch.isEmpty else { return LightingCatalog.effects }
        return LightingCatalog.effects.filter {
            $0.name.localizedCaseInsensitiveContains(normalizedSearch) || $0.summary.localizedCaseInsensitiveContains(normalizedSearch)
        }
    }

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var activeEffectScopes: [LightScope] {
        manager.activeEffects.keys.sorted { manager.scopeDisplayName($0) < manager.scopeDisplayName($1) }
    }

    private var scopedDeviceCount: Int { manager.devices(in: scope).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            content
        }
        .sheetFrame(minWidth: 680, idealWidth: 820, minHeight: 500, idealHeight: 680)
        .background(LumenBackground(glow: false))
        .alert("Allow Music-Reactive Lighting?", isPresented: Binding(get: { pendingAudioEffect != nil }, set: { if !$0 { pendingAudioEffect = nil } })) {
            Button("Cancel", role: .cancel) { pendingAudioEffect = nil }
            Button("Continue") {
                UserDefaults.standard.set(true, forKey: AppPreferenceKey.audioPrivacyAcknowledged)
                if let effect = pendingAudioEffect { manager.startEffect(effect, scope: scope) }
                pendingAudioEffect = nil
            }
        } message: {
            Text("LumenDesk analyzes Apple Music/system audio on the Mac (via the Screen Recording permission) and the microphone on iPhone and iPad. Audio is processed locally, never recorded or retained, and the active effect remains visible with a one-click Stop control.")
        }
        .onChange(of: section) { _ in
            searchText = ""
            themeCategory = nil
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Lumen.brandGradient).frame(width: 38, height: 38)
                Image(systemName: "wand.and.stars").foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Lighting Library").font(.title3.weight(.semibold))
                Text("Color and motion designed for both LIFX and Govee bulbs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ForEach(activeEffectScopes, id: \.self) { runScope in
                if let effectID = manager.activeEffects[runScope],
                   let effect = LightingCatalog.effects.first(where: { $0.id == effectID }) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                        VStack(alignment: .leading, spacing: 0) {
                            Text(effect.name).font(.caption.weight(.semibold))
                            Text(manager.scopeDisplayName(runScope)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Button("Stop") { manager.stopEffect(scope: runScope) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(6)
                    .background(Capsule().fill(Lumen.pink.opacity(0.14)))
                }
            }
            if activeEffectScopes.count > 1 {
                Button("Stop All") { manager.stopAllEffects() }.buttonStyle(.bordered)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var toolbar: some View {
        VStack(spacing: 10) {
            Picker("Library section", selection: $section) {
                ForEach(LibrarySection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(searchPlaceholder, text: $searchText).textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Lumen.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Lumen.hairline, lineWidth: 1))

                if section == .themes {
                    Menu {
                        Button("All moods") { themeCategory = nil }
                        Divider()
                        ForEach(LightingTheme.Category.allCases, id: \.self) { category in
                            Button(category.rawValue) { themeCategory = category }
                        }
                    } label: {
                        Label(themeCategory?.rawValue ?? "All moods", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .fixedSize()
                }

                if section != .scenes {
                    HStack(spacing: 6) {
                        Text("Apply to").font(.caption).foregroundStyle(.secondary)
                        Picker("Apply to", selection: $scope) {
                            Text("All Lights").tag(LightScope.all)
                            if !manager.rooms.isEmpty {
                                Divider()
                                ForEach(manager.rooms) { room in
                                    Text(room.name).tag(LightScope.room(room.id))
                                }
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("Apply themes and effects to")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var searchPlaceholder: String {
        switch section {
        case .scenes: return "Search saved scenes"
        case .themes: return "Search 18 color themes"
        case .effects: return "Search 10 animated effects"
        }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .scenes: scenesContent
        case .themes: themesContent
        case .effects: effectsContent
        }
    }

    private var themesContent: some View {
        ScrollView {
            if visibleThemes.isEmpty {
                noResults
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(visibleThemes) { themeCard($0) }
                }
                .padding(16)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func themeCard(_ theme: LightingTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: theme.icon)
                    .font(.title2).foregroundStyle(theme.colors.first?.color ?? Lumen.violetBright)
                Spacer()
                Text(theme.category.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold)).tracking(0.7)
                    .foregroundStyle(.secondary)
            }
            Text(theme.name).font(.headline)
            Text(theme.summary)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                ForEach(Array(theme.colors.enumerated()), id: \.offset) { _, swatch in
                    Rectangle().fill(swatch.color).frame(height: 24)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12), lineWidth: 1))
            HStack {
                Label("\(Int(theme.brightness * 100))%", systemImage: "sun.max.fill")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { manager.applyTheme(theme, scope: scope) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(scopedDeviceCount == 0)
                    .help(scopedDeviceCount == 0
                          ? "No lights in \(manager.scopeDisplayName(scope))"
                          : "Apply to \(manager.scopeDisplayName(scope))")
            }
        }
        .padding(12)
        .lumenCard(radius: 10)
    }

    private var effectsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(Lumen.violetBright)
                    Text("Effects run locally using common RGB and brightness commands. High-energy effects may not be suitable for people sensitive to flashing light.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(10).lumenCard(radius: 8, fill: Lumen.surfaceRaised)

                if visibleEffects.isEmpty {
                    noResults
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(visibleEffects) { effectCard($0) }
                    }
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    private func effectCard(_ effect: LightingEffect) -> some View {
        let isActive = manager.activeEffects[scope] == effect.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: effect.icon).font(.title2)
                    .foregroundStyle(isActive ? Lumen.pinkBright : Lumen.violetBright)
                Spacer()
                if effect.isAudioReactive {
                    Label("AUDIO", systemImage: "mic.fill").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Lumen.pinkBright)
                } else if effect.isHighEnergy {
                    Label("ENERGY", systemImage: "bolt.fill").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Lumen.warning)
                }
            }
            Text(effect.name).font(.headline)
            Text(effect.summary).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(Array(effect.colors.enumerated()), id: \.offset) { _, swatch in
                    Circle().fill(swatch.color).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
                }
                Spacer()
                if isActive {
                    Button("Stop") { manager.stopEffect(scope: scope) }
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button("Start") {
                        if effect.isAudioReactive && !UserDefaults.standard.bool(forKey: AppPreferenceKey.audioPrivacyAcknowledged) { pendingAudioEffect = effect }
                        else { manager.startEffect(effect, scope: scope) }
                    }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(scopedDeviceCount == 0)
                        .help(scopedDeviceCount == 0
                              ? "No lights in \(manager.scopeDisplayName(scope))"
                              : "Run in \(manager.scopeDisplayName(scope))")
                }
            }
        }
        .padding(12)
        .lumenCard(radius: 10, highlighted: isActive, glowColor: isActive ? Lumen.pink : nil)
    }

    private var scenesContent: some View {
        VStack(spacing: 0) {
            captureRow.padding(16)
            Divider()
            if manager.scenes.isEmpty {
                emptyScenes
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        if visibleScenes.isEmpty { noResults }
                        ForEach(visibleScenes) { sceneRow($0) }
                    }.padding(16)
                }.scrollContentBackground(.hidden)
            }
        }
        .sheetFrame(minWidth: 520, minHeight: 460)
        .sheet(item: $previewScene) { ScenePreviewView(scene: $0).environmentObject(manager) }
        .sheet(item: $editingScene) { SceneEditorView(scene: $0).environmentObject(manager) }
        .background(LumenBackground(glow: false))
    }

    private var captureRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("New scene name (e.g. “Evening”)", text: $newSceneName)
                    .textFieldStyle(.roundedBorder).onSubmit(capture)
                if let warning = manager.duplicateSceneNameMessage(newSceneName) { Text(warning).font(.caption2).foregroundStyle(Lumen.warning) }
            }
            Button("Capture Current State", action: capture)
                .buttonStyle(.borderedProminent)
                .disabled(newSceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.devices.isEmpty)
        }
    }

    private var emptyScenes: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "sparkles").font(.system(size: 32)).foregroundStyle(.secondary)
            Text("No scenes yet").font(.headline)
            Text("Set the lights how you like them, then capture the moment above.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResults: some View {
        Text("No lighting looks match your search.")
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(32)
    }

    private func sceneRow(_ scene: LightingScene) -> some View {
        HStack(spacing: 10) {
            Button { manager.toggleFavoriteScene(scene.id) } label: {
                Image(systemName: manager.isFavoriteScene(scene.id) ? "star.fill" : "star")
                    .foregroundStyle(manager.isFavoriteScene(scene.id) ? Lumen.gold : .secondary)
            }.buttonStyle(.plain)
            Image(systemName: "wand.and.stars").foregroundStyle(Lumen.violetBright).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                if renamingID == scene.id {
                    TextField("Scene name", text: $renameDraft).textFieldStyle(.roundedBorder)
                        .focused($renameFocused).onSubmit { commitRename(scene) }
                } else {
                    Text(scene.name).font(.callout.weight(.medium))
                }
                HStack(spacing: 3) {
                    ForEach(Array(sceneSwatches(scene).enumerated()), id: \.offset) { _, swatch in
                        Circle().fill(swatch.color).opacity(swatch.isOn ? 1 : 0.25).frame(width: 10, height: 10)
                    }
                }
                Text("\(scene.snapshots.count) light\(scene.snapshots.count == 1 ? "" : "s") · captured \(scene.createdAt.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()

            Button("Preview & Apply") { previewScene = scene }
                .buttonStyle(.bordered)
                .disabled(manager.availableDeviceIDs(for: scene).isEmpty)
                .accessibilityLabel("Preview and apply \(scene.name)")
                .accessibilityHint(manager.availableDeviceIDs(for: scene).isEmpty
                                   ? "No lights from this scene are currently available"
                                   : "Review and temporarily rehearse the saved state before applying it")

            Menu {
                Button("Preview & Apply…") { previewScene = scene }
                    .disabled(manager.availableDeviceIDs(for: scene).isEmpty)
                Button("Edit Draft…") { editingScene = scene }
                if !manager.revisions(for: scene.id).isEmpty { Button("Version History…") { editingScene = scene } }
                Button("Certify with Bureau of Lumens") { _ = manager.certify(scene) }
                Button("Rename…") { beginRename(scene) }
                Button(manager.isFavoriteScene(scene.id) ? "Remove Favorite" : "Favorite") { manager.toggleFavoriteScene(scene.id) }
                Button("Delete Scene", role: .destructive) { manager.deleteScene(scene.id) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(12).lumenCard(radius: 8)
    }

    private func sceneSwatches(_ scene: LightingScene) -> [(color: Color, isOn: Bool)] {
        scene.snapshots.values.prefix(8).map {
            (Color(hue: $0.hue, saturation: $0.saturation, brightness: max(0.5, $0.brightness)), $0.isOn)
        }
    }

    private func capture() {
        let name = newSceneName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        manager.captureScene(name: name)
        newSceneName = ""
    }

    private func beginRename(_ scene: LightingScene) {
        renameDraft = scene.name
        renamingID = scene.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename(_ scene: LightingScene) {
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { renamingID = nil; return }
        manager.renameScene(scene.id, to: name)
        renamingID = nil
    }
}

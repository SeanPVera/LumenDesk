import SwiftUI

/// A horizontally scrollable strip of compact tiles for the user's starred
/// lights, rooms, and scenes. Hidden entirely when nothing is pinned.
struct FavoritesStripView: View {
    @EnvironmentObject var manager: LightManager
    @State private var showingOrganizer = false

    var body: some View {
        Group {
            if hasFavorites {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(Lumen.gold)
                            .font(.caption)
                            .accessibilityHidden(true)
                        Text("Favorites")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Organize") { showingOrganizer = true }.font(.caption).buttonStyle(.plain)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(manager.favoriteOrder) { reference in
                                favoriteView(reference)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(duration: 0.35), value: hasFavorites)
        .onAppear { manager.reconcileFavoriteOrder() }
        .onChange(of: hasFavorites) { _ in manager.reconcileFavoriteOrder() }
        .sheet(isPresented: $showingOrganizer) { FavoriteOrganizerView().environmentObject(manager) }
    }

    @ViewBuilder
    private func favoriteView(_ reference: FavoriteReference) -> some View {
        switch reference.kind {
        case .light:
            if let device = manager.devices.first(where: { $0.id == reference.rawID }) { FavoriteTileView(device: device) }
        case .room:
            if let id = UUID(uuidString: reference.rawID), let room = manager.rooms.first(where: { $0.id == id }) { FavoriteRoomTile(room: room) }
        case .scene:
            if let id = UUID(uuidString: reference.rawID), let scene = manager.scenes.first(where: { $0.id == id }) { FavoriteSceneTile(scene: scene) }
        }
    }

    private var hasFavorites: Bool {
        !manager.favoriteDevices.isEmpty || !manager.favoriteRooms.isEmpty || !manager.favoriteScenes.isEmpty
    }
}

struct FavoriteOrganizerView: View {
    @EnvironmentObject var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("Organize Favorites").font(.title3.weight(.semibold)); Spacer(); Button("Done") { dismiss() } }
            Text("Drag favorites into the order you want. Lights, rooms, and scenes remain clearly labeled.").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(manager.favoriteOrder) { reference in
                    HStack { Image(systemName: icon(reference.kind)); Text(name(reference)); Spacer(); Text(reference.kind.rawValue.capitalized).font(.caption).foregroundStyle(.secondary) }
                }.onMove(perform: manager.moveFavorite)
            }.listStyle(.inset)
        }.padding(20).frame(width: 430, height: 460).background(LumenBackground(glow: false)).onAppear { manager.reconcileFavoriteOrder() }
    }
    private func icon(_ kind: FavoriteReference.Kind) -> String { switch kind { case .light: return "lightbulb"; case .room: return "rectangle.stack"; case .scene: return "wand.and.stars" } }
    private func name(_ reference: FavoriteReference) -> String {
        switch reference.kind {
        case .light: return manager.devices.first(where: { $0.id == reference.rawID })?.label ?? "Missing light"
        case .room: return UUID(uuidString: reference.rawID).flatMap { id in manager.rooms.first(where: { $0.id == id })?.name } ?? "Missing room"
        case .scene: return UUID(uuidString: reference.rawID).flatMap { id in manager.scenes.first(where: { $0.id == id })?.name } ?? "Missing scene"
        }
    }
}

private struct FavoriteRoomTile: View {
    @EnvironmentObject var manager: LightManager
    let room: Room

    var body: some View {
        let lights = manager.devices(in: room)
        let onCount = lights.filter { $0.isOn }.count
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "rectangle.stack.fill")
                    .foregroundStyle(Color.accentColor)
                Text(room.name).lineLimit(1).help(room.name)
                Toggle("", isOn: Binding(
                    get: { !lights.isEmpty && lights.allSatisfy { $0.isOn } },
                    set: { manager.setPower(in: room, on: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .tint(Lumen.pink)
                .disabled(lights.isEmpty)
            }
            Text(lights.isEmpty ? "No lights" : "\(onCount) of \(lights.count) on")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .favoriteTileStyle()
        .contextMenu { Button("Remove Room Favorite") { manager.toggleFavoriteRoom(room.id) } }
    }
}

private struct FavoriteSceneTile: View {
    @EnvironmentObject var manager: LightManager
    let scene: LightingScene

    var body: some View {
        Button {
            manager.applyScene(scene)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(Lumen.violetBright)
                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.name).lineLimit(1).help(scene.name)
                    Text("\(scene.snapshots.count) lights")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .favoriteTileStyle()
        .contextMenu { Button("Remove Scene Favorite") { manager.toggleFavoriteScene(scene.id) } }
    }
}

private struct FavoriteTileView: View {
    @EnvironmentObject var manager: LightManager
    @ObservedObject var device: LightDevice

    private var powerBinding: Binding<Bool> {
        Binding(get: { device.isOn },
                set: { manager.setPower(device, on: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(device.isOn ? device.color : Color.gray.opacity(0.35))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(.secondary.opacity(0.4), lineWidth: 0.5))
                    .accessibilityHidden(true)
                Text(device.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 110, alignment: .leading)
                    .help(device.label)
                Toggle("", isOn: powerBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
                    .tint(Lumen.pink)
                    .accessibilityLabel(device.isOn ? "Turn off \(device.label)" : "Turn on \(device.label)")
            }
        }
        .favoriteTileStyle()
        .opacity(device.isStale ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(device.label)\(device.isStale ? ", may be offline" : "")")
        .contextMenu {
            Button("Remove from Favorites") { manager.toggleFavorite(device.id) }
        }
    }
}

private extension View {
    func favoriteTileStyle() -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Lumen.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Lumen.hairline, lineWidth: 1)
            )
    }
}

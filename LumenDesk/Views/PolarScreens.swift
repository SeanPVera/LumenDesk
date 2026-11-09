import SwiftUI

// MARK: - Polar mark

/// The app's mark in SwiftUI: seven lit hexagon panels in the blue → mint →
/// amber gradient of the app icon. Used in the sidebar and empty states.
struct LumenHexMark: View {
    var size: CGFloat = 28

    /// Axial offsets of the seven-panel cluster, as fractions of the mark.
    private static let cells: [(x: CGFloat, y: CGFloat, color: Color)] = [
        (0.50, 0.50, Polar.mint),
        (0.50, 0.17, Polar.accent),
        (0.79, 0.33, Polar.select),
        (0.79, 0.67, Polar.mint),
        (0.50, 0.83, Polar.amber),
        (0.21, 0.67, Polar.amber),
        (0.21, 0.33, Polar.accent)
    ]

    var body: some View {
        ZStack {
            ForEach(Array(Self.cells.enumerated()), id: \.offset) { _, cell in
                PolarHexagon()
                    .fill(cell.color)
                    .frame(width: size * 0.36, height: size * 0.31)
                    .shadow(color: cell.color.opacity(0.7), radius: size * 0.08)
                    .position(x: size * cell.x, y: size * cell.y)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Up to four dots in a Look's captured colours.
struct LookSwatchDots: View {
    let look: LightingScene

    private var colors: [Color] {
        look.snapshots.values
            .filter(\.isOn)
            .sorted { $0.hue < $1.hue }
            .prefix(4)
            .map { Color(hue: $0.hue, saturation: $0.saturation, brightness: 1) }
    }

    var body: some View {
        HStack(spacing: -3) {
            if colors.isEmpty {
                Circle().fill(Polar.raised).frame(width: 10, height: 10)
            }
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Polar.deck, lineWidth: 1.5))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Looks library

/// The Looks window from the Polar "Looks" artboard: every saved Look that
/// touches this room as a lit card, plus the everyday templates. Applying
/// uses the same LightManager calls as the room's Look shelf.
struct LooksLibraryView: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    let room: Room
    let compose: () -> Void
    /// Opens a saved Look in the composer.
    var edit: ((LightingScene) -> Void)? = nil

    private var ids: Set<String> { Set(room.lightIDs) }
    private var roomLooks: [LightingScene] {
        manager.scenes.filter { !Set($0.snapshots.keys).isDisjoint(with: ids) }
    }

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: PolarSpacing.md)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PolarSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Looks — \(room.name)")
                        .font(.polarDisplay(24, weight: .bold))
                    Text("Apply a Look to the room, or compose a new one.")
                        .font(.polarUI(13))
                        .foregroundStyle(Polar.meter)
                }
                Spacer()
                Button(action: compose) {
                    Label("Compose Look", systemImage: "paintpalette")
                }
                .buttonStyle(PolarButtonStyle(kind: .prominent))
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Done") { dismiss() }
                    .buttonStyle(PolarButtonStyle(kind: .quiet))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(PolarSpacing.lg)
            .background(Polar.desk)
            .overlay(alignment: .bottom) { Rectangle().fill(Polar.ruleSoft).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: PolarSpacing.lg) {
                    if !roomLooks.isEmpty {
                        PolarSectionLabel("Library")
                        LazyVGrid(columns: columns, spacing: PolarSpacing.md) {
                            ForEach(roomLooks) { look in
                                lookCard(name: look.name,
                                         detail: "\(look.snapshots.keys.filter(ids.contains).count) lights in \(room.name)",
                                         colors: colors(of: look)) {
                                    manager.applyLook(look, deviceIDs: ids)
                                }
                                .contextMenu {
                                    if let edit {
                                        Button("Edit in Composer\u{2026}") { edit(look) }
                                    }
                                    Button("Duplicate Look") { manager.duplicateLook(look.id) }
                                    Button("Delete Look", role: .destructive) { manager.deleteScene(look.id) }
                                }
                            }
                        }
                    }
                    PolarSectionLabel("Everyday")
                    LazyVGrid(columns: columns, spacing: PolarSpacing.md) {
                        ForEach(RoomLookTemplate.everyday) { template in
                            if let theme = LightingCatalog.theme(withID: template.themeID) {
                                lookCard(name: template.name,
                                         detail: theme.name,
                                         colors: theme.colors.prefix(4).map(\.color),
                                         symbol: template.symbol) {
                                    manager.applyTheme(theme, deviceIDs: ids, in: .room(room.id))
                                }
                            }
                        }
                    }
                }
                .padding(PolarSpacing.lg)
            }
        }
        .background(Polar.stage)
        .foregroundStyle(Polar.chalk)
        .sheetFrame(minWidth: 640, idealWidth: 860, minHeight: 480, idealHeight: 620)
    }

    private func colors(of look: LightingScene) -> [Color] {
        let lit = look.snapshots.filter { ids.contains($0.key) && $0.value.isOn }.values
        let sorted = lit.sorted { $0.hue < $1.hue }.prefix(4)
        let mapped = sorted.map { Color(hue: $0.hue, saturation: $0.saturation, brightness: 1) }
        return mapped.isEmpty ? [Polar.raised] : Array(mapped)
    }

    private func lookCard(name: String, detail: String, colors: [Color], symbol: String? = nil,
                          apply: @escaping () -> Void) -> some View {
        Button(action: apply) {
            VStack(alignment: .leading, spacing: PolarSpacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Polar.stage)
                    ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                        Circle()
                            .fill(RadialGradient(colors: [color.opacity(0.95), color.opacity(0)],
                                                 center: .center, startRadius: 2, endRadius: 46))
                            .frame(width: 92, height: 92)
                            .offset(x: CGFloat(index) * 36 - CGFloat(colors.count - 1) * 18,
                                    y: index.isMultiple(of: 2) ? -6 : 8)
                    }
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
                }
                .frame(height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(name)
                    .font(.polarDisplay(16, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.polarUI(12))
                    .foregroundStyle(Polar.meter)
                    .lineLimit(1)
            }
            .padding(PolarSpacing.sm)
            .background(Polar.desk, in: RoundedRectangle(cornerRadius: Polar.radiusCard, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Polar.radiusCard, style: .continuous)
                .stroke(Polar.rule, lineWidth: 1))
            .shadow(color: (colors.first ?? .clear).opacity(0.18), radius: 16)
            .contentShape(RoundedRectangle(cornerRadius: Polar.radiusCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Apply \(name)")
        .accessibilityHint(detail)
    }
}

// MARK: - Needs attention

/// Fixtures in a room that are not Confirmed, with the action that fixes
/// each one. Shown on the Room Stage above the field.
struct NeedsAttentionStrip: View {
    @EnvironmentObject private var manager: LightManager
    let lights: [LightDevice]
    let openSetup: () -> Void

    private var troubled: [LightDevice] {
        lights.filter { $0.isStale || manager.commandState(for: $0.id).phase == .failed || $0.needsNanoleafPairing }
    }

    var body: some View {
        if !troubled.isEmpty {
            HStack(spacing: PolarSpacing.sm) {
                Image(systemName: RoomCanvasStatus.needsAttention.symbol)
                    .foregroundStyle(Polar.attention)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Needs attention")
                        .font(.polarUI(13, weight: .semibold))
                    Text(troubled.map(\.label).joined(separator: ", "))
                        .font(.polarUI(12))
                        .foregroundStyle(Polar.meter)
                        .lineLimit(1)
                }
                Spacer()
                if troubled.contains(where: { $0.needsNanoleafPairing }) {
                    Button("Pair again", action: openSetup)
                        .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
                }
                Button("Retry") { troubled.forEach { manager.retry($0) } }
                    .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
                Button("Rescan") { manager.scan() }
                    .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
                    .disabled(manager.isScanning)
            }
            .padding(.horizontal, PolarSpacing.md)
            .padding(.vertical, PolarSpacing.sm)
            .background(Polar.attention.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Polar.attention.opacity(0.45), lineWidth: 1))
            .accessibilityElement(children: .contain)
        }
    }
}

// MARK: - Offline

/// Shown over the Room Stage when every light in the room has stopped
/// answering: the stage keeps the last known layout and Looks stay editable.
struct OfflineBanner: View {
    @EnvironmentObject private var manager: LightManager
    let roomName: String

    var body: some View {
        HStack(spacing: PolarSpacing.sm) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Polar.pending)
            VStack(alignment: .leading, spacing: 2) {
                Text("Offline · local network unreachable")
                    .font(.polarUI(13, weight: .semibold))
                Text("Showing the last known layout for \(roomName). Looks stay editable; applying waits until lights are Confirmed again.")
                    .font(.polarUI(12))
                    .foregroundStyle(Polar.meter)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Retry connection") { manager.scan() }
                .buttonStyle(PolarButtonStyle(kind: .prominent, compact: true))
                .disabled(manager.isScanning)
        }
        .padding(PolarSpacing.md)
        .background(Polar.desk, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Polar.pending.opacity(0.6), lineWidth: 1))
    }
}

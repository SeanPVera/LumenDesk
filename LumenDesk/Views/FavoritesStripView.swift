import SwiftUI

/// A horizontally scrollable strip of compact tiles for the user's starred
/// lights. Hidden entirely when no favorites are set. Each tile exposes the
/// power toggle directly so frequently-used lights stay one click away.
struct FavoritesStripView: View {
    @EnvironmentObject var manager: LightManager

    var body: some View {
        let favorites = manager.favoriteDevices
        if !favorites.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text("Favorites")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(favorites) { device in
                            FavoriteTileView(device: device)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
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
                Text(device.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 110, alignment: .leading)
                    .help(device.name)
                Toggle("", isOn: powerBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .opacity(device.isStale ? 0.6 : 1)
        .contextMenu {
            Button("Remove from Favorites") { manager.toggleFavorite(device.id) }
        }
    }
}

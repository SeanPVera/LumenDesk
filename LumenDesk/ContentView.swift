import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: LightManager

    var body: some View {
        VStack(spacing: 0) {
            header

            if manager.devices.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(manager.devices) { device in
                            LightRowView(device: device)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .font(.title2)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("LumenDesk").font(.title3.weight(.semibold))
                Text(manager.statusMessage.isEmpty
                     ? "\(manager.devices.count) light\(manager.devices.count == 1 ? "" : "s") on this network"
                     : manager.statusMessage)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if manager.isScanning {
                ProgressView().controlSize(.small)
            }
            Button {
                manager.scan()
            } label: {
                Label("Scan", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(Divider(), alignment: .bottom)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "lightbulb.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No lights found yet").font(.headline)
            Text("Make sure your Mac is on the same Wi-Fi network as your bulbs. For Govee, enable “LAN Control” for each bulb in the Govee Home app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Scan again") { manager.scan() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#Preview {
    ContentView()
        .environmentObject(LightManager())
        .frame(width: 640, height: 480)
}

import SwiftUI

struct NanoleafPairingView: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = "16021"
    @State private var serviceID: String?
    @State private var isPairing = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Pair Nanoleaf Shapes").font(.title2.bold())
                    Spacer()
                    Button("Done") { dismiss() }.disabled(isPairing)
                }
                Text("Set up your Shapes in the Nanoleaf app first, then join the same Wi-Fi network.")
                    .foregroundStyle(.secondary)
                if manager.isDemoMode {
                    Text("Leave Demo Mode to pair your controller.").foregroundStyle(Lumen.warning)
                } else {
                    HStack {
                        Text("Controllers on this network").font(.headline)
                        Spacer()
                        Button("Scan") { manager.scan() }.disabled(isPairing || manager.isScanning)
                    }
                    ForEach(manager.nanoleafCandidates) { candidate in
                        Button {
                            host = candidate.endpoint.host
                            port = String(candidate.endpoint.port)
                            serviceID = candidate.id
                            error = nil
                        } label: {
                            HStack {
                                Image(systemName: "hexagon.fill").foregroundStyle(Lumen.cyan)
                                VStack(alignment: .leading) {
                                    Text(candidate.name)
                                    Text(candidate.endpoint.host).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if serviceID == candidate.id { Image(systemName: "checkmark.circle.fill") }
                            }
                            .padding(10)
                            .background(Lumen.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(isPairing)
                    }
                    if manager.nanoleafCandidates.isEmpty {
                        Text(manager.nanoleafDiscoveryError ?? "Scanning for Shapes. You can also enter the controller’s address from the Nanoleaf app or your router.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("IP address or local hostname", text: $host)
                            .onChange(of: host) { value in
                                if !manager.nanoleafCandidates.contains(where: { $0.id == serviceID && $0.endpoint.host == value }) {
                                    serviceID = nil
                                }
                            }
                        TextField("Port", text: $port)
                    }
                    .textFieldStyle(.roundedBorder)
                    .disabled(isPairing)
                    Text("Hold the controller’s power button for 5–7 seconds until the LED flashes. Press Pair within 30 seconds.")
                    if let error { Text(error).foregroundStyle(Lumen.warning).accessibilityLabel("Pairing failed: \(error)") }
                    HStack {
                        if isPairing { ProgressView().controlSize(.small) }
                        Spacer()
                        Button(isPairing ? "Pairing…" : "Pair") { pair() }
                            .buttonStyle(LumenPrimaryButtonStyle())
                            .disabled(isPairing || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("Pairing stays on this device in Keychain. Each Shapes controller appears as one light in your rooms.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .sheetFrame(minWidth: 420, idealWidth: 520)
        .background(LumenBackground(glow: false))
        .interactiveDismissDisabled(isPairing)
        .onAppear { if !manager.isDemoMode { manager.scan() } }
    }

    private func pair() {
        guard let port = Int(port) else { error = NanoleafError.invalidAddress.localizedDescription; return }
        isPairing = true
        error = nil
        Task { @MainActor in
            defer { isPairing = false }
            do {
                try await manager.pairNanoleaf(host: host, port: port, serviceID: serviceID)
                dismiss()
            } catch {
                self.error = (error as? NanoleafError ?? .unavailable).localizedDescription
            }
        }
    }
}

struct NanoleafEffectsControl: View {
    @EnvironmentObject private var manager: LightManager
    @ObservedObject var device: LightDevice
    @State private var showingPairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if device.needsNanoleafPairing {
                Button("Pair Nanoleaf Again") { showingPairing = true }
                Text("Access expired. Hold the controller’s power button to reconnect.")
                    .font(.caption).foregroundStyle(Lumen.warning)
            } else {
                Menu {
                    ForEach(device.nanoleafEffects, id: \.self) { name in
                        Button(name) { manager.selectNanoleafEffect(device, name: name) }
                    }
                } label: {
                    Label(device.nanoleafAppearance?.effect ?? "Nanoleaf Effects", systemImage: "hexagon.fill")
                }
                .disabled(device.nanoleafEffects.isEmpty || manager.animatingEffect(for: device.id) != nil)
                Text("Effects saved on your Shapes controller").font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showingPairing) { NanoleafPairingView().environmentObject(manager) }
    }
}

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
                    Text("Pair Nanoleaf Shapes or Aurora")
                        .font(LumenType.display(size: 24, weight: .bold))
                        .foregroundStyle(Lumen.graphite)
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(LumenSecondaryButtonStyle(compact: true))
                        .disabled(isPairing)
                }
                Text("Set up your Shapes or Aurora Light Panels in the Nanoleaf app first, then join the same Wi-Fi network.")
                    .foregroundStyle(Lumen.ash)
                if manager.isDemoMode {
                    Text("Leave Demo Mode to pair your controller.").foregroundStyle(Lumen.ochre)
                } else {
                    HStack {
                        Text("Controllers on this network")
                            .font(LumenType.display(size: 16, weight: .bold))
                            .foregroundStyle(Lumen.graphite)
                        Spacer()
                        Button("Scan") { manager.scan() }
                            .buttonStyle(LumenSecondaryButtonStyle(compact: true))
                            .disabled(isPairing || manager.isScanning)
                    }
                    ForEach(manager.nanoleafCandidates) { candidate in
                        Button {
                            host = candidate.endpoint.host
                            port = String(candidate.endpoint.port)
                            serviceID = candidate.id
                            error = nil
                        } label: {
                            HStack {
                                Image(systemName: "hexagon.fill").foregroundStyle(Lumen.verdigris)
                                VStack(alignment: .leading) {
                                    Text(candidate.name).foregroundStyle(Lumen.graphite)
                                    Text(candidate.endpoint.host).font(.caption).foregroundStyle(Lumen.ash)
                                }
                                Spacer()
                                if serviceID == candidate.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Lumen.ember)
                                }
                            }
                            .padding(10)
                            .background(Lumen.floor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(serviceID == candidate.id ? Lumen.ember : Lumen.rule, lineWidth: serviceID == candidate.id ? 2 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isPairing)
                    }
                    if manager.nanoleafCandidates.isEmpty {
                        Text(manager.nanoleafDiscoveryError ?? "Scanning for Shapes and Aurora controllers. You can also enter the controller’s address from the Nanoleaf app or your router.")
                            .font(.callout).foregroundStyle(Lumen.ash)
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
                        .foregroundStyle(Lumen.graphite)
                    if let error { Text(error).foregroundStyle(Lumen.ochre).accessibilityLabel("Pairing failed: \(error)") }
                    HStack {
                        if isPairing { ProgressView().controlSize(.small) }
                        Spacer()
                        Button(isPairing ? "Pairing…" : "Pair") { pair() }
                            .buttonStyle(LumenPrimaryButtonStyle())
                            .disabled(isPairing || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("Pairing stays on this device in Keychain. Each controller appears as one light in your rooms.")
                        .font(.caption).foregroundStyle(Lumen.ash)
                }
            }
            .padding(24)
        }
        .sheetFrame(minWidth: 420, idealWidth: 520)
        .background(Lumen.canvas)
        .foregroundStyle(Lumen.graphite)
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
                    .font(.caption).foregroundStyle(Lumen.ochre)
            } else {
                Menu {
                    ForEach(device.nanoleafEffects, id: \.self) { name in
                        Button(name) { manager.selectNanoleafEffect(device, name: name) }
                    }
                } label: {
                    Label(device.nanoleafAppearance?.effect ?? "Nanoleaf Effects", systemImage: "hexagon.fill")
                }
                .disabled(device.nanoleafEffects.isEmpty || manager.animatingEffect(for: device.id) != nil)
                Text("Effects saved on your \(device.nanoleafProductName) controller").font(.caption).foregroundStyle(Lumen.ash)
            }
        }
        .sheet(isPresented: $showingPairing) { NanoleafPairingView().environmentObject(manager) }
    }
}

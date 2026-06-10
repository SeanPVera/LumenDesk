import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit

struct DiagnosticsCenterView: View {
    @EnvironmentObject var manager: LightManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sheetHeader("Discovery Diagnostics", icon: "stethoscope", dismiss: dismiss)
            Text("LumenDesk uses local UDP broadcasts. These checks explain what the last scan could reach and what to try next.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(manager.scanDiagnostics) { diagnostic in DiagnosticRow(diagnostic: diagnostic) }
            Divider()
            HStack {
                Button("Open Network Settings") { openSettings("x-apple.systempreferences:com.apple.Network-Settings.extension") }
                Button("Open Privacy Settings") { openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") }
                Spacer()
                Button("Scan Again") { manager.scan() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 560)
        .background(LumenBackground(glow: false))
    }

    private func openSettings(_ value: String) { if let url = URL(string: value) { NSWorkspace.shared.open(url) } }
}

struct DeviceInspectorView: View {
    @EnvironmentObject var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var device: LightDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sheetHeader(device.label, icon: "info.circle", dismiss: dismiss)
            HStack {
                Circle().fill(device.isOn ? device.color : .gray).frame(width: 34, height: 34)
                VStack(alignment: .leading) {
                    Text(device.brand.displayName).font(.headline)
                    Text(device.isStale ? "Recovery recommended" : "Responding normally")
                        .font(.caption).foregroundStyle(device.isStale ? Lumen.warning : Color.green)
                }
                Spacer()
                Button("Identify") { manager.identify(device) }
                Button("Retry") { manager.retry(device) }
            }
            ForEach(manager.diagnostics(for: device)) { diagnostic in DiagnosticRow(diagnostic: diagnostic) }
            Divider()
            HStack {
                Button("Copy Diagnostics") {
                    let text = manager.diagnostics(for: device)
                        .filter { $0.title != "Address" && $0.title != "LAN identifier" }
                        .map { "\($0.title): \($0.value)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                }
                Spacer()
                if device.isStale { Button("Rescan Network") { manager.scan() }.buttonStyle(.borderedProminent) }
            }
        }
        .padding(20).frame(width: 500)
        .background(LumenBackground(glow: false))
    }
}

private struct DiagnosticRow: View {
    let diagnostic: ScanDiagnostic
    var body: some View {
        HStack {
            Image(systemName: diagnostic.status == .good ? "checkmark.circle.fill" : diagnostic.status == .warning ? "exclamationmark.triangle.fill" : "circle.fill")
                .foregroundStyle(diagnostic.status == .good ? Color.green : diagnostic.status == .warning ? Lumen.warning : Color.secondary)
                .frame(width: 20)
            Text(diagnostic.title).foregroundStyle(.secondary)
            Spacer()
            Text(diagnostic.value).textSelection(.enabled).multilineTextAlignment(.trailing)
        }
        .padding(10).background(Lumen.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ActivityLogView: View {
    @EnvironmentObject var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var kind: ActivityEvent.Kind?

    private var events: [ActivityEvent] {
        manager.activityEvents.filter { event in
            (kind == nil || event.kind == kind) && (query.isEmpty || event.title.localizedCaseInsensitiveContains(query) || event.detail.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            sheetHeader("Activity & Automation Log", icon: "clock.arrow.circlepath", dismiss: dismiss)
            HStack {
                TextField("Search history", text: $query).textFieldStyle(.roundedBorder)
                Picker("Type", selection: $kind) {
                    Text("All Types").tag(ActivityEvent.Kind?.none)
                    ForEach(ActivityEvent.Kind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                }.frame(width: 160)
                Button("Export…", action: export)
                Button("Clear", role: .destructive) { manager.clearActivity() }
            }
            List(events) { event in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: event.isFailure ? "exclamationmark.triangle.fill" : icon(for: event.kind))
                        .foregroundStyle(event.isFailure ? Lumen.warning : Lumen.violetBright).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title).font(.callout.weight(.medium))
                        if !event.detail.isEmpty { Text(event.detail).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                }.padding(.vertical, 4)
            }.listStyle(.inset)
        }
        .padding(20).frame(width: 700, height: 560).background(LumenBackground(glow: false))
    }

    private func icon(for kind: ActivityEvent.Kind) -> String {
        switch kind { case .scan: return "antenna.radiowaves.left.and.right"; case .schedule: return "clock"; case .scene: return "wand.and.stars"; case .recovery: return "wrench"; case .parliament: return "building.columns"; case .ecosystem: return "ladybug"; case .compliance: return "checkmark.seal"; default: return "lightbulb" }
    }

    private func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "LumenDesk-Activity.txt"
        if panel.runModal() == .OK, let url = panel.url { try? manager.activityExportText().write(to: url, atomically: true, encoding: .utf8) }
    }
}

struct PreciseColorEditorView: View {
    @EnvironmentObject var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var device: LightDevice
    @State private var red = 255.0
    @State private var green = 255.0
    @State private var blue = 255.0
    @State private var hex = "#FFFFFF"
    @State private var kelvin = 3500.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sheetHeader("Precise Color — \(device.label)", icon: "eyedropper", dismiss: dismiss)
            HStack {
                Circle().fill(candidate).frame(width: 64, height: 64).overlay(Circle().stroke(.white.opacity(0.25)))
                VStack(alignment: .leading) {
                    TextField("Hex", text: $hex).textFieldStyle(.roundedBorder).onSubmit(parseHex)
                    Text("RGB \(Int(red)), \(Int(green)), \(Int(blue)) · HSB \(Int(candidate.hsbComponents.h * 360))°, \(Int(candidate.hsbComponents.s * 100))%, \(Int(candidate.hsbComponents.b * 100))%").font(.caption).foregroundStyle(.secondary)
                }
            }
            channel("Red", value: $red, tint: .red)
            channel("Green", value: $green, tint: .green)
            channel("Blue", value: $blue, tint: .blue)
            HStack { Text("White temperature"); Slider(value: $kelvin, in: 2500...9000, step: 50); Text("\(Int(kelvin)) K").monospacedDigit().frame(width: 70) }
            if !manager.recentColors.isEmpty {
                Text("Recent colors").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack { ForEach(manager.recentColors) { recent in Button { set(recent.color) } label: { Circle().fill(recent.color).frame(width: 22, height: 22) }.buttonStyle(.plain).help("\(recent.name) · \(recent.hex)") } }
            }
            HStack { Spacer(); Button("Apply White") { manager.setKelvin(device, kelvin: Int(kelvin)); dismiss() }; Button("Apply Color") { manager.setColor(device, color: candidate); dismiss() }.buttonStyle(.borderedProminent) }
        }
        .padding(20).frame(width: 460).background(LumenBackground(glow: false))
        .onAppear { set(device.color); kelvin = Double(device.kelvin) }
        .onChange(of: red) { _ in updateHex() }.onChange(of: green) { _ in updateHex() }.onChange(of: blue) { _ in updateHex() }
    }

    private var candidate: Color { Color(red: red / 255, green: green / 255, blue: blue / 255) }
    private func channel(_ name: String, value: Binding<Double>, tint: Color) -> some View { HStack { Text(name).frame(width: 48, alignment: .leading); Slider(value: value, in: 0...255, step: 1).tint(tint); Text("\(Int(value.wrappedValue))").monospacedDigit().frame(width: 34) } }
    private func updateHex() { hex = String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue)) }
    private func set(_ color: Color) { let rgb = color.rgbComponents; red = rgb.r * 255; green = rgb.g * 255; blue = rgb.b * 255; updateHex() }
    private func parseHex() { let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted); guard clean.count == 6, let value = Int(clean, radix: 16) else { return }; red = Double((value >> 16) & 255); green = Double((value >> 8) & 255); blue = Double(value & 255); updateHex() }
}

struct LightingParliamentView: View {
    @EnvironmentObject var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    @State private var motion = "That all lights shall be dimmed to fifty percent"
    @State private var latest: ParliamentSession?

    var body: some View {
        VStack(spacing: 14) {
            sheetHeader("Democratic Lighting Parliament", icon: "building.columns.fill", dismiss: dismiss)
            Text("Every discovered bulb has a party affiliation and a completely unnecessary vote. Unreachable members abstain.").font(.callout).foregroundStyle(.secondary)
            HStack { TextField("Motion before the chamber", text: $motion).textFieldStyle(.roundedBorder); Button("Call the Vote") { latest = manager.conveneParliament(motion: motion) }.buttonStyle(.borderedProminent); Button("Executive Order") { manager.executiveIlluminationOrder(motion: motion) } }
            if let latest {
                HStack { result("Ayes", latest.ayes, .green); result("Noes", latest.noes, .red); result("Abstentions", latest.abstentions, .secondary); Spacer(); Text(latest.verdict).font(.headline) }.padding(12).lumenCard(radius: 10)
            }
            List(manager.parliamentMembers) { member in
                HStack { Image(systemName: "lightbulb.fill").foregroundStyle(partyColor(member.party)); VStack(alignment: .leading) { Text(member.parliamentaryName); Text(member.party.rawValue).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(member.lastVote).font(.caption); Gauge(value: Double(member.approval), in: 0...100) { Text("Approval") }.gaugeStyle(.accessoryLinear).frame(width: 90) }
            }.listStyle(.inset)
        }.padding(20).frame(width: 760, height: 580).background(LumenBackground(glow: false)).onAppear { manager.ensureParliament() }
    }

    private func result(_ name: String, _ value: Int, _ color: Color) -> some View { VStack { Text("\(value)").font(.title2.bold()).foregroundStyle(color); Text(name).font(.caption) } }
    private func partyColor(_ party: ParliamentMember.Party) -> Color { switch party { case .warmCoalition: return .orange; case .chromaticLeft: return .pink; case .efficiencyBloc: return .green; case .nocturnalCaucus: return .indigo } }
}

struct FireflyEcosystemView: View {
    @EnvironmentObject var manager: LightManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            sheetHeader("Aurora Firefly Conservatory", icon: "ladybug.fill", dismiss: dismiss)
            Text("A persistent artificial ecosystem whose genetics and energy respond to your real lighting habits. It is scientifically indefensible.").font(.callout).foregroundStyle(.secondary)
            HStack { metric("Population", "\(manager.fireflyCitizens.count)"); metric("Generations", "\(manager.fireflyCitizens.map(\.generation).max() ?? 1)"); metric("Rare", "\(manager.fireflyCitizens.filter { $0.rarity != "Common" }.count)"); Spacer(); Button("Advance Evolution") { manager.evolveFireflies() }; Button("Reseed", role: .destructive) { manager.seedFireflies() } }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 10) {
                    ForEach(manager.fireflyCitizens) { citizen in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Circle().fill(Color(hue: citizen.hue, saturation: 0.8, brightness: 1)).frame(width: 18, height: 18).shadow(color: Color(hue: citizen.hue, saturation: 0.8, brightness: 1), radius: 7); Text(citizen.name).font(.callout.weight(.medium)) }
                            Text("Generation \(citizen.generation) · \(citizen.rarity)").font(.caption2).foregroundStyle(.secondary)
                            ProgressView(value: citizen.energy) { Text("Energy") }.tint(Color(hue: citizen.hue, saturation: 0.8, brightness: 1))
                            Text("Prefers \(citizen.preferredKelvin) K").font(.caption2).foregroundStyle(.tertiary)
                        }.padding(10).lumenCard(radius: 9)
                    }
                }.padding(4)
            }
        }.padding(20).frame(width: 760, height: 600).background(LumenBackground(glow: false))
    }
    private func metric(_ title: String, _ value: String) -> some View { VStack(alignment: .leading) { Text(value).font(.title3.bold()); Text(title).font(.caption).foregroundStyle(.secondary) }.padding(10).lumenCard(radius: 8) }
}

struct ComplianceSuiteView: View {
    @EnvironmentObject var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSceneID: UUID?
    @State private var certification: SceneCertification?

    var body: some View {
        VStack(spacing: 14) {
            sheetHeader("International Bureau of Lumens", icon: "checkmark.seal.fill", dismiss: dismiss)
            Text("Certify scenes against fictional treaties, moth-attraction limits, naming law, and wall-paint diplomacy.").font(.callout).foregroundStyle(.secondary)
            HStack { Picker("Scene", selection: $selectedSceneID) { Text("Choose a scene").tag(UUID?.none); ForEach(manager.scenes) { Text($0.name).tag(Optional($0.id)) } }.frame(maxWidth: 320); Button("Begin 47-Point Inspection") { if let id = selectedSceneID, let scene = manager.scenes.first(where: { $0.id == id }) { certification = manager.certify(scene) } }.buttonStyle(.borderedProminent).disabled(selectedSceneID == nil); Spacer() }
            if let certification {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Image(systemName: "seal.fill").font(.system(size: 52)).foregroundStyle(sealColor(certification.seal)); VStack(alignment: .leading) { Text("\(certification.seal.rawValue.capitalized) Seal").font(.title2.bold()); Text("Score \(certification.score)/100 · \(certification.treatyCode)").foregroundStyle(.secondary) }; Spacer(); Button("Export 47-Page Dossier…") { exportPDF(certification) } }
                    ForEach(certification.findings, id: \.self) { Label($0, systemImage: "doc.text.magnifyingglass") }
                    Text("Certification is legally meaningless in every known jurisdiction.").font(.caption).foregroundStyle(.tertiary)
                }.padding(16).lumenCard(radius: 12)
            } else { Spacer(); VStack(spacing: 8) { Image(systemName: "checkmark.seal").font(.system(size: 36)).foregroundStyle(.secondary); Text("Awaiting Inspection").font(.headline); Text("Select a scene to begin an entirely unnecessary compliance process.").foregroundStyle(.secondary) }; Spacer() }
        }.padding(20).frame(width: 700, height: 520).background(LumenBackground(glow: false))
    }

    private func sealColor(_ seal: SceneCertification.Seal) -> Color { seal == .gold ? .yellow : seal == .silver ? .gray : .brown }
    private func exportPDF(_ certificate: SceneCertification) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = "IBL-\(certificate.treatyCode)-Dossier.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let document = PDFDocument()
        for pageNumber in 1...47 {
            let image = NSImage(size: NSSize(width: 612, height: 792))
            image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 612, height: 792).fill()
            let title = "INTERNATIONAL BUREAU OF LUMENS\nCompliance Dossier · Page \(pageNumber) of 47"
            title.draw(in: NSRect(x: 48, y: 650, width: 516, height: 90), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.black])
            let body = "Treaty code: \(certificate.treatyCode)\nSeal: \(certificate.seal.rawValue.uppercased())\nScore: \(certificate.score)/100\n\n\(certificate.findings.joined(separator: "\n\n"))\n\nAppendix \(pageNumber): This page exists solely because the specification demanded unreasonable complexity."
            body.draw(in: NSRect(x: 48, y: 120, width: 516, height: 500), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
            image.unlockFocus(); if let page = PDFPage(image: image) { document.insert(page, at: document.pageCount) }
        }
        document.write(to: url)
    }
}

@ViewBuilder
private func sheetHeader(_ title: String, icon: String, dismiss: DismissAction) -> some View {
    HStack { Label(title, systemImage: icon).font(.title3.weight(.semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
}

struct ScenePreviewView: View {
    @EnvironmentObject var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    let scene: LightingScene
    @State private var allowTurningOff = true

    private var preview: SceneApplicationPreview { manager.scenePreview(scene) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sheetHeader("Preview — \(scene.name)", icon: "eye", dismiss: dismiss)
            Text("Review the exact scope before LumenDesk changes the room.").font(.callout).foregroundStyle(.secondary)
            HStack { previewMetric("Affected", preview.affected.count, .blue); previewMetric("Unchanged", preview.unchanged.count, .secondary); previewMetric("Offline", preview.unreachable.count, Lumen.warning); previewMetric("Missing", preview.missingIDs.count, .red) }
            Toggle("Allow this scene to turn lights off", isOn: $allowTurningOff)
            if !preview.unreachable.isEmpty { Label("Offline lights will be attempted and listed for targeted retry.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Lumen.warning) }
            List(preview.affected) { device in
                HStack { Circle().fill(device.color).frame(width: 14, height: 14); Text(device.label); Spacer(); if preview.unchanged.contains(where: { $0.id == device.id }) { Text("Unchanged").foregroundStyle(.secondary) }; if device.isStale { Text("Offline").foregroundStyle(Lumen.warning) } }
            }.listStyle(.inset).frame(minHeight: 180)
            if let result = manager.lastSceneResult, result.sceneName == scene.name, !result.failedIDs.isEmpty {
                HStack { Label("\(result.failedIDs.count) light(s) need retry", systemImage: "wifi.slash").foregroundStyle(Lumen.warning); Spacer(); Button("Retry Failed Lights") { manager.retryLastSceneFailures() } }
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Apply Scene") { manager.applyScene(scene, allowTurningOff: allowTurningOff); dismiss() }.buttonStyle(.borderedProminent) }
        }.padding(20).frame(width: 560, height: 500).background(LumenBackground(glow: false))
    }
    private func previewMetric(_ title: String, _ value: Int, _ color: Color) -> some View { VStack { Text("\(value)").font(.title2.bold()).foregroundStyle(color); Text(title).font(.caption) }.frame(maxWidth: .infinity).padding(8).lumenCard(radius: 8) }
}

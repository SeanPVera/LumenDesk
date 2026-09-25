import SwiftUI

/// Generated output only; this is not a device confirmation or light measurement.
struct MusicModeVisualizerView: View {
    @EnvironmentObject private var manager: LightManager
    @ObservedObject var controller: AudioReactiveSessionController
    let scope: LightScope
    let fixtures: [MusicFixtureDescriptor]

    private var frame: MusicLightingFrame? { controller.latestFrame(for: scope) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Lumen.beamDim)
                    LumenEyebrow(text: "Generated lighting", tint: Lumen.beamDim, size: 10)
                }
                Spacer()
                if frame?.sustainedEnergyEvent == true {
                    Label("Sustained energy", systemImage: "bolt.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Lumen.gold)
                }
            }

            DisclosureGroup("Music diagnostics") {
                let snapshot = controller.latestSnapshot
                let age = snapshot.analysisTimestamp.map { max(0, ProcessInfo.processInfo.systemUptime - $0) }
                let analysisDelay = snapshot.analysisCompletedAt.flatMap { completed in snapshot.analysisTimestamp.map { max(0, completed - $0) } }
                let diagnostics = manager.musicRenderDiagnostics
                Text("Source: \(controller.sourceStatus.displayName) · snapshot age: \(age.map { String(format: "%.3f s", $0) } ?? "synthetic / unavailable")")
                Text("Capture to analysis: \(analysisDelay.map { String(format: "%.3f s", $0) } ?? "unavailable") · dropped buffers: \(snapshot.droppedBuffers)")
                Text(String(format: "RMS %.4f · onset %.2f · beat count %d · BPM %.1f · confidence %.2f", snapshot.rawRMS, snapshot.onset, snapshot.beatCount, snapshot.tempo, snapshot.beatConfidence))
                let phase = snapshot.beatInterval > 0 ? ((ProcessInfo.processInfo.systemUptime - snapshot.beatReferenceTime) / snapshot.beatInterval).truncatingRemainder(dividingBy: 1) : 0
                Text("Grid phase now: \(phase, specifier: "%.2f") · last render interval: \(controller.lastRenderInterval, specifier: "%.3f") s (target 0.050 s)")
                if let config = controller.effectiveConfiguration(for: scope) {
                    Text("Preset: \(config.preset.displayName) · beat: \(config.beatSensitivity, specifier: "%.2f") · intensity: \(config.effectIntensity, specifier: "%.2f") · brightness: \(config.masterBrightness, specifier: "%.2f")")
                }
                Text("Generated: \(diagnostics.generatedFrames) · coalesced: \(diagnostics.coalescedStates) · rejected: \(diagnostics.rejectedStates) · transport handoffs: \(diagnostics.commandsHandedOff)")
                let lifx = manager.musicLIFXDispatch
                let govee = manager.musicGoveeDispatch
                Text("Local UDP submissions: LIFX \(lifx.submitted), Govee volatile \(govee.submitted) · failures \(lifx.failed + govee.failed) · expired \(lifx.expired + govee.expired)")
                Text("Maximum transport queue age: \(max(lifx.maximumQueueAge,govee.maximumQueueAge), specifier: "%.3f") s")
                Text("Preview shows generated frames with device zone limits. Handoffs do not establish UDP receipt or visible timing. The 45 ms prediction bias is unmeasured. No raw audio is saved.")
            }
            .font(.caption)
            .foregroundStyle(Lumen.textSecondary)

            if fixtures.isEmpty {
                Text("Choose a scope containing at least one light to preview its choreography.")
                    .font(.caption)
                    .foregroundStyle(Lumen.textSecondary)
            } else {
                ForEach(fixtures) { fixture in
                    fixtureRow(fixture)
                }
            }
        }
        .padding(16)
        .lumenCard(fill: Lumen.surfaceRaised)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Music Mode fixture preview")
    }

    private func fixtureRow(_ fixture: MusicFixtureDescriptor) -> some View {
        let states = manager.musicCapabilityStates(frame?.states.filter { $0.fixtureID == fixture.id } ?? [], fixtureID: fixture.id)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fixture.label).font(LumenType.display(size: 14, weight: .semibold))
                Text(roleCaption(fixture))
                    .font(.caption2)
                    .foregroundStyle(Lumen.textTertiary)
            }
            .frame(minWidth: 90, idealWidth: 138, maxWidth: 180, alignment: .leading)

            Canvas { context, size in
                let count = max(1, fixture.segmentCount)
                let unit = size.width / CGFloat(count)
                for index in 0..<count {
                    let state = fixture.segmentCount > 0
                        ? states.first { $0.segmentID == index } : states.first
                    let rect = CGRect(x: CGFloat(index) * unit, y: 0,
                                      width: max(0, unit - (count > 40 ? 0 : 1)), height: size.height)
                    context.fill(Path(rect), with: .color(previewColor(state)))
                }
            }
            .frame(height: 18)
            .accessibilityLabel("Generated output for \(fixture.label)")
            .accessibilityValue(states.isEmpty ? "No generated frame" : "\(states.count) output values")

        }
    }

    private func previewColor(_ state: MusicLightingState?) -> Color {
        guard let state else { return Lumen.hairlineStrong }
        return Color(
            hue: state.hue,
            saturation: state.saturation,
            brightness: state.brightness
        )
    }

    private func roleCaption(_ fixture: MusicFixtureDescriptor) -> String {
        let role = fixture.resolvedRole
        if fixture.segmentCount > 0 {
            return "\(role.displayName) · \(fixture.segmentCount) RGBIC segments"
        }
        return "\(role.displayName) · \(transportLabel(fixture.transport))"
    }

    private func transportLabel(_ transport: MusicTransportKind) -> String {
        switch transport {
        case .lifxLAN: return "LIFX LAN"
        case .goveeLAN: return "Govee LAN"
        case .goveeRealtimeSegments: return "Govee real-time segments"
        }
    }
}

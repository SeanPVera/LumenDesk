import SwiftUI

/// Generated output only; this is not a device confirmation or light measurement.
struct MusicModeVisualizerView: View {
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
        let states = frame?.states.filter { $0.fixtureID == fixture.id } ?? []
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
            brightness: max(0.04, state.brightness)
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

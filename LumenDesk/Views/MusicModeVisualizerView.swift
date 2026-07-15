import SwiftUI

/// A vendor-neutral preview of the same fixture and segment frame sent to the
/// renderer. It remains useful in Demo Mode and when no hardware is reachable.
struct MusicModeVisualizerView: View {
    @ObservedObject var controller: AudioReactiveSessionController
    let scope: LightScope
    let fixtures: [MusicFixtureDescriptor]

    private var frame: MusicLightingFrame? { controller.latestFrame(for: scope) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Choreography preview", systemImage: "waveform.path.ecg.rectangle")
                    .font(.headline)
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
        .lumenCard(radius: 16, fill: Lumen.surfaceRaised)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Music Mode fixture preview")
    }

    private func fixtureRow(_ fixture: MusicFixtureDescriptor) -> some View {
        let states = frame?.states.filter { $0.fixtureID == fixture.id } ?? []
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fixture.label).font(.subheadline.weight(.semibold))
                Text(fixture.segmentCount > 0 ? "\(fixture.segmentCount) RGBIC segments" : transportLabel(fixture.transport))
                    .font(.caption2)
                    .foregroundStyle(Lumen.textTertiary)
            }
            .frame(width: 138, alignment: .leading)

            if fixture.segmentCount > 0 {
                GeometryReader { proxy in
                    let gap: CGFloat = 2
                    let width = max(3, (proxy.size.width - gap * CGFloat(max(0, fixture.segmentCount - 1))) / CGFloat(max(1, fixture.segmentCount)))
                    HStack(spacing: gap) {
                        ForEach(0..<fixture.segmentCount, id: \.self) { index in
                            let state = states.first { $0.segmentID == index }
                            RoundedRectangle(cornerRadius: 2)
                                .fill(previewColor(state))
                                .frame(width: width)
                                .shadow(color: previewColor(state).opacity(0.45), radius: 3)
                        }
                    }
                }
                .frame(height: 24)
            } else {
                let state = states.first
                Capsule()
                    .fill(previewColor(state))
                    .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
                    .shadow(color: previewColor(state).opacity(0.4), radius: 5)
            }
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

    private func transportLabel(_ transport: MusicTransportKind) -> String {
        switch transport {
        case .lifxLAN: return "LIFX LAN"
        case .goveeLAN: return "Govee LAN"
        case .goveeRealtimeSegments: return "Govee real-time segments"
        }
    }
}

import SwiftUI

/// H60B0 Uplighter controls: which sections are lit, and each section's own
/// colour or white, brightness and (for the ripple head) flow. Every change
/// is written with the lamp's section commands
/// (`GoveeSegmentState.uplighterSectionPackets`), so a control always drives
/// the section it names.
struct UplighterSectionsPanel: View {
    @EnvironmentObject private var manager: LightManager
    @ObservedObject var device: LightDevice
    var width: CGFloat = 900

    @State private var levels: [Double] = [1, 1, 1]
    @State private var flow: Double = 50

    private typealias Section = UplighterSection

    private var profile: GoveeSegmentProfile {
        manager.segmentStudioProfile(for: device) ?? .generic
    }

    private var state: GoveeSegmentState {
        var current = manager.segmentState(for: device)
        if current.segmentCount != 3 { current.resize(to: 3) }
        return current
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PolarSpacing.md) {
            modeRow
            let cards = Group {
                sectionCard(.ripple)
                sectionCard(.side)
                sectionCard(.down)
            }
            if width >= 900 {
                HStack(alignment: .top, spacing: PolarSpacing.sm) { cards }
            } else {
                VStack(alignment: .leading, spacing: PolarSpacing.sm) { cards }
            }
            CapabilityNote(
                symbol: "info.circle",
                text: "Over the network this lamp takes section on/off, colour or white, brightness and the ripple's flow speed, and LumenDesk sends exactly those. Govee's ripple scenes, music effects and DIY scenes for this lamp have no verified LAN command, so they stay in the Govee app. The side ring's 8 segments are painted as one, and the head's tilt is set by hand."
            )
        }
        .onAppear(perform: sync)
        .onChange(of: manager.segmentState(for: device)) { _ in sync() }
    }

    private func sync() {
        let current = state
        levels = current.colors.map(\.brightness)
        flow = Double(current.rippleFlow ?? Int(flow))
    }

    // MARK: Lit sections

    /// The lamp's six modes: any one section, or any two.
    private static let modes: [[Int]] = [[0, 1], [0, 2], [1, 2], [0], [1], [2]]

    private var modeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            PolarSectionLabel("Lit sections · up to \(profile.simultaneousZoneLimit ?? 2)")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.modes, id: \.self) { mode in
                        let chosen = state.poweredSegments == mode
                        Button {
                            var next = state
                            next.setPoweredSegments(mode)
                            apply(next)
                        } label: {
                            Text(mode.map { profile.zoneShortName($0) }.joined(separator: " + "))
                        }
                        .buttonStyle(PolarButtonStyle(kind: chosen ? .selected : .quiet, compact: true))
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
            }
        }
    }

    // MARK: Section cards

    private func sectionCard(_ section: Section) -> some View {
        let index = section.zoneIndex
        let zone = state.colors[index]
        let lit = device.isOn && zone.isOn
        return VStack(alignment: .leading, spacing: PolarSpacing.sm) {
            HStack(spacing: 8) {
                Image(systemName: section.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(lit ? zone.color : Polar.meter)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.zoneName(index))
                        .font(.polarUI(14, weight: .semibold))
                    Text(section.detail)
                        .font(.polarUI(11))
                        .foregroundStyle(Polar.meter)
                }
                Spacer(minLength: 4)
                Label(zone.isOn ? "Lit" : "Dark", systemImage: zone.isOn ? "circle.fill" : "circle")
                    .font(.polarUI(11, weight: .semibold))
                    .foregroundStyle(zone.isOn ? Polar.mint : Polar.meter)
            }

            if section != .down {
                swatchRow(section)
            }
            whiteRow(section, current: zone.kelvin)

            InstrumentSlider(
                title: "Brightness",
                value: Binding(get: { levels.indices.contains(index) ? levels[index] : 1 },
                               set: { if levels.indices.contains(index) { levels[index] = $0 } }),
                range: 0.01...1,
                onCommit: { value in
                    var next = state
                    next.colors[index].brightness = value
                    apply(next)
                }
            )

            if section == .ripple {
                InstrumentSlider(
                    title: "Ripple flow",
                    value: $flow,
                    range: 0...100,
                    step: 1,
                    fill: [Polar.select, Polar.mint],
                    readout: { $0 < 0.5 ? "Still" : "\(Int($0.rounded()))" },
                    onCommit: { value in
                        var next = state
                        next.rippleFlow = Int(value.rounded())
                        apply(next)
                    }
                )
                Text("How fast the lens turns. 0 holds the pattern still.")
                    .font(.polarUI(11))
                    .foregroundStyle(Polar.meter)
            }

            if !zone.isOn {
                Text("Light this section above to change it.")
                    .font(.polarUI(11))
                    .foregroundStyle(Polar.amber)
            }
        }
        .disabled(!zone.isOn)
        .opacity(zone.isOn ? 1 : 0.6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .polarPanel(fill: Polar.raised.opacity(0.55), glow: lit ? zone.color : nil, padding: PolarSpacing.md)
    }

    private func swatchRow(_ section: Section) -> some View {
        HStack(spacing: 6) {
            ForEach(FixtureColorSwatches.values.dropFirst(3), id: \.label) { swatch in
                Button {
                    var next = state
                    let old = next.colors[section.zoneIndex]
                    next.colors[section.zoneIndex] = GoveeSegmentColor(color: swatch.color, brightness: old.brightness, isOn: old.isOn)
                    apply(next)
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(PolarSwatchButtonStyle())
                .help("\(profile.zoneName(section.zoneIndex)) \(swatch.label)")
                .accessibilityLabel("\(profile.zoneName(section.zoneIndex)) \(swatch.label)")
            }
        }
    }

    private func whiteRow(_ section: Section, current: Int?) -> some View {
        HStack(spacing: 6) {
            ForEach(GoveeSegmentEditorView.whitePoints(in: GoveeProtocol.uplighterKelvinRange), id: \.self) { kelvin in
                let chosen = current == kelvin
                Button {
                    var next = state
                    let old = next.colors[section.zoneIndex]
                    next.colors[section.zoneIndex] = .white(kelvin: kelvin, brightness: old.brightness, isOn: old.isOn)
                    apply(next)
                } label: {
                    VStack(spacing: 2) {
                        Circle()
                            .fill(GoveeSegmentColor.white(kelvin: kelvin).color)
                            .overlay(Circle().stroke(chosen ? Polar.select : Color.white.opacity(0.22),
                                                     lineWidth: chosen ? 2 : 1))
                            .frame(width: 20, height: 20)
                        Text(verbatim: "\(kelvin)")
                            .font(.polarMono(9))
                            .foregroundStyle(Polar.meter)
                    }
                }
                .buttonStyle(PolarSwatchButtonStyle())
                .accessibilityLabel("\(profile.zoneName(section.zoneIndex)) white \(kelvin) kelvin")
            }
        }
    }

    private func apply(_ next: GoveeSegmentState) {
        manager.applySegments(device, state: next)
    }
}

typealias UplighterSection = GoveeProtocol.UplighterSection

extension GoveeProtocol.UplighterSection {
    /// The zone index in LumenDesk's layout: section number − 1.
    var zoneIndex: Int { Int(rawValue) - 1 }

    var symbol: String {
        switch self {
        case .ripple: return "water.waves"
        case .side: return "circle.dashed"
        case .down: return "lamp.floor"
        }
    }

    var detail: String {
        switch self {
        case .ripple: return "Projector head · colour or white"
        case .side: return "Middle band · colour or white"
        case .down: return "Reading light · white only, 2700–6500 K"
        }
    }
}

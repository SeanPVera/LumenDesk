import SwiftUI

/// The hero read-out on Govee light pages: the fixture drawn the way it
/// hangs — curtain columns, a COB bar, chained Glide bars, a three-lamp
/// uplighter, pods on a wire or a 75-segment strip — lit with the layout it
/// is holding. It mirrors the painter below it live; painting happens in the
/// painter, which owns the stream to the light.
struct GoveeHeroPanel: View {
    @EnvironmentObject private var manager: LightManager
    @ObservedObject var device: LightDevice
    let model: LightPageModel

    private var profile: GoveeSegmentProfile {
        manager.segmentStudioProfile(for: device) ?? .generic
    }

    private var state: GoveeSegmentState {
        profile.enforcingZoneLimit(manager.segmentState(for: device))
    }

    private var cells: [SegmentStrip.Cell] {
        state.colors.map { SegmentStrip.Cell(color: $0.color, isOn: device.isOn && $0.isOn) }
    }

    private var glow: Color? {
        guard device.isOn, let first = state.poweredSegments.first,
              state.colors.indices.contains(first) else { return nil }
        return state.colors[first].color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PolarSpacing.md) {
            HStack {
                PolarSectionLabel(heroTitle)
                Spacer()
                if manager.activeSegmentState(for: device.id) == nil {
                    Text("Solid colour · paint below to set a layout")
                        .font(.polarUI(12))
                        .foregroundStyle(Polar.meter)
                }
            }
            hero
            notes
        }
        .polarPanel(fill: Polar.deck, glow: glow, padding: PolarSpacing.lg)
    }

    private var heroTitle: String {
        if case .fallback = model {
            return "\(profile.layout.displayName) · \(state.segmentCount) \(profile.editorUnitName)s"
        }
        return model.heroTitle
    }

    @ViewBuilder
    private var hero: some View {
        switch model {
        case .goveeCurtain, .goveeCurtainString:
            SegmentStrip(cells: cells, unitName: "column", axis: .columns, cellHeight: 150)
        case .goveeUplighter:
            uplighter
        case .goveeStringPods:
            pods
        case .goveeGlideBars:
            GlideChainPanel(device: device, state: state)
        case .goveeStripS:
            SegmentStrip(cells: cells, unitName: "segment", rowLength: 15, labelEvery: 5, cellHeight: 20)
        case .goveeCOBStrip:
            cobBar
        default:
            SegmentStrip(cells: cells, unitName: profile.editorUnitName,
                         rowLength: state.segmentCount > 20 ? 15 : nil,
                         labelEvery: state.segmentCount > 20 ? 5 : 1, cellHeight: 26)
        }
    }

    /// A continuous chip-on-board bar: the zones blend into each other, so
    /// the hero draws one gradient bar with the zone numbers under it.
    private var cobBar: some View {
        VStack(spacing: 6) {
            Capsule()
                .fill(LinearGradient(colors: cells.map { $0.isOn ? $0.color : Polar.raised },
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 34)
                .shadow(color: (glow ?? .clear).opacity(0.6), radius: 14)
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
            HStack(spacing: 0) {
                ForEach(cells.indices, id: \.self) { index in
                    Text("\(index + 1)")
                        .font(.polarMono(12))
                        .foregroundStyle(Polar.meter)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("COB strip, \(cells.count) blended zones")
    }

    /// H608B: bulbs hanging from a wire.
    private var pods: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Polar.wall).frame(height: 2).padding(.horizontal, 8)
            HStack(alignment: .top, spacing: 0) {
                ForEach(cells.indices, id: \.self) { index in
                    VStack(spacing: 4) {
                        Rectangle().fill(Polar.wall).frame(width: 1, height: index.isMultiple(of: 2) ? 18 : 30)
                        GlowingOrb(color: cells[index].color, level: device.brightness,
                                   isOn: cells[index].isOn, silhouette: .pods, size: 22)
                        Text("\(index + 1)")
                            .font(.polarMono(12))
                            .foregroundStyle(Polar.meter)
                        if let kelvin = podKelvin(index) {
                            Text(verbatim: "\(kelvin)K")
                                .font(.polarMono(9))
                                .foregroundStyle(Polar.amber)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Pod \(index + 1)\(podKelvin(index).map { ", white \($0) kelvin" } ?? "")")
                    .accessibilityValue(cells[index].isOn ? "On" : "Off")
                }
            }
        }
        .frame(minHeight: 120)
    }

    private func podKelvin(_ index: Int) -> Int? {
        state.colors.indices.contains(index) ? state.colors[index].kelvin : nil
    }

    /// H60B0: three stacked lamps on a pole, named by the profile.
    private var uplighter: some View {
        HStack(alignment: .center, spacing: PolarSpacing.xxl) {
            VStack(spacing: 10) {
                ForEach(cells.indices, id: \.self) { index in
                    GlowingOrb(color: cells[index].color, level: device.brightness,
                               isOn: cells[index].isOn, silhouette: .lamp, size: 54)
                }
                Rectangle().fill(Polar.wall).frame(width: 3, height: 26)
                Capsule().fill(Polar.wall).frame(width: 46, height: 6)
            }
            .frame(width: 120)
            VStack(alignment: .leading, spacing: PolarSpacing.sm) {
                ForEach(cells.indices, id: \.self) { index in
                    HStack(spacing: PolarSpacing.sm) {
                        Text("\(index + 1)")
                            .font(.polarMono(13, weight: .bold))
                            .foregroundStyle(Polar.meter)
                        Text(profile.zoneName(index))
                            .font(.polarUI(14, weight: .semibold))
                        Spacer()
                        Label(cells[index].isOn ? "On" : "Off",
                              systemImage: cells[index].isOn ? "circle.fill" : "circle")
                            .font(.polarUI(12, weight: .semibold))
                            .foregroundStyle(cells[index].isOn ? Polar.mint : Polar.meter)
                    }
                    .padding(.horizontal, PolarSpacing.sm)
                    .padding(.vertical, PolarSpacing.xs)
                    .background(Polar.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if let limit = profile.simultaneousZoneLimit {
                    Text("This lamp lights \(limit) of its \(state.segmentCount) zones at a time.")
                        .font(.polarUI(12))
                        .foregroundStyle(Polar.meter)
                }
            }
        }
    }

    @ViewBuilder
    private var notes: some View {
        switch model {
        case .goveeCurtain, .goveeCurtainString:
            CapabilityNote(
                symbol: "rectangle.split.3x1",
                text: "Paints by column. Govee's LAN interface addresses the curtain's 20 columns; single beads are only reachable over Bluetooth, which LumenDesk doesn't use."
            )
            if model == .goveeCurtainString {
                Text("Model H70BC matched by elimination. If this light hangs as a string rather than a curtain, rename it in the room.")
                    .font(.polarUI(12))
                    .foregroundStyle(Polar.meter)
            }
        case .goveeStringPods:
            if profile.segmentWhiteRange != nil {
                CapabilityNote(
                    symbol: "thermometer.sun",
                    text: "Each pod can hold its own white point (2700–6500 K). The pods are RGB only, so whites are mixed from colour. Set them in the painter below."
                )
            }
        default:
            EmptyView()
        }
    }
}

/// A one-line statement of what a page's controls really drive.
struct CapabilityNote: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Polar.select)
        }
        .font(.polarUI(12))
        .foregroundStyle(Polar.meter)
        .accessibilityElement(children: .combine)
    }
}

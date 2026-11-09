import SwiftUI

// MARK: - Light page
//
// Every fixture opens its own page from the Room Stage. The page shares one
// header (breadcrumb, previous / next light in the room, name, model line,
// status, power, brightness, Identify) and then shows the controls that fit
// that exact model: a hero read-out of the fixture and its painter.
//
// Painting reuses the studios that already speak each protocol (Govee
// segment stream, LIFX matrix, Nanoleaf Shapes), so a page never invents a
// command. Controls the protocol cannot drive yet are gated by
// `LightPageFeatureFlags` and render as labelled previews.

struct LightPageView: View {
    @EnvironmentObject private var manager: LightManager
    @ObservedObject var device: LightDevice
    /// Opens another light's page (previous / next in the same room).
    var navigate: (String) -> Void = { _ in }
    /// Returns to the Room Stage.
    var close: () -> Void = {}

    private var model: LightPageModel { LightPageModel.resolve(device) }
    private var room: Room? { manager.room(forLightID: device.id) }

    private var roomNeighbours: (previous: LightDevice?, next: LightDevice?) {
        guard let room else { return (nil, nil) }
        let lights = manager.devices(in: room)
        guard let index = lights.firstIndex(where: { $0.id == device.id }), lights.count > 1 else {
            return (nil, nil)
        }
        let previous = lights[(index - 1 + lights.count) % lights.count]
        let next = lights[(index + 1) % lights.count]
        return (previous, next)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: PolarSpacing.md) {
                    navigationBar
                    LightPageHeader(device: device, model: model)
                    content(width: geometry.size.width - PolarSpacing.page * 2)
                }
                .padding(PolarSpacing.page)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Polar.stage)
        .foregroundStyle(Polar.chalk)
        .navigationTitle(device.label)
        .onExitCommandCompat(perform: close)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(device.label) light page")
    }

    // MARK: Navigation

    private var navigationBar: some View {
        HStack(spacing: PolarSpacing.xs) {
            Button(action: close) {
                Label(room?.name ?? "Room", systemImage: "chevron.left")
                    .font(.polarUI(13, weight: .semibold))
                    .foregroundStyle(Polar.accent)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back to the Room Stage (⌘[ or Esc)")
            Text("/").foregroundStyle(Polar.meter)
            Text(device.label)
                .font(.polarUI(13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: PolarSpacing.sm)
            if let previous = roomNeighbours.previous {
                Button { navigate(previous.id) } label: {
                    Text("Prev · \(previous.label)").lineLimit(1)
                }
                .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            }
            if let next = roomNeighbours.next, next.id != roomNeighbours.previous?.id {
                Button { navigate(next.id) } label: {
                    Text("Next · \(next.label)").lineLimit(1)
                }
                .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            }
        }
    }

    // MARK: Model-specific content

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        switch model {
        case .lifxLuna, .fallback(.lunaMatrix):
            painterPanel {
                LIFXLunaEditorView(device: device, embedded: true, embeddedWidth: width)
            }
        case .lifxColorBulb(let variant):
            ColorBulbControls(device: device, variant: variant)
        case .fallback(.basic):
            ColorBulbControls(device: device, variant: nil)
        case .nanoleafHexagons, .fallback(.nanoleafStudio):
            painterPanel {
                NanoleafShapesStudio(device: device, shapes: manager.shapes,
                                     presentation: .inline, wide: width >= 900)
            }
        case .goveeUplighter, .goveeCurtain, .goveeCurtainString, .goveeCOBStrip, .goveeGlideBars,
             .goveeStringPods, .goveeStripS, .fallback(.goveeSegments):
            GoveeHeroPanel(device: device, model: model)
            painterPanel {
                GoveeSegmentEditorView(device: device, embedded: true, embeddedWidth: width)
            }
        }
    }

    private func painterPanel<Inner: View>(@ViewBuilder _ inner: () -> Inner) -> some View {
        VStack(alignment: .leading, spacing: PolarSpacing.sm) {
            PolarSectionLabel(model.painterTitle)
                .padding(.horizontal, PolarSpacing.md)
                .padding(.top, PolarSpacing.md)
            inner()
        }
        .polarPanel(padding: 0)
    }
}

// MARK: - Header

/// Name, model line, status, power, brightness and Identify. Identical on
/// every light page so the same muscle memory works on every fixture.
struct LightPageHeader: View {
    @EnvironmentObject private var manager: LightManager
    @ObservedObject var device: LightDevice
    let model: LightPageModel

    private var status: RoomCanvasStatus { RoomCanvasStatus.resolve([device], manager: manager) }

    private var modelLine: String {
        if !model.modelLine.isEmpty { return model.modelLine }
        return [device.brand.displayName, device.sku].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PolarSpacing.md) {
            HStack(alignment: .top, spacing: PolarSpacing.md) {
                GlowingOrb(color: device.color, level: device.brightness, isOn: device.isOn,
                           silhouette: model.silhouette, size: 40, stale: device.isStale)
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.label)
                        .font(.polarDisplay(28, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(modelLine)
                        .font(.polarUI(13))
                        .foregroundStyle(Polar.meter)
                        .lineLimit(1)
                }
                Spacer(minLength: PolarSpacing.sm)
                PolarStatusPill(title: status.title, symbol: status.symbol, color: status.color)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: PolarSpacing.sm) { powerButtons; brightness.frame(minWidth: 220); identify }
                VStack(alignment: .leading, spacing: PolarSpacing.sm) {
                    HStack(spacing: PolarSpacing.sm) { powerButtons; identify }
                    brightness
                }
            }

            if device.isStale || manager.commandState(for: device.id).phase == .failed {
                HStack(spacing: PolarSpacing.sm) {
                    Label("This light isn't answering. Commands wait until it is Confirmed again.",
                          systemImage: RoomCanvasStatus.needsAttention.symbol)
                        .font(.polarUI(12, weight: .semibold))
                        .foregroundStyle(Polar.attention)
                    Spacer()
                    Button("Retry") { manager.retry(device) }
                        .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
                }
            }
        }
        .polarPanel(padding: PolarSpacing.lg)
    }

    private var powerButtons: some View {
        HStack(spacing: PolarSpacing.xs) {
            Button("On") { manager.setPower(device, on: true) }
                .buttonStyle(PolarButtonStyle(kind: device.isOn ? .prominent : .quiet))
                .frame(minWidth: 72)
            Button("Off") { manager.setPower(device, on: false) }
                .buttonStyle(PolarButtonStyle(kind: device.isOn ? .quiet : .selected))
                .frame(minWidth: 72)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Power")
    }

    private var brightness: some View {
        InstrumentSlider(
            title: "Brightness",
            value: Binding(
                get: { device.brightness },
                set: { manager.previewBrightness(device, value: $0) }
            ),
            range: 0.01...1,
            onCommit: { manager.commitBrightness(device, value: $0) }
        )
    }

    private var identify: some View {
        Button { manager.identify(device) } label: {
            Label("Identify", systemImage: "lightbulb.max")
        }
        .buttonStyle(PolarButtonStyle(kind: .quiet))
        .help("Flash this light so you can find it (Lights ▸ Identify Selected, ⌘I)")
    }
}

// MARK: - Colour bulb page

/// LIFX Mini, A19 and Color 800: one emitter, so the page is a big orb, a
/// white-point dial, colour swatches and a colour well. All wired to the
/// existing LIFX commands.
struct ColorBulbControls: View {
    @EnvironmentObject private var manager: LightManager
    @ObservedObject var device: LightDevice
    let variant: LIFXBulbVariant?
    @State private var kelvin: Double = 3500

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: PolarSpacing.md) {
                hero.frame(minWidth: 320)
                controls.frame(minWidth: 360)
            }
            VStack(spacing: PolarSpacing.md) {
                hero
                controls
            }
        }
        .onAppear { kelvin = Double(device.kelvin) }
        .onReceive(device.$kelvin) { kelvin = Double($0) }
    }

    private var hero: some View {
        VStack(spacing: PolarSpacing.lg) {
            PolarSectionLabel(LightPageModel.lifxColorBulb(.colorA19).heroTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
            GlowingOrb(color: device.color, level: device.brightness, isOn: device.isOn,
                       silhouette: .bulb, size: 96, stale: device.isStale)
                .frame(height: 200)
            if let variant {
                variantChips(current: variant)
            }
        }
        .polarPanel(padding: PolarSpacing.lg)
    }

    private func variantChips(current: LIFXBulbVariant) -> some View {
        VStack(alignment: .leading, spacing: PolarSpacing.xs) {
            Text("Template for Mini · A19 · Color 800")
                .font(.polarUI(12))
                .foregroundStyle(Polar.meter)
            HStack(spacing: 6) {
                ForEach(LIFXBulbVariant.allCases, id: \.rawValue) { item in
                    Text(item.chipLabel)
                        .font(.polarMono(12, weight: item == current ? .bold : .medium))
                        .foregroundStyle(item == current ? Polar.select : Polar.meter)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(item == current ? Polar.accent.opacity(0.2) : Polar.raised, in: Capsule())
                        .accessibilityLabel("\(item.displayName)\(item == current ? ", this light" : "")")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: PolarSpacing.lg) {
            PolarSectionLabel(LightPageModel.lifxColorBulb(.colorA19).painterTitle)
            HStack(alignment: .center, spacing: PolarSpacing.xl) {
                InstrumentDial(
                    title: "White point",
                    value: $kelvin,
                    range: device.kelvinRange,
                    onCommit: { manager.setKelvin(device, kelvin: Int($0)) }
                )
                VStack(alignment: .leading, spacing: PolarSpacing.sm) {
                    Text("Colour")
                        .font(.polarUI(12, weight: .semibold))
                        .foregroundStyle(Polar.meter)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 8), count: 4), spacing: 8) {
                        ForEach(FixtureColorSwatches.values, id: \.label) { swatch in
                            Button { manager.setColor(device, color: swatch.color) } label: {
                                Circle()
                                    .fill(swatch.color)
                                    .frame(width: 30, height: 30)
                                    .shadow(color: swatch.color.opacity(0.6), radius: 6)
                                    .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .help(swatch.label)
                            .accessibilityLabel(swatch.label)
                        }
                    }
                    HStack(spacing: 8) {
                        ColorPicker("Custom colour", selection: Binding(
                            get: { device.color },
                            set: { manager.setColor(device, color: $0) }
                        ), supportsOpacity: false)
                        .polarColorWell(device.color, width: 30, height: 30)
                        .accessibilityLabel("Custom colour")
                        Text("Custom").font(.polarUI(12, weight: .semibold)).foregroundStyle(Polar.meter)
                    }
                }
            }
            Text("\(Int(device.kelvinRange.lowerBound))–\(Int(device.kelvinRange.upperBound)) K. Drag the dial or use the arrow keys.")
                .font(.polarUI(12))
                .foregroundStyle(Polar.meter)
        }
        .polarPanel(padding: PolarSpacing.lg)
    }
}

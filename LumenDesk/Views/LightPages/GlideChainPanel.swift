import SwiftUI

/// H6062 hero: the Glide kit drawn in the shape it's mounted, lit with the
/// controller's 28 segments, plus the controls to declare that shape and
/// paint one piece at a time. Painting a piece writes the real segments
/// that cover it (`GlideChain.segmentRanges`) through the same durable
/// segment apply as the painter below.
struct GlideChainPanel: View {
    @EnvironmentObject private var manager: LightManager
    @ObservedObject var device: LightDevice
    let state: GoveeSegmentState
    /// Render tests pass a layout; the app reads the stored one.
    var initialChain: GlideChain? = nil

    @State private var chain: GlideChain? = nil
    @State private var selectedPiece: Int? = nil
    @State private var loaded = false

    private var ranges: [Range<Int>] {
        chain?.segmentRanges(segmentCount: state.segmentCount) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PolarSpacing.sm) {
            if let chain {
                GlideChainDrawing(chain: chain, colors: litColors, ranges: ranges, selected: selectedPiece)
                    .frame(height: 250)
                pieceChips(chain)
                editRow(chain)
                if let selectedPiece, chain.pieces.indices.contains(selectedPiece) {
                    paintRow(chain, piece: selectedPiece)
                }
                CapabilityNote(
                    symbol: "point.topleft.down.curvedto.point.bottomright.up",
                    text: "Govee doesn't report how the bars are arranged, so the layout is set here. Segments are spread along the chain by LED count (9 per bar, 3 per corner), and painting a piece writes those segments."
                )
            } else {
                SegmentStrip(cells: state.colors.map { SegmentStrip.Cell(color: $0.color, isOn: device.isOn && $0.isOn) },
                             unitName: "segment", rowLength: 14, labelEvery: 1, cellHeight: 18)
                setupPrompt
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            chain = initialChain ?? GlideChainStore.load(deviceID: device.id)
        }
    }

    private var litColors: [Color] {
        state.colors.map { device.isOn && $0.isOn ? $0.color : Polar.raised }
    }

    // MARK: Setup

    private var setupPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How is your Glide arranged?")
                .font(.polarUI(13, weight: .semibold))
            Text("Govee doesn't report the shape over the network. Pick your kit, then adjust the pieces to match the wall.")
                .font(.polarUI(12))
                .foregroundStyle(Polar.meter)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("6 + 1 kit") { setChain(.kitSixPlusOne) }
                Button("8 + 4 kit") { setChain(.kitEightPlusFour) }
                Button("Start with one bar") { setChain(GlideChain(pieces: [.bar])) }
            }
            .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
        }
    }

    // MARK: Pieces

    private func pieceChips(_ chain: GlideChain) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chain.pieces.indices, id: \.self) { index in
                    let chosen = selectedPiece == index
                    Button {
                        selectedPiece = chosen ? nil : index
                    } label: {
                        VStack(spacing: 1) {
                            Text(chain.label(index))
                            Text(rangeText(index))
                                .font(.polarMono(9))
                                .foregroundStyle(Polar.meter)
                        }
                    }
                    .buttonStyle(PolarButtonStyle(kind: chosen ? .selected : .quiet, compact: true))
                    .accessibilityLabel("\(chain.label(index)), \(rangeText(index))")
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
        }
    }

    private func rangeText(_ index: Int) -> String {
        guard ranges.indices.contains(index), !ranges[index].isEmpty else { return "no segment" }
        let r = ranges[index]
        return r.count == 1 ? "seg \(r.lowerBound + 1)" : "seg \(r.lowerBound + 1)–\(r.upperBound)"
    }

    private func editRow(_ chain: GlideChain) -> some View {
        HStack(spacing: 6) {
            Button { append(.bar) } label: { Label("Bar", systemImage: "plus") }
            Button { append(.cornerLeft) } label: { Label("Corner", systemImage: "arrow.turn.up.left") }
            Button { append(.cornerRight) } label: { Label("Corner", systemImage: "arrow.turn.up.right") }
            Button {
                var next = chain
                if !next.pieces.isEmpty { next.pieces.removeLast() }
                setChain(next.pieces.isEmpty ? nil : next)
            } label: { Label("Remove last", systemImage: "minus") }
            Spacer(minLength: 0)
            Menu("Kit") {
                Button("6 + 1 (L shape)") { setChain(.kitSixPlusOne) }
                Button("8 + 4 (frame)") { setChain(.kitEightPlusFour) }
                Divider()
                Button("Forget layout", role: .destructive) { setChain(nil) }
            }
            .fixedSize()
        }
        .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
    }

    private func paintRow(_ chain: GlideChain, piece: Int) -> some View {
        HStack(spacing: 6) {
            Text("Paint \(chain.label(piece))")
                .font(.polarUI(12, weight: .semibold))
                .foregroundStyle(Polar.meter)
            ForEach(FixtureColorSwatches.values.prefix(10), id: \.label) { swatch in
                Button {
                    paint(piece: piece, color: swatch.color)
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(PolarSwatchButtonStyle())
                .help("Paint \(chain.label(piece)) \(swatch.label)")
                .accessibilityLabel("Paint \(chain.label(piece)) \(swatch.label)")
            }
        }
        .disabled(!ranges.indices.contains(piece) || ranges[piece].isEmpty)
    }

    // MARK: Actions

    private func append(_ piece: GlidePiece) {
        var next = chain ?? GlideChain(pieces: [])
        next.pieces.append(piece)
        setChain(next)
    }

    private func setChain(_ next: GlideChain?) {
        chain = next
        if let selectedPiece, !(next?.pieces.indices.contains(selectedPiece) ?? false) {
            self.selectedPiece = nil
        }
        GlideChainStore.save(next, deviceID: device.id)
    }

    private func paint(piece: Int, color: Color) {
        guard ranges.indices.contains(piece) else { return }
        let next = GlideChainPainter.painting(manager.segmentState(for: device), range: ranges[piece], color: color)
        manager.applySegments(device, state: next)
    }
}

/// Pure paint rule for a piece, unit-tested.
enum GlideChainPainter {
    /// The layout with `range` set to `color`, keeping each segment's own
    /// brightness and power.
    static func painting(_ state: GoveeSegmentState, range: Range<Int>, color: Color) -> GoveeSegmentState {
        var next = state
        for index in range where next.colors.indices.contains(index) {
            let existing = next.colors[index]
            next.colors[index] = GoveeSegmentColor(color: color, brightness: existing.brightness, isOn: existing.isOn)
        }
        return next
    }
}

/// The chain drawn to scale: each piece a thick rounded stroke split into
/// the colours of the segments that cover it.
struct GlideChainDrawing: View {
    let chain: GlideChain
    let colors: [Color]
    let ranges: [Range<Int>]
    var selected: Int? = nil

    var body: some View {
        Canvas { context, size in
            let pieces = chain.geometry()
            guard !pieces.isEmpty else { return }
            let xs = pieces.flatMap { [$0.start.x, $0.end.x] }
            let ys = pieces.flatMap { [$0.start.y, $0.end.y] }
            let minX = xs.min() ?? 0, maxX = xs.max() ?? 1
            let minY = ys.min() ?? 0, maxY = ys.max() ?? 1
            let inset: CGFloat = 22
            let spanX = max(maxX - minX, 0.001), spanY = max(maxY - minY, 0.001)
            let scale = min((size.width - inset * 2) / spanX, (size.height - inset * 2) / spanY, 160)
            let offsetX = (size.width - spanX * scale) / 2 - minX * scale
            let offsetY = (size.height - spanY * scale) / 2 - minY * scale
            func map(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + offsetX, y: p.y * scale + offsetY) }
            let width = max(8, min(14, scale * 0.09))

            var heading = CGVector(dx: 1, dy: 0)
            for (index, piece) in pieces.enumerated() {
                let a = map(piece.start), b = map(piece.end)
                let range = ranges.indices.contains(index) ? ranges[index] : 0..<0
                let pieceColors = range.compactMap { colors.indices.contains($0) ? colors[$0] : nil }
                // A small gap at each joint so every piece reads on its own.
                let length = hypot(b.x - a.x, b.y - a.y)
                guard length > 0 else { continue }
                let gap = min(width / 2 + 3, length * 0.2)
                let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
                var legs: [(CGPoint, CGPoint)]
                if chain.pieces[index].isCorner {
                    // Corners bend 90°: first along the old heading, then the new.
                    let leg = length / 2.squareRoot()
                    let bend = CGPoint(x: a.x + heading.dx * leg, y: a.y + heading.dy * leg)
                    let start = CGPoint(x: a.x + heading.dx * gap, y: a.y + heading.dy * gap)
                    let nx = (b.x - bend.x) / max(leg, 0.001), ny = (b.y - bend.y) / max(leg, 0.001)
                    let end = CGPoint(x: b.x - nx * gap, y: b.y - ny * gap)
                    legs = [(start, bend), (bend, end)]
                    heading = CGVector(dx: nx, dy: ny)
                } else {
                    let start = CGPoint(x: a.x + ux * gap, y: a.y + uy * gap)
                    let end = CGPoint(x: b.x - ux * gap, y: b.y - uy * gap)
                    let parts = max(1, pieceColors.count)
                    legs = (0..<parts).map { part in
                        let t0 = CGFloat(part) / CGFloat(parts), t1 = CGFloat(part + 1) / CGFloat(parts)
                        return (CGPoint(x: start.x + (end.x - start.x) * t0, y: start.y + (end.y - start.y) * t0),
                                CGPoint(x: start.x + (end.x - start.x) * t1, y: start.y + (end.y - start.y) * t1))
                    }
                    heading = CGVector(dx: ux, dy: uy)
                }
                if selected == index {
                    var outline = Path()
                    outline.move(to: legs[0].0)
                    for leg in legs { outline.addLine(to: leg.1) }
                    context.stroke(outline, with: .color(Polar.select),
                                   style: StrokeStyle(lineWidth: width + 7, lineCap: .round, lineJoin: .round))
                }
                for (part, leg) in legs.enumerated() {
                    var path = Path()
                    path.move(to: leg.0)
                    path.addLine(to: leg.1)
                    let color: Color
                    if pieceColors.isEmpty {
                        color = Polar.raised
                    } else {
                        color = pieceColors[min(pieceColors.count - 1, part * pieceColors.count / legs.count)]
                    }
                    var glow = context
                    glow.addFilter(.blur(radius: 7))
                    glow.stroke(path, with: .color(color.opacity(0.55)), style: StrokeStyle(lineWidth: width + 6, lineCap: .round))
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                }
            }
            // The controller sits at the start of the chain.
            let start = map(pieces[0].start)
            context.fill(Path(ellipseIn: CGRect(x: start.x - 5, y: start.y - 5, width: 10, height: 10)),
                         with: .color(Polar.chalk))
        }
        .background(Polar.stage.opacity(0.6), in: RoundedRectangle(cornerRadius: Polar.radiusCard, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Glide chain: \(chain.barCount) bars and \(chain.pieces.count - chain.barCount) corners")
    }
}

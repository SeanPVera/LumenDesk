import SwiftUI
#if os(macOS)
import AppKit
#endif

extension NanoleafRGB {
    /// The panel colour as SwiftUI draws it: the exact bytes a Shapes panel
    /// is sent, nothing re-derived.
    var swiftUIColor: Color {
        Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    /// Relative luminance, for choosing legible text over a panel's fill.
    var luminance: Double {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

extension NanoleafPanelColor {
    /// A short spoken name, so VoiceOver can tell panels apart by more than
    /// a number: "orange, 80 percent", "white", "off".
    var spokenDescription: String {
        guard !isBlack else { return "off" }
        let level = "\(Int((intensity * 100).rounded())) percent"
        guard saturation >= 0.12 else { return "white, \(level)" }
        let degrees = hue * 360
        let names: [(Double, String)] = [(15, "red"), (45, "orange"), (70, "yellow"), (160, "green"),
                                         (200, "cyan"), (255, "blue"), (290, "purple"), (335, "pink"), (361, "red")]
        let name = names.first { degrees < $0.0 }?.1 ?? "red"
        return "\(name), \(level)"
    }
}

/// A Shapes wall drawn as it hangs, after the global orientation. Drawing,
/// pointer hit testing and drag-to-select all go through one
/// `NanoleafCanvasMapping`, so a panel is always selected where it is drawn.
/// Each light panel is also its own accessibility element.
struct NanoleafWallCanvas: View {
    let layout: NanoleafLayout
    let rotation: Double
    let display: NanoleafPanelDisplay
    var selection: Set<Int> = []
    var cursor: Int?
    var interactive = true
    /// Shows the "up on the wall" reference and the controller's position.
    var showsReference = true
    /// `.tight` fills the canvas; `.rotationStable` keeps one scale while an
    /// orientation is being tried, so the drawing turns without resizing.
    var fit: NanoleafCanvasMapping.Fit = .tight
    var onTap: (Int) -> Void = { _ in }
    var onMarquee: (Set<Int>) -> Void = { _ in }
    var onIdentify: ((Int) -> Void)?

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let mapping = NanoleafCanvasMapping(layout: layout, rotationDegrees: rotation,
                                                width: geometry.size.width, height: geometry.size.height,
                                                inset: showsReference ? 30 : 6, fit: fit)
            let numbers = layout.panelNumbers(rotationDegrees: rotation)
            ZStack {
                Canvas { context, _ in draw(in: &context, mapping: mapping, numbers: numbers) }
                    .accessibilityHidden(true)
                if interactive {
                    accessibilityPanels(mapping: mapping, numbers: numbers)
                }
                if let dragStart, let dragCurrent {
                    Rectangle()
                        .stroke(Lumen.lit, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .background(Rectangle().fill(Lumen.lit.opacity(0.08)))
                        .frame(width: abs(dragCurrent.x - dragStart.x), height: abs(dragCurrent.y - dragStart.y))
                        .position(x: (dragStart.x + dragCurrent.x) / 2, y: (dragStart.y + dragCurrent.y) / 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if showsReference {
                    Label("Up on the wall", systemImage: "arrow.up")
                        .font(.caption)
                        .foregroundStyle(Lumen.meter)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .gesture(selectionGesture(mapping: mapping), including: interactive ? .all : .none)
        }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, mapping: NanoleafCanvasMapping, numbers: [Int: Int]) {
        for entry in layout.panels where !entry.isPaintable {
            let center = mapping.screenCenter(of: entry)
            let radius = NanoleafGeometry.markerRadius(for: entry.kind) * mapping.scale
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(Lumen.faint), lineWidth: 1)
            if entry.kind == .controller, radius >= 7 {
                context.draw(Text(Image(systemName: "powerplug")).font(.system(size: min(14, radius))).foregroundColor(Lumen.faint),
                             at: CGPoint(x: center.x, y: center.y))
            }
        }
        for panel in layout.paintablePanels {
            guard let outline = mapping.screenOutline(of: panel), let first = outline.first else { continue }
            var path = Path()
            path.move(to: CGPoint(x: first.x, y: first.y))
            for point in outline.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
            path.closeSubpath()
            let color = display.colors[panel.panelID]
            if let color {
                context.fill(path, with: .color(color.swiftUIColor))
            } else {
                context.fill(path, with: .color(Lumen.floor))
                hatch(path, in: &context)
            }
            let selected = selection.contains(panel.panelID)
            if color == NanoleafRGB.black {
                // Off reads as a dashed boundary, not only as a dark fill.
                context.stroke(path, with: .color(Lumen.faint), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            } else {
                context.stroke(path, with: .color(Lumen.stage.opacity(0.9)), lineWidth: 1.5)
            }
            if selected {
                context.stroke(path, with: .color(Lumen.lit), lineWidth: 3)
            }
            if cursor == panel.panelID {
                // The keyboard cursor is a dashed ring inside the panel, so it
                // stays visible on a selected panel's outline.
                let center = mapping.screenCenter(of: panel)
                var ring = Path()
                for (index, point) in outline.enumerated() {
                    let inset = CGPoint(x: center.x + (point.x - center.x) * 0.72, y: center.y + (point.y - center.y) * 0.72)
                    if index == 0 { ring.move(to: inset) } else { ring.addLine(to: inset) }
                }
                ring.closeSubpath()
                context.stroke(ring, with: .color(Lumen.lit), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
            let inradius = (NanoleafGeometry.inradius(of: panel.kind) ?? 0) * mapping.scale
            guard inradius >= 9, let number = numbers[panel.panelID] else { continue }
            let center = mapping.screenCenter(of: panel)
            let point = CGPoint(x: center.x, y: center.y)
            let size = min(13, max(9, inradius * 0.55))
            if selected {
                // Selection is also a filled badge, not only an outline colour.
                let badge = CGRect(x: point.x - size * 0.95, y: point.y - size * 0.95, width: size * 1.9, height: size * 1.9)
                context.fill(Path(ellipseIn: badge), with: .color(Lumen.lit))
                context.draw(Text("\(number)").font(.system(size: size, weight: .bold)).foregroundColor(Lumen.stage), at: point)
            } else {
                let ink: Color = color.map { $0.luminance > 0.35 ? Lumen.stage : Lumen.chalk } ?? Lumen.meter
                context.draw(Text(color == nil ? "?" : "\(number)").font(.system(size: size, weight: .semibold)).foregroundColor(ink),
                             at: point)
            }
        }
    }

    /// Diagonal lines for a panel whose colour cannot be known.
    private func hatch(_ path: Path, in context: inout GraphicsContext) {
        let bounds = path.boundingRect
        var lines = Path()
        var x = bounds.minX - bounds.height
        while x < bounds.maxX {
            lines.move(to: CGPoint(x: x, y: bounds.maxY))
            lines.addLine(to: CGPoint(x: x + bounds.height, y: bounds.minY))
            x += 7
        }
        context.drawLayer { layer in
            layer.clip(to: path)
            layer.stroke(lines, with: .color(Lumen.faint.opacity(0.55)), lineWidth: 1)
        }
    }

    // MARK: Pointer

    private func selectionGesture(mapping: NanoleafCanvasMapping) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                dragStart = value.startLocation
                let moved = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                dragCurrent = moved > 6 ? value.location : nil
            }
            .onEnded { value in
                defer { dragStart = nil; dragCurrent = nil }
                let moved = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                if moved <= 6 {
                    let point = NanoleafPoint(value.startLocation.x, value.startLocation.y)
                    if let id = mapping.panelID(atScreen: point, in: layout) { onTap(id) }
                } else {
                    let ids = mapping.panelIDs(inScreenRectFrom: NanoleafPoint(value.startLocation.x, value.startLocation.y),
                                               to: NanoleafPoint(value.location.x, value.location.y), in: layout)
                    if !ids.isEmpty { onMarquee(Set(ids)) }
                }
            }
    }

    // MARK: Accessibility

    private func accessibilityPanels(mapping: NanoleafCanvasMapping, numbers: [Int: Int]) -> some View {
        ForEach(layout.paintablePanels) { panel in
            let center = mapping.screenCenter(of: panel)
            let side = max(16, (NanoleafGeometry.inradius(of: panel.kind) ?? 10) * mapping.scale * 1.4)
            let selected = selection.contains(panel.panelID)
            Color.clear
                .frame(width: side, height: side)
                .position(x: center.x, y: center.y)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel("Panel \(numbers[panel.panelID] ?? 0), \(panel.kind.displayName)")
                .accessibilityValue(accessibilityValue(for: panel.panelID, selected: selected))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint("Toggles this panel in the selection")
                .accessibilityAction { onTap(panel.panelID) }
                .accessibilityAction(named: "Identify on the wall") { onIdentify?(panel.panelID) }
                .accessibilitySortPriority(Double(-(numbers[panel.panelID] ?? 0)))
        }
    }

    private func accessibilityValue(for panelID: Int, selected: Bool) -> String {
        let colour = display.colors[panelID].map { NanoleafPanelColor(rgb: $0).spokenDescription } ?? "colour unknown"
        return selected ? "\(colour), selected" : colour
    }
}

/// A small, non-interactive drawing of a wall for fixture tiles.
struct NanoleafMiniWall: View {
    @ObservedObject var shapes: NanoleafShapesController
    let deviceID: String
    let fallback: Color
    let lit: Bool

    var body: some View {
        if let layout = shapes.layout(deviceID) {
            NanoleafWallCanvas(layout: layout, rotation: Double(shapes.displayOrientation(deviceID)),
                               display: lit ? display(layout) : NanoleafPanelDisplay.resolve(
                                layout: layout, output: .off, lastSent: [:], draft: nil, wholeWall: nil),
                               interactive: false, showsReference: false)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "hexagon")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(lit ? fallback : Lumen.meter)
                .accessibilityHidden(true)
        }
    }

    private func display(_ layout: NanoleafLayout) -> NanoleafPanelDisplay {
        let wall = shapes.wall(deviceID)
        let rgb = fallback.rgbComponents
        let whole = NanoleafRGB(red: UInt8((rgb.r * 255).rounded()), green: UInt8((rgb.g * 255).rounded()),
                                blue: UInt8((rgb.b * 255).rounded()))
        return NanoleafPanelDisplay.resolve(layout: layout, output: wall.output, lastSent: wall.lastSent,
                                            draft: nil, wholeWall: whole)
    }
}

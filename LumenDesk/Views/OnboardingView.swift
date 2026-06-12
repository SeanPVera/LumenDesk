import SwiftUI

/// First-run guided setup. Shown once (gated by `RootView`'s `@AppStorage`
/// flag) and walks the user from a branded welcome through discovery and into
/// a finished, organized setup:
///
///   welcome → prepare → discover → rooms → done
///
/// Every step is skippable so no one is ever trapped.
struct OnboardingView: View {
    @EnvironmentObject var manager: LightManager

    /// Called when the user finishes or skips. The caller flips the persisted
    /// "has onboarded" flag.
    let onFinish: () -> Void

    enum Step: Int, CaseIterable {
        case welcome, prepare, discover, rooms, done
    }

    @State private var step: Step = .welcome
    @State private var activeRoomID: UUID? = nil
    @State private var newRoomName: String = ""
    @FocusState private var roomFieldFocused: Bool

    var body: some View {
        ZStack {
            LumenBackground()

            VStack(spacing: 20) {
                topBar

                ScrollView {
                    Group {
                        switch step {
                        case .welcome:  welcomeStep
                        case .prepare:  prepareStep
                        case .discover: discoverStep
                        case .rooms:    roomsStep
                        case .done:     doneStep
                        }
                    }
                    .frame(maxWidth: 540)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal:   .move(edge: .leading).combined(with: .opacity)
                    ))
                }
                .scrollIndicators(.hidden)

                footer
            }
            .padding(28)
            .frame(maxWidth: 760)
        }
        .sheetFrame(minWidth: 560, minHeight: 480)
    }

    // MARK: - Top bar (progress + skip)

    private var topBar: some View {
        HStack(spacing: 10) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue
                          ? AnyShapeStyle(Lumen.brandGradient)
                          : AnyShapeStyle(Lumen.hairlineStrong))
                    .frame(width: s == step ? 26 : 16, height: 5)
                    .animation(.spring(duration: 0.3), value: step)
            }
            Spacer()
            if step != .done {
                Button("Skip setup") { onFinish() }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(Lumen.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 12)
            LumenWordmark(size: 44)
            Text("Beautiful, local control for your LIFX and Govee lights.")
                .font(.title3)
                .foregroundStyle(Lumen.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 14) {
                valueRow("lock.shield.fill", Lumen.violetBright,
                         "Entirely local", "No cloud, no accounts, no API keys — commands never leave your network.")
                valueRow("square.grid.2x2.fill", Lumen.pink,
                         "Rooms & scenes", "Group bulbs across brands and recall the perfect lighting in one tap.")
                valueRow("clock.fill", Lumen.gold,
                         "Set it and forget it", "Schedule lights to follow your day, sunrise to bedtime.")
            }
            .padding(.top, 4)
            Spacer(minLength: 12)
        }
    }

    private func valueRow(_ icon: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 34)
                .shadow(color: tint.opacity(0.5), radius: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(Lumen.textPrimary)
                Text(detail).font(.callout).foregroundStyle(Lumen.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .lumenCard()
    }

    // MARK: - Step 2: Prepare

    private var prepareStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepTitle("A quick checklist", "Two minutes now saves a lot of head-scratching later.")

            VStack(spacing: 12) {
                checklistCard("wifi", Lumen.violetBright,
                              "Same Wi-Fi network",
                              "Your Mac and every bulb must share one network and subnet. Many routers isolate “IoT” Wi-Fi — if so, join the same one.")
                checklistCard("network", Lumen.coral,
                              "Govee: enable LAN Control",
                              "In the Govee Home app: Device → Settings → LAN Control. Only certain Govee models support it.")
                checklistCard("dot.radiowaves.left.and.right", Lumen.pink,
                              "LIFX: powered & paired",
                              "Make sure each LIFX bulb is switched on and already set up in the LIFX app.")
            }

            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(Lumen.gold)
                    .accessibilityHidden(true)
                Text("Your device will ask for permission to find devices on your local network. Please choose **Allow** — it's required for discovery.")
                    .font(.callout)
                    .foregroundStyle(Lumen.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .lumenCard(fill: Lumen.surfaceRaised)
        }
    }

    private func checklistCard(_ icon: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(Lumen.textPrimary)
                Text(detail).font(.callout).foregroundStyle(Lumen.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .lumenCard()
    }

    // MARK: - Step 3: Discover

    private var discoverStep: some View {
        VStack(spacing: 18) {
            stepTitle("Finding your lights",
                      manager.isScanning ? manager.scanPhase : discoverSubtitle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if manager.isScanning && manager.devices.isEmpty {
                ScanPulse()
                    .padding(.vertical, 24)
            }

            if !manager.devices.isEmpty {
                Label("Toggle a light to see which bulb it is.", systemImage: "lightbulb.fill")
                    .font(.caption)
                    .foregroundStyle(Lumen.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 12)], spacing: 12) {
                    ForEach(manager.devices) { device in
                        DiscoverChip(device: device)
                    }
                }
                .animation(.spring(duration: 0.45), value: manager.devices.count)
            } else if !manager.isScanning {
                VStack(spacing: 14) {
                    Image(systemName: "lightbulb.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(Lumen.textTertiary)
                    Text("No lights found yet.")
                        .font(.headline)
                        .foregroundStyle(Lumen.textPrimary)
                    Text("Re-check the steps before, then scan again. You can also finish setup and scan later.")
                        .font(.callout)
                        .foregroundStyle(Lumen.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    DiscoveryDiagnosticsCard()
                        .environmentObject(manager)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
        .onAppear { manager.scan() }
    }

    private var discoverSubtitle: String {
        let n = manager.devices.count
        return n == 0 ? "Scanning your network…"
                      : "Found \(n) light\(n == 1 ? "" : "s")."
    }

    // MARK: - Step 4: Rooms

    private var roomsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepTitle("Group them into rooms",
                      manager.devices.isEmpty
                        ? "No lights to organize yet — you can set up rooms anytime from the main window."
                        : "Pick a room, then tap lights to add them. Toggle a light to see which bulb it is. Optional.")

            if !manager.devices.isEmpty {
                // Room pills + inline create field
                roomPills

                // Devices to assign
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                    ForEach(manager.devices) { device in
                        AssignChip(device: device, activeRoomID: activeRoomID)
                    }
                }
            }
        }
    }

    private var roomPills: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !manager.rooms.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(manager.rooms) { room in
                            roomPill(room)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .foregroundStyle(Lumen.violetBright)
                    .accessibilityHidden(true)
                TextField("New room name (e.g. Living Room)", text: $newRoomName)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Lumen.textPrimary)
                    .focused($roomFieldFocused)
                    .onSubmit(createRoom)
                Button("Add", action: createRoom)
                    .buttonStyle(.plain)
                    .foregroundStyle(canCreateRoom ? Lumen.violetBright : Lumen.textTertiary)
                    .disabled(!canCreateRoom)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .lumenCard(radius: Lumen.tileRadius, fill: Lumen.surfaceRaised)
        }
    }

    private func roomPill(_ room: Room) -> some View {
        let active = activeRoomID == room.id
        let count = manager.devices(in: room).count
        return Button {
            activeRoomID = active ? nil : room.id
        } label: {
            HStack(spacing: 6) {
                Text(room.name).font(.callout.weight(.medium))
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.black.opacity(0.25)))
                }
            }
            .foregroundStyle(active ? .white : Lumen.textSecondary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                Capsule().fill(active ? AnyShapeStyle(Lumen.brandGradient)
                                      : AnyShapeStyle(Lumen.surface))
            )
            .overlay(Capsule().stroke(active ? Color.clear : Lumen.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(active ? "Tap lights to add them to \(room.name)" : "Select \(room.name)")
    }

    // MARK: - Step 5: Done

    private var doneStep: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 12)
            ZStack {
                Circle()
                    .fill(Lumen.brandGradient)
                    .frame(width: 92, height: 92)
                    .shadow(color: Lumen.pink.opacity(0.6), radius: 22)
                Image(systemName: "checkmark")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)

            Text("You're all set")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Lumen.textPrimary)

            Text(doneRecap)
                .font(.title3)
                .foregroundStyle(Lumen.textSecondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(Lumen.gold)
                    .accessibilityHidden(true)
                Text("Tip: arrange your lights just right, then press **⇧⌘S** to save it as a Scene.")
                    .font(.callout)
                    .foregroundStyle(Lumen.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .lumenCard(fill: Lumen.surfaceRaised)
            Spacer(minLength: 12)
        }
    }

    private var doneRecap: String {
        let lights = manager.devices.count
        let rooms = manager.rooms.count
        if lights == 0 { return "Scan for your lights anytime from the main window." }
        let lightPart = "\(lights) light\(lights == 1 ? "" : "s")"
        let roomPart = rooms == 0 ? "" : " across \(rooms) room\(rooms == 1 ? "" : "s")"
        return "\(lightPart)\(roomPart) ready to go."
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { back() }
                    .buttonStyle(LumenSecondaryButtonStyle())
            }
            Spacer()
            Button(primaryTitle) { advance() }
                .buttonStyle(LumenPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "Get Started"
        case .done:    return "Enter LumenDesk"
        default:       return "Continue"
        }
    }

    // MARK: - Shared step header

    private func stepTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Lumen.textPrimary)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(Lumen.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private var canCreateRoom: Bool {
        !newRoomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func createRoom() {
        let trimmed = newRoomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manager.createRoom(name: trimmed)
        activeRoomID = manager.rooms.last?.id
        newRoomName = ""
        roomFieldFocused = false
    }

    private func advance() {
        switch step {
        case .welcome:  go(.prepare)
        case .prepare:  go(.discover)
        case .discover: go(.rooms)
        case .rooms:    go(.done)
        case .done:     onFinish()
        }
    }

    private func back() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        go(prev)
    }

    private func go(_ next: Step) {
        withAnimation(.spring(duration: 0.4)) { step = next }
    }
}

// MARK: - Scanning pulse animation

/// Concentric rings radiating from a radio glyph — the "we're listening on the
/// network" moment during discovery.
private struct ScanPulse: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Lumen.violetBright.opacity(0.5), lineWidth: 2)
                    .frame(width: 120, height: 120)
                    .scaleEffect(animate ? 1.7 : 0.45)
                    .opacity(animate ? 0 : 0.85)
                    .animation(
                        .easeOut(duration: 2.2)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i) * 0.7),
                        value: animate
                    )
            }
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 30))
                .foregroundStyle(Lumen.brandGradient)
                .shadow(color: Lumen.pink.opacity(0.5), radius: 10)
        }
        .frame(width: 130, height: 130)
        .onAppear { animate = true }
        .accessibilityHidden(true)
    }
}

// MARK: - Setup light chips

/// A discovered-light chip with a power toggle, so the user can flip a bulb on
/// or off and watch which physical light responds. Observes the device so the
/// toggle and color dot update live; an on-light glows in its own color as an
/// extra identification cue.
private struct DiscoverChip: View {
    @EnvironmentObject var manager: LightManager
    @ObservedObject var device: LightDevice

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(device.isOn ? device.color : Color.gray.opacity(0.4))
                .frame(width: 16, height: 16)
                .shadow(color: device.isOn ? device.color.opacity(0.7) : .clear, radius: 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Lumen.textPrimary)
                    .lineLimit(1)
                Text(device.brand.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(device.brand.tint)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: powerBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .tint(Lumen.pink)
                .help("Turn this light on or off to identify it")
                .accessibilityLabel(device.isOn ? "Turn off \(device.label)" : "Turn on \(device.label)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .lumenCard(radius: Lumen.tileRadius, glowColor: device.isOn ? device.color : nil)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    private var powerBinding: Binding<Bool> {
        Binding(get: { device.isOn }, set: { manager.setPower(device, on: $0) })
    }
}

/// An assignable-light chip: a power toggle to identify the bulb, plus a
/// tappable body that adds or removes the light from the selected room.
private struct AssignChip: View {
    @EnvironmentObject var manager: LightManager
    @ObservedObject var device: LightDevice
    let activeRoomID: UUID?

    var body: some View {
        let room = manager.room(forLightID: device.id)
        let inActiveRoom = room?.id == activeRoomID && activeRoomID != nil
        return HStack(spacing: 10) {
            Toggle("", isOn: powerBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .tint(Lumen.pink)
                .help("Turn this light on or off to identify it")
                .accessibilityLabel(device.isOn ? "Turn off \(device.label)" : "Turn on \(device.label)")

            Button {
                toggleAssign()
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(device.isOn ? device.color : Color.gray.opacity(0.4))
                        .frame(width: 15, height: 15)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.label)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Lumen.textPrimary)
                            .lineLimit(1)
                        Text(room?.name ?? "Unassigned")
                            .font(.caption2)
                            .foregroundStyle(room == nil ? Lumen.textTertiary : Lumen.violetBright)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: inActiveRoom ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title3)
                        .foregroundStyle(inActiveRoom ? Lumen.pink : Lumen.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(activeRoomID == nil)
            .help(activeRoomID == nil ? "Select or create a room first" : "Add or remove \(device.label)")
            .accessibilityLabel("\(device.label), currently \(room?.name ?? "unassigned")")
            .accessibilityHint(activeRoomID == nil ? "Select a room first" : "Adds or removes this light from the selected room")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .lumenCard(radius: Lumen.tileRadius, highlighted: inActiveRoom)
    }

    private var powerBinding: Binding<Bool> {
        Binding(get: { device.isOn }, set: { manager.setPower(device, on: $0) })
    }

    private func toggleAssign() {
        guard let rid = activeRoomID else { return }
        if manager.room(forLightID: device.id)?.id == rid {
            manager.assign(lightID: device.id, toRoom: nil)
        } else {
            manager.assign(lightID: device.id, toRoom: rid)
        }
    }
}

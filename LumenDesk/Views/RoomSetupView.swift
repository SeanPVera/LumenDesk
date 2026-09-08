import SwiftUI

// MARK: - Room setup
//
// Discovery hands the app a vendor, a model, an address, and whatever name
// someone typed into a phone app two years ago. The plan needs four things it
// never says: what rooms exist, which fixture is in which, where the rooms sit
// relative to each other, and where a lamp stands inside one.
//
// `RoomNameParser` answers the first for most of a real rig. `PlanLayout`
// answers the third and supplies defaults for the fourth. The second one no
// algorithm can answer, so this flow flashes the bulb and asks.
//
// Two entry points, one flow:
//
// - Nothing sorted yet: start at the proposals and run the whole thing.
// - A lamp bought last Tuesday: skip straight to the flash loop for whatever
//   is not on the plan. Every setup wizard works once; people buy lamps for
//   years, so none of this may live only in onboarding.

struct RoomSetupView: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.dismiss) private var dismiss

    enum Step { case propose, identify, arrange, done }

    @State private var step: Step = .propose
    @State private var proposals: [EditableProposal] = []
    @State private var queue: [String] = []
    @State private var queueIndex = 0
    @State private var skipped: [String] = []
    @State private var newRoomName = ""
    @State private var showingNewRoomField = false
    @State private var started = false

    /// A parser suggestion the user can rename or throw away before it becomes
    /// a real room.
    struct EditableProposal: Identifiable {
        let id = UUID()
        var name: String
        let token: String
        let lightIDs: [String]
        var rejected = false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Lumen.ruleSoft)

            Group {
                switch step {
                case .propose:  proposeStep
                case .identify: identifyStep
                case .arrange:  arrangeStep
                case .done:     doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider().overlay(Lumen.ruleSoft)
            footer
        }
        .background(Lumen.stage)
        .sheetFrame(minWidth: 720, idealWidth: 820, minHeight: 540, idealHeight: 600)
        .onAppear(perform: start)
        // The bulb keeps breathing until something stops it, so every exit
        // from this view has to put it back.
        .onDisappear { manager.endSustainedIdentify() }
    }

    // MARK: Lifecycle

    private func start() {
        guard !started else { return }
        started = true

        // Entry point two: rooms already exist, so only the strays need
        // sorting and the proposals step has nothing to say.
        if !manager.rooms.isEmpty {
            queue = manager.unplacedDevices.map(\.id)
            step = queue.isEmpty ? .arrange : .identify
            flashCurrent()
            return
        }

        proposals = RoomNameParser
            .proposals(for: manager.devices.map { (id: $0.id, name: $0.label) })
            .map { EditableProposal(name: $0.name, token: $0.token, lightIDs: $0.lightIDs) }
    }

    /// Turn accepted proposals into real rooms, then queue up whatever is left.
    private func commitProposals() {
        for proposal in proposals where !proposal.rejected {
            guard let roomID = manager.addRoom(named: proposal.name) else { continue }
            manager.assign(lightIDs: Set(proposal.lightIDs), toRoom: roomID)
        }
        queue = manager.unplacedDevices.map(\.id)
        queueIndex = 0
        step = queue.isEmpty ? .arrange : .identify
        flashCurrent()
    }

    private var currentDevice: LightDevice? {
        guard queueIndex < queue.count else { return nil }
        return manager.devices.first { $0.id == queue[queueIndex] }
    }

    private func flashCurrent() {
        guard step == .identify, let device = currentDevice, !device.isStale else {
            manager.endSustainedIdentify()
            return
        }
        manager.beginSustainedIdentify(device)
    }

    private func advance() {
        showingNewRoomField = false
        newRoomName = ""
        queueIndex += 1
        if queueIndex >= queue.count {
            manager.endSustainedIdentify()
            manager.ensurePlanLayout()
            step = .arrange
        } else {
            flashCurrent()
        }
    }

    private func assign(to roomID: UUID) {
        guard let device = currentDevice else { return }
        manager.endSustainedIdentify()
        manager.assign(lightID: device.id, toRoom: roomID)
        advance()
    }

    private func skipCurrent() {
        if let device = currentDevice { skipped.append(device.id) }
        manager.endSustainedIdentify()
        advance()
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(visibleSteps, id: \.self) { entry in
                HStack(spacing: 7) {
                    Text(stepNumber(entry))
                        .font(LumenType.readout(size: 9.5))
                        .foregroundStyle(step == entry ? Lumen.link : Lumen.faint)
                    Text(stepTitle(entry))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(step == entry ? Lumen.chalk : Lumen.muted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(step == entry ? Lumen.link : Color.clear)
                        .frame(height: 2)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    private var visibleSteps: [Step] {
        proposals.isEmpty ? [.identify, .arrange, .done] : [.propose, .identify, .arrange, .done]
    }

    private func stepNumber(_ entry: Step) -> String {
        guard let index = visibleSteps.firstIndex(of: entry) else { return "" }
        return String(format: "%02d", index + 1)
    }

    private func stepTitle(_ entry: Step) -> String {
        switch entry {
        case .propose:  return "Sort"
        case .identify: return "Identify"
        case .arrange:  return "Arrange"
        case .done:     return "Plan"
        }
    }

    private var footer: some View {
        HStack(spacing: 11) {
            Text(footerCount)
                .font(LumenType.readout(size: 10.5))
                .foregroundStyle(Lumen.muted)
                .frame(maxWidth: .infinity, alignment: .leading)

            switch step {
            case .propose:
                Button("Ask me about every fixture") {
                    for index in proposals.indices { proposals[index].rejected = true }
                }
                .buttonStyle(LumenSecondaryButtonStyle(compact: true))
                Button("Create these rooms", action: commitProposals)
                    .buttonStyle(LumenPrimaryButtonStyle(compact: true))
            case .identify:
                Button("Skip the rest") {
                    for index in queueIndex..<queue.count { skipped.append(queue[index]) }
                    queueIndex = queue.count
                    manager.endSustainedIdentify()
                    manager.ensurePlanLayout()
                    step = .arrange
                }
                .buttonStyle(LumenSecondaryButtonStyle(compact: true))
            case .arrange:
                Button("Reset layout") { manager.resetPlanLayout() }
                    .buttonStyle(LumenSecondaryButtonStyle(compact: true))
                Button("Looks right") { step = .done }
                    .buttonStyle(LumenPrimaryButtonStyle(compact: true))
            case .done:
                Button("Open the plan") { dismiss() }
                    .buttonStyle(LumenPrimaryButtonStyle(compact: true))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private var footerCount: String {
        switch step {
        case .propose:
            let covered = proposals.filter { !$0.rejected }.reduce(0) { $0 + $1.lightIDs.count }
            return "\(covered) of \(manager.devices.count) sorted from names · \(manager.devices.count - covered) to identify"
        case .identify:
            return "\(min(queueIndex + 1, queue.count)) of \(queue.count) to identify"
        case .arrange:
            return "\(manager.rooms.count) rooms on a \(PlanLayout.columns)-column board"
        case .done:
            let placed = manager.devices.count - manager.unplacedDevices.count
            return "\(manager.rooms.count) rooms · \(placed) of \(manager.devices.count) fixtures placed"
        }
    }

    // MARK: Step 1 — proposals

    private var proposeStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                stepHeading("These look like rooms",
                            "Most people already typed a room into their vendor app. Rename any of these, or reject one and its fixtures go into the identify queue instead.")

                if proposals.isEmpty {
                    Text("None of your fixture names carry a room, so every one of them gets flashed and asked about. That is the slower path, and it is also the accurate one.")
                        .font(.system(size: 13))
                        .foregroundStyle(Lumen.meter)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 236), spacing: 11)], spacing: 11) {
                        ForEach($proposals) { $proposal in
                            proposalCard($proposal)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func proposalCard(_ proposal: Binding<EditableProposal>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                TextField("Room name", text: proposal.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Lumen.chalk)
                    .disabled(proposal.wrappedValue.rejected)
                // Show the reasoning rather than asking to be trusted.
                Text("\u{201C}\(proposal.wrappedValue.token)\u{201D}")
                    .font(LumenType.readout(size: 9))
                    .foregroundStyle(Lumen.faint)
            }

            ForEach(proposal.wrappedValue.lightIDs, id: \.self) { lightID in
                if let device = manager.devices.first(where: { $0.id == lightID }) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(device.color)
                            .frame(width: 6, height: 6)
                        Text(device.label)
                            .font(.system(size: 12))
                            .foregroundStyle(Lumen.meter)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(device.brand == .lifx ? "LFX" : "GVE")
                            .font(LumenType.readout(size: 9))
                            .foregroundStyle(Lumen.faint)
                    }
                }
            }

            Button(proposal.wrappedValue.rejected ? "Rejected — undo" : "Not a room") {
                proposal.wrappedValue.rejected.toggle()
            }
            .buttonStyle(LumenSecondaryButtonStyle(compact: true))
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumenCard(radius: 8)
        .opacity(proposal.wrappedValue.rejected ? 0.4 : 1)
    }

    // MARK: Step 2 — the flash loop

    private var identifyStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                stepHeading("Look up. Which room is flashing?",
                            "The fixture is breathing on your network right now. Answer with the room you can see it in — you never have to know what it is called.")

                if let device = currentDevice {
                    HStack(alignment: .top, spacing: 26) {
                        IdentifyLamp(device: device)
                            .frame(width: 210)

                        VStack(alignment: .leading, spacing: 14) {
                            if device.isStale {
                                Label("This fixture is not answering, so it cannot be flashed. Put it in a room from memory, or skip it and it will wait in the tray.",
                                      systemImage: "wifi.slash")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Lumen.warn)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            roomChoices

                            if showingNewRoomField {
                                HStack(spacing: 7) {
                                    TextField("Room name", text: $newRoomName)
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit(createRoomAndAssign)
                                    Button("Add", action: createRoomAndAssign)
                                        .buttonStyle(LumenPrimaryButtonStyle(compact: true))
                                        .disabled(newRoomName.trimmingCharacters(in: .whitespaces).isEmpty)
                                }
                            }

                            HStack(spacing: 16) {
                                Button("I cannot see it", action: skipCurrent)
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Lumen.muted)
                                Button("Skip for now", action: skipCurrent)
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Lumen.muted)
                            }

                            if !manager.rooms.isEmpty { sortedSoFar }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var roomChoices: some View {
        VStack(alignment: .leading, spacing: 9) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 7)],
                      alignment: .leading, spacing: 7) {
                ForEach(manager.rooms) { room in
                    Button(room.name) { assign(to: room.id) }
                        .buttonStyle(LumenSecondaryButtonStyle())
                }
                Button("+ New room") { showingNewRoomField = true }
                    .buttonStyle(LumenSecondaryButtonStyle())
            }
        }
    }

    private func createRoomAndAssign() {
        guard let roomID = manager.addRoom(named: newRoomName) else { return }
        assign(to: roomID)
    }

    private var sortedSoFar: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().overlay(Lumen.ruleSoft)
            HStack(spacing: 6) {
                ForEach(manager.rooms) { room in
                    Text("\(room.name) \(room.lightIDs.count)")
                        .font(LumenType.readout(size: 9.5))
                        .foregroundStyle(Lumen.muted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Lumen.strip)
                        )
                }
            }
        }
    }

    // MARK: Step 3 — arrange

    private var arrangeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeading("Arrange your rooms",
                        "This does not have to match your floor plan. It has to look like your home to you. Drag a block to move it, drag its corner to resize. Skip it and the auto-layout is what you get, which is a real answer rather than a placeholder.")

            PlanBoardView(arranging: true,
                          selectedRoomID: .constant(nil),
                          selectedLightID: .constant(nil))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
    }

    // MARK: Step 4 — done

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeading("Your plan",
                        "Fixture dots are placed automatically inside each room. You can drag them from a room's inspector later, and most people never will.")

            PlanBoardView(arranging: false,
                          selectedRoomID: .constant(nil),
                          selectedLightID: .constant(nil))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !skipped.isEmpty {
                Label("\(skipped.count) fixture\(skipped.count == 1 ? "" : "s") stayed in the tray. They sit on the plan until you sort them, and nothing was invented to hold them.",
                      systemImage: "tray")
                    .font(.system(size: 12))
                    .foregroundStyle(Lumen.warn)
            }
        }
        .padding(20)
    }

    // MARK: Shared

    private func stepHeading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Lumen.chalk)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Lumen.meter)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
        }
    }
}

// MARK: - The lamp

/// A picture of the fixture that is currently breathing, so the screen and the
/// room agree about which lamp is being asked about.
private struct IdentifyLamp: View {
    @EnvironmentObject private var manager: LightManager
    @ObservedObject var device: LightDevice

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    private var live: Bool { !device.isStale }

    private var identityLine: String {
        var line = device.brand.displayName
        if let sku = device.sku, !sku.isEmpty { line += " " + sku }
        return line + " · " + device.address
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(colors: [device.color.opacity(0.75), .clear],
                                       center: .center, startRadius: 2, endRadius: 52)
                    )
                    .frame(width: 104, height: 104)
                    .scaleEffect(breathing ? 1.12 : 0.9)
                    .opacity(live ? (breathing ? 0.65 : 0.2) : 0.08)

                Circle()
                    .fill(live ? device.color : Lumen.faint)
                    .frame(width: 34, height: 34)
                    .shadow(color: live ? device.color.opacity(0.9) : .clear, radius: 18)
            }
            .frame(height: 110)
            .animation(reduceMotion || !live ? nil
                       : .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                       value: breathing)
            .onAppear { breathing = true }

            Text(device.label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Lumen.chalk)
                .multilineTextAlignment(.center)

            Text(identityLine)
                .font(LumenType.readout(size: 9.5))
                .foregroundStyle(Lumen.muted)
                .multilineTextAlignment(.center)

            Button("Flash it again") { manager.beginSustainedIdentify(device) }
                .buttonStyle(LumenSecondaryButtonStyle(compact: true))
                .disabled(!live)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .lumenCard(radius: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Now flashing: \(device.label)")
    }
}

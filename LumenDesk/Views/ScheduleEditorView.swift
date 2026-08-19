import SwiftUI

struct ScheduleEditorView: View {
    @EnvironmentObject var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    let room: Room

    @State private var editingEntry: ScheduleEntry?
    @State private var showingNewEntry = false
    @State private var showingSolarSettings = false
    @State private var testingEntry: ScheduleEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Schedules — \(room.name)").font(LumenType.display(size: 19, weight: .bold))
                    Text("Choose days, edit rules in place, preview the timeline, and test safely.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Solar Times…") { showingSolarSettings = true }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()

            let schedules = manager.schedules(for: room.id)
            let warnings = manager.conflictWarnings(for: room.id)
            ScheduleTimelineView(entries: schedules, warnings: warnings)
                .padding(.horizontal, 16).padding(.top, 12)

            if schedules.isEmpty {
                VStack(spacing: 8) { Spacer(); Image(systemName: "clock.badge.plus").font(.system(size: 34)).foregroundStyle(.secondary); Text("No schedules yet").font(LumenType.display(size: 15, weight: .semibold)); Text("Add a rule with locale-aware time and weekday controls.").foregroundStyle(.secondary); Spacer() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(schedules) { entry in scheduleRow(entry) }.listStyle(.inset)
            }

            Divider()
            HStack {
                Text("\(schedules.count) automation rule\(schedules.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { showingNewEntry = true } label: { Label("Add Schedule", systemImage: "plus") }.buttonStyle(LumenPrimaryButtonStyle())
            }.padding(16)
        }
        .sheetFrame(minWidth: 560, idealWidth: 680, minHeight: 460, idealHeight: 620).background(LumenBackground(glow: false))
        .sheet(isPresented: $showingSolarSettings) { SolarSettingsView().environmentObject(manager) }
        .sheet(isPresented: $showingNewEntry) { ScheduleFormView(room: room, entry: nil).environmentObject(manager) }
        .sheet(item: $editingEntry) { ScheduleFormView(room: room, entry: $0).environmentObject(manager) }
        .confirmationDialog("Test this automation now?", isPresented: Binding(get: { testingEntry != nil }, set: { if !$0 { testingEntry = nil } })) {
            Button("Run Test") { if let entry = testingEntry { manager.testSchedule(entry, in: room) }; testingEntry = nil }
            Button("Cancel", role: .cancel) { testingEntry = nil }
        } message: { Text("The room will change immediately. You can use Undo afterward.") }
    }

    private func scheduleRow(_ entry: ScheduleEntry) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { entry.isEnabled }, set: { manager.setScheduleEnabled(entry.id, in: room.id, enabled: $0) }))
                .labelsHidden()
                .toggleStyle(LumenRockerStyle(showsLabel: false))
                .accessibilityLabel("Enable \(entry.action.displayName) at \(entry.timeString)")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.timeString)
                        .font(LumenType.readout(size: 15, weight: .semibold))
                    Text(entry.daySummary.uppercased())
                        .font(LumenType.instrumentLabel(size: 9))
                        .tracking(0.8)
                        .foregroundStyle(Lumen.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Lumen.surfaceRaised)
                        )
                }
                Text(entry.action.displayName).font(.caption).foregroundStyle(.secondary)
                Text(manager.nextRunDescription(for: entry)).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Test") { testingEntry = entry }
                .buttonStyle(LumenSecondaryButtonStyle(compact: true))
            Menu {
                Button("Edit…") { editingEntry = entry }
                Button("Duplicate") { manager.duplicateSchedule(entry, in: room.id) }
                Divider()
                Button("Delete", role: .destructive) { manager.deleteSchedule(entry.id, from: room.id) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .lumenInteractiveTarget()
        }.padding(.vertical, 5)
    }
}

private struct ScheduleTimelineView: View {
    let entries: [ScheduleEntry]
    let warnings: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                LumenEyebrow(text: "24-hour timeline")
                Spacer()
                Text("00   06   12   18   24")
                    .font(LumenType.readout(size: 9))
                    .foregroundStyle(Lumen.textTertiary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Lumen.void)
                        .overlay(
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .stroke(Lumen.hairline, lineWidth: 1)
                        )
                        .frame(height: 8)
                    ForEach(entries) { entry in
                        let minute = entry.action.isRelativeToSun ? 720 : entry.hour * 60 + entry.minute
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(entry.isEnabled ? Lumen.beamBright : Lumen.offline)
                            .frame(width: 4, height: 14)
                            .shadow(color: entry.isEnabled ? Lumen.beam.opacity(0.6) : .clear, radius: 5)
                            .offset(x: max(0, min(proxy.size.width - 4, CGFloat(minute) / 1440 * proxy.size.width)))
                            .help("\(entry.daySummary), \(entry.timeString): \(entry.action.displayName)")
                    }
                }.frame(height: 14)
            }.frame(height: 14)
            if !warnings.isEmpty { ForEach(warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(Lumen.warning) } }
        }.padding(10).lumenCard()
    }
}

private struct ScheduleFormView: View {
    @EnvironmentObject var manager: LightManager
    @Environment(\.dismiss) private var dismiss
    let room: Room
    let entry: ScheduleEntry?
    @State private var date = Date()
    @State private var action: ScheduleAction = .turnOff
    @State private var offset = 0
    @State private var weekdays = Set(1...7)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry == nil ? "New Schedule" : "Edit Schedule").font(LumenType.display(size: 19, weight: .bold))
            Label("Times use \(TimeZone.current.identifier). Across daylight-saving changes, skipped actions are held for review after wake; repeated wall-clock times run once.", systemImage: "globe")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Action", selection: $action) { ForEach(ScheduleAction.allCases, id: \.self) { Text($0.displayName).tag($0) } }
            if action.isRelativeToSun {
                Picker("Offset", selection: $offset) { ForEach([-120,-90,-60,-30,-15,0,15,30,60,90,120], id: \.self) { Text($0 == 0 ? "Exactly" : "\($0 > 0 ? "+" : "")\($0) minutes").tag($0) } }
            } else {
                #if os(macOS)
                DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute).datePickerStyle(.field)
                #else
                DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute).datePickerStyle(.compact)
                #endif
            }
            VStack(alignment: .leading, spacing: 6) {
                LumenEyebrow(text: "Days")
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { day in
                        Toggle(Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: Binding(
                            get: { weekdays.contains(day) },
                            set: { on in
                                if on { weekdays.insert(day) } else { weekdays.remove(day) }
                            }
                        ))
                        .toggleStyle(LumenChipStyle())
                        .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                    }
                }
                HStack(spacing: 6) {
                    Button("Every day") { weekdays = Set(1...7) }
                        .buttonStyle(LumenSecondaryButtonStyle(compact: true))
                    Button("Weekdays") { weekdays = Set(2...6) }
                        .buttonStyle(LumenSecondaryButtonStyle(compact: true))
                    Button("Weekends") { weekdays = [1, 7] }
                        .buttonStyle(LumenSecondaryButtonStyle(compact: true))
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(LumenSecondaryButtonStyle())
                Button("Save") { save() }
                    .buttonStyle(LumenPrimaryButtonStyle())
                    .disabled(weekdays.isEmpty)
            }
        }.padding(20).sheetFrame(minWidth: 440, idealWidth: 520).background(LumenBackground(glow: false)).onAppear(perform: load)
    }

    private func load() { guard let entry else { return }; action = entry.action; offset = entry.offsetMinutes; weekdays = entry.weekdays; date = Calendar.current.date(bySettingHour: entry.hour, minute: entry.minute, second: 0, of: Date()) ?? Date() }
    private func save() {
        let parts = Calendar.current.dateComponents([.hour,.minute], from: date)
        let value = ScheduleEntry(id: entry?.id ?? UUID(), isEnabled: entry?.isEnabled ?? true, hour: parts.hour ?? 0, minute: parts.minute ?? 0, offsetMinutes: action.isRelativeToSun ? offset : 0, action: action, weekdays: weekdays)
        if entry == nil { manager.addSchedule(value, to: room.id) } else { manager.updateSchedule(value, in: room.id) }
        dismiss()
    }
}

// MARK: - Solar settings sheet

struct SolarSettingsView: View {
    @EnvironmentObject var manager: LightManager
    @Environment(\.dismiss) private var dismiss

    @State private var sunriseHour: Int = 0
    @State private var sunriseMinute: Int = 0
    @State private var sunsetHour: Int = 0
    @State private var sunsetMinute: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sunrise & Sunset Times")
                .font(LumenType.display(size: 19, weight: .bold))
            Text("Set your local sunrise and sunset times. LumenDesk uses these for solar-relative schedules.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            HStack(spacing: 12) {
                Image(systemName: "sunrise.fill").foregroundStyle(Lumen.gold)
                Text("Sunrise").frame(width: 70, alignment: .leading)
                timePicker(hour: $sunriseHour, minute: $sunriseMinute)
            }
            HStack(spacing: 12) {
                Image(systemName: "sunset.fill").foregroundStyle(Lumen.violetBright)
                Text("Sunset").frame(width: 70, alignment: .leading)
                timePicker(hour: $sunsetHour, minute: $sunsetMinute)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    manager.setSunriseTime(hour: sunriseHour, minute: sunriseMinute)
                    manager.setSunsetTime(hour: sunsetHour, minute: sunsetMinute)
                    dismiss()
                }
                .buttonStyle(LumenPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .sheetFrame(minWidth: 320, idealWidth: 400)
        .background(LumenBackground(glow: false))
        .onAppear {
            sunriseHour   = manager.sunriseHour
            sunriseMinute = manager.sunriseMinute
            sunsetHour    = manager.sunsetHour
            sunsetMinute  = manager.sunsetMinute
        }
    }

    private func timePicker(hour: Binding<Int>, minute: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            Picker("Hour", selection: hour) {
                ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d", h)).tag(h) }
            }
            .labelsHidden().frame(width: 60)
            Text(":").foregroundStyle(.secondary)
            Picker("Minute", selection: minute) {
                ForEach(0..<60, id: \.self) { m in Text(String(format: "%02d", m)).tag(m) }
            }
            .labelsHidden().frame(width: 60)
        }
    }
}

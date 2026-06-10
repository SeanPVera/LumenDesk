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
                    Text("Schedules — \(room.name)").font(.title3.weight(.semibold))
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
                VStack(spacing: 8) { Spacer(); Image(systemName: "clock.badge.plus").font(.system(size: 34)).foregroundStyle(.secondary); Text("No schedules yet").font(.headline); Text("Add a rule with locale-aware time and weekday controls.").foregroundStyle(.secondary); Spacer() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(schedules) { entry in scheduleRow(entry) }.listStyle(.inset)
            }

            Divider()
            HStack {
                Text("\(schedules.count) automation rule\(schedules.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { showingNewEntry = true } label: { Label("Add Schedule", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }.padding(16)
        }
        .frame(width: 620, height: 560).background(LumenBackground(glow: false))
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
            Toggle("", isOn: Binding(get: { entry.isEnabled }, set: { manager.setScheduleEnabled(entry.id, in: room.id, enabled: $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                HStack { Text(entry.timeString).font(.headline.monospacedDigit()); Text(entry.daySummary).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.secondary.opacity(0.15), in: Capsule()) }
                Text(entry.action.displayName).font(.caption).foregroundStyle(.secondary)
                Text(manager.nextRunDescription(for: entry)).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Test") { testingEntry = entry }
            Menu {
                Button("Edit…") { editingEntry = entry }
                Button("Duplicate") { manager.duplicateSchedule(entry, in: room.id) }
                Divider()
                Button("Delete", role: .destructive) { manager.deleteSchedule(entry.id, from: room.id) }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
        }.padding(.vertical, 5)
    }
}

private struct ScheduleTimelineView: View {
    let entries: [ScheduleEntry]
    let warnings: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text("24-hour timeline").font(.caption.weight(.semibold)); Spacer(); Text("Midnight   6 AM   Noon   6 PM   Midnight").font(.caption2).foregroundStyle(.tertiary) }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.14)).frame(height: 8)
                    ForEach(entries) { entry in
                        let minute = entry.action.isRelativeToSun ? 720 : entry.hour * 60 + entry.minute
                        Circle().fill(entry.isEnabled ? Lumen.violetBright : .gray).frame(width: 12, height: 12).offset(x: max(0, min(proxy.size.width - 12, CGFloat(minute) / 1440 * proxy.size.width))).help("\(entry.daySummary), \(entry.timeString): \(entry.action.displayName)")
                    }
                }.frame(height: 14)
            }.frame(height: 14)
            if !warnings.isEmpty { ForEach(warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(Lumen.warning) } }
        }.padding(10).lumenCard(radius: 8)
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
            Text(entry == nil ? "New Schedule" : "Edit Schedule").font(.title3.weight(.semibold))
            Picker("Action", selection: $action) { ForEach(ScheduleAction.allCases, id: \.self) { Text($0.displayName).tag($0) } }
            if action.isRelativeToSun {
                Picker("Offset", selection: $offset) { ForEach([-120,-90,-60,-30,-15,0,15,30,60,90,120], id: \.self) { Text($0 == 0 ? "Exactly" : "\($0 > 0 ? "+" : "")\($0) minutes").tag($0) } }
            } else {
                DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute).datePickerStyle(.field)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Days").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack { ForEach(1...7, id: \.self) { day in Button(Calendar.current.veryShortWeekdaySymbols[day - 1]) { if weekdays.contains(day) { weekdays.remove(day) } else { weekdays.insert(day) } }.buttonStyle(.bordered).tint(weekdays.contains(day) ? Lumen.violetBright : .secondary).accessibilityLabel(Calendar.current.weekdaySymbols[day - 1]) } }
                HStack { Button("Every day") { weekdays = Set(1...7) }; Button("Weekdays") { weekdays = Set(2...6) }; Button("Weekends") { weekdays = [1,7] } }.font(.caption)
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(weekdays.isEmpty) }
        }.padding(20).frame(width: 440).background(LumenBackground(glow: false)).onAppear(perform: load)
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
                .font(.title3.weight(.semibold))
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
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
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

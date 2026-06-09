import SwiftUI

struct ScheduleEditorView: View {
    @EnvironmentObject var manager: LightManager
    @Environment(\.dismiss) private var dismiss

    let room: Room

    @State private var draftHour: Int = 20
    @State private var draftMinute: Int = 0
    @State private var draftOffset: Int = 0   // signed offset in minutes for sun-relative
    @State private var draftAction: ScheduleAction = .turnOff

    @State private var showingSolarSettings: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Schedules \u{2014} \(room.name)")
                        .font(.title3.weight(.semibold))
                    Text("Automatically control these lights at a set time every day.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            let schedules = manager.schedules(for: room.id)
            let warnings = manager.conflictWarnings(for: room.id)

            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Schedule conflict warning", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Lumen.warning)
                    ForEach(warnings, id: \.self) { warning in
                        Text(warning).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Lumen.warning.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Lumen.warning.opacity(0.3), lineWidth: 1))
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            if schedules.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(schedules) { entry in
                            scheduleRow(entry)
                        }
                    }
                    .padding(16)
                }
            }

            Divider()

            addRow
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            // Solar settings hint
            if draftAction.isRelativeToSun {
                HStack(spacing: 6) {
                    Image(systemName: "sun.horizon.fill")
                        .foregroundStyle(Lumen.gold)
                        .font(.caption)
                    Text("Sunrise: \(String(format: "%02d:%02d", manager.sunriseHour, manager.sunriseMinute))  \u{00B7}  Sunset: \(String(format: "%02d:%02d", manager.sunsetHour, manager.sunsetMinute))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Estimate") { manager.applyEstimatedSolarTimes() }
                        .font(.caption)
                        .help("Estimate based on month (assumes Northern Hemisphere)")
                    Button("Configure\u{2026}") { showingSolarSettings = true }
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
        .frame(width: 420, height: 400)
        .background(LumenBackground(glow: false))
        .sheet(isPresented: $showingSolarSettings) {
            SolarSettingsView().environmentObject(manager)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "clock")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No schedules yet")
                .font(.headline)
            Text("Add a schedule below to automatically control lights at a set time each day.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func scheduleRow(_ entry: ScheduleEntry) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { manager.setScheduleEnabled(entry.id, in: room.id, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("\(entry.timeString) \u{2014} \(entry.action.displayName)")
            .accessibilityHint(entry.isEnabled ? "Tap to disable" : "Tap to enable")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.timeString)
                        .font(.callout.weight(.semibold).monospacedDigit())
                    if entry.action.isRelativeToSun {
                        let base = entry.action == .atSunrise
                            ? String(format: "%02d:%02d", manager.sunriseHour, manager.sunriseMinute)
                            : String(format: "%02d:%02d", manager.sunsetHour, manager.sunsetMinute)
                        Text("(\u{2248} \(base))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(entry.action.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(manager.nextRunDescription(for: entry))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(role: .destructive) {
                manager.deleteSchedule(entry.id, from: room.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(Lumen.danger)
            }
            .buttonStyle(.plain)
            .help("Delete this schedule entry")
            .accessibilityLabel("Delete \(entry.timeString) \(entry.action.displayName)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .lumenCard(radius: 8)
        .opacity(entry.isEnabled ? 1.0 : 0.5)
    }

    @ViewBuilder private var addRow: some View {
        let atLimit = manager.schedules(for: room.id).count >= 4
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // Show clock pickers for absolute actions; offset picker for solar.
                if draftAction.isRelativeToSun {
                    offsetPicker
                } else {
                    clockPickers
                }

                Picker("Action", selection: $draftAction) {
                    ForEach(ScheduleAction.allCases, id: \.self) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 120)
                .accessibilityLabel("Action")

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Button("Add") {
                        let entry: ScheduleEntry
                        if draftAction.isRelativeToSun {
                            entry = ScheduleEntry(hour: 0, minute: 0,
                                                 offsetMinutes: draftOffset, action: draftAction)
                        } else {
                            entry = ScheduleEntry(hour: draftHour, minute: draftMinute,
                                                 offsetMinutes: 0, action: draftAction)
                        }
                        manager.addSchedule(entry, to: room.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(atLimit)
                    .help(atLimit ? "Maximum of 4 schedules per room" : "Add schedule")
                    .accessibilityLabel("Add schedule")
                    .accessibilityHint(atLimit ? "Maximum of 4 schedules reached" : "")
                    Text("\(manager.schedules(for: room.id).count) of 4")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(atLimit ? AnyShapeStyle(Lumen.warning) : AnyShapeStyle(.tertiary))
                  main
                }
            }
        }
    }

    private var clockPickers: some View {
        HStack(spacing: 4) {
            Picker("Hour", selection: $draftHour) {
                ForEach(0..<24, id: \.self) { h in
                    Text(String(format: "%02d", h)).tag(h)
                }
            }
            .labelsHidden()
            .frame(width: 60)
            .accessibilityLabel("Hour")

            Text(":")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Picker("Minute", selection: $draftMinute) {
                ForEach(0..<60, id: \.self) { m in
                    Text(String(format: "%02d", m)).tag(m)
                }
            }
            .labelsHidden()
            .frame(width: 60)
            .accessibilityLabel("Minute")
        }
    }

    private var offsetPicker: some View {
        HStack(spacing: 4) {
            Picker("Offset", selection: $draftOffset) {
                ForEach([-120, -90, -60, -45, -30, -15, 0, 15, 30, 45, 60, 90, 120], id: \.self) { min in
                    let label: String = {
                        if min == 0 { return "exactly" }
                        let sign = min > 0 ? "+" : ""
                        return "\(sign)\(min)m"
                    }()
                    Text(label).tag(min)
                }
            }
            .labelsHidden()
            .frame(width: 80)
            .accessibilityLabel("Offset from \(draftAction == .atSunrise ? "sunrise" : "sunset")")
        }
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

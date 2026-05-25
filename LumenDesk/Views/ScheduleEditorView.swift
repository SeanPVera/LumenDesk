import SwiftUI

/// Sheet for managing daily automation schedules for a single room. Up to 4
/// entries per room; each entry fires at the same clock time every day.
struct ScheduleEditorView: View {
    @EnvironmentObject var manager: LightManager
    @Environment(\.dismiss) private var dismiss

    let room: Room

    @State private var draftHour: Int = 20
    @State private var draftMinute: Int = 0
    @State private var draftAction: ScheduleAction = .turnOff

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Schedules — \(room.name)")
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
        }
        .frame(width: 400, height: 380)
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
            .accessibilityLabel("\(entry.timeString) — \(entry.action.displayName)")
            .accessibilityHint(entry.isEnabled ? "Tap to disable" : "Tap to enable")

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.timeString)
                    .font(.callout.weight(.semibold).monospacedDigit())
                Text(entry.action.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                manager.deleteSchedule(entry.id, from: room.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Delete this schedule entry")
            .accessibilityLabel("Delete \(entry.timeString) \(entry.action.displayName)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .opacity(entry.isEnabled ? 1.0 : 0.5)
    }

    @ViewBuilder private var addRow: some View {
        let atLimit = manager.schedules(for: room.id).count >= 4
        HStack(spacing: 8) {
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
                ForEach([0, 15, 30, 45], id: \.self) { m in
                    Text(String(format: "%02d", m)).tag(m)
                }
            }
            .labelsHidden()
            .frame(width: 60)
            .accessibilityLabel("Minute")

            Picker("Action", selection: $draftAction) {
                ForEach(ScheduleAction.allCases, id: \.self) { action in
                    Text(action.displayName).tag(action)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 110)
            .accessibilityLabel("Action")

            Spacer()

            Button("Add") {
                manager.addSchedule(
                    ScheduleEntry(hour: draftHour, minute: draftMinute, action: draftAction),
                    to: room.id
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(atLimit)
            .help(atLimit
                  ? "Maximum of 4 schedules per room"
                  : "Add a \(draftAction.displayName) schedule at \(String(format: "%02d:%02d", draftHour, draftMinute))")
            .accessibilityLabel("Add schedule")
            .accessibilityHint(atLimit ? "Maximum of 4 schedules reached" : "")
        }
    }
}

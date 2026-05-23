import SwiftUI

/// A sheet listing the saved lighting scenes. Lets the user apply, rename,
/// delete existing scenes and capture the current state as a new one.
struct ScenesView: View {
    @EnvironmentObject var manager: LightManager
    @Environment(\.dismiss) private var dismiss

    @State private var newSceneName: String = ""
    @State private var renamingID: UUID?
    @State private var renameDraft: String = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scenes").font(.title3.weight(.semibold))
                    Text("Capture the current lighting state, recall it later in one tap.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            captureRow
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            if manager.scenes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(manager.scenes) { scene in
                            sceneRow(scene)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 460, height: 480)
    }

    private var captureRow: some View {
        HStack(spacing: 8) {
            TextField("New scene name (e.g. "Evening")", text: $newSceneName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(capture)
                .accessibilityLabel("Scene name")
            Button("Capture Current State", action: capture)
                .buttonStyle(.borderedProminent)
                .disabled(newSceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || manager.devices.isEmpty)
                .accessibilityLabel("Capture current lighting state")
                .accessibilityHint(manager.devices.isEmpty
                                   ? "No lights discovered yet"
                                   : "Saves all \(manager.devices.count) lights as a scene named \(newSceneName)")
        }
    }

    private func capture() {
        let trimmed = newSceneName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manager.captureScene(name: trimmed)
        newSceneName = ""
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No scenes yet").font(.headline)
            Text("Set the lights how you like them, then capture the moment above.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func sceneRow(_ scene: LightingScene) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(.purple)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                if renamingID == scene.id {
                    HStack(spacing: 4) {
                        TextField("Scene name", text: $renameDraft)
                            .textFieldStyle(.roundedBorder)
                            .focused($renameFocused)
                            .onSubmit { commitRename(scene) }
                            .onExitCommand { renamingID = nil }
                        Button { renamingID = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text(scene.name)
                        .font(.callout.weight(.medium))
                }
                Text("\(scene.snapshots.count) light\(scene.snapshots.count == 1 ? "" : "s") · captured \(scene.createdAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Apply") { manager.applyScene(scene) }
                .buttonStyle(.bordered)
                .accessibilityLabel("Apply \(scene.name)")
                .accessibilityHint("Restores \(scene.snapshots.count) light\(scene.snapshots.count == 1 ? "" : "s") to the saved state")

            Menu {
                Button("Rename…") { beginRename(scene) }
                Button("Delete Scene", role: .destructive) { manager.deleteScene(scene.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("More options for \(scene.name)")
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
    }

    private func beginRename(_ scene: LightingScene) {
        renameDraft = scene.name
        renamingID = scene.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename(_ scene: LightingScene) {
        manager.renameScene(scene.id, to: renameDraft)
        renamingID = nil
    }
}

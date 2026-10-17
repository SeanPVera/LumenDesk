import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

@main
struct LumenDeskApp: App {
    @StateObject private var manager = LightManager()

    var body: some Scene {
        #if os(macOS)
        macScenes
        #else
        WindowGroup {
            RootView()
                .environmentObject(manager)
                .preferredColorScheme(.light)
        }
        #endif
    }

    #if os(macOS)
    @SceneBuilder private var macScenes: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(manager)
                .frame(minWidth: 620, minHeight: 540)
                .preferredColorScheme(.light)
        }
        .windowResizability(.automatic)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan for Lights") {
                    manager.start(discover: false)
                    manager.scan()
                }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Cancel Queued Light Commands") { manager.cancelQueuedCommands() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(manager.commandPendingIDs.isEmpty)
            }
            CommandGroup(after: .importExport) {
                Button("Back Up Rooms & Looks\u{2026}") { exportConfiguration() }
                Button("Restore Rooms & Looks\u{2026}") { importConfiguration() }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Light Change") { manager.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!manager.canUndo)
                Button("Redo Light Change") { manager.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!manager.canRedo)
            }
        }

        Settings {
            NavigationStack { RoomCanvasSettingsView() }
                .environmentObject(manager)
                .preferredColorScheme(.light)
        }

        MenuBarExtra {
            MenuBarPopoverView()
                .environmentObject(manager)
                .preferredColorScheme(.light)
        } label: {
            LumenMark(size: 16, monochrome: true)
                .foregroundStyle(moodColor)
        }
        .menuBarExtraStyle(.window)
    }

    // MARK: - Mood ring colour for the menu-bar icon

    private var moodColor: Color {
        let on = manager.devices.filter { $0.isOn }
        guard !on.isEmpty else { return .yellow }
        let hsbs = on.map { $0.color.hsbComponents }
        let avgH = hsbs.reduce(0.0) { $0 + $1.h } / Double(on.count)
        let avgS = hsbs.reduce(0.0) { $0 + $1.s } / Double(on.count)
        let avgB = on.reduce(0.0) { $0 + $1.brightness } / Double(on.count)
        return Color(hue: avgH, saturation: avgS, brightness: max(0.6, avgB))
    }

    // MARK: - Export / Import

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "LumenDesk-Rooms-and-Looks.json"
        panel.title = "Back Up Rooms & Looks"
        // Dismissing the panel is a cancel, not a failure.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        manager.exportConfiguration(to: url)
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Restore Rooms & Looks"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            manager.publishError("Restore failed \u{2014} could not read \u{201C}\(url.lastPathComponent)\u{201D}.")
            return
        }

        manager.requestConfigurationImport(data, fileName: url.lastPathComponent)
    }
    #endif
}

// MARK: - Root

/// Decides between the first-run guided setup and the main app. The
/// `hasOnboarded` flag is persisted, so the walkthrough only ever appears on a
/// fresh install (or after the user resets it).
struct RootView: View {
    @EnvironmentObject var manager: LightManager
    @AppStorage("LumenDesk.hasOnboarded.v1") private var hasOnboarded = false
    @AppStorage(AppPreferenceKey.quietInterface) private var quietInterface = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoomCanvasShellView(
            startInSetup: !hasOnboarded,
            onPrepared: { hasOnboarded = true }
        )
        .animation(reduceMotion || quietInterface ? nil : .easeInOut(duration: 0.18), value: hasOnboarded)
        .managedActionConfirmations(manager)
        .onAppear { startReturningWorkspace() }
        .onChange(of: hasOnboarded) { _ in startReturningWorkspace() }
        .onChange(of: manager.isDemoMode) { _ in startReturningWorkspace() }
    }

    private func startReturningWorkspace() {
        // First-run Prepare owns the first scan and permission prompt. The
        // transport actors still initialize so its Find step can scan.
        manager.start(discover: hasOnboarded)
    }
}

private struct ConfirmationPresentationModifier: ViewModifier {
    @ObservedObject var coordinator: ConfirmationCoordinator

    func body(content: Content) -> some View {
        content.alert(item: Binding(
            get: { coordinator.pendingRequest },
            set: { if $0 == nil { coordinator.dismissPendingRequest() } }
        )) { request in
            Alert(
                title: Text(request.title),
                message: Text(request.message),
                primaryButton: request.isDestructive
                    ? .destructive(Text(request.confirmTitle), action: coordinator.confirmPendingRequest)
                    : .default(Text(request.confirmTitle), action: coordinator.confirmPendingRequest),
                secondaryButton: .cancel(coordinator.cancelPendingRequest)
            )
        }
    }
}

extension View {
    func managedActionConfirmations(_ manager: LightManager) -> some View {
        modifier(ConfirmationPresentationModifier(coordinator: manager.confirmationCoordinator))
    }
}

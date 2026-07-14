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
                .preferredColorScheme(.dark)
                .onAppear { manager.start() }
        }
        #endif
    }

    #if os(macOS)
    @SceneBuilder private var macScenes: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(manager)
                .frame(minWidth: 520, minHeight: 380)
                .preferredColorScheme(.dark)
                .onAppear { manager.start() }
        }
        .windowResizability(.automatic)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan for Lights") { manager.scan() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Toggle All Lights") {
                    manager.setAllPower(on: !manager.devices.contains(where: { $0.isOn }))
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("Cancel Queued Light Commands") { manager.cancelQueuedCommands() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(manager.commandPendingIDs.isEmpty)
            }
            CommandGroup(after: .importExport) {
                Button("Export Configuration\u{2026}") { exportConfiguration() }
                Button("Import Configuration\u{2026}") { importConfiguration() }
            }
            CommandMenu("View") {
                Picker("Layout", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: "LumenDesk.workspaceLayout.v1") ?? WorkspaceLayout.automatic.rawValue },
                    set: { UserDefaults.standard.set($0, forKey: "LumenDesk.workspaceLayout.v1") }
                )) { ForEach(WorkspaceLayout.allCases) { Text($0.title).tag($0.rawValue) } }
                Divider()
                Picker("Density", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: "LumenDesk.interfaceDensity.v1") ?? InterfaceDensity.comfortable.rawValue },
                    set: { UserDefaults.standard.set($0, forKey: "LumenDesk.interfaceDensity.v1") }
                )) { ForEach(InterfaceDensity.allCases) { Text($0.title).tag($0.rawValue) } }
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
            LumenDeskSettingsView()
                .environmentObject(manager)
                .preferredColorScheme(.dark)
        }

        MenuBarExtra {
            MenuBarPopoverView()
                .environmentObject(manager)
                .preferredColorScheme(.dark)
        } label: {
            Image(systemName: "lightbulb.fill")
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
        guard let data = manager.exportConfigurationData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "LumenDesk-Configuration.json"
        panel.title = "Export LumenDesk Configuration"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import LumenDesk Configuration"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }

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

    var body: some View {
        ZStack {
            if hasOnboarded {
                LumenDeskShellView()
                    .transition(.opacity)
            } else {
                OnboardingView(onFinish: { hasOnboarded = true })
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: hasOnboarded)
        .managedActionConfirmations(manager)
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

import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct LumenDeskApp: App {
    @StateObject private var manager = LightManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .frame(minWidth: 520, minHeight: 380)
                .onAppear { manager.start() }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan for Lights") { manager.scan() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Toggle All Lights") {
                    manager.setAllPower(on: !manager.devices.contains(where: { $0.isOn }))
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(after: .importExport) {
                Button("Export Configuration\u{2026}") { exportConfiguration() }
                Button("Import Configuration\u{2026}") { importConfiguration() }
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

        MenuBarExtra {
            MenuBarPopoverView()
                .environmentObject(manager)
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

        // UX 5: Warn before silently overwriting existing configuration.
        let alert = NSAlert()
        alert.messageText = "Replace Current Configuration?"
        let roomWord = manager.rooms.count == 1 ? "room" : "rooms"
        let sceneWord = manager.scenes.count == 1 ? "scene" : "scenes"
        alert.informativeText = "Importing \"\(url.lastPathComponent)\" will overwrite \(manager.rooms.count) \(roomWord) and \(manager.scenes.count) \(sceneWord), along with all favorites and custom names. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        manager.importRoomsData(data)
    }
}

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
                Button("Export Configuration…") { exportConfiguration() }
                Button("Import Configuration…") { importConfiguration() }
            }
        }
    }

    private func exportConfiguration() {
        guard let data = manager.exportRoomsData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "LumenDesk-Rooms.json"
        panel.title = "Export Room Configuration"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import Room Configuration"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        manager.importRoomsData(data)
    }
}

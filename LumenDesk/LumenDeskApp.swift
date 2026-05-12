import SwiftUI

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
            }
        }
    }
}

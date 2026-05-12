import SwiftUI

@main
struct LumenDeskApp: App {
    @StateObject private var manager = LightManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 380)
                #endif
                .onAppear { manager.start() }
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan for Lights") { manager.scan() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        #endif
    }
}

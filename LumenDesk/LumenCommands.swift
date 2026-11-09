import SwiftUI

// MARK: - App commands
//
// The menu bar from the Polar "App menus" artboard. Commands that act on
// window state (which room is open, what is selected) are posted on the
// command bus and handled by `RoomCanvasShellView`, which owns that state;
// commands that act on lights go straight to LightManager.

enum LumenCommand: String {
    case newLook
    case addLights
    case openLooks
    case openLive
    case identifySelected
    case openLightPage
}

extension Notification.Name {
    static let lumenCommand = Notification.Name("LumenDesk.command")
}

enum LumenCommandBus {
    static func post(_ command: LumenCommand) {
        NotificationCenter.default.post(name: .lumenCommand, object: nil,
                                        userInfo: ["command": command.rawValue])
    }

    static func command(from notification: Notification) -> LumenCommand? {
        (notification.userInfo?["command"] as? String).flatMap(LumenCommand.init(rawValue:))
    }
}

#if os(macOS)
struct LumenDeskCommands: Commands {
    @ObservedObject var manager: LightManager

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Look\u{2026}") { LumenCommandBus.post(.newLook) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Add Lights\u{2026}") { LumenCommandBus.post(.addLights) }
                .keyboardShortcut("n", modifiers: .command)
        }

        CommandGroup(before: .toolbar) {
            ForEach(Array(manager.rooms.prefix(9).enumerated()), id: \.element.id) { index, room in
                Button(room.name) {
                    UserDefaults.standard.set(room.id.uuidString, forKey: AppPreferenceKey.roomCanvasOpenRequest)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            if !manager.rooms.isEmpty { Divider() }
            Button("Looks") { LumenCommandBus.post(.openLooks) }
                .keyboardShortcut("l", modifiers: .command)
            Button("Live") { LumenCommandBus.post(.openLive) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
        }

        CommandMenu("Lights") {
            Button("All Off") { manager.setAllPower(on: false) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(manager.devices.isEmpty)
            Button("All On") { manager.setAllPower(on: true) }
                .disabled(manager.devices.isEmpty)
            Divider()
            Button("Identify Selected") { LumenCommandBus.post(.identifySelected) }
                .keyboardShortcut("i", modifiers: .command)
            Button("Open Light Page") { LumenCommandBus.post(.openLightPage) }
                .keyboardShortcut(.return, modifiers: .command)
            Divider()
            Button("Refresh Network") {
                manager.start(discover: false)
                manager.scan()
            }
            .keyboardShortcut("r", modifiers: .command)
            Button("Cancel Queued Light Commands") { manager.cancelQueuedCommands() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(manager.commandPendingIDs.isEmpty)
        }
    }
}
#endif

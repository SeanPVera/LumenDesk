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
    case saveLook
    case duplicateLook
}

extension Notification.Name {
    static let lumenCommand = Notification.Name("LumenDesk.command")
    /// Posted by the room window when ⌘S should open the Looks bar's
    /// "Save current as a Look" prompt (no composer is open).
    static let lumenSaveCurrentLook = Notification.Name("LumenDesk.saveCurrentLook")
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

        CommandGroup(after: .saveItem) {
            Button("Save Current as Look\u{2026}") { LumenCommandBus.post(.saveLook) }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(manager.rooms.isEmpty)
            Button("Duplicate Look") { LumenCommandBus.post(.duplicateLook) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(manager.scenes.isEmpty)
        }

        CommandGroup(replacing: .help) {
            Link("LumenDesk Help", destination: URL(string: "https://github.com/SeanPVera/LumenDesk#readme")!)
            Divider()
            Text("Rooms \u{2318}1\u{2013}9 \u{00B7} Looks \u{2318}L \u{00B7} Live \u{21E7}\u{2318}L")
            Text("Light page \u{2318}\u{21A9} \u{00B7} Back \u{2318}[ \u{00B7} Identify \u{2318}I")
            Text("Save Look \u{2318}S \u{00B7} Duplicate Look \u{2318}D")
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

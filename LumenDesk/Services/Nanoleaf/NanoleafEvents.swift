import Foundation

/// A touch gesture, by the IDs the OpenAPI documents (3.5.2.4.1).
enum NanoleafGesture: Int, Equatable {
    case singleTap = 0
    case doubleTap = 1
    case swipeUp = 2
    case swipeDown = 3
    case swipeLeft = 4
    case swipeRight = 5

    var displayName: String {
        switch self {
        case .singleTap: return "Tap"
        case .doubleTap: return "Double tap"
        case .swipeUp: return "Swipe up"
        case .swipeDown: return "Swipe down"
        case .swipeLeft: return "Swipe left"
        case .swipeRight: return "Swipe right"
        }
    }
}

/// Something the controller announced on its event stream (`GET /events`).
/// These are how LumenDesk learns that the Nanoleaf app, a physical button,
/// HomeKit or a touch changed the wall, without polling for it.
enum NanoleafEvent: Equatable {
    /// Power, brightness, colour or mode changed (event type 1).
    case stateChanged
    /// The arrangement or its global orientation changed (event type 2).
    case layoutChanged
    /// The selected effect changed (event type 3), with its name when given.
    case effectChanged(String?)
    /// A touch on the wall (event type 4). The panel is only known for taps.
    case touch(gesture: NanoleafGesture, panelID: Int?)
}

/// Incremental parser for the `text/event-stream` framing the controller
/// uses: an `id:` line naming the event type, then a `data:` line carrying
/// one JSON object. Each data line is complete on its own, so events are
/// emitted as soon as it arrives; that works whether or not the line reader
/// in use passes the blank separator lines through.
struct NanoleafEventStreamParser {
    private var eventType: Int?

    /// Consumes one line (without its terminator) and returns any events it
    /// completed. Anything unreadable is dropped rather than guessed at.
    mutating func consume(line rawLine: String) -> [NanoleafEvent] {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            eventType = nil
            return []
        }
        if line.hasPrefix(":") { return [] } // comment / keep-alive
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "id":
            eventType = Int(value.trimmingCharacters(in: .whitespaces))
        case "data":
            guard let eventType else { return [] }
            return Self.events(type: eventType, data: value)
        default:
            break
        }
        return []
    }

    static func events(type: Int, data: String) -> [NanoleafEvent] {
        switch type {
        case 1: return [.stateChanged]
        case 2: return [.layoutChanged]
        case 3:
            let entries = decode(data)
            let name = entries.lazy.compactMap { $0["value"] as? String }.first
            return [.effectChanged(name)]
        case 4:
            return decode(data).compactMap { entry in
                guard let raw = (entry["gesture"] as? NSNumber)?.intValue,
                      let gesture = NanoleafGesture(rawValue: raw) else { return nil }
                let panel = (entry["panelId"] as? NSNumber)?.intValue
                return .touch(gesture: gesture, panelID: panel.flatMap { $0 >= 0 ? $0 : nil })
            }
        default:
            return []
        }
    }

    private static func decode(_ data: String) -> [[String: Any]] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              let events = object["events"] as? [[String: Any]] else { return [] }
        return events
    }
}

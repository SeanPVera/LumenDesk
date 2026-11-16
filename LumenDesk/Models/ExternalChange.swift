import Foundation

/// What LumenDesk can truthfully say about a change it did not confirm
/// making: which light, what it reported before and after, when the
/// difference was first read, and what evidence there is about the cause.
///
/// LIFX and Govee LAN replies carry a light's state and nothing about who set
/// it, so for those brands the sender cannot be read off the wire and this
/// type says so instead of naming an app. Nanoleaf names the scene its
/// controller is running, which is evidence about the cause, not a sender.
struct ExternalChange: Equatable, Identifiable {
    /// One channel a light reported differently.
    enum Field: String, CaseIterable {
        case power, brightness, colour, whitePoint, mode

        var title: String {
            switch self {
            case .power: return "Power"
            case .brightness: return "Brightness"
            case .colour: return "Colour"
            case .whitePoint: return "White point"
            case .mode: return "Mode"
            }
        }
    }

    struct Difference: Equatable, Identifiable {
        let field: Field
        let before: String
        let after: String

        var id: String { field.rawValue }
        var summary: String { "\(field.title) \(before) \u{2192} \(after)" }
    }

    /// What LumenDesk observed around the change. None of it is a sender.
    enum Evidence: Equatable {
        /// A Nanoleaf panel reported a tap moments before the reading.
        case panelTouched
        /// A Nanoleaf controller is running a scene stored on it.
        case controllerScene(name: String)
        /// A Nanoleaf controller reports a mode LumenDesk did not start.
        case foreignMode(detail: String)
        /// The light had stopped answering before the reading that differed.
        case returnedAfterSilence
        /// The reply says nothing about the cause.
        case unreported
    }

    /// How long after LumenDesk sends something no reading confirms (a
    /// segment or matrix layout, a command that timed out) a differing
    /// reading is still that send arriving, and so not an outside change:
    /// two refresh intervals.
    static let ownSendWindow: TimeInterval = 60
    /// How long after a panel tap a differing reading is put down to it.
    static let touchWindow: TimeInterval = 10

    let deviceID: String
    /// "LIFX", "Govee" or "Nanoleaf".
    let vendor: String
    /// What the light reported the last time it agreed with LumenDesk.
    let before: ConfirmedDeviceState
    /// The newest reading that differs from `before`.
    private(set) var after: ConfirmedDeviceState
    /// When LumenDesk first read a difference. The change itself happened
    /// somewhere between `before.confirmedAt` and this.
    let noticedAt: Date
    private(set) var evidence: Evidence

    var id: String { deviceID }

    init(deviceID: String, vendor: String, before: ConfirmedDeviceState,
         after: ConfirmedDeviceState, noticedAt: Date, evidence: Evidence) {
        self.deviceID = deviceID
        self.vendor = vendor
        self.before = before
        self.after = after
        self.noticedAt = noticedAt
        self.evidence = evidence
    }

    /// A later reading that still differs from `before`. The first cause
    /// found is kept unless this reading is the first to offer one.
    mutating func update(after reading: ConfirmedDeviceState, evidence newEvidence: Evidence) {
        after = reading
        if evidence == .unreported { evidence = newEvidence }
    }

    // MARK: What changed

    /// Same thresholds the manager uses to decide a reading differs at all,
    /// so a flagged light always has at least one difference to show.
    static func materiallyDiffers(_ lhs: ConfirmedDeviceState, _ rhs: ConfirmedDeviceState) -> Bool {
        lhs.isOn != rhs.isOn
            || abs(lhs.brightness - rhs.brightness) > 0.03
            || lhs.colorHex != rhs.colorHex
            || abs(lhs.kelvin - rhs.kelvin) > 100
            || lhs.nanoleafAppearance != rhs.nanoleafAppearance
    }

    var differences: [Difference] {
        var found: [Difference] = []
        if before.isOn != after.isOn {
            found.append(Difference(field: .power, before: before.isOn ? "On" : "Off",
                                    after: after.isOn ? "On" : "Off"))
        }
        if before.nanoleafAppearance != after.nanoleafAppearance {
            found.append(Difference(field: .mode, before: Self.modeName(before.nanoleafAppearance),
                                    after: Self.modeName(after.nanoleafAppearance)))
        }
        if abs(before.brightness - after.brightness) > 0.03 {
            found.append(Difference(field: .brightness, before: Self.percent(before.brightness),
                                    after: Self.percent(after.brightness)))
        }
        if before.colorHex != after.colorHex {
            found.append(Difference(field: .colour, before: before.colorHex, after: after.colorHex))
        }
        if abs(before.kelvin - after.kelvin) > 100 {
            found.append(Difference(field: .whitePoint, before: "\(before.kelvin) K",
                                    after: "\(after.kelvin) K"))
        }
        return found
    }

    /// "Brightness 40% → 80%, Colour #FF8800 → #3366FF"
    var differenceSummary: String {
        differences.map(\.summary).joined(separator: ", ")
    }

    static func percent(_ value: Double) -> String {
        "\(Int((max(0, min(1, value)) * 100).rounded()))%"
    }

    static func modeName(_ appearance: NanoleafAppearance?) -> String {
        guard let appearance else { return "Not reported" }
        switch appearance.colorMode {
        case "hs": return "One colour"
        case "ct": return "White"
        case "effect":
            if let effect = appearance.effect { return "Scene \u{201C}\(effect)\u{201D}" }
            return "Panel layout or stream"
        default: return appearance.colorMode
        }
    }

    /// `#RRGGBB` as an integer, for drawing the two colours as swatches.
    static func rgbValue(hex: String) -> UInt? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6 else { return nil }
        return UInt(digits, radix: 16)
    }

    // MARK: When

    /// The change happened inside this window: after the last reading that
    /// agreed with LumenDesk, and no later than the first that did not.
    var window: ClosedRange<Date> {
        min(before.confirmedAt, noticedAt)...noticedAt
    }

    /// A window this short is one refresh interval, so "about then" is fair.
    var isPinpointed: Bool {
        window.upperBound.timeIntervalSince(window.lowerBound) <= 90
    }

    func timingStatement(format: (Date) -> String) -> String {
        if isPinpointed {
            return "Changed at about \(format(noticedAt))."
        }
        return "Changed between \(format(window.lowerBound)) and \(format(window.upperBound)). LumenDesk had no reading from this light in between."
    }

    // MARK: Where from

    /// True when the origin statement is drawn from circumstance and may be
    /// wrong, false when it only restates what the light reported.
    var originIsInference: Bool {
        switch evidence {
        case .panelTouched, .returnedAfterSilence: return true
        case .controllerScene, .foreignMode, .unreported: return false
        }
    }

    /// A short label for the cause, as far as the evidence goes.
    var originTitle: String {
        switch evidence {
        case .panelTouched: return "Probably a tap on the panels"
        case .controllerScene(let name): return "Scene \u{201C}\(name)\u{201D} on the controller"
        case .foreignMode: return "Another app"
        case .returnedAfterSilence: return "Probably lost power"
        case .unreported: return "Sender not reported"
        }
    }

    /// One or two sentences on the cause. States what is known and stops.
    var originStatement: String {
        switch evidence {
        case .panelTouched:
            return "A panel reported a tap moments before this reading, so the change was most likely made at the wall."
        case .controllerScene(let name):
            return "The controller is running its stored scene \u{201C}\(name)\u{201D}. A scene starts from the controller\u{2019}s button, the Nanoleaf app, HomeKit or a voice assistant; the controller does not say which."
        case .foreignMode(let detail):
            return "\(detail). The controller does not name the app."
        case .returnedAfterSilence:
            return "This light had stopped answering before this reading. A light that loses power at a wall switch or socket comes back in its power-on state, so that is the likely cause."
        case .unreported:
            return "\(vendor) lights report their state and nothing about who set it. LumenDesk on this device had no command in flight, so something else did: the \(vendor) app, a voice assistant or home hub, a schedule in another app, LumenDesk on another device, or a physical switch."
        }
    }
}

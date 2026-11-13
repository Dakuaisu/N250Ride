import Foundation
import Observation
import RideCore

/// Every phone-link feature the N250 owner's manual describes, each with the bytes
/// that should trigger it (or what to do in real life), and what the rider saw.
/// The report goes back to development to fill the gaps in the protocol.
@MainActor
@Observable
final class ManualChecklist {
    enum Outcome: String, Codable, CaseIterable {
        case untested, asManual, different, nothing

        var label: String {
            switch self {
            case .untested: "Not tried"
            case .asManual: "As manual"
            case .different: "Different"
            case .nothing: "Nothing"
            }
        }
    }

    struct Result: Codable, Equatable {
        var outcome: Outcome = .untested
        var note = ""
    }

    struct Check: Identifiable {
        let id: String
        let title: String
        /// What the manual says should appear, or what this probe is for.
        let expected: String
        /// Real-world steps when no bytes can trigger it.
        var howTo: String?
        var steps: [BluetoothConsole.Preset] = []
    }

    struct Section: Identifiable {
        var id: String { title }
        let title: String
        let footer: String
        let checks: [Check]
    }

    private(set) var results: [String: Result]
    private let defaults: UserDefaults
    private static let key = "manualChecklistResults"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        results = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: Result].self, from: $0) } ?? [:]
    }

    func result(_ id: String) -> Result { results[id] ?? Result() }

    func set(_ id: String, outcome: Outcome) {
        results[id, default: Result()].outcome = outcome
        persist()
    }

    func set(_ id: String, note: String) {
        results[id, default: Result()].note = note
        persist()
    }

    func reset() {
        results = [:]
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(results), forKey: Self.key)
    }

    func tested(in sections: [Section]) -> Int {
        sections.flatMap(\.checks).filter { result($0.id).outcome != .untested }.count
    }

    func report(_ sections: [Section], appVersion: String, statusProfile: GeneralStatusProfile?,
                consoleLog: String) -> String {
        var lines = ["N250 Ride - manual checklist",
                     "App \(appVersion), status packet \(statusProfile?.rawValue ?? "off"), "
                         + "\(tested(in: sections))/\(sections.flatMap(\.checks).count) tried", ""]
        for section in sections {
            lines.append("## \(section.title)")
            for check in section.checks {
                let r = result(check.id)
                let note = r.note.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append("[\(r.outcome.label)] \(check.id) \(check.title)" + (note.isEmpty ? "" : " - \(note)"))
            }
            lines.append("")
        }
        lines.append("## Console log")
        lines.append(consoleLog)
        return lines.joined(separator: "\n")
    }

    // MARK: Catalogue

    static func sections(statusProfile: GeneralStatusProfile) -> [Section] {
        [navigation(), rerouting(), calls(statusProfile), phoneStatus(statusProfile), alerts(), arrows()]
    }

    private static let nav = ClusterGATT.navigation
    private static let status = ClusterGATT.generalStatus

    /// A navigation frame with the given icon and distances, ETA 9:30 AM unless set.
    static func frame(_ icon: UInt8, step: Int = 300, total: Int = 4_200, hour: Int = 9, minute: Int = 30,
                      pm: Bool = false, exit: Int = 0, edit: (inout [UInt8]) -> Void = { _ in }) -> [UInt8] {
        let known = ClusterIcon.isKnown(icon)
        var b = (try? TbtFrame.encode(TbtFields(frameType: .navigation, icon: known ? icon : ClusterIcon.straight,
                                                 isAM: !pm, stepMetres: step, totalMetres: total, etaHour: hour,
                                                 etaMinute: minute, roundaboutExit: exit))) ?? TbtFrame.stop()
        b[1] = icon
        edit(&b)
        b[47] = TbtFrame.checksum(b)
        return b
    }

    static func gps(_ value: UInt8) -> (inout [UInt8]) -> Void {
        { $0[12] = ($0[12] & ~0x0C) | (value << 2) }
    }

    private static func send(_ name: String, _ bytes: [UInt8], to target: String = nav,
                             ends: Bool = false) -> BluetoothConsole.Preset {
        BluetoothConsole.Preset(name: name, target: target, bytes: bytes, endsStatusTest: ends)
    }

    private static func navigation() -> Section {
        Section(title: "Navigation (manual item 20)", footer: "Each frame stays on the dashboard for 5 s.", checks: [
            Check(id: "nav.turn", title: "Turn ahead",
                  expected: "Turn arrow; top display TURN-300; bottom toggles ETA 9:30 and ETD 4.2 km.",
                  steps: [send("Turn right, 300 m", frame(ClusterIcon.turnRight))]),
            Check(id: "nav.straight", title: "Straight ahead",
                  expected: "Straight arrow; top display shows the distance without TURN (1.5 km).",
                  steps: [send("Straight, 1.5 km", frame(ClusterIcon.straight, step: 1_500))]),
            Check(id: "nav.uturn", title: "U-turn ahead",
                  expected: "U-turn arrow; top display UTURN-250.",
                  steps: [send("U-turn right, 250 m", frame(ClusterIcon.uTurnRight, step: 250)),
                          send("U-turn left, 250 m", frame(ClusterIcon.uTurnLeft, step: 250))]),
            Check(id: "nav.blink", title: "Turn close by (blinking)",
                  expected: "Arrow blinks when the turn is under 100 m.",
                  steps: [send("Turn left, 80 m, blinking", frame(ClusterIcon.turnLeft + ClusterIcon.blinkOffset, step: 80))]),
            Check(id: "nav.eta", title: "ETA / ETD toggle",
                  expected: "Bottom display alternates ETA (arrival time) and ETD (distance left). Note how often.",
                  steps: [send("ETA 6:45 PM, 12.7 km left", frame(ClusterIcon.turnRight, step: 2_350, total: 12_700,
                                                                  hour: 6, minute: 45, pm: true))]),
            Check(id: "nav.units", title: "Metres and kilometres",
                  expected: "Write exactly what each shows: 2.35 km step (may read 2.34), 800 m left.",
                  steps: [send("Step 2,350 m", frame(ClusterIcon.turnLeft, step: 2_350, total: 9_000)),
                          send("800 m left in total", frame(ClusterIcon.turnLeft, step: 200, total: 800))]),
            Check(id: "nav.destination", title: "Destination reached",
                  expected: "DESTINATION in the top display, REACHED in the bottom.",
                  steps: [send("Destination reached", frame(ClusterIcon.destinationReached, step: 0, total: 0))]),
            Check(id: "nav.nogps", title: "No GPS",
                  expected: "NO GPS. (Confirmed 13 Nov: GPS flag 0.)",
                  steps: [send("Turn right, GPS off", frame(ClusterIcon.turnRight, edit: gps(0)))]),
            Check(id: "nav.start", title: "Navigation start",
                  expected: "What the official app sends first: straight arrow, everything else 0.",
                  steps: [send("Start frame", TbtFrame.start())]),
            Check(id: "nav.stop", title: "Navigation off",
                  expected: "Arrows and navigation text disappear. Send a turn first, then the stop frame.",
                  steps: [send("Turn right, 300 m", frame(ClusterIcon.turnRight)),
                          send("Stop frame", TbtFrame.stop())]),
        ])
    }

    private static func rerouting() -> Section {
        Section(title: "REROUTING - find the signal", footer: "The manual lists REROUTING but the protocol notes don't say how to trigger it. Try each; note any that shows it.", checks: [
            Check(id: "reroute.wrongway", title: "Wrong-way icon (66)",
                  expected: "Strongest guess: Bajaj's app sends this when you leave the route.",
                  steps: [send("Icon 66", frame(ClusterIcon.wrongWay)),
                          send("Icon 66, blinking (98)", frame(ClusterIcon.wrongWay + ClusterIcon.blinkOffset, step: 80))]),
            Check(id: "reroute.gps3", title: "GPS status 3",
                  expected: "0 = NO GPS, 1 = normal, 2 = arrow only; 3 is the unused value.",
                  steps: [send("Turn right, GPS status 3", frame(ClusterIcon.turnRight, edit: gps(3)))]),
            Check(id: "reroute.gaps", title: "Unlisted icons 77, 83, 87",
                  expected: "Gaps in the known icon list.",
                  steps: [send("Icon 77", frame(77)), send("Icon 83", frame(83)), send("Icon 87", frame(87))]),
            Check(id: "reroute.empty", title: "Arrow with no distances",
                  expected: "Bajaj's app may send a blank frame while recalculating.",
                  steps: [send("Straight, 0 m, 0 m left", frame(ClusterIcon.straight, step: 0, total: 0, hour: 0, minute: 0))]),
        ])
    }

    private static func calls(_ profile: GeneralStatusProfile) -> Section {
        let ended = send("Call ended", GeneralStatusEncoder.encode(profile, GeneralStatusFields(heartbeat: 9, callState: .ended)),
                         to: status, ends: true)
        func call(_ state: ClusterCallState, _ name: String, heartbeat: UInt8) -> [UInt8] {
            GeneralStatusEncoder.encode(profile, GeneralStatusFields(heartbeat: heartbeat, callState: state, callerName: name))
        }
        return Section(title: "Calls (manual items 25, 28)", footer: "Sent as status packets; the app's own status packets pause until you send Call ended or leave this screen.", checks: [
            Check(id: "call.incomingPacket", title: "Incoming call (sent by N250 Ride)",
                  expected: "Call icon blinks; caller name TEST in the bottom display.",
                  steps: [send("Incoming call, TEST", call(.incoming, "TEST", heartbeat: 1), to: status), ended]),
            Check(id: "call.numberPacket", title: "Incoming call with a number",
                  expected: "The manual says name or mobile number is shown.",
                  steps: [send("Incoming call, 9876543210", call(.incoming, "9876543210", heartbeat: 2), to: status), ended]),
            Check(id: "call.activePacket", title: "Call answered (sent by N250 Ride)",
                  expected: "Call icon steady once the call is received.",
                  steps: [send("Call in progress, TEST", call(.active, "TEST", heartbeat: 3), to: status), ended]),
            Check(id: "call.outgoingPacket", title: "Outgoing call (not in the manual)",
                  expected: "Unknown: note anything shown.",
                  steps: [send("Outgoing call, TEST", call(.outgoing, "TEST", heartbeat: 4), to: status), ended]),
            Check(id: "call.real", title: "Real incoming call",
                  expected: "Call icon blinks, caller shows, and both stay until you answer or it stops ringing.",
                  howTo: "Keep N250 Ride open and connected. Ask someone to call you and let it ring for 15 s."),
            Check(id: "call.accept", title: "Accept with Mode",
                  expected: "Press Mode under 1 s while ringing: the call is answered and the icon goes steady.",
                  howTo: "During a real call, press Mode briefly."),
            Check(id: "call.reject", title: "Reject with Mode",
                  expected: "Hold Mode over 3 s while ringing: the call is rejected.",
                  howTo: "During a real call, hold Mode for 4 s."),
        ])
    }

    private static func phoneStatus(_ profile: GeneralStatusProfile) -> Section {
        func packet(battery: Int = 3, signal: Int = 4, heartbeat: UInt8) -> [UInt8] {
            GeneralStatusEncoder.encode(profile, GeneralStatusFields(batteryBars: battery, signal: signal, heartbeat: heartbeat))
        }
        return Section(title: "Phone status (manual items 26, 27)", footer: "Sent as status packets. Leave this screen to hand the status channel back to the app.", checks: [
            Check(id: "status.battery", title: "Phone battery level",
                  expected: "Battery bars follow the value. Note how many bars each shows.",
                  steps: (0...4).map { send("Battery \($0)", packet(battery: $0, heartbeat: UInt8(20 + $0)), to: status) }),
            Check(id: "status.signal", title: "Phone network range",
                  expected: "Signal bars follow the value. Note how many bars each shows.",
                  steps: [0, 2, 4, 7].map { send("Signal \($0)", packet(signal: $0, heartbeat: UInt8(30 + $0)), to: status) }),
        ])
    }

    private static func alerts() -> Section {
        Section(title: "Alerts and Bluetooth (manual items 16-18)", footer: "Earlier test: the bike acknowledged the sent alerts but showed nothing. The real-life checks tell us if the dashboard gets them from iOS instead.", checks: [
            Check(id: "alert.missedPacket", title: "Missed call (sent by N250 Ride)",
                  expected: "Missed call icon.",
                  steps: [send("Missed call from TEST", PhonePackets.missedCall(name: "TEST", number: "9999999999",
                                                                             epochSeconds: UInt32(Date().timeIntervalSince1970)),
                               to: PhonePackets.missedCallCharacteristic)]),
            Check(id: "alert.messagePacket", title: "Message (sent by N250 Ride)",
                  expected: "Message icon blinks 6 s, then stays on.",
                  steps: [send("SMS from TEST", PhonePackets.alert(.sms, sender: "TEST", epochSeconds: UInt32(Date().timeIntervalSince1970)),
                               to: PhonePackets.alertCharacteristic),
                          send("WhatsApp from TEST", PhonePackets.alert(.whatsApp, sender: "TEST",
                                                                        epochSeconds: UInt32(Date().timeIntervalSince1970)),
                               to: PhonePackets.alertCharacteristic)]),
            Check(id: "alert.realMissed", title: "Real missed call",
                  expected: "Missed call icon after the call stops ringing.",
                  howTo: "Ask someone to call you and let it ring out without answering."),
            Check(id: "alert.realSms", title: "Real SMS",
                  expected: "Message icon blinks 6 s, then stays on.",
                  howTo: "Ask someone to send you an SMS."),
            Check(id: "alert.realWhatsApp", title: "Real WhatsApp message",
                  expected: "Message icon blinks 6 s, then stays on (the manual says all messages).",
                  howTo: "Ask someone to send you a WhatsApp message."),
            Check(id: "alert.ignition", title: "Message icon after ignition off/on",
                  expected: "Message icon gone until a new message arrives.",
                  howTo: "After a message icon is showing, switch the ignition off and on."),
            Check(id: "bt.icon", title: "Bluetooth icon",
                  expected: "Blinks for 10 s after ignition on; steady while N250 Ride is connected.",
                  howTo: "Switch the ignition on with N250 Ride open, and watch the Bluetooth icon."),
        ])
    }

    private static func arrows() -> Section {
        let icons = ClusterIcon.solid.sorted()
        return Section(title: "Every arrow", footer: "Checks each icon number draws the arrow its name says.", checks: icons.map { icon in
            let roundabout = icon == ClusterIcon.roundaboutLeft || icon == ClusterIcon.roundaboutRight
            return Check(id: "icon.\(icon)", title: "\(icon) \(ClusterIcon.name(icon))",
                         expected: roundabout ? "Roundabout, exit value 4." : ClusterIcon.name(icon),
                         steps: [send("Send \(icon)", frame(icon, exit: roundabout ? 4 : 0))])
        })
    }
}

import RideCore
import SwiftUI

/// Parked-bike test panel and privacy-restricted diagnostics. Test frames are
/// locked while any navigation or simulation runs.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var rightGlyph = false
    @State private var nibble = 0

    private let samples: [(String, Maneuver, Int, RoundaboutDirection?)] = [
        ("Left 250 m", .turnLeft, 250, nil),
        ("Right 250 m", .turnRight, 250, nil),
        ("Straight 1.2 km", .straight, 1_200, nil),
        ("U-turn right 80 m", .uTurnRight, 80, nil),
        ("Roundabout, straight on", .roundaboutClockwise, 300, .straight),
        ("Roundabout, right", .roundaboutClockwise, 300, .right),
        ("Roundabout, slight left", .roundaboutClockwise, 300, .slightLeft),
        ("Anticlockwise roundabout, left", .roundaboutCounterClockwise, 300, .left),
        ("Arrival", .arrival, 0, nil),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        BluetoothConsoleView()
                    } label: {
                        Label("Bluetooth console", systemImage: "terminal")
                    }
                    .accessibilityIdentifier("bluetoothConsoleLink")
                    NavigationLink {
                        ManualChecklistView()
                    } label: {
                        Label("Manual checklist", systemImage: "checklist")
                    }
                    .accessibilityIdentifier("manualChecklistLink")
                } footer: {
                    Text("Send raw bytes to the dashboard and watch its buttons, or test every feature the owner's manual lists. Parked bike only.")
                }

                Section {
                    Toggle("Simulation mode", isOn: Binding(get: { model.simulationMode },
                                                            set: { model.setSimulationMode($0) }))
                        .disabled(model.stage != .choosing || model.provider == nil)
                        .accessibilityIdentifier("simulationToggle")
                } footer: {
                    Text("Replays a synthetic route instead of real navigation; no Apple or Google route requests. Change it only between rides.")
                }

                if model.diagnosticsLocked {
                    Section { LockBanner() }
                }

                Section {
                    ForEach(samples, id: \.0) { sample in
                        Button(sample.0) { model.sendTestFrame(sample.1, stepMetres: sample.2, roundaboutDirection: sample.3) }
                            .accessibilityIdentifier("test-\(sample.0)")
                    }
                    Button("Clear dashboard", role: .destructive) { model.clearTestFrame() }
                        .accessibilityIdentifier("clearDashboardButton")
                } header: {
                    Text("Test frames")
                } footer: {
                    Text("Use only with the bike parked. Each frame shows for 5 seconds; tap another to replace it.")
                }
                .disabled(model.diagnosticsLocked)

                Section {
                    Picker("Glyph", selection: $rightGlyph) {
                        Text("Left arrow (85), clockwise").tag(false)
                        Text("Right arrow (78), anticlockwise").tag(true)
                    }
                    Stepper("Exit value: \(nibble)", value: $nibble, in: 0...15)
                    Button("Send roundabout probe") { model.sendRoundaboutProbe(rightGlyph: rightGlyph, nibble: nibble) }
                        .accessibilityIdentifier("sendRoundaboutProbe")
                } header: {
                    Text("Roundabout probe")
                } footer: {
                    Text("Raw value, one-eighth turn per step. Left arrow: 1 sharp left to 7 sharp right (clockwise). Right arrow: 1 right to 6 sharp left (anticlockwise). Navigation sends the value matching the route's exit direction. Shown for 5 seconds.")
                }
                .disabled(model.diagnosticsLocked)

                Section {
                    Picker("Status packet", selection: Binding(get: { model.statusProfile }, set: { model.setStatusProfile($0) })) {
                        Text("Off").tag(GeneralStatusProfile?.none)
                        Text("Legacy (55 bytes)").tag(GeneralStatusProfile?.some(.legacy55))
                        Text("V2 (89 bytes)").tag(GeneralStatusProfile?.some(.v2_89))
                    }
                    .accessibilityIdentifier("statusProfilePicker")
                } header: {
                    Text("Phone status on dashboard")
                } footer: {
                    Text("Sends this phone's battery level every 5 s. Try each option and keep the one that shows the battery correctly without errors. No call or message information is sent.")
                }

                CustomStatusSection()

                Section {
                    LabeledContent("Wakes", value: "\(model.counters.wakes)")
                    LabeledContent("Snapshots", value: "\(model.counters.snapshots)")
                    LabeledContent("Lock Screen updates", value: "\(model.activityUpdates)")
                    LabeledContent("Since", value: model.counters.startedAt.formatted(date: .omitted, time: .shortened))
                    Button("Reset counters") { model.resetCounters() }
                } header: {
                    Text("Energy counters")
                } footer: {
                    Text("Compare rides with Energy saving on and off. Counts, not a battery measurement.")
                }

                Section("Recent frames") {
                    ForEach(model.recentFrames) { frame in
                        VStack(alignment: .leading) {
                            Text(ClusterIcon.name(frame.summary.icon)
                                 + (frame.summary.roundaboutExit > 0 ? " · value \(frame.summary.roundaboutExit)" : ""))
                            Text("\(frame.summary.stepText) / \(frame.summary.totalText) · ETA \(frame.summary.etaHour):\(String(format: "%02d", frame.summary.etaMinute))\(frame.summary.isPM ? " PM" : " AM")")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("recentFrame")
                    }
                }

                Section {
                    ShareLink(item: model.diagnosticsExport()) {
                        Label("Share diagnostics", systemImage: "square.and.arrow.up")
                    }
                    Button("Delete diagnostics log", role: .destructive) { model.clearDiagnostics() }
                } header: {
                    Text("Diagnostics (\(model.diagnostics.entries.count) events)")
                } footer: {
                    Text("Contains only app/SDK versions, states, counts and error categories - no locations, road names, keys or bike identifiers. Route limits are counted on this phone and reset if the app is reinstalled.")
                }

                Section {
                    Button("Forget paired bike", role: .destructive) { model.bike.forgetBike() }
                } footer: {
                    Text("To remove the iOS pairing too: Settings > Bluetooth > (bike) > Forget This Device. To return to the official app, stop navigation here first.")
                }
            }
            .navigationTitle("Diagnostics")
        }
    }
}

/// Bench testing: send chosen values instead of the phone's real ones.
private struct CustomStatusSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            Toggle("Use custom values", isOn: $model.customStatusEnabled)
                .accessibilityIdentifier("customStatusToggle")
            Group {
                Stepper("Volume: \(model.customVolume)", value: $model.customVolume, in: 0...15)
                Stepper("Battery bars: \(model.customBatteryBars)", value: $model.customBatteryBars, in: 0...4)
                Stepper("Signal bars: \(model.customSignal)", value: $model.customSignal, in: 0...7)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Raw bytes, e.g. 13=2, 17=0x01", text: $model.customRawBytes)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("customRawBytes")
                    if let error = model.customRawBytesError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .disabled(!model.customStatusEnabled)
            Button("Send now") { model.sendStatusNow() }
                .disabled(model.statusProfile == nil || model.customRawBytesError != nil)
                .accessibilityIdentifier("sendStatusNow")
        } header: {
            Text("Custom status packet")
        } footer: {
            Text(model.statusProfile == nil
                 ? "Choose a status packet type above first."
                 : "Sent every 5 s while on. Raw bytes are written after encoding as offset=value (decimal or 0x hex); the V2 checksum is recomputed unless you set byte 88. Values reset when the app restarts.")
        }
    }
}

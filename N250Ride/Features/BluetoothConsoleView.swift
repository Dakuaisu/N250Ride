import RideCore
import SwiftUI

struct BluetoothConsoleView: View {
    @Environment(AppModel.self) private var model
    @State private var presetProfile: GeneralStatusProfile = .legacy55

    var body: some View {
        @Bindable var console = model.console
        List {
            Section {
                Label("Parked bike only. Ignition on, engine off.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                LinkStatusRow(state: model.bike.state)
                LockBanner()
            }

            Section {
                Picker("Channel", selection: $console.target) {
                    ForEach(console.targets) { target in
                        Text(target.name).tag(target.id)
                    }
                }
                .accessibilityIdentifier("consoleTarget")
                TextField("Hex bytes, e.g. 11 47 00 …", text: $console.hexText, axis: .vertical)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .lineLimit(2...6)
                    .accessibilityIdentifier("consoleHex")
                if let bytes = console.parsed {
                    Text("\(bytes.count) bytes").font(.caption).foregroundStyle(.secondary)
                } else if !console.hexText.isEmpty {
                    Text("Not valid hex").font(.caption).foregroundStyle(.red)
                }
                if console.isNavigationTarget {
                    Toggle("Fix checksum (byte 47)", isOn: $console.fixChecksum)
                    if let preview = console.framePreview {
                        Text("\(ClusterIcon.name(preview.icon)) · \(preview.stepText) / \(preview.totalText) · ETA \(preview.etaHour):\(String(format: "%02d", preview.etaMinute))\(preview.isPM ? " PM" : " AM") · exit \(preview.roundaboutExit) · type \(preview.frameType) · GPS \((console.parsed?[12] ?? 0) >> 2 & 0x03)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Toggle("Wait for acknowledgement", isOn: $console.withResponse)
                }
                Button {
                    console.send()
                } label: {
                    Label("Send", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(console.parsed == nil || model.diagnosticsLocked || !model.bike.state.isReady)
                .accessibilityIdentifier("consoleSend")
                Button("Clear dashboard", role: .destructive) { console.clearDashboard() }
            } header: {
                Text("Send")
            } footer: {
                Text("Navigation frames are requested for 5 s, then a clear is requested; only you can confirm what the dashboard showed. Other channels get one write. The firmware-update service is always blocked.")
            }

            Section {
                Picker("Status packet type", selection: $presetProfile) {
                    Text("Legacy").tag(GeneralStatusProfile.legacy55)
                    Text("V2").tag(GeneralStatusProfile.v2_89)
                }
                .pickerStyle(.segmented)
                ForEach(BluetoothConsole.presets(statusProfile: presetProfile)) { preset in
                    Button(preset.name) { console.run(preset) }
                }
            } header: {
                Text("Experiments")
            } footer: {
                Text("Tapping an experiment sends it straight away. Call experiments pause the app's own status packets until you send Call ended or leave the console.")
            }

            Section {
                Toggle("Watch buttons (control channel)", isOn: Binding(get: { console.polling },
                                                                       set: { console.setPolling($0) }))
                    .accessibilityIdentifier("consolePoll")
                if !console.controlBytes.isEmpty {
                    ControlBytesGrid(bytes: console.controlBytes, changed: console.changedControlBytes)
                }
            } footer: {
                Text("Reads the dashboard's button channel every 0.7 s and highlights bytes that change. Press Mode briefly, then hold it, and watch.")
            }

            Section {
                Button("Explore services") { console.explore() }
                ForEach(model.bike.gattServices) { service in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(service.id).font(.caption.monospaced().weight(.semibold))
                        ForEach(service.characteristics) { characteristic in
                            Text("  \(characteristic.id) \(Self.describe(characteristic.properties))\(BikeConnection.isBlocked(characteristic.id) ? " · BLOCKED" : "")")
                                .font(.caption2.monospaced())
                                .foregroundStyle(BikeConnection.isBlocked(characteristic.id) ? .red : .secondary)
                        }
                    }
                }
            } header: {
                Text("Services")
            }

            Section {
                ShareLink(item: console.exportText) { Label("Share log", systemImage: "square.and.arrow.up") }
                Button("Clear log", role: .destructive) { console.clearLog() }
                ForEach(console.entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.time.formatted(date: .omitted, time: .standard)) · \(BluetoothConsole.short(entry.channel))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(entry.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(Self.color(entry.kind))
                    }
                }
            } header: {
                Text("Log")
            }
        }
        .navigationTitle("Bluetooth console")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.console.appeared() }
        .onDisappear { model.console.stop() }
        .alert("Write to an unknown channel?", isPresented: $console.confirmingUnknown) {
            Button("Send anyway", role: .destructive) { console.send(confirmed: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This channel's purpose isn't known. Writing unknown data could change dashboard settings.")
        }
    }

    static func describe(_ p: CharacteristicProperties) -> String {
        [p.contains(.read) ? "read" : nil, p.contains(.write) ? "write" : nil,
         p.contains(.writeWithoutResponse) ? "write-no-ack" : nil, p.contains(.notify) ? "notify" : nil]
            .compactMap { $0 }.joined(separator: "/")
    }

    static func color(_ kind: BluetoothConsole.Entry.Kind) -> Color {
        switch kind {
        case .sent: .blue
        case .received: .green
        case .info: .secondary
        case .error: .red
        }
    }
}

private struct ControlBytesGrid: View {
    let bytes: [UInt8]
    let changed: Set<Int>

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
            ForEach(Array(bytes.enumerated()), id: \.offset) { index, byte in
                VStack(spacing: 0) {
                    Text("\(index)").font(.caption2).foregroundStyle(.secondary)
                    Text(HexBytes.format([byte])).font(.body.monospaced().weight(changed.contains(index) ? .bold : .regular))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(changed.contains(index) ? Color.yellow.opacity(0.4) : Color.secondary.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

/// Explains why bench tools are locked and offers to close the route or end the ride.
struct LockBanner: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingEnd = false

    var body: some View {
        if let reason = model.diagnosticsLockReason {
            VStack(alignment: .leading, spacing: 8) {
                Label("Locked: \(reason)", systemImage: "lock.fill").foregroundStyle(.red)
                Button(isRide ? "End ride" : "Close route", role: .destructive) {
                    if isRide { confirmingEnd = true } else { model.endRideForDiagnostics() }
                }
                .accessibilityIdentifier("unlockDiagnosticsButton")
            }
            .confirmationDialog("End the current ride?", isPresented: $confirmingEnd, titleVisibility: .visible) {
                Button("End ride", role: .destructive) { model.endRideForDiagnostics() }
            }
        }
    }

    private var isRide: Bool {
        if case .navigating = model.stage { return true }
        return false
    }
}

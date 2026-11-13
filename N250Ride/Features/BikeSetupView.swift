import RideCore
import SwiftUI

/// Ordered, parked compatibility check. Each visual step needs the rider's answer;
/// a Bluetooth acknowledgement is reported separately and never counts as "seen".
struct BikeSetupView: View {
    @Environment(AppModel.self) private var model

    private var setup: BikeSetupModel { model.setup }

    var body: some View {
        List {
            Section {
                Text("Step \(setup.step.rawValue + 1) of \(BikeSetupModel.Step.allCases.count): \(setup.step.title)")
                    .font(.headline)
                    .accessibilityIdentifier("setupStep")
                content
                if let message = setup.message {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .accessibilityIdentifier("setupMessage")
                }
            }
            if setup.step != .report {
                Section {
                    Button("Next") { setup.next() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("setupNext")
                    Button("Start over", role: .destructive) { setup.cancel(); setup.begin() }
                }
            }
        }
        .navigationTitle("Check this bike")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if setup.step == .parked { setup.begin() } }
        .onDisappear { setup.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch setup.step {
        case .parked:
            Label("Park the bike. Ignition on, engine off. Don't do this while riding.", systemImage: "parkingsign.circle")
        case .connect:
            LinkStatusRow(state: model.bike.state)
            Text("Connect on the Bike tab if needed, then tap Next.").foregroundStyle(.secondary)
        case .link:
            LabeledContent("Navigation channel", value: setup.report.gatt.label)
            LabeledContent("Writes", value: setup.report.writeMode)
            LabeledContent("Largest write", value: "\(setup.report.maximumWrite) bytes")
            Text("These come from the bike's Bluetooth service, not from the dashboard display.")
                .font(.footnote).foregroundStyle(.secondary)
        case .clear:
            Button("Clear the dashboard") { setup.sendClear() }
                .accessibilityIdentifier("setupClear")
            LabeledContent("Bluetooth result", value: setup.report.clearTransport.label)
        case .samples:
            ForEach(BikeSetupModel.samples) { sample in
                VStack(alignment: .leading, spacing: 6) {
                    Button("Send: \(sample.label)") { setup.send(sample) }
                    ObservationPicker(title: "Did the dashboard show it?",
                                      value: setup.report.samples[sample.id] ?? .notRun) { setup.observe(sample, $0) }
                }
            }
        case .stopFrame:
            Button("Show an arrow, then turn navigation off") { setup.sendStopFrame() }
            ObservationPicker(title: "Did the arrow disappear?", value: setup.report.stopFrameVisual) { setup.observeStopFrame($0) }
        case .status:
            Text(model.statusProfile == nil
                 ? "The app isn't sending phone status. Skip this step, or pick a profile in Diagnostics first."
                 : "With status packets on, check the phone battery and signal bars on the dashboard.")
            ObservationPicker(title: "Battery and signal shown?", value: setup.report.statusVisual) { setup.observeStatus($0) }
        case .reconnect:
            LinkStatusRow(state: model.bike.state)
            Text("Switch the ignition off for 10 seconds, then on. Watch whether the app reconnects by itself.")
            ObservationPicker(title: "Reconnected by itself?", value: setup.report.reconnect) { setup.observeReconnect($0) }
        case .report:
            LabeledContent("Result", value: setup.report.verdict)
                .accessibilityIdentifier("setupVerdict")
            LabeledContent("Bluetooth service", value: setup.report.gatt.label)
            LabeledContent("Clear (Bluetooth)", value: setup.report.clearTransport.label)
            ForEach(BikeSetupModel.samples) { sample in
                LabeledContent(sample.label, value: (setup.report.samples[sample.id] ?? .notRun).label)
            }
            LabeledContent("Navigation off (seen)", value: setup.report.stopFrameVisual.label)
            LabeledContent("Phone status (seen)", value: setup.report.statusVisual.label)
            LabeledContent("Reconnect", value: setup.report.reconnect.label)
            Text("Checked parked, with this app version and calibration. It doesn't prove behaviour while riding.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct ObservationPicker: View {
    let title: String
    let value: SetupObservation
    let set: @MainActor @Sendable (SetupObservation) -> Void

    var body: some View {
        Picker(title, selection: Binding(get: { value }, set: set)) {
            Text("Yes").tag(SetupObservation.pass)
            Text("No").tag(SetupObservation.fail)
            Text("Not sure").tag(SetupObservation.inconclusive)
        }
        .pickerStyle(.segmented)
    }
}

import RideCore
import SwiftUI

struct ManualChecklistView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingReset = false

    private var sections: [ManualChecklist.Section] {
        ManualChecklist.sections(statusProfile: model.statusProfile ?? .legacy55)
    }

    var body: some View {
        let sections = sections
        List {
            Section {
                Label("Parked bike only. Ignition on, engine off.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                LinkStatusRow(state: model.bike.state)
                LockBanner()
                if let last = model.console.entries.first {
                    Text("Last: \(last.text)")
                        .font(.caption.monospaced())
                        .foregroundStyle(last.kind == .error ? .red : .secondary)
                        .accessibilityIdentifier("checklistLast")
                }
            } footer: {
                Text("\(model.checklist.tested(in: sections)) of \(sections.flatMap(\.checks).count) tried. Tap a button to send it, watch the dashboard, then mark what you saw.")
            }

            ForEach(sections) { section in
                Section {
                    ForEach(section.checks) { check in
                        CheckRow(check: check)
                    }
                } header: {
                    Text(section.title)
                } footer: {
                    Text(section.footer)
                }
            }

            Section {
                ShareLink(item: report(sections)) {
                    Label("Share results", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("checklistShare")
                Button("Reset all results", role: .destructive) { confirmingReset = true }
            }
        }
        .navigationTitle("Manual checklist")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.console.stop() }
        .confirmationDialog("Clear every result?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { model.checklist.reset() }
        }
    }

    private func report(_ sections: [ManualChecklist.Section]) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        return model.checklist.report(sections, appVersion: version, statusProfile: model.statusProfile,
                                      consoleLog: model.console.exportText)
    }
}

private struct CheckRow: View {
    @Environment(AppModel.self) private var model
    let check: ManualChecklist.Check

    var body: some View {
        let result = model.checklist.result(check.id)
        VStack(alignment: .leading, spacing: 8) {
            Text(check.title).font(.headline)
            Text(check.expected).font(.subheadline).foregroundStyle(.secondary)
            if let howTo = check.howTo {
                Label(howTo, systemImage: "hand.point.right").font(.subheadline)
            }
            if !check.steps.isEmpty {
                FlowButtons(steps: check.steps) { model.console.run($0) }
            }
            Picker("Result", selection: Binding(get: { result.outcome },
                                                set: { model.checklist.set(check.id, outcome: $0) })) {
                ForEach(ManualChecklist.Outcome.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("outcome.\(check.id)")
            TextField("What did the dashboard show?", text: Binding(get: { result.note },
                                                                    set: { model.checklist.set(check.id, note: $0) }),
                      axis: .vertical)
                .font(.subheadline)
                .accessibilityIdentifier("note.\(check.id)")
        }
        .padding(.vertical, 4)
    }
}

private struct FlowButtons: View {
    let steps: [BluetoothConsole.Preset]
    let action: (BluetoothConsole.Preset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(steps) { step in
                Button(step.name) { action(step) }
                    .buttonStyle(.bordered)
                    .font(.subheadline)
            }
        }
    }
}

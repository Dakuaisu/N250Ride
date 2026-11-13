import RideCore
import SwiftUI

struct RideSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showRecoveryDisclosure = false
    @State private var confirmingRecoveryDiscard = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Toggle("Spoken directions", isOn: $model.voiceEnabled)
                        .accessibilityIdentifier("voiceToggle")
                    Picker("Style", selection: $model.voiceStyle) {
                        Text("Detailed").tag(VoiceStyle.detailed)
                        Text("Concise").tag(VoiceStyle.concise)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("voiceStylePicker")
                    LabeledContent("Plays through", value: model.voice.outputName)
                    Button("Test audio") { model.voice.test() }
                        .accessibilityIdentifier("testAudioButton")
                    if let reason = model.voice.holdReason {
                        Label(reason, systemImage: "speaker.slash").foregroundStyle(.orange)
                        if model.voice.holds.contains(.speakerFallback) {
                            Button("Use the phone speaker") { model.allowPhoneSpeaker() }
                        }
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Uses whatever audio output the phone has chosen (helmet, earphones or speaker). Concise skips the early 1 km warning and road names. If your headset disconnects, voice pauses until it's back or you allow the speaker.")
                }

                Section {
                    Toggle("Avoid tolls", isOn: $model.routePreferences.avoidTolls)
                        .accessibilityIdentifier("avoidTollsToggle")
                    Toggle("Avoid highways", isOn: $model.routePreferences.avoidHighways)
                        .accessibilityIdentifier("avoidHighwaysToggle")
                } header: {
                    Text("Routes")
                } footer: {
                    Text("Applies to new routes and reroutes. Apple Maps may still use a toll road or highway when there is no other way.")
                }

                Section {
                    Toggle("Energy saving", isOn: $model.energySaving)
                        .accessibilityIdentifier("energyToggle")
                } footer: {
                    Text("Fewer Lock Screen updates and no map animations. GPS accuracy, rerouting and dashboard timing are unchanged. Savings haven't been measured yet.")
                }

                Section {
                    Toggle("Offer to resume interrupted rides", isOn: Binding(
                        get: { model.recovery.enabled },
                        set: { on in on ? (showRecoveryDisclosure = true) : model.recovery.setEnabled(false) }))
                        .accessibilityIdentifier("recoveryToggle")
                    if let problem = model.recovery.problem {
                        Text(problem).font(.footnote).foregroundStyle(.orange)
                    }
                    if model.recovery.isBlocked {
                        Button("Discard saved ride", role: .destructive) { confirmingRecoveryDiscard = true }
                            .accessibilityIdentifier("discardRecoveryFileButton")
                    }
                } header: {
                    Text("Ride recovery")
                } footer: {
                    Text("Keeps the destination, any stop and your route options on this phone for up to 24 hours, so you can resume if the app stops. No route, directions or position is kept. Turning this off deletes it.")
                }

                Section {
                    Toggle("Keep ride history", isOn: Binding(get: { model.history.enabled },
                                                              set: { model.history.setEnabled($0) }))
                        .accessibilityIdentifier("historyToggle")
                    NavigationLink("Ride history") { RideHistoryView() }
                        .accessibilityIdentifier("historyLink")
                    if model.history.isBlocked {
                        Text("Stored history can't be read. Open Ride history to discard it.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("History")
                } footer: {
                    Text("Off by default. Saves only the date, ride time and an estimated distance, on this phone, for 30 days (up to 100 rides). Never positions or a track. Starts with your next ride.")
                }

                Section("Places") {
                    shortcutRow("Home", place: model.places.home, shortcut: .home)
                    shortcutRow("Work", place: model.places.work, shortcut: .work)
                    Button("Clear recent destinations", role: .destructive) { model.clearRecents() }
                        .disabled(model.places.recents.isEmpty)
                }
            }
            .navigationTitle("Ride settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Discard the saved ride? It can't be read by this version.",
                                isPresented: $confirmingRecoveryDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { model.discardRecovery() }
            }
            .alert("Keep interrupted rides?", isPresented: $showRecoveryDisclosure) {
                Button("Turn on") { model.recovery.setEnabled(true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("N250 Ride will store the destination and stop of your current ride on this phone (not in backups) for up to 24 hours. Resuming always asks first and gets a fresh route.")
            }
        }
    }

    @ViewBuilder
    private func shortcutRow(_ title: String, place: Favourite?, shortcut: AppModel.Shortcut) -> some View {
        if let place {
            LabeledContent(title, value: place.label)
                .swipeActions {
                    Button("Clear", role: .destructive) { model.clearShortcut(shortcut) }
                }
        } else {
            LabeledContent(title, value: "Not set")
        }
    }
}

struct RideHistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingDeleteAll = false
    @State private var confirmingDiscard = false

    var body: some View {
        List {
            if model.history.rides.isEmpty {
                Text(model.history.enabled ? "No rides yet." : "History is off. Turn it on in Ride settings.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.history.rides) { ride in
                VStack(alignment: .leading, spacing: 4) {
                    Text(ride.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                    Text("\(Format.duration(ride.activeSeconds)) · about \(Format.distance(ride.estimatedMetres))")
                        .font(.subheadline)
                    Text(Self.outcome(ride.outcome)).font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { model.history.delete(ride.id) }
                }
            }
            if let problem = model.history.problem {
                Text(problem).font(.footnote).foregroundStyle(.orange)
            }
            if model.history.isBlocked {
                Button("Discard stored history", role: .destructive) { confirmingDiscard = true }
                    .accessibilityIdentifier("discardHistoryButton")
            }
            if !model.history.rides.isEmpty {
                Section {
                    ShareLink(item: model.history.exportJSON()) { Label("Export summaries", systemImage: "square.and.arrow.up") }
                    Button("Delete all history", role: .destructive) { confirmingDeleteAll = true }
                } footer: {
                    Text("Distances are estimates from GPS, not the bike's odometer.")
                }
            }
        }
        .navigationTitle("Ride history")
        .confirmationDialog("Delete every saved ride?", isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { model.history.deleteAll() }
        }
        .confirmationDialog("Discard the stored history? It can't be read by this version.",
                            isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { model.history.discardStored() }
        }
    }

    static func outcome(_ outcome: RideSummary.Outcome) -> String {
        switch outcome {
        case .completed: "Arrived"
        case .endedByRider: "Ended early"
        case .interrupted: "Interrupted"
        }
    }
}

import RideCore
import SwiftUI

struct RideSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Toggle("Spoken directions", isOn: $model.voiceEnabled)
                        .accessibilityIdentifier("voiceToggle")
                } footer: {
                    Text("Plays through your helmet intercom or earphones when connected. Music is lowered while a direction is spoken.")
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

import MapKit
import RideCore
import SwiftUI

/// Where-to screen: search by name first, then favourites, the map, and pasted
/// coordinates. Every path goes through the same confirmation.
struct DestinationPicker: View {
    @Environment(AppModel.self) private var model
    @State private var pasted = ""
    @State private var pasteError: String?
    @State private var showCoordinates = false
    @State private var renaming: Favourite?
    @State private var newLabel = ""

    var body: some View {
        @Bindable var search = model.search

        Section {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search places, landmarks, addresses", text: $search.query)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityIdentifier("searchField")
                if model.search.isResolving {
                    ProgressView()
                } else if !model.search.query.isEmpty {
                    Button {
                        model.search.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.vertical, 6)

            ForEach(model.search.suggestions) { suggestion in
                Button {
                    model.useSearchSuggestion(suggestion)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title).foregroundStyle(.primary)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("suggestion-\(suggestion.id)")
            }
            if let error = model.search.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }
        } footer: {
            if model.search.suggestions.isEmpty {
                Text("Search uses Apple Maps.")
            }
        }

        if model.search.suggestions.isEmpty {
            Section {
                HStack(spacing: 12) {
                    ShortcutButton(title: "Home", systemImage: "house.fill", place: model.places.home)
                    ShortcutButton(title: "Work", systemImage: "briefcase.fill", place: model.places.work)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                if model.places.home == nil || model.places.work == nil {
                    Text("Set Home or Work when you confirm a destination.")
                }
            }

            if !model.places.recents.isEmpty {
                Section("Recent") {
                    ForEach(model.places.recents) { place in
                        Button {
                            model.navigate(to: place)
                        } label: {
                            Label(place.label, systemImage: "clock.arrow.circlepath")
                        }
                        .accessibilityIdentifier("recent-\(place.label)")
                    }
                }
            }

            Section {
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    Task { @MainActor in model.handleIncoming(text) }
                }
                .labelStyle(.titleAndIcon)
                .accessibilityIdentifier("pasteLinkButton")
                if let message = model.linkMessage {
                    Text(message).font(.footnote).foregroundStyle(.orange)
                }
            } header: {
                Text("From another app")
            } footer: {
                Text("Copy a place from Apple Maps, Google Maps or WhatsApp and paste it here, or use Share → N250 Ride.")
            }

            Section {
                if model.provider != nil {
                    Button {
                        model.selectedTab = .map
                    } label: {
                        Label("Pick a spot on the map", systemImage: "hand.tap")
                    }
                }
                DisclosureGroup("Coordinates or plus code", isExpanded: $showCoordinates) {
                    HStack {
                        TextField("12.9716, 77.5946 or 7J4VWHC2+VG", text: $pasted)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("pasteField")
                        Button("Use") {
                            if let error = model.proposePasted(pasted) {
                                pasteError = Self.message(for: error)
                            } else {
                                pasteError = nil
                                pasted = ""
                            }
                        }
                        .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("usePastedButton")
                    }
                    if let pasteError {
                        Text(pasteError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("pasteError")
                    }
                }
            }

            Section("Favourites") {
                if model.favourites.items.isEmpty {
                    Text("Save a destination when you confirm it, and it shows up here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.favourites.items) { favourite in
                    Button {
                        model.propose(favourite.coordinate, label: favourite.label)
                    } label: {
                        Label(favourite.label, systemImage: "star.fill")
                    }
                    .accessibilityIdentifier("favourite-\(favourite.label)")
                    .swipeActions {
                        Button("Delete", role: .destructive) { model.deleteFavourite(favourite.id) }
                        Button("Rename") {
                            newLabel = favourite.label
                            renaming = favourite
                        }
                    }
                    .contextMenu {
                        Button("Set as Home", systemImage: "house") {
                            model.setShortcut(.home, label: favourite.label, coordinate: favourite.coordinate)
                        }
                        Button("Set as Work", systemImage: "briefcase") {
                            model.setShortcut(.work, label: favourite.label, coordinate: favourite.coordinate)
                        }
                    }
                }
            }
            .alert("Rename favourite", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newLabel)
                Button("Save") {
                    if let renaming { model.renameFavourite(renaming.id, to: newLabel) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    static func message(for error: DestinationParseError) -> String {
        switch error {
        case .empty: "Enter coordinates or a plus code."
        case .malformed: "Use latitude, longitude in decimal degrees, e.g. 12.9716, 77.5946."
        case .latitudeOutOfRange: "Latitude must be between -90 and 90."
        case .longitudeOutOfRange: "Longitude must be between -180 and 180."
        case .shortPlusCode: "Short plus codes (like 7JCJ+8J Bengaluru) need a town lookup. Paste the full code, e.g. 7J4VWHC2+VG."
        case .invalidPlusCode: "That is not a valid plus code."
        }
    }
}

/// One-tap Home/Work: goes straight to route options when set.
private struct ShortcutButton: View {
    @Environment(AppModel.self) private var model
    let title: String
    let systemImage: String
    let place: Favourite?

    var body: some View {
        Button {
            if let place { model.navigate(to: place) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.title2)
                Text(title).font(.headline)
                Text(place == nil ? "Not set" : "Go")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .foregroundStyle(place == nil ? Color.secondary : Color.accentColor)
        .disabled(place == nil)
        .accessibilityIdentifier("shortcut-\(title)")
    }
}

/// Confirmation step shared by every destination source, with the place on an
/// Apple map (required when showing Apple search results).
struct DestinationConfirmation: View {
    @Environment(AppModel.self) private var model
    let pending: AppModel.PendingDestination
    @State private var label: String
    @State private var saveAsFavourite = false
    @State private var shortcut: AppModel.Shortcut?

    init(pending: AppModel.PendingDestination) {
        self.pending = pending
        _label = State(initialValue: pending.label)
    }

    private var location: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: pending.coordinate.latitude, longitude: pending.coordinate.longitude)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Map(initialPosition: .region(MKCoordinateRegion(center: location, latitudinalMeters: 900,
                                                                    longitudinalMeters: 900))) {
                        Marker(pending.label.isEmpty ? "Destination" : pending.label, coordinate: location)
                    }
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets())
                    .allowsHitTesting(false)
                    .accessibilityLabel("Map showing the destination")

                    TextField("Name (optional)", text: $label)
                        .font(.headline)
                        .accessibilityIdentifier("labelField")
                    Toggle("Save as favourite", isOn: $saveAsFavourite)
                        .accessibilityIdentifier("saveFavouriteToggle")
                    Picker("Shortcut", selection: $shortcut) {
                        Text("None").tag(AppModel.Shortcut?.none)
                        Text("Home").tag(AppModel.Shortcut?.some(.home))
                        Text("Work").tag(AppModel.Shortcut?.some(.work))
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("shortcutPicker")
                } footer: {
                    Text(String(format: "%.6f, %.6f", pending.coordinate.latitude, pending.coordinate.longitude))
                        .font(.caption.monospaced())
                }

                Section {
                    Button {
                        model.confirmDestination(label: label, saveAsFavourite: saveAsFavourite, shortcut: shortcut)
                    } label: {
                        Text(model.mode == .simulation ? "Use this destination" : "Get routes")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("confirmDestinationButton")
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle("Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelDestination() }
                        .accessibilityIdentifier("cancelDestinationButton")
                }
            }
        }
    }

    private var footer: String {
        switch model.mode {
        case .simulation:
            "Simulation: a synthetic route is replayed. No route request is made."
        case .live:
            "Asks \(model.provider?.name ?? "the navigation provider") for up to three routes to choose from."
        }
    }
}

import RideCore
import SwiftUI

/// What works and what doesn't, most important first, with the safe action.
struct RideHealthView: View {
    @Environment(AppModel.self) private var model
    let health: RideHealth

    var body: some View {
        if health.items.isEmpty {
            Label(health.primary.message, systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("rideHealth")
        } else {
            ForEach(Array(health.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline) {
                    Label(item.message, systemImage: Self.symbol(item))
                        .foregroundStyle(Self.tint(item.severity))
                        .font(index == 0 ? .body.weight(.semibold) : .subheadline)
                    Spacer(minLength: 8)
                    if let action = item.action { actionButton(action) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(index == 0 ? "rideHealth" : "rideHealth-\(index)")
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: RideHealth.Action) -> some View {
        switch action {
        case .openSettings:
            Button("Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.bordered)
        case .retryRoute:
            Button("Retry") { model.requestReroute(.manual) }.buttonStyle(.bordered)
        case .reconnectBike:
            Button("Connect") { model.bike.connectRemembered() }.buttonStyle(.bordered)
        case .allowSpeaker:
            Button("Use speaker") { model.allowPhoneSpeaker() }.buttonStyle(.bordered)
        case .confirmLeg, .resumeRide:
            EmptyView()
        }
    }

    static func symbol(_ item: RideHealth.Item) -> String {
        switch item.kind {
        case .position: "location.slash"
        case .route: "arrow.triangle.branch"
        case .confirmation: "hand.raised"
        case .dashboard: "gauge.with.dots.needle.0percent"
        case .voice: "speaker.slash"
        }
    }

    static func tint(_ severity: RideHealth.Severity) -> Color {
        switch severity {
        case .ok: .green
        case .info: .secondary
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// Recalculate during a ride, with progress, Cancel and Retry.
struct RouteOperationRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.routeOperation {
        case .idle where model.mode == .simulation:
            EmptyView()
        case .idle:
            Button {
                model.requestReroute(.manual)
            } label: {
                Label("Recalculate route", systemImage: "arrow.triangle.2.circlepath")
            }
            .accessibilityIdentifier("recalculateButton")
        case .preparing(let reason):
            HStack(spacing: 12) {
                ProgressView()
                Text(reason == .replacement ? "Preparing the new route…" : "Recalculating…")
                Spacer()
                Button("Cancel") { model.cancelRouteOperation() }
                    .accessibilityIdentifier("cancelRerouteButton")
            }
        case .failed(_, let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .accessibilityIdentifier("rerouteError")
                Text("The current route is kept.").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("Retry") { model.requestReroute(.manual) }.buttonStyle(.bordered)
                        .accessibilityIdentifier("retryRerouteButton")
                    Button("Dismiss") { model.dismissRouteError() }
                }
            }
        }
    }
}

/// Leg one is done; nothing is guided until the rider continues.
struct AtStop: View {
    @Environment(AppModel.self) private var model
    let pending: AppModel.PendingDestination

    var body: some View {
        let stopName = model.ride?.itinerary.stop?.label ?? ""
        Section {
            Label("You've reached \(stopName.isEmpty ? "your stop" : stopName).", systemImage: "mappin.circle.fill")
                .font(.title3.weight(.semibold))
            if case .failed(_, let message) = model.routeOperation {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Button {
                model.continueToFinal()
            } label: {
                Label("Continue to \(RideView.title(pending))", systemImage: "location.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("continueToFinalButton")
        } footer: {
            Text("A new route from where you are now is calculated when you continue.")
        }
        Section {
            Button("End ride", role: .destructive) { model.stopNavigation() }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("endAtStopButton")
        }
    }
}

/// Offered after an interruption. Nothing is requested until Resume.
struct RecoveryPrompt: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let offer = model.recoveryOffer {
            Section {
                switch offer {
                case .resume(let intent):
                    Text("Your ride to \(Self.name(intent.context)) was interrupted.")
                    Button("Resume") { model.resumeRecovery() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("resumeRideButton")
                case .unfinishedStart(let pending, let previous):
                    Text("A route change to \(Self.name(pending.context)) may not have started before the app stopped.")
                    Button("Use the new destination") { model.resumeRecovery(usePending: true) }
                        .accessibilityIdentifier("resumeRideButton")
                    if let previous {
                        Button("Resume the ride to \(Self.name(previous.context))") { model.resumeRecovery(usePending: false) }
                    }
                }
                Button("Discard", role: .destructive) { model.discardRecovery() }
                    .accessibilityIdentifier("discardRecoveryButton")
            } header: {
                Text("Resume ride?")
            } footer: {
                Text("Resuming finds your current position and asks for a fresh route. Directions start only when you tap Start.")
            }
        }
    }

    static func name(_ context: RideContext) -> String {
        context.activeTarget.label.isEmpty ? "your destination" : context.activeTarget.label
    }
}

/// Destinations shared or pasted while you were busy.
struct WaitingDestinations: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingDiscard = false

    var body: some View {
        if !model.inbox.waiting.isEmpty || model.inbox.problem != nil {
            Section {
                ForEach(model.inbox.waiting) { item in
                    InboxRow(item: item)
                }
                if let problem = model.inbox.problem {
                    Text(problem).font(.footnote).foregroundStyle(.orange)
                }
                if model.inbox.isBlocked {
                    Button("Discard saved destinations", role: .destructive) { confirmingDiscard = true }
                        .accessibilityIdentifier("discardInboxButton")
                        .confirmationDialog("Discard the saved destinations? They can't be read by this version.",
                                            isPresented: $confirmingDiscard, titleVisibility: .visible) {
                            Button("Discard", role: .destructive) { model.inbox.discardStored() }
                        }
                }
            } header: {
                Text("Waiting destinations")
            } footer: {
                Text("Kept on this phone for 7 days. Opening one asks before any route is requested.")
            }
        }
    }
}

struct InboxRow: View {
    @Environment(AppModel.self) private var model
    let item: IncomingDestination

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label.isEmpty ? (item.isResolved ? "Shared place" : "Shared link") : item.label)
                Text(Self.status(item)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(item.status == .accepted ? "Try again" : "Open") { model.openInboxItem(item.id) }
                .buttonStyle(.bordered)
                .disabled(model.stage != .choosing)
        }
        .swipeActions {
            Button("Remove", role: .destructive) { model.discardInboxItem(item.id) }
        }
        .accessibilityIdentifier("inbox-\(item.label)")
    }

    static func status(_ item: IncomingDestination) -> String {
        switch item.status {
        case .pending: "Received \(item.receivedAt.formatted(date: .abbreviated, time: .shortened))"
        case .reserved: "Open"
        case .accepted: "Confirmed but not started - try again when ready"
        case .failed(let reason): reason
        }
    }
}

/// During a ride: what arrived, and what can safely be done with it.
struct QueuedDestinationsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming: IncomingDestination?

    var body: some View {
        List {
            Section {
                ForEach(model.inbox.waiting) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.label.isEmpty ? "Shared place" : item.label).font(.headline)
                        if item.isResolved {
                            HStack {
                                if model.ride?.itinerary.stop == nil {
                                    Button("Add as stop") {
                                        if let coordinate = item.coordinate {
                                            model.addStop(RideDestination(coordinate: coordinate, label: item.label,
                                                                          provenance: .shared), inboxItem: item.id)
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                }
                                Button("Replace destination") { confirming = item }
                                    .buttonStyle(.bordered)
                            }
                        } else {
                            Text("Open it after the ride to read the link.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Only while parked. The current route stays until the new one is ready; if it fails, nothing changes.")
            }
        }
        .navigationTitle("Waiting destinations")
        .confirmationDialog("Replace the current destination?", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            Button("Replace") {
                if let confirming { model.replaceDestination(with: confirming.id) }
                confirming = nil
            }
        }
    }
}

import SwiftUI

@main
struct N250RideApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { model.handleOpenURL($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // Safety first: overdue freshness/clear deadlines are processed before anything new is shown.
            model.foregroundSafetyCheck()
            model.checkShareInbox()
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            RideView()
                .tabItem { Label("Ride", systemImage: "location.north.line.fill") }
                .tag(AppModel.Tab.ride)
            MapTabView()
                .tabItem { Label("Map", systemImage: "map") }
                .tag(AppModel.Tab.map)
            BikeView()
                .tabItem { Label("Bike", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(AppModel.Tab.bike)
            DiagnosticsView()
                .tabItem { Label("Diagnostics", systemImage: "wrench.and.screwdriver") }
                .tag(AppModel.Tab.diagnostics)
        }
        .sheet(item: confirmationBinding) { pending in
            DestinationConfirmation(pending: pending.value)
                .interactiveDismissDisabled()
        }
    }

    private struct Identified: Identifiable {
        let value: AppModel.PendingDestination
        var id: String { "\(value.coordinate.latitude),\(value.coordinate.longitude)" }
    }

    /// Shown from any tab: long-press on the Map tab, search, favourites and pasted
    /// coordinates all lead to the same confirmation.
    private var confirmationBinding: Binding<Identified?> {
        Binding(
            get: {
                if case .confirming(let pending) = model.stage { return Identified(value: pending) }
                return nil
            },
            set: { if $0 == nil { model.cancelDestination() } }
        )
    }
}

import SwiftUI

/// Full-screen map: long-press to choose a destination, see route options before
/// starting, and follow the ride.
struct MapTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let provider = model.provider {
            ZStack(alignment: .bottom) {
                ProviderMapHost(view: provider.mapHostView)
                    .ignoresSafeArea(edges: .top)
                    .accessibilityLabel("Map. Long-press to choose a destination.")

                HStack(spacing: 12) {
                    Label(hint, systemImage: hintSymbol)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                    Spacer()
                    Button {
                        provider.recenter()
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.title3)
                            .frame(width: 48, height: 48)
                            .background(.regularMaterial, in: Circle())
                    }
                    .accessibilityLabel("Re-centre map")
                }
                .padding()
            }
        } else {
            ContentUnavailableView("Map unavailable", systemImage: "map",
                                   description: Text("This build has no live map provider."))
        }
    }

    private var hint: String {
        switch model.stage {
        case .choosing, .confirming, .failed: "Long-press to set a destination"
        case .requesting: "Finding routes…"
        case .preview: "Blue is your selected route"
        case .navigating: "Navigating"
        }
    }

    private var hintSymbol: String {
        if case .navigating = model.stage { return "location.north.line.fill" }
        return "hand.tap"
    }
}

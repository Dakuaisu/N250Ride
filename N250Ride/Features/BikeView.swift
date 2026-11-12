import RideCore
import SwiftUI

struct BikeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: model.bike.state.isReady ? "checkmark.circle.fill" : "bolt.horizontal.circle")
                            .font(.system(size: 56))
                            .foregroundStyle(model.bike.state.isReady ? .green : .orange)
                        Text(LinkStatusRow.text(model.bike.state))
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                        primaryAction
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } footer: {
                    Text("Close the official Bajaj app and disconnect other phones first; the dashboard talks to one phone at a time.")
                }

                if !model.bike.discovered.isEmpty || model.bike.state == .scanning {
                    Section("Nearby devices - tap your bike") {
                        ForEach(model.bike.discovered) { bike in
                            Button {
                                model.bike.select(bike)
                            } label: {
                                HStack {
                                    Image(systemName: "motorcycle")
                                    VStack(alignment: .leading) {
                                        Text(bike.name).foregroundStyle(.primary)
                                        Text("Signal \(bike.rssi) dBm")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if bike.id == model.bike.rememberedBikeID {
                                        Image(systemName: "checkmark").foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                        if model.bike.state == .scanning {
                            HStack {
                                ProgressView()
                                Text("Looking for bikes…").foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if model.bike.rememberedBikeID != nil {
                    Section {
                        Button("Disconnect") { model.bike.disconnect() }
                        Button("Forget this bike", role: .destructive) { model.bike.forgetBike() }
                    }
                }
            }
            .navigationTitle("Bike")
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch model.bike.state {
        case .ready:
            EmptyView()
        case .scanning:
            Button("Stop scanning") { model.bike.stopScan() }
                .buttonStyle(.bordered)
        case .connecting, .discovering, .reconnecting:
            ProgressView()
        default:
            if model.bike.rememberedBikeID != nil {
                Button {
                    model.bike.connectRemembered()
                } label: {
                    Text("Connect").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                Button("Scan for another bike") { model.bike.scan() }
                    .accessibilityIdentifier("scanButton")
            } else {
                Button {
                    model.bike.scan()
                } label: {
                    Text("Scan for bike").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("scanButton")
            }
        }
    }
}

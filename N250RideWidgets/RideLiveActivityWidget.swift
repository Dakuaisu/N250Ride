import ActivityKit
import SwiftUI
import WidgetKit

@main
struct N250RideWidgets: WidgetBundle {
    var body: some Widget {
        RideLiveActivityWidget()
    }
}

/// Next turn on the Lock Screen and in the Dynamic Island while riding.
struct RideLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            LockScreenRideView(state: context.isStale ? .stale : context.state, destination: context.attributes.destination)
                .activityBackgroundTint(.black.opacity(0.8))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.isStale ? RideActivityAttributes.ContentState.stale : context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.symbol)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(state.warning ? .orange : .cyan)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let arrival = state.arrival {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Arrive").font(.caption2).foregroundStyle(.secondary)
                            Text(arrival, style: .time).font(.headline)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.headline).font(.title2.weight(.bold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(state.detail).font(.subheadline).lineLimit(1).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: state.symbol)
                    .foregroundStyle(state.warning ? .orange : .cyan)
            } compactTrailing: {
                Text(state.headline).font(.caption.weight(.bold)).lineLimit(1)
            } minimal: {
                Image(systemName: state.symbol)
            }
        }
    }
}

struct LockScreenRideView: View {
    let state: RideActivityAttributes.ContentState
    let destination: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: state.symbol)
                .font(.system(size: 44, weight: .bold))
                .frame(width: 56)
                .foregroundStyle(state.warning ? .orange : .cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.headline).font(.title.weight(.bold)).lineLimit(1)
                if !state.detail.isEmpty {
                    Text(state.detail).font(.headline).lineLimit(1)
                }
                HStack(spacing: 4) {
                    if let arrival = state.arrival {
                        Text("Arrive")
                        Text(arrival, style: .time)
                    }
                    if !state.remaining.isEmpty { Text("· \(state.remaining)") }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding()
    }
}

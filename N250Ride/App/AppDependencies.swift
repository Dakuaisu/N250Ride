import Foundation
import RideCore

/// Whether a phone call is ringing, dialling or connected.
@MainActor
protocol CallStateSource: AnyObject {
    var onChange: ((Bool) -> Void)? { get set }
    var callInProgress: Bool { get }
}

extension CallMonitor: CallStateSource {}

/// Everything time-, storage- and platform-related that AppModel needs, supplied
/// before any live service starts. Tests pass virtual time and fakes; the app uses `live()`.
@MainActor
struct AppDependencies {
    var clock: RideClock
    var timers: RideTimers
    var storage: URL
    var calls: CallStateSource
    var speech: SpeechClient
    var audio: AudioSessionClient
    var liveActivities: Bool
    var activitySink: ActivitySink

    static func live() -> AppDependencies {
        AppDependencies(clock: SystemRideClock(), timers: SystemRideTimers(), storage: StorageLocation.standard,
                        calls: CallMonitor(), speech: SystemSpeechClient(), audio: SystemAudioSessionClient(),
                        liveActivities: true, activitySink: ActivityKitSink())
    }
}

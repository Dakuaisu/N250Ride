import CallKit

/// Whether a phone call is ringing, dialling or connected. iOS tells apps only the
/// call's state, never the caller's name or number.
@MainActor
final class CallMonitor: NSObject, CXCallObserverDelegate {
    var onChange: ((Bool) -> Void)?
    private let observer = CXCallObserver()

    override init() {
        super.init()
        observer.setDelegate(self, queue: .main)
    }

    var callInProgress: Bool { observer.calls.contains { !$0.hasEnded } }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        MainActor.assumeIsolated { onChange?(callInProgress) }
    }
}

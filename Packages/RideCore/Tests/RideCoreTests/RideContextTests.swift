import Foundation
import Testing
@testable import RideCore

private let place = Coordinate(latitude: 12.9716, longitude: 77.5946)!
private let other = Coordinate(latitude: 12.9352, longitude: 77.6245)!

func destination(_ label: String, _ coordinate: Coordinate = place,
                 _ provenance: DestinationProvenance = .manual) -> RideDestination {
    RideDestination(coordinate: coordinate, label: label, provenance: provenance)
}

@Suite("Ride identity and journey context")
struct RideContextTests {
    @Test func contextsRoundTripAndKeepProvenance() throws {
        let context = try #require(RideContext(itinerary: Itinerary(final: destination("Office", place, .searchResult),
                                                                    stop: destination("Fuel", other, .saved)),
                                               preferences: RoutePreferences(avoidTolls: true)))
        #expect(context.phase == .toStop && context.activeTarget.label == "Fuel")
        let decoded = try JSONDecoder().decode(RideContext.self, from: JSONEncoder().encode(context))
        #expect(decoded == context)
        #expect(decoded.itinerary.final.provenance == .searchResult)
    }

    @Test func invalidRecordsAreRejected() {
        #expect(RideContext(itinerary: Itinerary(final: destination("Office")), phase: .atStop) == nil)
        let badCoordinate = #"{"latitude": 95, "longitude": 10}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Coordinate.self, from: badCoordinate) }
        let long = String(repeating: "x", count: 61)
        let json = #"{"id":"\#(UUID())","coordinate":{"latitude":1,"longitude":2},"label":"\#(long)","provenance":"manual"}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RideDestination.self, from: json.data(using: .utf8)!) }
        #expect(destination(" " + long).label.count == RideDestination.maxLabelLength)
    }

    @Test func snapshotsNeedTheExactCommittedGeneration() {
        var machine = NavigationStateMachine()
        let session = SessionID()
        machine.begin(session)
        let future = NavigationSnapshot(session: session, generation: RouteGeneration(1),
                                        observedAt: MonotonicInstant(offset: .seconds(1)), state: .active)
        #expect(machine.accept(future) == .failure(.uncommittedGeneration), "a speculative route cannot commit itself")
        _ = machine.advanceGeneration()
        #expect(machine.accept(future) == .success(future))
    }

    @Test func refreshKeepsTheMeasurementTime() throws {
        let engine = try #require(GuidanceEngine(route: cityRoute, session: SessionID(), generation: RouteGeneration(0)))
        let measured = engine.update(LocationFix(coordinate: at(0, 200), horizontalAccuracy: 5,
                                                 observedAt: MonotonicInstant(offset: .seconds(1)))).snapshot
        #expect(measured.measurementAt == MonotonicInstant(offset: .seconds(1)))
        let refreshed = try #require(engine.refresh(at: MonotonicInstant(offset: .seconds(4))))
        #expect(refreshed.observedAt == MonotonicInstant(offset: .seconds(4)))
        #expect(refreshed.measurementAt == MonotonicInstant(offset: .seconds(1)))
    }
}

@Suite("Location admission")
struct LocationAdmissionTests {
    let receipt = Date(timeIntervalSince1970: 1_800_000_000)
    let monotonic = MonotonicInstant(offset: .seconds(100))

    func sample(age: TimeInterval, accuracy: Double = 5) -> LocationSample {
        LocationSample(coordinate: place, horizontalAccuracy: accuracy, timestamp: receipt.addingTimeInterval(-age))
    }

    @Test func acceptsCurrentSamplesAtTheirMeasurementTime() throws {
        var admission = LocationAdmission()
        let fix = try admission.admit(sample(age: 2), receiptWall: receipt, receiptMonotonic: monotonic).get()
        #expect(fix.measuredAt == MonotonicInstant(offset: .seconds(98)))
        #expect(fix.expiresAt == MonotonicInstant(offset: .seconds(103)))
    }

    @Test func rejectsCachedFutureDuplicateAndInvalidSamples() {
        var admission = LocationAdmission()
        func admit(_ s: LocationSample) -> Result<AdmittedFix, LocationAdmission.Rejection> {
            admission.admit(s, receiptWall: receipt, receiptMonotonic: monotonic)
        }
        let old = admit(sample(age: 5)), future = admit(sample(age: -1.5)), invalid = admit(sample(age: 1, accuracy: -1))
        #expect(old == .failure(.tooOld) && future == .failure(.fromTheFuture) && invalid == .failure(.invalidAccuracy))
        let near = admit(sample(age: -0.5))
        #expect((try? near.get())?.measuredAt == monotonic, "slightly future samples are clamped to receipt, not given extra life")
        let duplicate = admit(sample(age: -0.5)), older = admit(sample(age: 1))
        #expect(duplicate == .failure(.notNewer) && older == .failure(.notNewer))
    }

    @Test func requirementsFollowPurpose() {
        let now = receipt
        #expect(FixRequirement.initial.accepts(sample(age: 20, accuracy: 80), now: now))
        #expect(!FixRequirement.current.accepts(sample(age: 20, accuracy: 10), now: now))
        #expect(!FixRequirement.current.accepts(sample(age: 1, accuracy: 60), now: now))
        let afterTap = FixRequirement(maxAge: 5, maxAccuracy: 50, measuredAfter: now.addingTimeInterval(-1))
        #expect(!afterTap.accepts(sample(age: 2), now: now), "measured before the rider asked")
        #expect(afterTap.accepts(sample(age: 0.5), now: now))
    }
}

@Suite("Connection epochs")
struct BikeLinkLifecycleTests {
    @Test func oldAttemptsAndOldBikesHaveNoAuthority() {
        var lifecycle = BikeLinkLifecycle()
        let a = UUID(), b = UUID()
        let first = lifecycle.begin(a)
        #expect(first.replaced == nil)
        #expect(lifecycle.owns(a, epoch: first.epoch))
        let switched = lifecycle.begin(b)
        #expect(switched.replaced == a, "switching bikes names the old one so it can be cancelled")
        #expect(!lifecycle.owns(a, epoch: first.epoch) && !lifecycle.isCurrent(a))
        let lateA = lifecycle.validated(a, epoch: first.epoch)
        #expect(!lateA, "A's late validation cannot make B ready")
        lifecycle.retire()
        let staleTimer = lifecycle.validated(b, epoch: switched.epoch)
        #expect(!staleTimer, "a timer from before the teardown is stale")
        let retry = lifecycle.begin(b)
        let current = lifecycle.validated(b, epoch: retry.epoch)
        #expect(retry.replaced == nil && current)
        #expect(lifecycle.validatedEpoch == retry.epoch)
    }
}

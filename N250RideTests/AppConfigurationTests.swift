import RideCore
import Testing
@testable import N250Ride

struct AppConfigurationTests {
    func config(_ provider: NavigationProviderKind, key: String?, authorised: Bool) -> AppConfiguration {
        AppConfiguration(navigationProvider: provider, googleAPIKey: key, liveNavigationAuthorized: authorised,
                         provenStatusProfile: nil)
    }

    @Test func appleIsUnmeteredWithoutKey() {
        #expect(config(.apple, key: nil, authorised: false).liveRoutePolicy == .unmetered)
    }

    @Test func googleWithoutKeyIsDisabled() {
        #expect(config(.google, key: nil, authorised: true).liveRoutePolicy == .disabled(reason: "No Google API key configured"))
    }

    @Test func googleKeyWithoutAuthorisationStaysDisabled() {
        #expect(config(.google, key: "k", authorised: false).liveRoutePolicy
            == .disabled(reason: "Google eligibility/billing gates not passed"))
    }

    @Test func authorisedGoogleIsMeteredWithLocalLimits() {
        #expect(config(.google, key: "k", authorised: true).liveRoutePolicy
            == .metered(RouteRequestLimits(perDay: 20, perMonth: 600)))
    }

    @Test func defaultBuildIsAppleWithNoGoogleKey() {
        let loaded = AppConfiguration.load(bundle: .main)
        #expect(loaded.navigationProvider == .apple)
        #expect(loaded.googleAPIKey == nil)
    }
}

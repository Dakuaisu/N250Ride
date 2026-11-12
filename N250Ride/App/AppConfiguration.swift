import Foundation
import RideCore

enum NavigationProviderKind: String {
    /// Apple MapKit car-profile routing (owner decision 2026-11-12).
    case apple
    /// Google Navigation SDK; needs the SDK linked, a key and GATE-1/GATE-2.
    case google
}

/// Build-time configuration read from Info.plist (populated from Config/*.xcconfig).
struct AppConfiguration {
    var navigationProvider: NavigationProviderKind
    var googleAPIKey: String?
    /// Set only after GATE-1 and GATE-2 pass and the owner authorises activation (task 10).
    var liveNavigationAuthorized: Bool
    /// Set only after the N250 bench test proves a profile (task 9).
    var provenStatusProfile: GeneralStatusProfile?

    var liveRoutePolicy: RouteRequestPolicy {
        switch navigationProvider {
        case .apple:
            return .unmetered
        case .google:
            guard googleAPIKey != nil else { return .disabled(reason: "No Google API key configured") }
            guard liveNavigationAuthorized else {
                return .disabled(reason: "Google eligibility/billing gates not passed")
            }
            return .metered(RouteRequestLimits())
        }
    }

    static func load(bundle: Bundle = .main) -> AppConfiguration {
        let info = bundle.infoDictionary ?? [:]
        let key = (info["N250GoogleAPIKey"] as? String) ?? ""
        return AppConfiguration(
            navigationProvider: (info["N250NavigationProvider"] as? String).flatMap(NavigationProviderKind.init) ?? .apple,
            googleAPIKey: key.isEmpty || key.hasPrefix("$(") ? nil : key,
            liveNavigationAuthorized: (info["N250LiveNavigationAuthorized"] as? String) == "YES",
            provenStatusProfile: (info["N250StatusProfile"] as? String).flatMap(GeneralStatusProfile.init(rawValue:))
        )
    }
}

# N250Ride: Google Navigation feasibility

**Read date: 2026-11-11. GATE-1 OPEN/blocked pending reply.** This is documentary research, not Google approval or a device/routing test. Google live activation remains blocked by GATE-1 and GATE-2. Source IDs and full URLs are in the [evidence register](../.omo/evidence/n250-ios-navigation/task-02-feasibility.md).

## Verified facts

### Eligibility and the motorcycle display

- **Commercial-only wording remains current:** “You can use the Navigation SDK for iOS only for commercial applications.” [G2, read 2026-11-11] The reviewed pages do not define a free, single-user personal app as commercial or establish a personal-use exception. Being free, publicly available, an individual customer, or below a free billing allowance does not establish eligibility.
- **External navigation-only displays are addressed technically.** “A turn-by-turn data feed provides navigation-only information to devices not designed for map-based navigation guidance.” G1 describes maneuver icons, estimated distances/time, small displays and projecting guidance for two-wheeled vehicle riders. [G1, read 2026-11-11] This supports the feed concept; it does not expressly approve BLE delivery to this particular instrument cluster.
- **Embedded-vehicle terms need clarification.** The platform terms say: “Customer will not use the Google Maps Core Services in connection with any Customer Application or device embedded in a vehicle.” [T1 §3.2.3(f), read 2026-11-11] Applying that restriction to an iPhone sending guidance to an existing motorcycle instrument cluster remains unresolved; G1's rider-display example is not treated as a contractual exception.
- Service-specific terms permit Navigation SDK content without a corresponding Google Map, but prohibit using that content in conjunction with a non-Google map. [T2 §12.1–12.2, read 2026-11-11] Mapless display permission does not resolve personal eligibility or the embedded-system issue. The reviewed terms distinguish EEA billing addresses; an EEA-specific terms analysis was not performed.

### Attribution, terms and onboarding

- New implementations must use **Google Maps** attribution: logo where possible, text where space is limited. G2 says: “Position attribution near the top or bottom of the content, and within the same visual container.” Attribution must remain visible and legible; it cannot be hidden, obscured or modified. [G2, read 2026-11-11]
- G2's space-limited text guidance specifies unaltered “Google Maps”, no wrapping/localization, normal-weight sans-serif text at 12–16sp and 4.5:1 contrast. Logo guidance specifies 16–19dp height and clear space. Translating those published specifications to this segmented display, and its ability to comply, are **unverified**. [G2, read 2026-11-11]
- **Inference:** attribution accompanying Google content on the cluster is the conservative reading of the same-container rule. Phone-map attribution alone is not verified as sufficient for a separate cluster. No cluster-specific exemption was found. [G2, read 2026-11-11]
- “Your app must implement a dialog with the Navigation SDK Terms of Service notice that each driver must accept.” The iOS FAQ names `GMSNavigationServices.showTermsAndConditionsDialogIfNeededWithCompanyName`. [F1, read 2026-11-11] G2 prohibits modifying SDK in-product terms without written consent, and requires first-use terms, independent-judgment and applicable toll/HOV-cost notices. [G2, read 2026-11-11]
- Application terms must notify users of Google Maps features/content and flow down the Google Maps End User Additional Terms and Google Privacy Policy. Location collection requires the applicable notice/consent, including express, prior, revocable consent under the reviewed terms. [T1 §§3.2.2(a), 4.4(c), read 2026-11-11] Those linked end-user documents were not separately read. An exact current requirement for this private app to publish its **own** terms/privacy at publicly accessible URLs was **unverified**, not disproved.
- Documented setup requires a billing-enabled Google Cloud project, enabled Navigation SDK for iOS and Maps SDK for iOS, and an API key. Navigation requires the Maps SDK installed as well. [G7 actual destination; S1, read 2026-11-11] The standard setup pages do not establish a general sales-approval prerequisite. This does not waive the commercial-only policy.

### iOS capability, coverage and installation

| Question | Verified documentation result, read 2026-11-11 |
| --- | --- |
| Two-wheeler on iOS? | **Yes.** `GMSNavigationTravelModeTwoWheeler`, Swift `.twoWheeler = 3`. G8 says: “Two-wheeler routes will be fetched”. Cycling is a separate case. [G8] |
| India coverage? | **Yes, listed:** India has a filled circle under **Two-Wheeled Vehicle Directions**, and Traffic Layer, in the Navigation SDK coverage table. The legend means good data quality/availability in the area, not guaranteed success on every road. Generic cycling coverage is not evidence of motorized two-wheeler coverage. [G9; C1] |
| Latest announced SDK? | **11.3.0**, announced **2026-11-02**. Version 11.4.0 appears only as planned fixes, not an available release. [S3] |
| Minimum iOS / Xcode? | **iOS 17.0; Xcode 26.0+** for the current release. Release notes distinguish older 11.0–11.2 releases supporting iOS 16. [S1–S3] |
| Swift Package Manager? | **Yes.** “The Navigation SDK can be installed via Swift Package Manager.” Package URL `https://github.com/googlemaps/ios-navigation-sdk`, product `GoogleNavigation`; instructions recommend **Exact Version**. Pin only after checking the owner's toolchain/device. CocoaPods is deprecated from 11.0.0. [S2–S3] |

G1 establishes remaining time/distance feed data; a particular clock-time ETA field or its on-device behavior was not independently tested. No SDK installation or live India route was performed.

## Open questions

1. Is this free, initially developer-only personal use eligible despite the commercial-only restriction? No commercial status is claimed.
2. Is BLE projection to the rider's existing, vehicle-embedded N250 cluster permitted, considering T1 and G1 together? Is express permission needed?
3. What attribution must appear on that display, and what compliant option exists if its segmented hardware cannot render the prescribed branding? Is phone-only attribution ever sufficient here?
4. What application terms/privacy publication and driver-onboarding requirements apply to this private installation?
5. Which billing agreement, regional schedule and quota metrics apply to the owner? See [cost model](cost-model.md). Actual account eligibility, quotas and accepted exposure are unverified.
6. Does the owner's actual iPhone/iOS and installed Xcode support SDK 11.3.0? Documentation compatibility is not a device check.

## Question for Google (owner to send)

**Subject: Navigation SDK for iOS eligibility and motorcycle instrument-cluster guidance**

Hello Google Maps Platform team,

I am developing N250Ride, a free native iPhone app, initially for my own single-user personal use as its developer. I would install it through Xcode Personal Team signing. I am not claiming commercial status. Public distribution is only a possible future direction.

The app would use the Navigation SDK for iOS for traffic-aware two-wheeler guidance in India. It would display a Google map on the phone and send turn arrows, distance and ETA over Bluetooth LE to the existing segmented instrument cluster on my own 2026 Bajaj Pulsar N250 motorcycle. The cluster would show navigation-only guidance, not a map. Destinations would come from map long-press, locally saved favourites, or pasted latitude/longitude and full plus codes decoded on-device. I do not plan to use Places, Geocoding or Routes API.

Your iOS policy says the SDK is only for commercial applications, while the navigation-only feed documentation describes projecting guidance for two-wheeled riders. Could you please clarify:

1. Is this initially non-commercial, free personal application eligible under the Navigation SDK for iOS terms? Would making an app available free to others change eligibility, and under what conditions?
2. Is forwarding guidance to this existing motorcycle instrument cluster permitted, including under the platform terms' embedded-vehicle-system restriction? Is specific written permission required?
3. What Google Maps attribution is required on the external segmented display? If it cannot render the prescribed logo/text, is there an approved alternative, and can attribution on the phone ever suffice?
4. What driver-acceptance, application-terms and privacy-publication requirements apply to a private single-user installation?
5. Which Navigation Request billing schedule and free allowance would apply, including India eligibility, and could native map loads incur another SKU with or without a map ID? What server-enforced quota controls and exact counting units are available to limit destination events and spending?

My goal is zero additional spending. I understand that free allowances and budget alerts are not a guarantee against charges. I would appreciate written clarification before activating live navigation.

Thank you.

**Draft only; not sent by the agent.**

## Owner decisions

| Decision / event | Date / answer |
| --- | --- |
| Question sent | TBD |
| Reply received | TBD |
| Deadline after which Apple fallback (task 19) is considered | TBD — owner sets |
| Billing setup accepted | TBD |

**GATE-1 OPEN/blocked pending reply.** The current text does not establish permission for this intended use. If eligibility or acceptable cost exposure cannot be settled, the owner-approved direction is task 19: Apple MapKit, explicitly labelled **car-profile routing**. The owner confirms the switch; it is not automatic, and this research does not implement it.

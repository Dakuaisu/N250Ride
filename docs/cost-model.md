# N250Ride: Navigation cost model

**Read date: 2026-11-11. GATE-2 OPEN/blocked pending owner billing decision.** Standard published pay-as-you-go prices, not a customer-specific quote. No billing account or project was inspected or changed. Full source URLs are in the [evidence register](../.omo/evidence/n250-ios-navigation/task-02-feasibility.md).

## Verified billing unit

The Navigation Request SKU bills **destination events**, not riding hours. The SKU definition says: “Each destination included in the request.” [B1, read 2026-11-11] G3 says: “API calls can include one or more destinations, also referred to as waypoints.” One call can therefore produce multiple billable events, up to the documented 25 destinations per request. [G3; B1, read 2026-11-11]

| Action | Billing treatment / planning rule |
| --- | --- |
| Request a route to one destination | One requested destination event. [G3; B1] |
| Request multiple destinations/waypoints | Count every destination included, not just the last stop or the number of method calls. [G3; B1] |
| Explicitly replace destinations | `setDestinations` overrides the previous destinations. Conservatively count **all destinations in the replacement request**, including retained stops. [B1; B6] |
| Submit identical destinations again | No explicit same-coordinate deduplication exemption was verified. Count again before dispatch; do not assume reuse is free. This is conservative application of the published per-request rule. [G3; B1; B6] |
| Start turn-by-turn guidance on an obtained route | “There are no additional charges to start turn-by-turn guidance for a route.” [G3] |
| Ordinary SDK traffic/closure/deviation reroute after a destination was fetched | No additional Navigation charge for those route changes. This exemption is not proof that a new app-issued destination request is free. [G3] |
| Simulate along a **new** route using listed SDK methods | Listed as a billing trigger; SDK simulation must not be confused with local no-network fixtures. [B1] |

All sources in this table were read 2026-11-11. The SKU trigger list still uses older `callback:` signatures; the current API reference also documents newer `completionHandler:` variants. That documentation mismatch does not establish an exemption. [B1; B6]

**Inference from the billing unit:** six hours of navigation has no separate hourly Navigation Request fee in this published model; charges depend on requested destinations and any other applicable SKUs. This is not a statement that all SDK activity is free.

## Published Navigation Request prices

All rates below are **USD per 1,000 destination events**, applied incrementally to monthly usage. Custom agreements/Mobility Services may differ. [G3–G5; B3, read 2026-11-11]

| Global monthly events | USD / 1,000 |
| --- | ---: |
| 1–1,000 | Free |
| 1,001–100,000 | 25.00 |
| 100,001–500,000 | 20.00 |
| 500,001–1,000,000 | 15.00 |
| 1,000,001–5,000,000 | 8.00 |
| 5,000,001 onward | 2.00 |

Source: G4, read 2026-11-11. SKU: Navigation Request (`AF6D-A7B0-31CF`).

| Eligible India monthly events | USD / 1,000 |
| --- | ---: |
| 1–7,000 | Free |
| 7,001–5,000,000 | 8.00 |
| 5,000,001 onward | 2.00 |

Source: G5, read 2026-11-11. SKU: Navigation Request (India) (`9C23-024B-56A1`). The final tier is applied above five million, avoiding a duplicated boundary in the page's “5,000,000+” heading.

### Regional eligibility and allowance scope

- India pricing requires an **India-based customer, billed in India, with a large majority of usage in India**. In-region usage is defined by locations requested or returned. Google monitors eligibility and may disqualify ineligible customers; a numeric “large majority” percentage was not verified. India residence or an India route alone does not prove eligibility. [B3; B5, read 2026-11-11]
- G5 publishes USD rates; B5 says new India-based customers are charged in INR using the applicable currency conversion. `$8` does not mean ₹8. Actual owner billing currency/eligibility is unverified. [G5; B5, read 2026-11-11]
- Free usage is **per SKU per month**, and Google aggregates projects linked to the billing account. A separate project under that account must **not** be modeled as receiving another independent Navigation free allowance. This conclusion combines the per-SKU allowance and account-aggregation rules; it is not a standalone quotation about separate projects. [G4; B3–B4, read 2026-11-11]
- Free usage resets on the first day of the month at midnight Pacific US time. Other projects' consumption of the same SKU reduces available headroom. [B3–B4, read 2026-11-11]

## Worked examples

Assumptions: one destination per explicit request; 30 days; no other consumption of the Navigation SKU on the billing account; applicable published allowance; no other paid SKU usage. These are Navigation-only arithmetic examples, not a zero-bill promise.

| Destinations/day | Days | Events | Global free cap / remaining | India free cap / remaining | Navigation charge under assumptions |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | 30 | 60 | 1,000 / 940 | 7,000 / 6,940 | US$0 |
| 10 | 30 | 300 | 1,000 / 700 | 7,000 / 6,700 | US$0 |
| 20 | 30 | 600 | 1,000 / 400 | 7,000 / 6,400 | US$0 |

The plan's **1,000 free then US$25/1,000 global**, and **7,000 free then US$8/1,000 eligible India**, match the current first-tier prices. [G4–G5, read 2026-11-11]

## Quotas and zero-spend limitations

| Control / metric | Verified documentation and remaining limitation |
| --- | --- |
| Per-minute limit | G3's **HTML Page Summary**, not its main-body limits section, states **30,000 queries per minute**. It is not explicitly labelled a default. Queries are not documented there as destination events. Actual project metric/value remains unverified. |
| Per-call limit | Up to **25 destinations/waypoints per request**. This is a payload limit, not a spending cap. [G3; B1] |
| Daily controls | G6 documents project-level quotas and daily reset at midnight Pacific. **Navigation-specific daily default, exact counter unit, available minimum setting and applicability to this owner project are unverified.** |
| Matching billing units | G6 says to select a quota counting the SKU's billing unit. A requests/day quota cannot be assumed to cap destination events/day when one call includes several destinations. |
| Budget alerts | “Setting a budget does not automatically cap Google Cloud or Google Maps Platform usage or spending.” Alerts are notifications, not request rejection. [G6] |
| Measurement | G6 says quota metrics are not the billing source of truth; finalized-charge visibility can lag up to 48 hours. Actual quota enforcement and billing boundaries have not been tested. |

Sources read 2026-11-11. Server quotas can restrict project usage, but no account-specific hard spending boundary is established here. A dedicated project is useful for isolation, not another free allowance or a proven zero-charge cap. No console changes were made.

## Other SKU exposure: the native map

- **Maps SDK:** the SKU details identify iOS `GMSMapView` **without a map ID** as a trigger. The current global and India tables show **Unlimited** free Maps SDK usage. Panning/zooming/layer changes do not themselves generate additional map loads. The current SKU replaces older Mobile Native Dynamic/Static Maps naming. [B2; B4; G4–G5, read 2026-11-11]
- **Dynamic Maps:** not JavaScript-only. Its SKU details explicitly include **Navigation SDK for iOS and Maps SDK for iOS map loads with a map ID**. Such usage can trigger a separate map-load SKU alongside Navigation Request. [B2, read 2026-11-11]
- Dynamic Maps globally: **10,000 free/month**, then USD/1,000 loads **$7.00** through 100,000; **$5.60** through 500,000; **$4.20** through 1,000,000; **$2.10** through 5,000,000; **$0.53** thereafter. Eligible India: **70,000 free**, then **$2.10** through 5,000,000 and **$0.53** thereafter. These are separate per-SKU allowances, subject to shared account consumption. [G4–G5, read 2026-11-11]
- The no-map-ID native Maps SDK rule supports a free map-load baseline, but the exact billing-line attribution for a **Navigation** map without a map ID is less explicit in B2. It remains **unverified**; do not promise every Navigation map is bundled or always free. A map embedded in a native app is not thereby the separate Maps Embed API product.
- Planned destination selection is map long-press, local favourites, pasted coordinates or full plus codes decoded on-device. It requires no Places, Geocoding or Routes API calls. Their usage would be separate exposure if later added; it is excluded from this workflow. [Project scope; SKU separation in G4–G5]

## Planned local limits — safeguards, not a guarantee

These are implementation requirements from the plan, **not controls implemented or tested by this research**:

1. Persist a maximum **20 destination submissions/day** and **600 per calendar month**. Count each waypoint/destination conservatively **before dispatch**, including attempts and replacement requests, rather than counting only successes or one method call per route.
2. Reject excess, serialize requests, prevent concurrent/double submissions and **never automatically retry destination requests**. A deliberate user retry is a new counted attempt. Reconnection or UI recreation must not resubmit.
3. Local counters can reset on reinstall and do not see other devices/projects/account consumers. They are **not a zero-spend guarantee** and do not enforce account-wide limits.
4. Define the counter timezone explicitly during implementation; a local calendar month/day does not automatically align with Google's Pacific billing/quota boundaries. A 31-day month also remains bounded by the 600/month limit, rather than assuming 20 × 30 forever.

## Open decisions and gate

The owner must decide whether to accept billing setup/exposure, establish India eligibility and shared usage, verify actual quota availability/units/enforcement, clarify no-map-ID Navigation map billing, and resolve personal/cluster permission in [GATE-1](feasibility.md). No evidence currently proves a zero-spend hard cap.

**GATE-2 OPEN/blocked pending owner billing decision.** Google live requests remain disabled until both gates pass and activation is separately authorized. If unresolved or declined, the owner decides whether to trigger task 19, the approved **Apple MapKit car-profile routing** fallback, labelled as such; no automatic switch is authorized here.

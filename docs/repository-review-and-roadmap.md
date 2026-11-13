# N250 Ride: Repository Review and Roadmap

Review date: 2026-11-13. Repository: the repository root. Baseline commit: `52c656bd8ab1e086fee659579e9230cbde7c0dc7`. The working tree was clean before review. This is a read-only implementation review, not approval for road use. Only this report was intentionally authored; no recommendation was implemented.

## 1. Executive overview

### App and architecture

N250 Ride is an iPhone navigation companion for a Bajaj Pulsar N250 instrument cluster. Apple MapKit provides **automobile**, not motorcycle-specific, routes. A local guidance engine interprets route steps and GPS measurements; a Bluetooth adapter sends 48-byte navigation frames to the existing dashboard. The phone also provides spoken instructions and a Live Activity.

The architecture is appropriate for this app: a process-lifetime, main-actor `AppModel` owns the ride, an isolated pure-Swift `RideCore` package implements policy, and narrow location/directions/audio interfaces support deterministic tests. Retain these boundaries rather than rewriting the application.

| Area | Current implementation and ownership |
| --- | --- |
| Languages/build | Swift 6, SwiftUI/UIKit, SwiftPM, XcodeGen YAML, xcconfig/plists, shell scripts; Java only for offline protocol-oracle tooling. iOS deployment target 17; RideCore also targets macOS 14. |
| Entry points/targets | `N250RideApp` creates one `AppModel`; `ShareViewController` is the share-extension entry; `N250RideWidgets` supplies the Live Activity. Separate app-unit and UI-test targets. |
| Dependencies | Enabled project/package dependencies are local `RideCore` and app-owned extensions. Apple frameworks include MapKit, CoreLocation, CoreBluetooth, AVFoundation, ActivityKit, WidgetKit, CallKit, Observation and UniformTypeIdentifiers. Google Maps/Navigation 11.3.0 entries are commented out; their source is conditional. |
| Route state | `RideID` identifies the logical journey; `SessionID` identifies a running leg; `RouteGeneration` identifies a committed reroute; operation UUIDs and prepared handles identify provisional work. `NavigationStateMachine` accepts only the exact committed generation. |
| GPS/concurrency | Platform callbacks enter main-actor adapters. `LocationAdmission` maps genuine sensor timestamps to monotonic measurement/expiry instants. Route requests prepare separately from synchronous commit. `RideTimers` schedules application deadlines; some BLE/console work still uses direct sleeping tasks. |
| Dashboard | `SessionCoordinator` derives output intent; `ClusterWritePump` coalesces pending work, prioritizes clear, serializes acknowledged writes, honors without-response readiness, and stalls after an ambiguous timeout. `BikeConnection` owns the actual central/peripheral. |
| Persistence | Favourites/Home/Work/recents, switches and counters use UserDefaults. Recovery, app inbox, history and bike reports use bounded versioned JSON files in Application Support, atomic replacement, after-first-unlock protection and backup exclusion. These files currently run synchronously on the main actor. |
| External inputs | GPS and authorization, MapKit directions/search results, BLE advertisements/services/characteristics/callbacks, audio/call notifications, shared item providers, pasted text and `n250ride://` URLs, short-link HTTP redirects, saved JSON and preferences. |

Control flow is: destination confirmation -> route-gate authorization -> provider prepare -> preview -> fresh-position Start check -> provider commit -> coordinator session -> accepted GPS -> guidance -> phone/voice/activity/dashboard projections. Reroutes retain the old route until commit. Stop invalidates app route work, stops the provider, ends the coordinator session and requests clearing. A transport result is **not** proof of physical display or clearing.

### Coverage and limitations

The review accounted for all **119 tracked files**, including **94 Swift files**. The two unmodified upstream OLC CSV fixtures were excluded from authored-code inspection; their notice and consuming tests were read. All remaining tracked authored source, tests, manifests, configuration, tooling and documentation were reviewed through the review lanes. The local ignored xcconfig, 11 authored Markdown files under `.omo`, and generated project/scheme metadata were also inspected. The lead reviewer independently traced the report's consequential findings through current source and callers; an adversarial cross-check removed several first-pass false positives. The complete inventory and exclusions are in section 9.

Fresh verification: **157 Swift Testing tests in 34 suites passed**; a simulator app build and build-for-testing succeeded. App/UI tests were compiled, **not executed**. No simulator was launched or reconfigured; no bike, headset, physical phone, account, signing/provisioning or paid service was accessed. No runtime reproduction of the app-adapter findings is claimed. Static confirmation and remaining device uncertainty are explicitly separated below.

### Top five risks

1. **Stale spoken instructions:** pending turn prompts can survive freshness expiry or a step change even after phone/dashboard guidance is suppressed (H1).
2. **Output inconsistency:** Live Activity deduplication ignores changing sensor expiry; visible clear/ACK wording can overstate what the bike did (M1, L1).
3. **Cancellation/transition gaps:** cancelled fix waits retain GPS work, a delayed Start can cross preview expiry, and arrival at a stop can leave an abandoned reroute holding the request gate (M2, M3).
4. **Persistence correctness:** future-schema records can be overwritten despite being rejected on load; failed mutations can diverge from disk; continuing a two-leg ride resets history totals (M4-M6).
5. **BLE evidence attribution:** console writes bypass the pump's single-flight assumptions, and the setup wizard can reuse old clear evidence or skip showing its test arrow (M7, M8). Actual cross-connection callback timing and cluster behavior remain unverified.

### Top five opportunities

1. Extend the existing deterministic replay to delayed Start, expiry, speech completion, stop-arrival and storage-failure boundaries.
2. Add a small Bluetooth platform seam and a fake ActivityKit sink, testing production adapter logic rather than only pure helper policies.
3. Deliver a parked pre-ride readiness card and honest ETA/route-age explanation without another routing backend.
4. Add a read-only maneuver preview and explicit destination-entrance refinement, keeping interaction before the ride.
5. Complete privacy/storage controls and capability-gated durable sharing, rather than duplicating already implemented recovery/history/inbox features.

### Protections already present, not new findings

Current source already implements transactional Apple route preparation, operation deadlines, ticket release on ordinary Cancel/Stop, session and exact-generation rejection, source-timestamp admission, independent measurement freshness, no off-route votes from refresh, distinct step sequence, bounded/latest-value pump queues, timeout-stall/reconnect, clear retry, both TI FFC/FFD firmware-family write blocks including service checks, overlapping call/audio holds, and bounded categorical diagnostics. See `AppModel.swift:600`, `AppleNavigationProvider.swift:106`, `Navigation.swift:155`, `LocationAdmission.swift:59`, `GuidanceEngine.swift:164`, `ClusterWritePump.swift:128`, and `BikeConnection.swift:164` under their inventory paths. Older plans describing these as missing are not current proof.

## 2. Confirmed findings

Severity describes demonstrated implementation impact, not a predicted accident. **Statically confirmed** means the current control/data flow establishes the defect; it does not mean a device scenario was reproduced. No remotely exploitable critical vulnerability or active dependency vulnerability was established.

### Critical

None confirmed.

### High

#### H1. Queued turn speech can outlive both its measurement and its maneuver

**Evidence:** `N250Ride/Navigation/VoiceGuide.swift:99` (`handle`), `:141` (`enqueue`), `:165` (`finished`); `Packages/RideCore/Sources/RideCore/Guidance/VoicePromptPlanner.swift:10` (`VoicePrompt`); `N250Ride/App/AppModel.swift:1155` (`wakeUp`). **Status: statically confirmed; no real-audio reproduction.**

**Trigger/failure:** A turn prompt is speaking and a closer-stage prompt is pending. GPS stops updating. At the five-second measurement expiry, `wakeUp` clears dashboard intent and updates health/activity, but does not invalidate voice. When the current utterance finishes, `finished` can speak the pending turn: it checks holds and session/generation, not current eligibility or measurement expiry. Even an ineligible active snapshot merely returns from `handle`; it does not silence existing speech. Separately, a new step that generates no replacement prompt leaves the previous step's pending turn eligible by session/generation alone. The rider can hear an obsolete turn after the other surfaces correctly pause.

**Existing guards/tests:** Holds, route identity and utterance tags are useful. `RideFlowTests.swift:404` tests an initially ineligible snapshot and generation replacement, not an already queued prompt expiring or a same-generation step transition. The planner has a step key, but the queued `VoicePrompt` does not carry it.

**Smallest effective fix:** Pass eligibility invalidation into voice when health/deadlines change; stop current turn speech and discard pending turns on expiry. Include session/generation/step identity and a validity deadline in queued turn context, and revalidate immediately before speaking. Preserve deliberate status announcements and independent call/interruption/output holds; do not replay a backlog when a hold ends.

**Regression:** Queue mid/Now prompts, advance fake time through measurement expiry without another snapshot, finish the first utterance, and assert no pending turn speaks and audio is deactivated. Repeat with a new step that has no prompt, unsupported/no-location states, route replacement and overlapping holds.

### Medium

#### M1. Live Activity deduplication discards renewed GPS expiry

**Evidence:** `N250Ride/App/RideLiveActivity.swift:39` (`update`, especially `:44`); `N250Ride/App/AppModel.swift:1084` (`staleDate`); `N250RideWidgets/RideLiveActivityWidget.swift:16` and `:20` (stale presentation). **Status: statically confirmed submitted-content defect; physical rendering unverified.**

**Trigger/failure:** Fresh fixes arrive while the rider is stationary or displayed distance/ETA rounds to the same values. `ContentState` is unchanged, so `update` returns even though the newly supplied `staleDate` is later. ActivityKit retains the expiry of an older measurement and can show stale content while phone guidance remains current. Apple explicitly defines staleDate/isStale as the stale-content contract [A3]. Energy mode's ten-second minimum interval is also longer than the five-second evidence lifetime: simply adding expiry to equality without reconciling those policies is insufficient.

**Existing guards/tests:** Widget variants correctly render `.stale`; serialized update/end tasks prevent one class of ordering race. Those safeguards do not renew expiry. Tests disable real Live Activities and do not observe submitted content/deadlines.

**Fix:** Track the last submitted expiry as well as displayed state. Schedule bounded freshness renewals with headroom below the five-second lifetime, or deliberately publish a non-directional low-update mode. Keep immediate downgrades and serialized End; inject a clock/activity sink. Do not promise exact system rendering time or app wakeups from staleDate.

**Regression:** Equal states with later measurements must submit later expiries; throttle suppression must leave a scheduled renewal, not lose it. Test stationary rides, energy mode, expiry, wall-clock changes and End overtaking queued work. Physical lock-screen/island validation remains a separate gate.

#### M2. Preview lifetime and location-acquisition cancellation are not enforced through the whole async Start path

**Evidence:** `N250Ride/App/AppModel.swift:704` (preview expiry), `:735` (`startNavigation`, callback at `:753`); `N250Ride/Navigation/AppleNavigationProvider.swift:161` (`checkStart`), `:187` (`cancelPreparation`), `:193` (`discardPrepared`), `:276` (`awaitFix`), `:315` (`updateLocationRunning`). **Status: statically confirmed.**

**Trigger/failure:** Start is tapped shortly before the two-minute preview limit while no current fix exists. Preview expiry fires during the fix wait. A later `.ready` answer still calls `commitStart`, because its callback checks the handle/stage but not expiry again. Also, cancelling preparation releases its owner but leaves its waiter; discarding a preview with an outstanding Start check leaves both its waiter and acquisition owner until callback/15-second timeout. GPS can continue acquiring after the rider cancelled, and repeated cancelled waits accumulate temporarily.

**Existing guards/tests:** Handle checks prevent an old preview reopening a different one; full `provider.stop()` drains waiters. `RideFlowTests.swift:88` checks expiry before Start, not during it. `AppleProviderAdapterTests.swift:43` checks timeout cleanup and `:95` checks ignored cancelled answers, not immediate cancellation cleanup.

**Fix:** Associate each waiter/owner with its operation or prepared handle and cancel it on that exact cancellation/discard. Recheck proposal identity and expiry immediately before committing. Cancel or explicitly invalidate an outstanding Start check when the preview expires. Keep map/guidance ownership intact when releasing only acquisition work.

**Regression:** Start at preview age 119 seconds, deliver a fresh near-origin fix after expiry, assert zero commits. Cancel an initial acquisition or Start check with no map/guidance owner and assert location stops immediately, no waiter remains and its old timeout has no effect on a newer request.

#### M3. Reaching an intermediate stop can leave a cancelled reroute blocking Continue

**Evidence:** `N250Ride/App/AppModel.swift:992` (`handleArrival`), `:933` (`continueToFinal`), `:629` (operation coalescing), `:678` (`operationTimedOut`); `N250Ride/Navigation/AppleNavigationProvider.swift:216` (`stop`). **Status: statically confirmed.**

**Trigger/failure:** Manual reroute is preparing while the rider reaches the intermediate stop. Arrival stops the provider, which silently cancels its pending preparation, but `AppModel.operation` and its ticket remain. Continue clears the visible route status then returns at the existing-operation guard. It cannot calculate leg two until the original 30-second operation deadline, measured from reroute start, releases the ticket; that timeout can then display an obsolete manual-reroute error. This is a bounded stall, not resurrection of the old leg.

**Existing guards/tests:** Ordinary Cancel/Stop release the app operation; next-leg sessions are correctly distinct. `StopFlowTests.stopArrivalEndsTheLegAndWaitsForContinue` (`RideFlowTests.swift:170`) has no calculation in flight at arrival.

**Fix:** On the reached-stop transition, retire/cancel and finish any app-owned operation before stopping the provider, clear its visible status, then enter atStop. Reuse existing cancellation/ticket finalization rather than inventing another gate.

**Regression:** Start a manual reroute, deliver an accepted stop arrival, immediately Continue after satisfying debounce, and assert one next-leg preparation with a new session; advancing past the abandoned deadline must change nothing.

#### M4. Rejected future-schema records can still be overwritten by ordinary actions

**Evidence:** `N250Ride/Persistence/ProtectedFileStore.swift:39` (`load`) and `:54` (`save`); `IncomingInbox.swift:51`/`:75`; `RideHistoryStore.swift:39`/`:60`; `RecoveryStore.swift:35`/`:54`, all under `N250Ride/Persistence`. **Status: statically confirmed.**

**Trigger/failure:** A newer app version writes schema N+1, then an older build opens it. Load reports unknown schema, but store initialization continues with empty/default state and nothing prevents `save`. Adding an inbox item, toggling history, or starting a recovery-enabled ride overwrites the rejected file with schema 1. This contradicts `StoreError.unknownSchema`'s explicit never-overwrite-until-discard contract and the recovery error message.

**Existing guards/tests:** Header/schema checks prevent unsafe decoding; atomic writes prevent partial replacement. Neither prevents replacement of incompatible data. The damaged-record test (`RideFlowTests.swift:307`) checks an offer/error, not preservation after subsequent writes.

**Fix:** Retain a typed load state and make an existing incompatible/unavailable record non-writable until successful reload, supported migration or explicit discard/reset. Do not conflate unavailable data with an empty store. Handle recovery, inbox, history and bike-report consumers consistently; storage failure need not stop safe in-memory navigation.

**Regression:** Seed future-schema bytes, load each store, exercise normal mutation/start/enable actions, and assert original bytes are unchanged and the user sees a recovery/discard choice. Explicit discard should be the only reset path.

#### M5. Failed persistence mutations can diverge from disk, including accepted inbox intent

**Evidence:** `N250Ride/Persistence/IncomingInbox.swift:112` (`update`), `:118` (`remove`), `:93` (`setStatus`); `N250Ride/App/AppModel.swift:389` (`confirmDestination`), `:982` (`replaceDestination`), `:790` (consume); `N250Ride/Persistence/RideHistoryStore.swift:122`/`:131`/`:184` (deletion/save). **Status: statically confirmed error-path defect.**

**Trigger/failure:** A file write fails, for example due to unavailable storage or disk exhaustion. Inbox status/delete/resolve and history deletion mutate published memory before saving, with no rollback/result contract. A removed item or history row can return after relaunch. More importantly, setting an inbox item accepted returns no result, so route preparation can proceed despite failure to durably record that acceptance. A crash can leave a misleading pending/previous state. No automatic redispatch occurs, so do not inflate this into guaranteed duplicate requests.

**Existing guards/tests:** Stores set generic `problem` messages; inbox `add` already rolls back on failure. Thus errors are not entirely silent, but callers cannot distinguish durable success. The ordinary restart/capacity tests at `RideFlowTests.swift:256` and successful history deletion at `:331` do not inject failures. During navigation, inbox failure is less visible than on its waiting-items screen.

**Fix:** Return typed mutation results, preserve a committed snapshot and expose pending/failed changes or rollback where appropriate. Durable acceptance must succeed before dispatching an inbox-backed operation. Consumption/deletion failure needs an explicit retry state and identity-based suppression, without interrupting an already safe active route. Do not claim secure erasure or cross-store atomicity.

**Regression:** Inject failures before replacement and after runtime commit. Assert no provider dispatch after failed acceptance, no false successful deletion, explicit retry, idempotent restart and no automatic retry. Test the case where file bytes were replaced but backup-exclusion metadata then failed, since the current save can report failure after replacement.

#### M6. Continuing to leg two resets the first leg's history accumulator

**Evidence:** `N250Ride/App/AppModel.swift:1003` (`history.breakSegment` on stop), `:789` (`history.begin` in `commitStart`); `N250Ride/Persistence/RideHistoryStore.swift:79` (`begin`) and `:162` (`flushDraft`). **Status: statically confirmed.**

**Trigger/failure:** History is enabled for a ride with a stop. The first leg accumulates time/distance; reaching the stop breaks its sensor segment without finalizing the logical ride. Starting leg two calls `begin` again. It looks only in saved `contents.rides`, not the existing recording/draft, and commonly creates a zero accumulator. The completed summary omits leg one's totals. Reinitialization can also replace useful draft/revision state.

**Existing guards/tests:** `RideID` correctly survives the stop; `RideAccumulator.breakSegment` itself preserves totals. Tests cover itinerary continuity and isolated accumulator behavior, but the stop flow (`RideFlowTests.swift:170`) never asserts recorded totals.

**Fix:** Make begin/resume semantics explicit. Continuing the same actively recorded ride and consent epoch should retain its accumulator/revision and only reset sensor anchors; cold recovery should load the highest committed baseline. Preserve opt-out and deletion suppression. Also specify/test whether a ride originally started with history off may begin recording after recovery; the current no-row path lacks an original-start consent marker.

**Regression:** Feed distinct measured movement/time into two legs, Continue, finish, and assert one row with both segments and no stop-gap bridge. Add interruption/resume, enable/disable, deletion and revision tests.

#### M7. Raw BLE writes do not preserve callback ownership

**Evidence:** `N250Ride/Bluetooth/BikeConnection.swift:49` (`pendingRawWrites`), `:183` (`rawWrite`), `:459` (`didWriteValueFor`); `Packages/RideCore/Sources/RideCore/Link/ClusterWritePump.swift:108` (`didCompleteWrite`). **Status: callback-routing defect statically confirmed; physical callback interleaving/unintended delivery not reproduced.**

**Trigger/failure:** Two acknowledged raw writes to the same characteristic are tracked as one Set entry. The first callback consumes it; the second falls through to the pump. All non-navigation UUIDs, including unknown or alert channels, are mapped to `.status`. If a pump status write is in flight, an unrelated callback can complete it; otherwise the raw result is lost. Raw status can also overlap an already submitted pump status write when console pause is enabled, because pausing does not retract the in-flight write. The single-flight guarantee covers pump traffic, not all writes made to the peripheral.

**Existing guards/tests:** Raw navigation writes are forbidden; status requires the app's status sender to be paused/off; firmware UUID/service checks and negotiated size checks are present. Pump-only tests correctly verify serialization and timeout stalling. They cannot exercise delegate routing. Apple callbacks identify peripheral/characteristic/error, not an app transaction [A1].

**Fix:** Establish one acknowledged-write owner across raw and pump paths, or reject raw writes until pump traffic on the affected channel is quiescent. Track individual raw operations rather than a UUID Set. Reject non-current peripherals and unknown pump characteristics before completion routing. For same-peripheral reconnects, do not pretend a callback supplies an epoch; use an explicit lifecycle/adapter contract and retire ambiguous work.

**Regression:** Adapter-level fake events for two same-characteristic raw writes, raw/pump overlap, unknown-channel callback during status flight, failed callbacks, disconnect and timeout. Assert one owner per completion. Actual late callbacks across reconnect remain a device gate, not a claimed Apple ordering violation.

#### M8. Bike setup can reuse old clear evidence and omit the arrow-before-clear observation

**Evidence:** `N250Ride/Features/BikeSetupModel.swift:158` (`sendClear`), `:181` (`sendStopFrame`); `N250Ride/Features/BikeSetupView.swift:64`; `Packages/RideCore/Sources/RideCore/Session/SessionCoordinator.swift:190`/`:365`; `Packages/RideCore/Sources/RideCore/Link/ClusterWritePump.swift:94`. **Status: statically confirmed validation weakness; no claim about actual cluster behavior.**

**Trigger/failure:** Link setup already sent and acknowledged a clear. The wizard's Clear action calls `clearDiagnosticFrame`; when output is already clear, the coordinator intentionally sends nothing new. The wizard immediately samples the previous global `.clearTransportAcknowledged` and marks its action Pass. This is reuse of earlier evidence, not a real new clear miscredited after `submitClear` (that path correctly resets delivery). For the stop-frame check, show-arrow and clear are submitted back-to-back; if transport is busy/backpressured, the clear discards the unsent pending arrow. The rider may be asked whether an arrow disappeared without first seeing it appear.

**Existing guards/tests:** Capability reports distinguish transport from visual results, and the main verdict requires rider observations. `BikeSetupTests` (`RideFlowTests.swift:442`) tests those verdict rules, not operation-specific clear evidence or a held transport.

**Fix:** Give the wizard an explicit fresh-clear operation/result. Keep pending/inconclusive until that operation completes; never infer display from ACK. Split Show arrow and Clear into rider-driven steps and require an appeared observation before testing disappearance. Keep ordinary coordinator clear deduplication for normal navigation.

**Regression:** Start from a prior acknowledged clear; wizard must submit a new request and not immediately pass. Hold writes, show/clear, and verify the workflow cannot record a successful disappearance without an observed appearance. Repeat on no-response links; physical display still needs parked validation.

#### M9. Changed route preferences do not reach reroutes of the existing ride

**Evidence:** `N250Ride/Features/RideSettingsView.swift:38` and `:45` (controls promise new routes/reroutes); `N250Ride/App/AppModel.swift:102` (`routePreferences.didSet`), `:852` (`requestReroute`), `:664` (request uses `context.preferences`); `N250Ride/Navigation/AppleNavigationProvider.swift:119`. **Status: statically confirmed.**

**Trigger/failure:** Start a ride with tolls/highways allowed, turn an avoidance switch on, then explicitly recalculate. The setting updates defaults and `provider.routePreferences`, but the request uses the existing RideContext preferences captured earlier. The Apple prepare path reads the request, not that provider property. The rider's recalculation can ignore the changed avoidance setting. Apple avoidance remains advisory even after this implementation bug is fixed.

**Existing guards/tests:** Settings apply to newly constructed contexts. `AppModelProviderTests.swift:246` checks only the spy's mutable property, not the actual next request/query.

**Fix:** Define one effective preference owner. For the documented behavior, copy the current explicit preferences into the proposed reroute context and commit/checkpoint that context only when replacement succeeds. Alternatively make the UI explicitly say changes apply only to the next ride, but that reduces the existing promise. Avoid keeping an unused duplicate provider setting as a misleading abstraction.

**Regression:** Change switches during navigation, request manual/automatic reroute and next leg, assert request/query flags and persisted effective context; failed preparation must not silently mutate the committed route's policy.

### Low

#### L1. Some UI/console wording claims more than the output path proves

**Evidence:** `N250Ride/Features/RideView.swift:391` (`DashboardIntentView`, `:400` says "Dashboard cleared"); `N250Ride/Bluetooth/BikeConnection.swift:202` (no-response write emits `.wrote(...nil)`); `N250Ride/Features/BluetoothConsole.swift:189` (`handle` labels that "Write acknowledged"), `:94` ("shown for 5 s"). **Status: statically confirmed.**

The ride footer sees only intent, so can claim cleared while disconnected or pending. A no-response raw write is immediately logged acknowledged without an acknowledgement; diagnostic submission is described as shown without visual evidence. `DashboardDelivery` and the core tests already distinguish these facts, so reuse them in presentation. Use "clear requested", "submitted without response", and "test requested for 5 s"; reserve visual confirmation for the rider. Add string/presentation tests for link-down, pending, no-response, transport ACK and visual observation. This is not evidence that the physical cluster failed to clear.

#### L2. UI tests are not actor-clean on the current toolchain

**Evidence:** `N250RideUITests/SimulationUITests.swift:4` and `N250RideUITests/LiveAppleRouteUITests.swift:5` (test classes/methods). **Status: reproduced compiler warnings, not reproduced runtime races.**

The fresh Xcode 27.2 build-for-testing succeeds but emits many diagnostics for calling main-actor XCUIAutomation APIs from nonisolated test methods/autoclosures. Correct test isolation using supported XCTest/main-actor annotations or isolated helpers, without weakening strict checking. Rebuild both test targets and require these diagnostics to disappear; then run the relevant UI tests under an authorized simulator workflow. There is no basis here to assert that every warning is a distinct runtime bug.

#### L3. Setup/troubleshooting still describe a Google-first baseline

**Evidence:** `docs/setup.md:21` says bootstrap resolves pinned Google packages; `docs/troubleshooting.md:7` says Simulation is expected without Google credentials; `Config/App.xcconfig:1` says no-key simulation. Current enabled dependencies/provider contradict those claims (`project.yml:15`, `AppConfiguration.swift:20`). **Status: statically confirmed documentation inconsistency.**

Readers can be steered toward unnecessary keys or billing setup while the Apple build needs neither. Update current-path text, clearly label conditional Google instructions and archival plans, and describe freshness as measurement age rather than simply "no navigation update" (`troubleshooting.md:15`). Acceptance: no-key Apple setup and explicit simulation have separate explanations consistent with configuration tests. Do not change credentials, enable Google or regenerate the project merely to correct documentation.

## 3. Performance and efficiency

### Measurements actually obtained

| Measurement | Result | Interpretation |
| --- | --- | --- |
| Fresh external-scratch core build | 26.15 seconds reported by SwiftPM | Toolchain/build observation, not app launch or runtime speed. |
| Core Swift Testing run | 157 tests / 34 suites, 0.099 seconds reported | Deterministic core tests pass; not an endurance benchmark. XCTest separately printed zero tests because this package uses Swift Testing. |
| Generic iOS Simulator app build | Exit 0 | Current app/extensions compile; no simulator runtime or device proof. |
| Build-for-testing | Exit 0, UI actor-isolation warnings | Test bundles compile, but were not run. |
| Battery, peak RAM, GPS/CPU load, ActivityKit latency, BLE throughput | Not measured | No quantitative savings, road reliability or six-hour claims are justified. |

### Reasoned costs, not benchmarks

| Source/cost | Consequence and proportionate improvement | Evidence/acceptance |
| --- | --- | --- |
| `RoutePolyline.project`, `Guidance/RoutePolyline.swift:51`, loops over every segment even though it applies an along-distance window | O(N) segment-bound checks per admitted fix, not O(window-size). Binary-search cumulative distances to restrict the segment range before considering a spatial index. Avoid a complex index unless profiling justifies it. | Synthetic long-route benchmark with identical projection results; measure median/p95 at 1k/10k/100k segments and self-crossings. No current latency claim. |
| `AppleNavigationProvider.swift:129` creates a complete GuidanceEngine for each candidate just to validate it; `:178` reconstructs the selected engine on commit | Repeats polyline/maneuver preparation, including string interpretation. Potentially noticeable on long routes/main actor. Retain a validated immutable plan or prepared engine if measurement shows payoff and identity remains immutable. | Compare route-prepare/commit duration and peak memory with large synthetic alternatives. Never move MapKit/UIKit objects across actors casually. |
| `RecordFile.save` encodes and writes synchronously on the main actor; history draft cadence is 60 seconds, inbox mutations can write repeatedly | Small bounded stores mitigate volume, but slow storage can block location/UI/clear scheduling. Introduce a serialized store boundary with versioned results after defining M4/M5 semantics; do not simply launch unordered detached writes. | Measure encode/write p95 and longest main-thread stall on a real device under load; stale writes must not overwrite newer revisions. |
| `VoiceGuide.spoken` (`VoiceGuide.swift:61`, append at `:161`) is an uncapped lifetime list of prompt text, retained across reset | Unbounded in-process growth and unnecessary retention of spoken road text, apparently only for instrumentation. Remove production capture or make it a small explicitly debug-only ring; tests already have `FakeSpeech`. | Long synthetic prompt run has bounded memory; diagnostics still contain no road names. No measured leak is claimed. |
| Share item collection (`ShareViewController.swift:27`), app parsing (`AppModel.swift:466`), parser URL tokenization (`MapLink.swift:127`) run before a global input-size bound | Extension aggregates all loaded strings and a joined copy; parser builds URL arrays. The 4 KiB inbox check bounds stored unresolved links, not initial input/coordinate-bearing text. Cap provider count and accepted bytes before aggregation/parsing; stop after a valid bounded candidate. | Oversized/many-provider fixtures reject clearly with bounded downstream work. A malicious-provider crash has not been reproduced; platform loading may allocate before the app can reject. |
| Console control polling every 700 ms (`BluetoothConsole.swift:138`) has no explicit read-in-flight state | Potential overlapping reads on a slow peripheral. Add one-outstanding-read/backoff only if adapter/device tests show a problem; never poll during navigation. | Fake delayed read and parked validation; quantify frequency and queue behavior first. |
| Live Activity task chain (`RideLiveActivity.swift:71`) serializes but does not coalesce slow pending updates | Correct ordering is valuable; a slow sink could accumulate obsolete updates. Keep latest pending state plus authoritative End if a delayed-sink test demonstrates backlog. | Fake sink delays updates; memory stays bounded and End wins. No observed OS backlog claim. |

### Maintainability with measurable payoff

`AppModel.swift` is 1,387 lines and owns routing transactions, inbox, recovery/history, health scheduling, bench tools and presentation integration. The defects above occur at those boundaries. First lock their behavior with regression traces; then extract a narrow route-operation owner/finalizer and a storage-result boundary. Keep one runtime authority and one BLE owner. Do not replace this with a generic event bus, parallel coordinator or wholesale architectural rewrite.

Existing caps are useful: ten inbox items, eight recents, 100 history rows, 500 diagnostic events, 300 console entries, 20 recent frames, and latest-value pump slots. Favourites and the voice capture have no analogous item-count cap. A favourites migration is not urgent without evidence of large user collections; a bounded voice capture is cheap.

Simulation is network-free only in the narrower sense of route requests: `PlaceSearch` and the real map/provider still exist, and the map can fetch tiles. `AppDependencies` also does not replace `BikeConnection`; AppModel constructs a real CBCentralManager even with virtual dependencies. Make a no-live-services test composition explicit before calling replay fully hermetic. Replace real 2.1-second debounce sleeps in `AppModelProviderTests.swift:127`/`:140`/`:165` with the existing manual timers, and prefer state predicates over the six-second UI sleep (`SimulationUITests.swift:118`).

## 4. Prioritized improvements

Estimates below are **engineering judgments**, in focused engineer-days including automated tests, not measured delivery commitments. They assume one engineer familiar with Swift/iOS; account/device access adds calendar uncertainty. Risk is change/regression risk. Each item is independently testable; feature work is separate in section 5.

| Rank | Work / benefit | Modules and reusable components | Approach, dependencies | Effort / uncertainty | Risk / acceptance / timing |
| --- | --- | --- | --- | --- | --- |
| R1 | H1: no obsolete spoken turns | VoiceGuide, VoicePromptPlanner, AppModel health/wake; reuse prompt priority, ManualRideTimers, FakeSpeech/FakeAudio | Add step/deadline validity and explicit invalidation, not an extra speech queue | 2-4 days; medium | High safety regression sensitivity; expiry/step/holds traces green. **Now, before road testing.** |
| R2 | M7 + L1: truthful, owned BLE results | BikeConnection, ClusterWritePump, BluetoothConsole; reuse lifecycle policy and transport fake | Narrow central/peripheral event facade; serialize all acknowledged traffic; classify submission/ACK/visual separately | 3-6 days; high at OS-object boundary | Preserve firmware blocks, no-response readiness and timeout retirement; cross-channel/epoch adapter tests. **Now.** |
| R3 | M2/M3: cancellation completes ownership cleanup | AppModel route operation, Apple provider waiters; reuse tickets, timer tokens, exact identity | One terminal-operation helper; owner-keyed waiter cancellation; commit-time preview validation | 2-4 days; medium | Tests for each terminal path/arrival race; active route unaffected on failure. **Now; can run parallel to R1.** |
| R4 | M1: consistent lock-screen freshness | RideLiveActivity, AppModel, shared content/widget; reuse chain and stale renderer | Inject activity sink/clock, model state plus expiry, reconcile energy cadence with freshness | 2-4 days; OS rendering uncertainty | Stationary/energy/End tests; physical locked-screen gates. **Now.** |
| R5 | M4/M5: preserve data and honest acceptance/deletion | RecordFile, inbox, recovery, history, setup; reuse envelopes/caps | Typed load/write state, explicit reset, failure-injected transactional mutations; then consider serial I/O | 3-6 days; medium-high, metadata-after-write ambiguity | Future-schema bytes preserved; failed acceptance dispatches zero; deletion failure visible after restart. **Now, before durable-feature expansion.** |
| R6 | M6: accurate consented two-leg summaries | RideHistoryStore, AppModel arrival/commit, RideAccumulator | Continue same recording; separate cold resume; persist original consent eligibility as needed | 1-3 days; medium | Two-leg sums, no gap bridge or deleted-row resurrection, consent changes. **Now after R5 contract.** |
| R7 | M8: valid compatibility evidence | BikeSetupModel/View, coordinator clear API, transport fake | Fresh clear request identity; explicit appeared/clear/disappeared observations | 1-3 days plus parked gate | Backpressured show cannot be recorded as observed; no ACK counted as display. **Now after R2.** |
| R8 | M9: settings match actual requests | AppModel, RideContext, provider request; reuse RoutePreferences | Make proposed effective preferences explicit and commit them transactionally | 1-2 days; low-medium | Query flags and checkpoint agree; failed reroute preserves old committed context. **Now.** |
| R9 | Bounded input/resource work | Share controller, parser/import, voice capture | 4 KiB proposed input policy applied before parsing, bounded provider count; remove uncapped prompt capture | 1-2 days; provider allocation still OS-owned | Oversize/many-input tests; no locations in logs. **Now hardening; no proven exploit claim.** |
| R10 | L2/L3 + test determinism | UI tests, AppModelProviderTests, setup/troubleshooting/config comments | Actor-clean tests, virtual debounce, truthful current docs; no project-generation requirement for audit mode | 1-2 days; low | Build-for-testing no actor warnings; tests count only exercised scenarios. **Now.** |
| R11 | Long-route performance | RoutePolyline and candidate planning | Benchmark, binary-search bounds, reuse immutable preparation only when measured | 2-5 days; benefit unknown | Identical replay outputs and documented p95/memory improvement. **Later, measurement first.** |
| R12 | Release assurance, not another feature | support matrix, existing manual procedures, all adapters | Owner-approved device matrix, fault recovery, safe parked testing before supervised riding/endurance | 3-6 engineering days plus access/weather/calendar | Record independent transport/display/audio/background evidence. **Required before release; no road-readiness claim now.** |

**Do not do now:** enable Google to solve these defects; introduce cloud sync/analytics; rewrite the core; lower GPS quality or extend freshness simply to reduce warnings; persist route geometry for offline reuse without capability/terms review. These increase risk/cost without addressing the demonstrated failures.

## 5. Recommended features

### Existing functionality and the previous plan

Do not propose health, recovery, manual reroute/Cancel/Retry, concise voice/Repeat/Test, a bike wizard, app-owned destination inbox, one intermediate stop, opt-in summary history, energy controls, or replay as entirely new. All exist in current source. They need reliability completion, not duplicate implementations.

`.omo/plans/n250-next-features.md` was reviewed in full, including its implementation record at line 774. Its early dossiers describe an older baseline; its shared contracts and owner gates remain useful. Current assessment:

| Previous item | Current code and recommendation |
| --- | --- |
| F1 health | Implemented (`RideHealth`, phone/widget projections). Retain shared measurement policy; close H1/M1 output gaps. |
| F2 recovery | Implemented opt-in intent journal and explicit fresh-route resume. Keep process-death limitation; close M4/M5 and provenance gates. |
| F3 manual reroute | Implemented transactional Apple prepare/commit with deadline/Cancel/Retry. Close M2/M3/M9, not a second route path. |
| F4 voice | Styles/Repeat/Test/call/output holds implemented. H1 is a remaining queue-validity gap. Real helmet tests still required. |
| F5 wizard | Implemented per-bike report and observations. Revise evidence workflow per M8; do not equate connected with compatible. |
| F6 shared queue | Main-app bounded queue implemented. Full extension durability is not: named pasteboard remains. N8 below is a gated extension, not an existing guarantee. |
| F7 one stop | Implemented, with distinct leg sessions/manual continuation. Close arrival/history races. More stops are not the immediate priority. |
| F8 history | Implemented opt-in summaries/export/delete. Preserve original consent and segment totals; retention/deletion error handling needs work. |
| F9 energy | Implemented reduced activity cadence/map animation. No measured battery savings; reconcile M1 before promoting it. |
| F10 replay | Production AppModel/Apple provider replay and core pump replay exist. Extend boundaries; real Bluetooth adapter, ActivityKit and all crash points are not covered. |

The plan's D05 App Group and D12 provider-data-retention gates remain unresolved, and its final device verification wave is not complete. Its old source references/test counts are historical context, not fresh results. Update it to a residual-work register rather than executing all tasks as unstarted work.

### Feature comparison

These are **incremental new capabilities**, not renamings of existing screens. Value/frequency are product judgments for a private rider-facing app; effort includes tests after relevant R-items, excludes device/account delays. No feature requires a new paid backend in the recommended scope.

| ID | Capability | Rider value / frequency | Distraction / architectural fit | Effort | Recommendation / dependency |
| --- | --- | --- | --- | --- | --- |
| N1 | Parked pre-ride readiness summary | High / every ride | Low before departure; reuses health and capability data | 2-4 days | **Implement now**, after R1-R4/R7 |
| N2 | ETA confidence and route-age explanation | High / every ride | Passive, no riding interaction; snapshot/route metadata | 2-4 days | **Implement now**, after R4/R8 |
| N3 | Read-only maneuver preview before Start | Medium-high / unfamiliar trips | Parked only; reuse prepared route plan/map | 3-5 days | **Implement now**, after R3 |
| N4 | Data inventory and verified deletion center | Medium / occasional | Settings only; purpose-specific stores | 3-5 days | **Implement now**, after R5/R6 |
| N5 | Bounded cross-layer support timeline | Indirect high / diagnosing failures | No riding interaction; existing typed diagnostics/replay | 3-6 days | **Implement now**, alongside R2-R5 |
| N6 | Explicit entrance/gate refinement | High / recurring large destinations | Parked map confirmation; reuse saved places | 3-6 days | **Implement later**, after R5 and provenance decision |
| N7 | Localized maneuver-confidence presentation | High in supported locales / frequent | Passive conservative output; classifier/voice policy | 5-10 days | **Implement later**, after R1 and locale evidence |
| N8 | Durable extension queue with handoff receipts | High / sharing trips | Confirmation retained; app-group/file boundary | 5-9 days plus signing gate | **Defer until capabilities/terms verified**, then implement |
| N9 | Versioned per-bike evidence dashboard/export | Medium / setup and upgrades | Parked only; extends existing report/wizard | 3-6 days plus hardware | **Implement later**, after R2/R7 |
| N10 | Explicit in-ride pause/resume | Medium-high / long stops | Large parked control; existing session/health/recovery | 4-7 days | **Implement later**, after R1-R6 |

### N1. Parked pre-ride readiness summary

**Use case/flow:** Before departing, the rider sees one compact card: current position quality, routing profile, bike connection/evidence age, system audio output, recovery availability and any unresolved failure. Open details or Test audio while parked, then use the existing Start flow.

**Scope/non-goals:** A derived readiness explanation, not a new navigation authority, speed-based safety lock, automatic bike probe or promise that the road is safe. The existing ride health is primarily in-navigation; the wizard is a manual compatibility experiment, not a daily preflight.

**Integration/state:** Extend pure `RideHealthInput` with preflight facts or create a separate pure `PreflightSummary` projection; compose `AppModel`, `VoiceGuide.outputName`, `BikeCapabilityReport` and StartCheck results in `RideView.RouteChoice`. Track fact age and distinguish unknown from failed. No new route dispatch on view appearance.

**Requirements/cost/privacy:** No new permission/signing/network cost. Inspect already available battery/output/status values; do not start continuous location or audio merely to fill the card. Do not persist a daily checklist or labels by default.

**Dependencies/effort:** R1-R4/R7 and clear language on transport versus display; 2-4 days, moderate presentation-policy uncertainty. Roll out as informational, never a new blocker beyond existing permission/fix checks. Roll back the card without changing safety gates.

**Acceptance:** Pure tests for missing permission, stale fix, disconnected bike, old report, headset hold and storage failure; opening the screen makes zero route/BLE writes. **Device gate:** VoiceOver/large text/sunlight readability, real selected headset name and permission states. Prefer reused facts over active automatic probes, which would add writes, battery work and false confidence.

### N2. ETA confidence and route age

**Use case/flow:** The rider sees "route estimate, calculated 35 min ago" in parked details, with a concise qualification that ETA scales by route distance and is not continuously traffic-refreshed. Recalculate is the existing explicit action, not an automatic periodic request.

**Scope/non-goals:** Explain estimate quality and active leg versus whole journey; do not fabricate traffic confidence percentages, motorcycle-specific speed forecasts or a guaranteed arrival time. Display a useful range only after validating a defensible model.

**Integration/state:** Add calculated-at/estimate-source metadata to prepared/committed route descriptions; preserve it through RouteGeneration. Reuse `GuidanceEngine.remainingSeconds`, route operations and `TurnCard`/activity mapping. Use the snapshot's authoritative ETA or explicit paired clock consistently rather than computing subtly different wall-clock values in every view.

**Requirements/cost/privacy:** No new permission, signing or paid network dependency. Metadata stays session-local; no stored route/traffic archive. Passive text should not increase activity updates beyond R4's safe budget.

**Dependencies/effort:** R4/R8; 2-4 days, low implementation but medium product-wording uncertainty. Roll out detailed age in parked details first, concise qualification on primary screens; rollback removes metadata presentation, not freshness checks.

**Acceptance:** Reroute resets route age only on commit; failed request does not; both legs identify their own estimate; frozen clock yields matching phone/activity ETA; no automatic extra query. **Device gate:** clock/time-zone changes, lock-screen legibility and actual MapKit estimates. Prefer honest explanation over a timer-driven traffic-refresh feature, which adds network/battery/request exposure.

### N3. Read-only maneuver preview before Start

**Use case/flow:** At route preview, open "Review turns" to inspect the next few maneuvers and unfamiliar junctions on the existing Apple map; choose another already prepared alternative if necessary, then Start normally.

**Scope/non-goals:** A parked read-only current-leg list, not in-ride scrolling, road safety scoring, itinerary optimization or a route-data archive. Existing route-choice/map screens do not expose a maneuver-list preview.

**Integration/state:** Expose bounded immutable `PreparedManeuverPreview` values from the provider's already validated route plan; retain the prepared-handle lifetime and selected option. Reuse `GuidanceEngine` maneuver classification/sequence and `TurnCard` symbols; explicitly identify unsupported maneuvers. Avoid recalculating a route or creating another engine per rendered row.

**Requirements/cost/privacy:** No new permission/signing/paid service. Map tiles may use existing network access; no offline guarantee. Preview data remains in memory and is discarded with its handle; provider-derived text retention needs no new archive.

**Dependencies/effort:** R3; 3-5 days with moderate mapping uncertainty. Roll out current leg and limited list first; rollback removes the screen, leaving preview/Start intact.

**Acceptance:** Alternative selection changes list without another query; Cancel/expiry/Stop removes it; unsupported turns are not straight arrows; bounded large-route rendering and dynamic text tests. **Device gate:** real route-step alignment in target languages and parked readability. Prefer current prepared data to speculative second-leg prefetch or a new directions API.

### N4. Data inventory and verified deletion center

**Use case/flow:** In Settings, see separate categories for saved places, waiting destinations, interrupted ride, summaries, bike reports and diagnostics. Select one to delete, understand what remains, and retry if disk cleanup fails.

**Scope/non-goals:** Transparent purpose/retention/backup explanation and category-specific deletion. Not cloud sync, an encryption/password system, a promise of forensic secure erasure, or a single toggle that silently disables unrelated features. Current scattered controls exist; the new capability is a unified inventory with durable outcome reporting.

**Integration/state:** Reuse each store's existing deletion APIs after R5, add typed deletion results and a `PrivacyInventory` projection. Include UserDefaults favourites/shortcuts/recents explicitly: RecordFile protection/backup policy does not automatically apply to them. Maintain suppression for an actively recording/resumable deleted ride.

**Requirements/cost/privacy:** Local only, no permissions or network cost. No collection telemetry. Explain that disabling history currently stops future recording but keeps saved summaries until deletion; offer a separate explicit delete choice, not a silent behavioral change.

**Dependencies/effort:** R5/R6 and owner decisions on saved-place backup; 3-5 days, moderate failure-state uncertainty. Roll out category controls first; rollback removes the combined view without undoing deletion or re-enabling recording.

**Acceptance:** Delete/restart, failed write/remove, future schema, disabled history, active ride and recovery suppression; no location/BLE action is triggered by deletion. **Device gate:** file protection before/after unlock, backup policy inspection and real Share export behavior. Prefer purpose-specific deletion to a broad reset that could unexpectedly erase Home/Work or ride intent.

### N5. Bounded cross-layer support timeline

**Use case/flow:** After a failed parked/device trial, export a short chronological explanation: sensor age category -> route operation ID alias -> accepted/rejected generation -> clear requested/submitted/transport result -> voice hold/activity update. A maintainer can replay the event ordering without a rider's coordinates or road text.

**Scope/non-goals:** Extend existing categorical diagnostics with bounded timing/correlation and optional synthetic replay export; not full GPS recording, packet capture, analytics upload, persistent crash surveillance or automatic support submission.

**Integration/state:** Reuse `DiagnosticsLog`, core/app replay event models and `RideClock`. Add typed event fields, ephemeral locally aliased identities and a versioned export schema. Record BLE ownership and freshness expiry causes, not free-form OS error descriptions or raw packets containing names.

**Requirements/cost/privacy:** No new permission/backend/signing. Default in-memory bounded ring; export explicit and previewable. Never include coordinates, raw URLs, destination/road names, hardware identifiers, keys or caller details. Keep work O(1) per event where practical.

**Dependencies/effort:** Alongside R2-R5, 3-6 days; event-schema uncertainty medium. Enable detailed tracing only for a bounded opted-in window if default categorical events suffice. Rollback stops collection and discards the ring; exported copies remain under the user's control.

**Acceptance:** Inject sensitive sentinels across every event type; deterministic order/identity normalization; cap/expiry/schema validation; exported trace cannot dispatch routes or write to BLE by itself. **Device gate:** reproduce a parked disconnect/audio interruption and verify useful evidence without sensitive data. Prefer typed traces over raw BLE/location dumps and a cloud crash service.

### N6. Explicit entrance/gate refinement

**Use case/flow:** A mall/hospital search result points to a campus center. Before confirming, tap "Choose entrance", reposition the destination on the Apple map while parked, give it a user-authored label such as "East gate", and optionally save that coordinate for later.

**Scope/non-goals:** Deliberate coordinate refinement, not an inferred legally accessible entrance, automatic rerouting while moving, scraped provider POI databases or replacing map attribution. Existing long-press selection chooses a point; it does not provide an explicit edit flow for an existing selected destination.

**Integration/state:** Add a confirmation subflow to `DestinationConfirmation`/provider map selection; reuse `Coordinate`, `PendingDestination`, `RideDestination` and favourites. Preserve original source provenance and separate user-authored label/adjusted point from provider metadata; cancel restores the original choice. A refined point creates a new explicit request only after confirmation.

**Requirements/cost/privacy:** Existing maps/location permissions only; no paid service. Normal map tiles/network apply. Saving provider-derived data remains subject to the field/provenance decision; manual adjustment does not automatically clear all terms obligations. No route geometry storage.

**Dependencies/effort:** R5, provenance/account decision; 3-6 days, medium UI/terms uncertainty. Roll out transient edits first, durable saved entrances only after clearance. Rollback removes edit controls without migrating existing places gratuitously.

**Acceptance:** Confirm/cancel, invalid coordinates, source preservation, one request, saved label limits, no mid-ride replacement without existing confirmation. **Device gate:** real campus entrances, map gestures and accessibility. Prefer rider-selected points over a new entrance-search backend that cannot guarantee motorcycle access.

### N7. Localized maneuver confidence

**Use case/flow:** On supported non-English route instructions, conservative guidance explains when it cannot confidently classify a junction and asks the rider to follow the map instead of implying a specific arrow.

**Scope/non-goals:** Measured locale support and explicit classification reason/confidence, not an LLM translating safety-critical instructions, guessing unsupported maneuvers or promising every country/language. Geometry fallback already exists; this feature makes supported locale behavior explicit and extends it with evidence.

**Integration/state:** Extend `ManeuverClassifier` output with a typed basis/reason such as text-and-geometry, geometry-only or ambiguous. Carry conservative eligibility/presentation through GuidanceStep, mapper, voice and activity. Add selected language/traffic-side policy only where route/provider contracts support it; preserve sequence/session identity.

**Requirements/cost/privacy:** No new permission/signing/paid API in the recommended rule/fixture approach. Synthetic locale fixtures and consented ephemeral real-route inspection; no provider instruction archive by default. CPU cost should remain bounded per prepared route, not per spoken callback.

**Dependencies/effort:** R1, target-language route evidence; 5-10 days per initial locale group, high accuracy uncertainty. Roll out opt-in per validated locale; rollback disables the new locale rules and restores conservative unsupported output.

**Acceptance:** Localized roundabout/fork/ramp/double-bend and contradictory cue fixtures, identical geometry with different text, no false straight fallback, voice/widget/cluster consistency. **Device gate:** parked review of real route examples with a fluent rider, then authorized supervised validation. Prefer transparent rules and abstention over generative turn interpretation.

### N8. Durable share-extension queue with receipts

**Use case/flow:** Share two destinations before opening N250 Ride; each is saved separately, acknowledged as durable only after shared-container commit, then imported into the app-owned inbox without overwriting the previous item. During a ride they wait for explicit use.

**Scope/non-goals:** Bounded per-item durable handoff, not automatic route execution, guaranteed delivery through arbitrary storage failure, background launch after termination or a named-pasteboard durability claim. The current named pasteboard is one short-lived slot and warns about loss; this is genuinely additional behavior.

**Integration/state:** Reuse `IncomingDestination` identity/caps/TTL, but preserve provenance and durable state. Add authorized App Group storage with immutable per-item IDs, coordinated capacity/expiry checks, import-commit-before-ack and idempotent retry. Full local inbox leaves the shared item unacknowledged; expose pending-import count. Never import all items by deleting shared data first.

**Requirements/cost/privacy:** Matching signed App Group entitlement and container access in both targets must be verified under the actual account; API availability alone is insufficient [A5]. No paid routing service, but account/capability availability is an owner decision, not a promise of free provisioning. Apply file protection, backup exclusion, input byte/count caps and provider-retention approval.

**Dependencies/effort:** R5/R9, D05/D12 gates; 5-9 days after access, high OS/cross-process uncertainty. Feature-gate the durable transport. If unavailable, clearly retain explicit paste/open-URL fallback; do not silently label it durable. Rollback stops new writes while permitting safe import/discard of committed items.

**Acceptance:** Concurrent writers, capacity full, duplicate import, crash after local commit/before acknowledgement, expiry and storage failure; zero automatic route requests. **Device gate:** signed host and actual Share extension, termination/reboot/locked storage, multiple source apps, actual group-access check. Prefer a coordinated App Group queue over named pasteboard or a new cloud service.

### N9. Versioned per-bike evidence dashboard

**Use case/flow:** After an app/calibration change, the rider sees which previous parked observations remain relevant and which need rechecking; export a small compatibility report for that exact bike/profile and app version.

**Scope/non-goals:** Extend existing saved wizard reports with clear evidence provenance, scope and staleness; not automatically detecting firmware versions, probing unknown services, fleet compatibility certification or assuming all N250s behave alike. `isCurrent` currently checks calibration/profile, not the stored appVersion (`BikeSetupModel.swift:39`).

**Integration/state:** Reuse BikeCapabilityReport and fixed diagnostic samples. Add schema/evidence revision, observed app version, optional rider-entered bike/firmware label, test timestamps and separate clearing/disconnect-timeout observations. Bind a wizard run to one connection/bike identity; switching bikes invalidates unfinished observations rather than mixing them.

**Requirements/cost/privacy:** Existing BLE permission and a parked bike; no backend. Keep real peripheral UUID local, redact it from shared reports. Optional labels can identify the owner/bike and need explicit export preview. No automatic firmware reads or writes.

**Dependencies/effort:** R2/R7/R5; 3-6 days plus hardware access, high device-validation uncertainty. Roll out read-only report details first; new observations remain unverified until performed. Rollback preserves existing reports but marks unsupported revisions unknown.

**Acceptance:** Version/calibration/profile changes, bike switch mid-wizard, missing/failed/inconclusive observations, redacted export and future-schema preservation. **Device gate:** parked clear/timeout/reconnect and fixed sample observation on each claimed configuration. Prefer per-configuration evidence over a blanket model-supported badge.

### N10. Explicit in-ride pause/resume

**Use case/flow:** At an unscheduled fuel/tea stop, Pause stops directional speech, requests dashboard clear and stops recording active movement without ending the logical journey. Resume is explicit and checks a fresh position; if the old route origin/progress is unsuitable, use the existing authorized recalculate/preview path.

**Scope/non-goals:** A rider-controlled paused phase, not auto-pause from speed, automatic waypoint continuation or automatic execution after termination. Intermediate-stop waiting already exists; this adds a pause at arbitrary points without losing the destination.

**Integration/state:** Add a typed paused journey phase/reason to RideContext/health and recovery schema; define whether the provider retains an inactive in-memory plan or requires fresh preparation. Reuse coordinator clear/end semantics, voice holds, segment breaks and route gate. Never leave a hidden active session producing arrows beneath a paused UI.

**Requirements/cost/privacy:** Existing permissions only. GPS ownership must be explicit: while paused and map hidden, release guidance acquisition rather than claiming savings from a switch alone. Resume may need a normal network route request; do not promise offline resume or app relaunch. Recovery remains separately consented.

**Dependencies/effort:** R1-R6 and schema migration decision; 4-7 days, high transition complexity. Roll out foreground pause first; recovery of paused intent later only after crash tests. Rollback can offer End ride, but cannot silently resume a paused journey.

**Acceptance:** Pause during speech/preparation, disconnect/reconnect while paused, repeated pause/resume, denied/stale fix, crash/restart, consented totals with no parked-gap bridge, Stop always wins. **Device gate:** parked phone lock/unlock, actual clear/speech cessation, release/reacquisition of location. Prefer explicit controls over automatic speed-based transitions, which are ambiguous in traffic and GPS noise.

## 6. Delivery roadmap

### Stage A: Close safety and identity gaps

Ship R1-R4 before adding riding features. Independent work items: voice validity, BLE callback ownership, waiter/preview cancellation, stop-arrival finalization, and activity expiry renewal. Each must have a deterministic failing trace that exercises the production owner, then a passing regression. Preserve firmware-service restrictions, exact route generation, one active request and no-response backpressure.

**Release gate:** core suite and app-adapter tests pass; build/test targets compile; phone/voice/activity share the same measurement-based eligibility; no unowned completion can advance a newer operation. Do not use a passing pure `BikeLinkLifecycle` test as proof that `BikeConnection` forwards epochs correctly.

### Stage B: Make durable state truthful

R5 defines storage availability/schema/results first; R6 fixes continuation/consent totals; R7 makes wizard evidence operation-specific; R8 aligns preferences with requests. R9/R10 are small parallel hardening/tooling work after contracts are clear.

**Release gate:** future-schema preservation, acceptance-before-dispatch, failure/restart/delete behavior and two-leg history assertions all pass. Crash tests enumerate pending intent, runtime commit, checkpoint, inbox consumption and history flush independently. No filesystem result is described as runtime navigation success.

### Stage C: Add low-risk rider value

N1 preflight, N2 ETA explanation, N3 maneuver preview and N4 data controls can ship independently after their foundations. N5 support timeline should grow with each reliability fix, using the existing replay/typed diagnostics rather than recording private routes.

**Release gate:** no added network requests from passive views; large text/VoiceOver and parked controls checked; new data has explicit ownership, cap, lifetime and deletion behavior. Feature rollback removes presentation without restoring unsafe output policies.

### Stage D: Owner-gated extensions

N6 entrance saving and N7 locale support follow source/locale validation. N8 waits for signed App Group access and retention decisions. N9 requires per-bike observations. N10 follows completed lifecycle/storage tests. Multi-stop optimization, cloud sync, Google activation and offline route archives remain separate deferred product decisions, not hidden additions to these features.

### Stage E: Physical assurance

With explicit owner permission, first run parked tests: arrows, clear, no-response versus acknowledged behavior, disconnect retention, reconnect ordering, exact bike/report binding, headset removal/calls and file protection. Then validate locked-screen/background behavior on supported iOS versions and signing configurations. Only after those pass consider supervised road testing and a six-hour endurance run. Log factual observations separately from app counters and transport results.

**Final gate:** support matrix names device/OS/app/calibration/profile and test date, unresolved limitations stay visible, and no device result is generalized beyond tested configurations. A Live Activity or declared background mode is not perpetual execution; standard location updates stop on termination [A2/A3].

## 7. Quick wins

1. Revalidate preview expiry inside the asynchronous Start completion (M2); add a delayed-ready test.
2. Retire the app-owned reroute when entering atStop (M3); immediate Continue must not wait for an old timeout.
3. Continue the same history recording across leg two rather than calling a reset-like begin (M6).
4. Change intent/submission/ACK/display wording to precise statements everywhere (L1).
5. Add assertions on the actual reroute request preferences, not only a spy property (M9).
6. Block saves after unknown-schema load until explicit discard (M4), with original-byte preservation tests.
7. Remove/bound production `VoiceGuide.spoken`; use FakeSpeech for test inspection.
8. Add byte/provider-count checks before share parsing/aggregation and make oversize rejection explicit.
9. Remove real debounce sleeps with ManualRideTimers; correct UI-test actor isolation and stale Apple/Google documentation.
10. Split the wizard's arrow appearance and disappearance checks; do not infer a new clear result from a previous global ACK.

These are recommendations, not changes made by this review. H1, M1 and M7 should not be reduced to cosmetic one-line patches; their ownership/deadline contracts need the fuller regression work above.

## 8. Unverified concerns and owner decisions

| Topic | Evidence, uncertainty and decision needed |
| --- | --- |
| Physical dashboard state | Software can request, submit or observe transport ACK only. Parked observation is needed for stop-frame clearing, disconnect timeout, roundabouts, ETA formatting and status profiles. Existing reported arrow tests do not establish a complete navigation system. |
| BLE lifecycle epoch propagation | Timers capture epochs, but peripheral delegate methods at `BikeConnection.swift:405`/`:459` do not validate callback identity/epoch. Static omission is real; delivery of particular late callbacks across reconnect on the same CBPeripheral is not established. Use adapter event tests plus actual disconnect/reconnect traces; don't invent a callback token Apple does not provide. |
| Bluetooth restoration | `willRestoreState` restores a target/delegate but full validated/GATT/pump recovery is not proven. Restored state and runtime navigation intent must be reconciled without auto-start. Requires actual termination/restoration testing and OS documentation for the adopted API path. |
| Foreground/background freshness | `N250RideApp` on active currently checks sharing, not an explicit safety re-evaluation. Whether pending scheduled work executes before first visible/voice output after a long suspension is not reproduced. Add a foreground safety tick before presentation, and test real lock/suspension. Do not infer failure solely from missing a handler. |
| Audio interruption/route notifications | Apple documents route removal as a reason to pause; shouldResume is a hint, not universal permission or prohibition [A4]. Existing overlapping holds are useful. Actual headset/media/call behavior, notification ordering and callback actor assumptions need device validation. |
| Speech adapter cleanup | `SystemSpeechClient.tags` removes entries on finish/cancel, but Apple does not promise didCancel for all queued/unspoken utterances [A4]. A retained tag under stop/start stress is a plausible concern, not a measured leak. Test adapter stop/callback lifetimes; clear retired tag bookkeeping explicitly if needed. |
| Named-pasteboard sharing | Apple documents named app pasteboards as nonpersistent [A5]. The current extension says Sent without a put result and warns only about restart. Cross-process visibility/lifetime on the actual signed host/extension must be tested; a runner-process pasteboard UI test does not exercise the extension's NSItemProvider path or signing. No durable-storage claim is warranted. |
| App Groups | No App Group entitlements were found in the project specification. Actual account eligibility, matching effective signed entitlements and container access are owner gates. Do not alter signing to discover them during this audit. |
| Provider-derived data retention | Recovery/inbox store destination coordinates/labels; saved-place provenance is incomplete, and inbox records do not retain a full original-source provenance field. The plan's D12 remains unreviewed. The binding developer-account agreement/field-specific interpretation must be reviewed by the owner; a user confirmation or generic opt-in is not proof of permission [A7]. This review makes no legal violation finding. |
| Saved-place privacy | UserDefaults places are not covered by RecordFile backup exclusion. Decide backup/export/deletion disclosures and whether to migrate; do not silently migrate unrelated legacy data. Lock-screen destination labels can also reveal sensitive places. |
| Retention | Recovery eligibility is 24 hours, inbox pruning seven days, history pruning 30 days/100 rows. These are evaluated on load/mutation, not an OS-guaranteed erasure job at an exact deadline. Decide whether unavailable/expired files need explicit cleanup and communicate the distinction. |
| Input/resource hardening | Oversized item-provider input, crafted route geometry, and slow BLE reads were not used to crash the app. Add bounded synthetic tests before calling them exploitable denial of service. A Google-domain regex is not a domain-ownership certificate; validate the intended host list if relying on additional country domains. No actual hostile allowed domain was established. |
| Dormant Google adapter | Current build excludes SDKs and tests behind canImport. Before any activation, address operation cancellation (`GoogleNavigationController.swift:159` is empty), pending-result identity, source measurement admission (`:211` merely checks nonnegative accuracy and republishes), and mutable prepare behavior. Mapper sets measurementAt to publication time (`GoogleGuidanceMapper.swift:119`). These are activation blockers, not active Apple-build failures or verified Google-API behavior. |
| Dependencies/advisories | No active external Swift package version is declared. The two source-derived components are pinned/attributed, not linked Android/Google runtime dependencies. Current Apple Xcode 27.2 security notes were checked: they describe CoreDevice/Instruments fixes included in that release [A8], not a demonstrated reachable app vulnerability. Device OS patch level and signed-binary linkage were not audited. Dormant SDK 11.3.0 needs a fresh vendor-advisory/API check if enabled. |
| Broader product choices | More than one stop, offline routing, automatic post-termination execution, arbitrary helmet controls and cloud services are deferred. They add capability/contract/state/cost requirements beyond current evidence; none is promised by this roadmap. |

**Rejected/downgraded first-pass concerns:** MapKit candidates are explicitly sorted by expectedSeconds (`PlatformClients.swift:108`), so "unsorted fastest route" was rejected. `TEST_RUNNER_N250_LIVE` versus `N250_LIVE` was not called a bug without checking Xcode's forwarding convention. A hypothetical nil weak console host is not an established normal UI path. Keeping prior history after recording opt-out is an explicit policy choice, not automatically a privacy bug. Team IDs and test sentinels are not leaked credentials. Generated `.xcodeproj` metadata does exist and was inspected, despite a capped discovery lane initially missing it.

## 9. Review evidence and exclusions

### Coverage method and inventory

The authoritative tracked inventory came from `git ls-files`, not the initially capped broad glob. It contains 119 files, 94 Swift. Narrow filesystem inventories covered Config, docs, scripts and authored `.omo` Markdown. Independent lanes read core policy/tests, BLE/protocol/tooling, app/provider/audio/tests, persistence/input/privacy and configuration/docs/extensions. Reported candidate defects were then read/traced by the lead and adversarially checked against callers/guards. Whole-repository review does not imply formal verification or execution of every path.

All paths below are relative to the repository root. Every listed source/test file was reviewed; directory headings are not claims about generated descendants.

**App and platform source**

```text
N250Ride/App/
  AppConfiguration.swift  AppDependencies.swift  AppModel.swift
  CallMonitor.swift  N250RideApp.swift  RideLiveActivity.swift  RideTimers.swift
N250Ride/Bluetooth/
  BikeConnection.swift
N250Ride/Features/
  BikeSetupModel.swift  BikeSetupView.swift  BikeView.swift
  BluetoothConsole.swift  BluetoothConsoleView.swift  DestinationView.swift
  DiagnosticsView.swift  ManualChecklist.swift  ManualChecklistView.swift
  MapTabView.swift  RideHealthView.swift  RideSettingsView.swift  RideView.swift
N250Ride/Navigation/
  AppleNavigationProvider.swift  GoogleGuidanceMapper.swift
  GoogleNavigationController.swift  LinkExpander.swift  LiveNavigationProvider.swift
  PlaceSearch.swift  PlatformClients.swift  RouteRequestFailure.swift  VoiceGuide.swift
N250Ride/Persistence/
  IncomingInbox.swift  ProtectedFileStore.swift  RecoveryStore.swift  RideHistoryStore.swift
N250RideShare/ShareViewController.swift
N250RideWidgets/RideLiveActivityWidget.swift
Shared/RideActivityAttributes.swift  Shared/ShareInbox.swift
```

**Core authored source**, under `Packages/RideCore/Sources/RideCore/`:

```text
Destinations/  Destination.swift  MapLink.swift  SavedPlaces.swift
Diagnostics/   DiagnosticsLog.swift
Domain/        BikeLink.swift  Clock.swift  Navigation.swift
Guidance/      GuidanceEngine.swift  LocationAdmission.swift  ManeuverClassifier.swift
               RoutePolyline.swift  VoicePromptPlanner.swift
History/       RideHistory.swift
Link/          BikeLinkLifecycle.swift  ClusterWritePump.swift
Navigation/    FixtureNavigationSource.swift
Protocol/      ClusterIcon.swift  GeneralStatus.swift  HexBytes.swift
               PhonePackets.swift  TbtFrame.swift
Routing/       RoutePreferences.swift  RouteRequestGate.swift
Session/       ItineraryPolicy.swift  RecoveryJournal.swift  RideContext.swift
               RideHealth.swift  SessionCoordinator.swift
```

**Tests and authored test data**

```text
N250RideTests/
  AppConfigurationTests.swift  AppModelProviderTests.swift  AppReplayTests.swift
  AppleProviderAdapterTests.swift  GoogleGuidanceMapperTests.swift
  ManualChecklistTests.swift  RideFlowTests.swift
  Support/AppReplayRunner.swift  Support/FakePlatform.swift  Support/TestDependencies.swift
N250RideUITests/
  LiveAppleRouteUITests.swift  SimulationUITests.swift
Packages/RideCore/Tests/RideCoreTests/
  CoreReplayTests.swift  DiagnosticProbeTests.swift  DiagnosticsTests.swift
  GuidanceEngineTests.swift  JourneyTests.swift  LinkTests.swift  MapLinkTests.swift
  ProtocolTests.swift  RideContextTests.swift  RideHealthTests.swift  RoutingTests.swift
  SavedPlacesTests.swift  SessionTests.swift  VoicePromptTests.swift
  Support/CoreReplayRunner.swift
  Resources/golden-vectors.json  Resources/olc/NOTICE
```

**Configuration, tools and operational documentation**

```text
.gitignore  project.yml  Packages/RideCore/Package.swift
Config/App.xcconfig  Config/Local.example.xcconfig
N250Ride/Info.plist  N250RideShare/Info.plist  N250RideWidgets/Info.plist
README.md  THIRD_PARTY_NOTICES.md
docs/setup.md  docs/support-matrix.md  docs/troubleshooting.md
docs/cost-model.md  docs/feasibility.md  docs/protocol/provenance.md
scripts/test.sh  scripts/bootstrap-xcode.sh
scripts/oracle/generate-vectors.sh  scripts/oracle/VectorGen.java
scripts/oracle/stubs/android/os/Build.java
scripts/oracle/stubs/com/bajajnav/relay/PhoneBridge.java
```

Ignored local configuration `Config/Local.xcconfig` was inspected for provider/signing implications without copying its values into this report. A development-team identifier is not a secret credential. No entitlements file was found; no signed entitlement inspection was performed. Generated `N250Ride.xcodeproj/project.pbxproj` and `xcshareddata/xcschemes/N250Ride.xcscheme` were additionally read for current target/build-phase/package safety; no generation or edits were performed.

**Authored historical plans/evidence read as context, not proof of current behavior**

```text
.omo/plans/n250-next-features.md
.omo/plans/n250-ios-navigation.md
.omo/drafts/n250-next-features.md
.omo/drafts/n250-ios-navigation.md
.omo/evidence/n250-ios-navigation/task-progress.md
.omo/evidence/n250-ios-navigation/task-01-environment.md
.omo/evidence/n250-ios-navigation/task-02-feasibility.md
.omo/evidence/n250-ios-navigation/task-03-provenance.md
.omo/evidence/n250-ios-navigation/task-09-15-procedures.md
.omo/evidence/n250-ios-navigation/task-19-apple-terms-and-api.md
.omo/evidence/n250-ios-navigation/task-20-link-spike.md
```

### Commands actually run and their results

Read/search tools, codegraph queries and primary-document retrieval were used throughout. `rg` was attempted once and was unavailable; specialized file tools were used instead. Git was checked, not assumed, and not initialized. Read-only Git commands were `git status --short --untracked-files=all` (with fsmonitor disabled), `git ls-files`, `git rev-parse --is-inside-work-tree HEAD`, and `git ls-files '*.swift' | wc -l`, with the harness's `GIT_MASTER=1` prefix. Counts were 119 tracked files and 94 Swift files; initial status was empty.

Toolchain commands: `xcrun swift --version` reported Apple Swift 6.4.2, target arm64-apple-macosx27.0.0; `xcodebuild -version` reported Xcode 27.2, build 27B52. `xcrun swift test --help` was inspected before selecting external output paths. The external scratch parent was verified to exist.

The following test command was run from the repository root; all paths are literal destinations used during this review:

```sh
xcrun swift test \
  --package-path Packages/RideCore \
  --scratch-path /var/folders/m7/n050zbyj61zf21wxj8z41plm0000gn/T/opencode/pulsar-review-20261113-core \
  --cache-path /var/folders/m7/n050zbyj61zf21wxj8z41plm0000gn/T/opencode/pulsar-review-20261113-cache \
  --config-path /var/folders/m7/n050zbyj61zf21wxj8z41plm0000gn/T/opencode/pulsar-review-20261113-config \
  --security-path /var/folders/m7/n050zbyj61zf21wxj8z41plm0000gn/T/opencode/pulsar-review-20261113-security \
  --disable-automatic-resolution --skip-update
```

Result: exit 0, build complete in 26.15 seconds; **157 tests / 34 suites passed**. SwiftPM warned that skip-update is deprecated. No dependencies are declared to fetch. The separate XCTest zero-test summary is not the Swift Testing result.

Two Xcode commands were run with the same options below, first action `build`, then action `build-for-testing`:

```sh
xcodebuild build \
  -project N250Ride.xcodeproj -scheme N250Ride \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /var/folders/m7/n050zbyj61zf21wxj8z41plm0000gn/T/opencode/pulsar-review-20261113-xcode \
  -clonedSourcePackagesDirPath /var/folders/m7/n050zbyj61zf21wxj8z41plm0000gn/T/opencode/pulsar-review-20261113-packages \
  -disableAutomaticPackageResolution -skipPackageUpdates CODE_SIGNING_ALLOWED=NO -quiet
```

Both exited 0. The generic simulator destination produced an Xcode placeholder-version diagnostic. Build-for-testing emitted UI-test actor-isolation warnings (L2). Repeated diagnostic renderings are not counted as unique defects. Signing was disabled only for these invocations; no signing configuration was changed. No simulator test or real app surface was launched.

The Markdown report passed an independent read-only structure/consistency proofread. A requested LSP diagnostic check could not run because the local LSP daemon was unreachable; no LSP-clean claim is made. Git's whitespace check on tracked changes was clean; the new report was additionally checked directly. Final Git status showed only this new untracked report, with no tracked application/configuration/test changes. Release-configuration builds, iOS 17 runtime behavior, device archives and enabled-Google compilation were not checked.

`scripts/test.sh`, bootstrap and vector-generation scripts were **inspected but not run**. The app branch regenerates the project and resets simulator location permissions (`scripts/test.sh:47`, `:53`); bootstrap can install platforms; the oracle script can clone/check out/compile upstream code. Those side effects were outside this review. App test source also constructs real platform objects, so compilation was kept separate from execution. Existing xcresult claims were not substituted for fresh runs.

### Exclusions and unavailable checks

| Excluded path/category | Reason and remaining assurance requirement |
| --- | --- |
| `Packages/RideCore/Tests/RideCoreTests/Resources/olc/decoding.csv`, `validityTests.csv` | Unmodified upstream test fixtures, not authored implementation; notice/provenance and consuming assertions read, and fixtures exercised by fresh core tests. No line-by-line third-party dataset audit. |
| `.git/**` internals/hooks/objects | Repository metadata, not authored app code. Only read-only status/inventory/HEAD inspection; no hooks executed, commits or changes to Git configuration. |
| `.codegraph/**` | Generated search database/logs/cache, not product code. Queried for context; not security-audited as an application component. |
| `N250Ride.xcodeproj/**` other than inspected project/scheme; `**/xcuserdata/**`, `.swiftpm/**` | Generated project/workspace/user state. Current app/test targets and build actions were checked from project/scheme and successful builds; UI state/binary metadata not reviewed. |
| `**/.build/**`, `build/**`, `DerivedData/**`, external review build/cache paths | Generated build artifacts. Build results inspected, not an authored-code review of compiler outputs or every binary. |
| `.omo/evidence/**/*.xcresult/**`, screenshots, test-output `.txt`, generated vector copy JSON | Historical/generated evidence and binary attachments; not current proof. Authored Markdown procedures/status listed above were read. New safe checks supplied fresh compile/core-test evidence. No archived screenshot/xcresult forensic audit. |
| `.omo/run-continuation/**` | Harness-generated runtime/session metadata, including files produced automatically by this review's tooling. Not application configuration/source; not read as app evidence. |
| `scripts/oracle/.upstream/**`, vendored/checkouts/lockfiles/caches/binaries if present | Excluded third-party/generated material by requested scope. Authored ports, manifests, stubs, scripts, notices and committed golden vectors were reviewed. No upstream clone, binary linkage/SBOM audit or lockfile audit. |
| Real phone/bike/headset, account agreements and effective provisioning | Permission/access not supplied for interaction. Required for physical rendering/clearing, lock/background/termination, audio/calls, App Group sharing and contractual conclusions. |

**Unread authored source/tests/config/scripts/operational Markdown within the inventoried scope: none.** Excluded generated artifacts and upstream fixtures are explicitly listed above, not silently called reviewed. This is complete source-scope coverage with limited runtime assurance, not a complete device/security certification. A dedicated team-mode security workflow was unavailable in this harness; security conclusions here come from direct boundary review, independent review lanes, primary contracts and adversarial source checks, not an executed exploit campaign. No injection/path-traversal/subprocess exploit, hardcoded credential leak or affected reachable runtime dependency advisory was confirmed.

### Primary platform references

Retrieved/checked on 2026-11-13. These establish documented API contracts, not this installation's effective entitlements, the owner's binding agreement, or observed device behavior.

| ID | Primary sources and use |
| --- | --- |
| A1 | [CBPeripheral.writeValue](https://developer.apple.com/documentation/corebluetooth/cbperipheral/writevalue(_:for:type:)) and [didWriteValueFor](https://developer.apple.com/documentation/corebluetooth/cbperipheraldelegate/peripheral(_:didwritevaluefor:error:)-4f5ea): characteristic write result; without-response success is not guaranteed; no payload transaction ID or visual-render receipt. [Cancellation](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/cancelperipheralconnection(_:)) is nonblocking and pending commands may not complete. |
| A2 | [CLLocation.timestamp](https://developer.apple.com/documentation/corelocation/cllocation/timestamp), [didUpdateLocations](https://developer.apple.com/documentation/corelocation/cllocationmanagerdelegate/locationmanager(_:didupdatelocations:)), [standard updates](https://developer.apple.com/documentation/corelocation/cllocationmanager/startupdatinglocation()), [background flag](https://developer.apple.com/documentation/corelocation/cllocationmanager/allowsbackgroundlocationupdates): measurement time, batched observations, adopted service termination/background limits. Newer session APIs are not assumed adopted by this iOS-17-compatible code. |
| A3 | [ActivityContent.staleDate](https://developer.apple.com/documentation/activitykit/activitycontent/staledate), [ActivityViewContext.isStale](https://developer.apple.com/documentation/widgetkit/activityviewcontext/isstale), [Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities): stale presentation and independent activity sandbox, not a perpetual host-process execution grant. |
| A4 | [Audio route changes](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes), [shouldResume](https://developer.apple.com/documentation/avfaudio/avaudiosession/interruptionoptions/shouldresume), [stopSpeaking](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/stopspeaking(at:)), [didCancel](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizerdelegate/speechsynthesizer(_:didcancel:)): route-loss privacy, interruption policy hint and cancellation callback limits. |
| A5 | [Named pasteboards](https://developer.apple.com/documentation/uikit/uipasteboard/init(name:create:)), [persistence](https://developer.apple.com/documentation/uikit/uipasteboard/ispersistent), [App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups), [container access](https://developer.apple.com/documentation/foundation/filemanager/containerurl(forsecurityapplicationgroupidentifier:)): no durable named-board promise; signed group membership and actual access must be verified. |
| A6 | [Automobile routing](https://developer.apple.com/documentation/mapkit/mkdirectionstransporttype/automobile), [routes](https://developer.apple.com/documentation/mapkit/mkdirections/response/routes), [expectedTravelTime](https://developer.apple.com/documentation/mapkit/mkroute/expectedtraveltime): driving profile and estimate semantics, not motorcycle suitability or globally fastest routing. Current source sorts returned candidates itself. |
| A7 | [Apple Developer agreements](https://developer.apple.com/support/terms/) and [Maps terms](https://www.apple.com/legal/internet-services/maps/terms-en.html): public context only; account-accepted terms/field-specific retention permission remain owner decisions. No legal compliance verdict is given. |
| A8 | [Xcode 27.2 security content](https://support.apple.com/en-us/149589) and [Apple security releases](https://support.apple.com/en-us/100100): current toolchain advisory check. Listed fixes are not presented as vulnerabilities of this app. |

### Completion boundary

The requested report was absent when the docs directory was checked, so no prior report was overwritten. The safe checks and review did not require project generation, dependency installation, signing changes, simulator permission changes or hardware writes. All fixes, feature proposals, acceptance tests and release gates above remain recommendations for separately authorized implementation.

## 10. Resolution status (2026-11-13)

All confirmed findings were fixed, each with a regression test in `N250RideTests/ReviewRegressionTests.swift`
(plus `WriteCompletionRouter` and `requestFreshClear` in RideCore). Verified: 157 core tests, 86 app unit tests
and 14 simulation UI tests pass; build-for-testing has no warnings. No device, bike, headset or lock-screen
check was made, so every device gate in sections 6 and 8 remains open.

| Finding | Fix |
| --- | --- |
| H1 | Turn prompts carry their step and a validity deadline (measurement + 5 s) and are re-checked just before speaking; losing eligibility (including expiry with no new snapshot) cuts the current turn and drops the pending one. Status prompts and independent holds unchanged. Uncapped `spoken` log removed. |
| M1 | Live Activity renews the stale date when a newer measurement arrives even if the text is unchanged (at most every 2 s), delivers throttled changes later, and goes through an injectable sink; End still wins. |
| M2 | Fix waits belong to their operation or preview; cancel/discard drop them and release GPS immediately. Preview expiry abandons a pending Start check, and commit re-checks expiry. |
| M3 | Reaching the stop retires an in-flight reroute and releases its ticket before ending the leg. |
| M4 | A record that can't be read (newer schema, damaged, oversized, unavailable) is never overwritten; stores refuse writes until an explicit discard. |
| M5 | Inbox and history mutations roll back on a failed write and return a result; a waiting destination is dispatched only after its acceptance is stored. A backup-exclusion failure after the bytes were written is a warning, not a lost save. |
| M6 | Leg two continues the same recording (totals kept, anchor reset); a resumed ride records only if it was being recorded under the current consent. A draft is saved at ride start. |
| M7 | `WriteCompletionRouter` gives each raw write its own answer (FIFO per characteristic), refuses raw writes while the app's own write on that channel is outstanding, and drops answers nobody asked for. Callbacks from a non-current peripheral are ignored. |
| M8 | The wizard sends its own fresh clear and judges only that clear's answer; the arrow must be confirmed visible before its disappearance can be recorded. |
| M9 | Every calculation uses the current route preferences; the ride adopts them only when the route commits. The unused provider property was removed. |
| L1 | Footer and console say "clear requested", "sent, not acknowledged", "bike acknowledged (not proof it was shown)", "test requested for 5 s". |
| L2 | UI test classes are `@MainActor`; no actor-isolation diagnostics remain. |
| L3 | Setup, troubleshooting and `App.xcconfig` describe the Apple no-key build; freshness is described as measurement age. |
| Quick wins | 4 KiB input cap before parsing and at most 8 share attachments; the extension reports a failed hand-off; foreground safety tick before new output; speech tags cleared on stop; provider tests use virtual time instead of 2.1 s sleeps. |

Not done (recommendations, not defects): performance items R11, features N1-N10, the Bluetooth platform seam
(callback routing logic is tested in core, not through a fake `CBPeripheral`), and the App Group (N8, owner gate).

### Second review round (2026-11-13)

A follow-up review of the fixes found eight further issues; all were confirmed and fixed, each with a test in
`SecondReviewRegressionTests`. Verified: 157 core tests and 99 app unit tests pass; the 14 simulation UI tests
pass (two needed a rerun because of keyboard/toggle timing under a heavily loaded Mac, in screens this round
did not change). No device checks.

| # | Issue | Fix |
| --- | --- | --- |
| 1 | Test audio replaced the tracked prompt without stopping a speaking turn | Test audio stops the current turn and drops the pending one before speaking. |
| 2 | A failed save of a resolved short link reopened the item, expanding the link again (repeatedly) | Reopen only after the resolved place is stored; otherwise show a storage message and stop. Link expansion is injectable for tests. |
| 3 | Ending a ride deleted an unreadable (preserved) recovery file | `finish` keeps a blocked journal; only an explicit discard removes it. |
| 4 | Resuming at the stop after a restart lost leg two from history | Resume at the stop continues the recording (consent-checked), and the totals are saved on reaching the stop. |
| 5 | A reroute still running at final arrival could commit afterwards | Final arrival retires the operation; no recalculation after arriving. |
| 6 | Throttled Live Activity text could delay freshness renewal; a change back to the shown text stayed queued | Freshness renewal and text throttling are scheduled independently; returning to the shown text drops the held change. |
| 7 | Unreadable inbox/history/recovery data could not be discarded from the app | Confirmation-backed Discard buttons in Waiting destinations, Ride history and Ride settings. |
| 8 | The pump didn't wait for an outstanding console write; unacknowledged console writes ignored readiness | The pump holds a channel while a console write on it awaits its answer; console writes time out after 3 s (link retired) and unacknowledged ones respect Bluetooth readiness. Production callback interleaving remains a device gate. |

# Support matrix (as of 2026-11-12, Apple MapKit build)

Every row states what is **verified**, and how. "Unverified" means not observed yet - do not rely on it.

| Area | Status | Evidence |
| --- | --- | --- |
| Packet encoding (TBT 48-byte, status 55/89-byte) | Verified against pinned Ride Relay encoder, byte-for-byte | 99 + 28 golden vectors, `scripts/test.sh core` |
| Session safety (stale/stop/reroute/reconnect clearing, old-route rejection) | Verified in unit tests on a virtual clock | RideCore tests |
| Route request limits / no auto-retry / Bluetooth cannot request routes | Verified in unit tests | RideCore tests |
| Plus-code and coordinate parsing | Verified against 420 Open Location Code reference vectors | RideCore tests |
| Diagnostics exclude keys, coordinates, road text | Verified with sentinel values | RideCore tests |
| iOS app build | Verified: simulator and generic-device (arm64, unsigned) builds succeed, Xcode 27.2, Swift 6 strict concurrency, no warnings in app code | task-11-14-app-tests.txt |
| Simulation UI flow (paste → confirm → start → stop, favourites, short-code rejection) | Verified: 5 UI tests pass on iPhone 18 Pro simulator (iOS 27.2); screenshots small/large, light/dark, largest text size | task-01-tests.xcresult, task-14-screens/ |
| Google SDK adapter | Excluded from the current build (owner chose Apple MapKit 2026-11-12); code kept behind `canImport`, compiled and fixture-tested against SDK 11.3.0 before exclusion | task-11-14-app-tests.txt |
| Google eligibility (GATE-1) | **Open** - policy says commercial applications only | docs/feasibility.md |
| Zero-spend boundary (GATE-2) | **Open** - no hard cap proven | docs/cost-model.md |
| Install on owner's iPhone | Installed 2026-11-12 (iPhone17,3, iOS 27.0.1, free Personal Team signing, expires after 7 days). First launch pending the owner trusting the developer certificate | task-progress.md |
| iPhone ↔ N250 Bluetooth link | **Unverified** (owner reports N160/NS200 work; not this N250, not from iPhone) | task 20 / task 9 |
| N250 status profile | Likely **legacy55** (owner: network bars appeared; phone has legacy55 saved). Battery display not yet confirmed. Signal bars are a fixed placeholder (4) - iOS gives apps no signal strength | task-09-15-procedures.md |
| Turn arrows on N250 (parked) | Owner-observed 2026-11-12: test arrows display correctly | task-09-15-procedures.md |
| Roundabout display | Owner bench 2026-11-12: value = angle on a fixed picture, 1/8 turn per step. Glyph 85 sweeps clockwise 1 sharp left → 7 sharp right; glyph 78 anticlockwise 1 right → 6 sharp left. Clockwise (India) roundabouts use 85. App sends the value for Google's exit direction; unknown/undrawable directions clear the dashboard. Diagnostics samples to be confirmed on the bike | task-09-15-procedures.md |
| Stop frame clears N250 display; cluster timeout after disconnect | **Unverified** | task 9 |
| Locked-screen background operation | **Unverified** - background modes declared (Bluetooth, location) | task 15 |
| Road use / six-hour endurance | **Not started** | task 17 |
| Caller name on dashboard | **Not available on iPhone**: cluster did not show it via iOS notifications (ANCS) with N250 Ride connected, and iOS gives apps no caller name | task-09-15-procedures.md |
| Apple MapKit routing | Live provider. Terms checked (DPLA §3.3.3(F)(iii) notice shown). **Car-profile** routes only (no motorcycle profile in MapKit) | task-19-apple-terms-and-api.md |
| Guidance engine (snapping, progress, off-route/reroute throttle, GPS gaps, arrival, ETA) | Verified in unit tests and by replaying 4 real Apple Maps Bengaluru routes at 10 m spacing: all reach arrival, no false reroutes (incl. a U-turn route) | task-19-real-route-check.txt |
| Maneuver classification from Apple steps | 45/45 maneuvers on 4 real routes classified (turns, keeps, U-turns, a roundabout with direction). Uses English instruction text: other phone languages fall back to geometry with stricter suppression | task-19-real-route-check.txt |
| Live Apple guidance on the road | **Not yet ridden** - on-device route request, locked-screen location and real GPS untested | task 15/17 |
| ETA during ride | Apple's route time scaled by remaining distance; no live traffic refresh until a reroute | GuidanceEngine |
| Place search (Apple Maps) | Verified live in simulator: "Orion Mall" → suggestions → resolved; Bengaluru landmarks checked on Mac (Cubbon Park, Orion Mall, Lalbagh, Bangalore Palace). Result shown on an Apple map (terms Att. 6 §2.4) | live-apple-route.xcresult |
| Alternative routes | Verified live: 3 Apple routes returned in ~2 s from one request; switching sends no request (unit-tested with spy) | live-apple-route.xcresult, AppModelProviderTests |
| Live guidance with moving location (simulator) | Verified: simulated rider along a real Apple route at 6 m/s; turn card counted 210 m → 90 m, dashboard frame switched to blinking turn-right below 100 m | ui-redesign-screens/6*, 7* |
| Custom status packet (Diagnostics) | Volume/battery/signal/raw-byte overrides encoded and sent (unit-tested); effect on N250 **not yet observed** | CustomStatusTests |
| Spoken directions | Planner unit-tested (stages ~1 km / 300 m / now, reroute, GPS lost, arrival); speech runs in simulator rides. Real helmet/earphone audio **not yet heard on device** | VoicePromptTests |
| Avoid tolls / highways | Passed to Apple Maps on every request and reroute (unit-tested forwarding) | AppModelProviderTests |
| Live Activity (Lock Screen, Dynamic Island) | Verified in simulator: compact island showed arrow + distance and kept updating in the background during a moving live ride | ui-redesign-screens/8-dynamic-island.png |
| Share → N250 Ride, paste link, n250ride:// | Link parser tested on Apple/Google/WhatsApp/geo/plus-code forms; cross-process hand-off verified (test runner wrote, app opened confirmation). Real Share sheet from Google Maps **not yet tried on device**; Google short links expanded by following their redirect | MapLinkTests, SimulationUITests |
| Home / Work / recents | One-tap Home goes straight to route options; recents deduplicated within 75 m (tested) | SavedPlacesTests, AppModelProviderTests |
| Bluetooth console | Built with safety rules (parked only, firmware service blocked, unknown channels confirmed, single-write limit); presets fill bytes without sending. **Not yet used on the bike** | SimulationUITests |
| Dashboard uses Apple notifications (ANCS) | Owner: "Share System Notifications" is on for the bike in iOS Bluetooth settings | owner report 2026-11-12 |

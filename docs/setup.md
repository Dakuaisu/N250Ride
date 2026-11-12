# Setup

## Requirements (verified 2026-11-11)
- macOS with Xcode 26 or later (Xcode 27.2 installed here). Google Navigation SDK **11.3.0** needs Xcode 26+ and iOS 17+.
- Homebrew `xcodegen` (2.46 used). Homebrew `openjdk` only if you regenerate protocol vectors.
- iPhone on iOS 17 or later for device use.

## 1. Xcode (once)
```sh
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
```
`xcode-select -s` is required first: while the active developer directory is the Command Line Tools,
`sudo xcodebuild` refuses to run.

## 2. Build and test (simulation, no Google key)
```sh
scripts/bootstrap-xcode.sh
```
This installs the iOS simulator platform if missing, generates `N250Ride.xcodeproj`, resolves the pinned
Google packages (11.3.0, exact) and runs `scripts/test.sh core` and `scripts/test.sh app`. Result bundles go
to `.omo/evidence/n250-ios-navigation/`.

Individually:
```sh
scripts/test.sh core                                  # RideCore
SIMULATOR_UDID=<udid> scripts/test.sh app             # app + UI tests on a simulator
```

## 3. Install on your iPhone (free signing)
1. `cp Config/Local.example.xcconfig Config/Local.xcconfig` and set `N250_DEVELOPMENT_TEAM` (your Personal Team
   ID from Xcode > Settings > Accounts) and a unique `N250_BUNDLE_ID`.
2. `xcodegen generate`, open `N250Ride.xcodeproj`, choose your iPhone, Run.
3. On the phone: enable Settings > Privacy & Security > Developer Mode (restart), and after the first install
   Settings > General > VPN & Device Management > trust your developer certificate.
   Command-line alternative once the team is set: `xcodebuild build -scheme N250Ride -destination id=<UDID> -allowProvisioningUpdates`
   then `xcrun devicectl device install app --device <UDID> <path to Debug-iphoneos/N250Ride.app>`.
4. Free Personal Team installs **expire after 7 days**; reconnect and Run again to renew.

The app uses **Apple Maps** car routing (no key, no billing). On first use it shows Apple's required notice
("YOUR USE OF THIS REAL TIME ROUTE GUIDANCE APPLICATION IS AT YOUR SOLE RISK …"). Diagnostics → Simulation mode
replays a synthetic route instead, with no route requests.

## 4. Optional: Google navigation (only after GATE-1 and GATE-2 pass)
Re-enable the commented Google packages and dependencies in `project.yml`, set `N250_NAV_PROVIDER = google`,
then follow the steps below. The Google adapter code is kept behind `#if canImport(GoogleNavigation)` and
must be rebuilt and re-tested when enabled.
Do not do this until Google has confirmed eligibility and you accept the billing exposure in
[cost-model.md](cost-model.md).
1. In a **dedicated** Google Cloud project, enable only the Navigation SDK. Create an API key restricted to
   **iOS apps** with your bundle ID and to the Navigation SDK API only.
2. Set quotas/alerts as described in cost-model.md. Alerts do **not** stop charges.
3. In `Config/Local.xcconfig`: `N250_GOOGLE_API_KEY = …` and `N250_LIVE_NAVIGATION_AUTHORIZED = YES`.
4. Regenerate and run. Accept Google's terms dialog in the app.
5. Rotate the key in the Cloud console if it is ever exposed; never commit `Config/Local.xcconfig`.

Local limits (20 destinations/day, 600/month) are counted on the phone before each request. They reset on
reinstall and cannot see other usage on your billing account; they are not a zero-charge guarantee.

## 5. Bike pairing
Close the official Bajaj app and disconnect other phones. Bike tab > Scan > pick your bike. Status packets
stay off until a profile is proven on the N250 (`N250_STATUS_PROFILE` in Local.xcconfig after task 9).

## Regenerating protocol vectors
```sh
brew install openjdk
scripts/oracle/generate-vectors.sh --check
```

## Live Apple test in the simulator (optional, uses the network)
```sh
U=<simulator udid>
xcrun simctl privacy $U grant location-always <bundle id>
xcrun simctl location $U start --speed=6 --interval=1 - < waypoints.txt   # or: location $U set 12.9757,77.6050
TEST_RUNNER_N250_LIVE=1 xcodebuild test -project N250Ride.xcodeproj -scheme N250Ride \
  -destination "platform=iOS Simulator,id=$U" -only-testing:N250RideUITests/LiveAppleRouteUITests
```
Normal test runs skip this test, so they never contact Apple.

# N250 Ride

N250 Ride is an iPhone navigation app for the 2026 Bajaj Pulsar N250's existing
instrument cluster. It computes turn-by-turn guidance on the phone and sends
turn arrows, distance, and ETA to the dashboard over Bluetooth Low Energy (BLE).

**Development status:** this is a development build, not a road-validated release.
Parked testing has confirmed that test arrows display on the N250. That does not
establish end-to-end navigation reliability. See the
[support matrix](docs/support-matrix.md) for feature-by-feature evidence and limits.

## Capabilities

The following features are implemented; implementation does not mean they have
been verified on the motorcycle:

- Apple Maps place search, destination confirmation, and alternative routes,
  with options to avoid tolls and highways.
- On-phone guidance with route progress, off-route detection, rerouting, arrival
  handling, and BLE dashboard updates.
- Spoken directions, saved Home and Work destinations, and recent destinations.
- Destination import through pasted map links, the share extension, and the
  `n250ride://` URL scheme.
- A Live Activity for the Lock Screen and Dynamic Island on supported devices.
- Synthetic-route simulation, diagnostics, and a parked-only Bluetooth console
  for inspecting and testing cluster communication.
- Ride health that explains GPS, route, bike and voice problems and never shows a
  direction from stale position data, on the phone and the Lock Screen.
- Manual recalculate with cancel and retry; route changes take effect only once
  the new route is ready.
- One optional stop on the way, a queue for destinations shared during a ride,
  opt-in recovery of interrupted rides and opt-in, privacy-limited ride history.
- Concise or detailed voice with repeat and test, paused during calls or when a
  headset disconnects; a parked, step-by-step bike compatibility check; an energy
  saving mode.

## Routing and current limits

The active provider is **Apple Maps (MapKit), using car-profile routes**. MapKit
has no motorcycle routing profile, so these routes are not motorcycle-specific.
Turn-by-turn guidance is computed by the local `RideCore` engine. The default
Apple build needs no Google API key or Google billing setup.

- Locked-screen and background operation on a physical device remain unverified.
  Declared background modes and simulator behavior are not proof of reliability
  on the road.
- Road testing and six-hour endurance testing have not started. Perform initial
  bike checks while parked; don't rely on this build as your sole navigation aid.
- Stop-frame clearing and cluster timeout after disconnection remain unverified
  on the N250. Status packet profiles require separate parked validation.
- Real helmet or earphone voice output and sharing from another app's Share sheet
  still need device testing.
- ETA is based on Apple's route time scaled by remaining distance. Traffic is
  not refreshed until a reroute.
- Maneuver classification uses English instructions, with a more conservative
  geometry fallback for other languages.
- iOS does not let this app answer phone calls or access caller names. Caller-name
  display is not available through N250 Ride.

**Google navigation is optional and disabled.** Its adapter is retained behind
`canImport(GoogleNavigation)`, but the SDK packages and dependencies are excluded
from the current project. Re-enabling it requires eligibility approval (GATE-1),
an accepted billing boundary (GATE-2), configuration changes, and fresh testing.
Neither gate is settled. See [feasibility](docs/feasibility.md) and the
[cost model](docs/cost-model.md); local request limits are not a hard billing cap.

## Requirements

- macOS with Xcode 26 or later for iOS builds and simulator tests, following the
  documented setup baseline.
- Swift 6. The project enables complete strict concurrency checking.
- XcodeGen (`brew install xcodegen`; version 2.46 was used in the setup guide).
- An installed iOS simulator runtime for app tests.
- An iPhone running iOS 17 or later and a signing team for device installation.
  A physical motorcycle is needed to validate dashboard behavior.

The standalone `RideCore` package targets macOS 14 or later and iOS 17 or later.
Its tests can run with a compatible Swift 6 Command Line Tools installation,
without full Xcode.

## Setup

Run commands from the repository root. For first-time Xcode selection, license
acceptance, and simulator setup, follow [the setup guide](docs/setup.md).

### Generate and open the project

```sh
brew install xcodegen
scripts/test.sh core
xcodegen generate
open N250Ride.xcodeproj
```

Select the `N250Ride` scheme and an iPhone simulator in Xcode to build and run.
Diagnostics > Simulation mode replays a synthetic route without route requests.

After installing Xcode and completing its first-launch setup, the optional
bootstrap script installs the iOS simulator platform if missing, generates the
project, resolves dependencies, and runs core and app tests:

```sh
scripts/bootstrap-xcode.sh
```

### Configure signing for an iPhone

Copy the example configuration:

```sh
cp Config/Local.example.xcconfig Config/Local.xcconfig
```

In `Config/Local.xcconfig`, uncomment and set `N250_DEVELOPMENT_TEAM` to your Xcode
team ID and `N250_BUNDLE_ID` to a unique bundle identifier. This local file is
ignored by version control and included by `Config/App.xcconfig`. Never commit
real signing values or API keys.

Regenerate the project, open it, select your iPhone, and run:

```sh
xcodegen generate
open N250Ride.xcodeproj
```

Enable Developer Mode and trust the developer certificate on the phone as
described in the setup guide. Free Personal Team installs expire after seven
days and must be renewed. Leave Google navigation and status-profile overrides
disabled unless their respective prerequisites have been verified.

For initial bike pairing, close the official Bajaj app, disconnect other phones,
and use Bike > Scan while parked.

## Tests

Run the standalone core suite:

```sh
scripts/test.sh core
```

Run app unit tests and UI tests on the first available iPhone simulator:

```sh
scripts/test.sh app
```

To choose a simulator, list the available devices and substitute its identifier:

```sh
xcrun simctl list devices available
SIMULATOR_UDID="YOUR_SIMULATOR_UDID" scripts/test.sh app
```

Run both suites with `scripts/test.sh all`. The app test command regenerates the
Xcode project and writes a timestamped `.xcresult` bundle under
`.omo/evidence/n250-ios-navigation/` by default. Normal runs skip the opt-in live
Apple routing test; instructions for that network-backed test are in the
[setup guide](docs/setup.md#live-apple-test-in-the-simulator-optional-uses-the-network).

Core tests cover protocol encoding, session safety, BLE write scheduling,
destination parsing, request limits, and guidance logic. App and UI tests cover
provider integration and simulated user flows. These checks do not establish
physical-bike compatibility or road endurance.

## Architecture

The iOS app coordinates routing, location, and user interaction. `RideCore`
handles guidance and protocol logic, while the CoreBluetooth adapter sends
encoded updates to the cluster. The share extension accepts destinations, and
the widget extension presents the ride's Live Activity.

| Path | Responsibility |
| --- | --- |
| `Packages/RideCore/` | Pure Swift guidance engine, packet encoders, session state and safety rules, BLE write pump, request gate, destination parsing, and diagnostics. |
| `N250Ride/` | SwiftUI app, composition root, platform adapters including CoreBluetooth and MapKit, and the disabled optional Google adapter. |
| `N250RideShare/` | Share extension for incoming destinations. |
| `N250RideWidgets/` | Live Activity presentation. |
| `Shared/` | Types and handoff code shared with extensions. |
| `N250RideTests/`, `N250RideUITests/` | App unit tests and UI tests. |
| `project.yml` | XcodeGen specification for the app, extensions, and test targets. |
| `Config/` | Tracked build defaults and an example for ignored local overrides. |
| `scripts/` | Test entry points, Xcode bootstrap, and protocol golden-vector tooling. |
| `docs/` | Setup, validation status, troubleshooting, routing constraints, and protocol provenance. |

## Documentation

- [Setup and device installation](docs/setup.md)
- [Support matrix and verification evidence](docs/support-matrix.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Google eligibility and feasibility](docs/feasibility.md)
- [Google costs and billing limits](docs/cost-model.md)
- [Protocol documentation and provenance](docs/protocol/)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

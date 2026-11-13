# Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `scripts/test.sh app` says BLOCKED | Xcode missing or licence not accepted: `sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch`. |
| `swift test` fails with "Unknown error parsing property list" or "no such module 'Testing'" | Command Line Tools only. Use `scripts/test.sh core`, which adds the needed flags. |
| App shows "Simulation" | Simulation mode is switched on in Diagnostics (or the build has no live provider). The default Apple Maps build needs no key: turn Simulation mode off between rides to use live routes. |
| "Live navigation is off: …" | The route gate is disabled by configuration; no request was sent. |
| "Daily/Monthly limit reached" | Local limit hit (20/day, 600/month). Resets at local midnight / month start. |
| "No two-wheeler route found" | Only in a Google build (disabled by default). Google returned no two-wheeler route; the app never falls back to car routing. |
| Bike not in scan list | Close the official app, turn off Bluetooth on other phones, ignition on, scan again (10 s). The scan only lists devices with a name. |
| "Connection failed: serviceNotFound" | The selected device is not the cluster, or the cluster firmware differs. Capture the service list with a BLE inspector (task 20). |
| "writeLengthTooSmall" | The cluster accepts less than a 48-byte frame. Frames are never split; report the value. |
| Dashboard shows an old arrow after the phone disconnected | The phone cannot clear a cluster it is not connected to. The cluster clears on its own timeout (to be measured). On reconnect the app always requests a clear first. |
| Dashboard clear requested with "guidance is stale" / "GPS lost" | The newest genuine GPS measurement is 5 s old or more (a quiet GPS, a tunnel, or the phone suspended). Directions resume with the next real fix; re-sent old positions never count. |
| Ride footer says "sent, not acknowledged" or "delivery uncertain" | The bike's Bluetooth didn't confirm the write. Only you can see what the dashboard shows; after a timed-out write the app reconnects and clears first. |
| Arrow missing for a ramp/unknown maneuver | Deliberate: unclassifiable maneuvers clear the dashboard instead of guessing. |
| Return to the official Bajaj app | Stop navigation, Diagnostics > Forget paired bike, then optionally iOS Settings > Bluetooth > Forget This Device. Nothing on the bike was changed. |
| Free-signed app stops opening | Personal Team builds expire after 7 days. Reconnect and Run from Xcode. |

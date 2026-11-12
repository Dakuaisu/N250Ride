# Protocol provenance

N250Ride's cluster encoders are a Swift port of Ride Relay (MIT, © 2026 Mano K):

- Repository: https://github.com/manov-ik/ride-relay
- Pinned commit: `530632e4ae116645a16710a15f73e492159a7699` (v1.7, 2026-10-26)
- Files the port follows (SHA-256 at the pin):
  - `app/src/com/bajajnav/relay/TbtFrame.java` `fe6e783777c8739c97e6d60fbe30748a89150db64acce74a7e902a9b460b2107`
  - `app/src/com/bajajnav/relay/Pack.java` `a190a94471f0d63bfab00a73adfe67a564e56592e1f550db0a077b969fe3040e`
  - `app/src/com/bajajnav/relay/GeneralPacket.java` `d742b6a400f09c5eb6005b5000c9f7535c02067aa40731850270a283447d7508`
- Also read: `docs/PROTOCOL.md`, `ClusterLink.java`, `RelayService.java`, `NavParser.java` (blink rule).

No upstream code is redistributed; the MIT notice is in [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).

## Oracle

`scripts/oracle/generate-vectors.sh` compiles the three pinned files **unmodified** with two oracle-only
stubs (`android.os.Build.MODEL = "iPhone"`, a `PhoneBridge` reporting no call) plus `VectorGen.java`, and
writes `Packages/RideCore/Tests/RideCoreTests/Resources/golden-vectors.json` (synthetic inputs only).
`--check` regenerates and diffs. Java is a development-only dependency.

## Behaviour pinned by the vectors (not by upstream comments)

| Topic | Observed upstream behaviour | RideCore |
| --- | --- | --- |
| Distance | Not true 16.16: low word is decimal hundredths, truncated via `double`. 4,350 m → `4.34 km`; 1,999 m → `1.99 km` | Same arithmetic (deliberate fix deferred until bench evidence) |
| Units | Byte 0 bit4 = step unit (1 = metres), bit7 = PM; byte 12 bit0 = total unit, bits 2-3 = GPS active | Same |
| Stop frame | **Not** 48 zeros: `10 00… 05 (byte 12) … 15 (checksum)` | Same; cluster reaction to be observed (task 9/20) |
| Text | `[^0-9A-Za-z.]` → one space per code point, trimmed, first 31 bytes kept (the appended "." is cut) | Same |
| Out-of-range input | Silently wraps (hour > 15, exit > 15, km > 65,535) or clamps negatives | **Rejected**; the session clears the dashboard instead |
| Unknown maneuver | Upstream maps to wrong-way (66) | **Suppressed** (clear), never wrong-way or straight |
| Blink | Icon + 32 when step < 100 m, except destination | Same |
| Roundabout exit | High nibble of byte 7 (upstream relay actually always sends 0) | Angle value from Google's exit direction via `RoundaboutCalibration.n250`; unknown/undrawable → dashboard cleared |
| General status | Legacy 55 bytes (no checksum) / V2 89 bytes (checksum @88); heartbeat shared, wrapping | Both profiles, neutral phone fields; none sent until a profile is proven on the N250 |

## Open hazards (need the parked-bike test)

- Which general-status profile (if any) the N250 cluster requires for link health.
- Whether the stop frame clears the N250 display, and the cluster's own timeout after link loss.
- Roundabout (owner bench 2026-11-12): byte-7 high nibble is an exit **angle** on a fixed picture (entry at
  bottom, 1/8 turn per step), not an exit count. Glyph 85 sweeps clockwise (1 sharp left … 7 sharp right),
  glyph 78 anticlockwise (1 right … 6 sharp left). Upstream's cw→78 naming is reversed for drawing; RideCore maps
  clockwise → 85, anticlockwise → 78.

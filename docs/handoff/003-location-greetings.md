# Handoff: location-greetings

- Goal / why: The location stream exists so Chi's "いってらっしゃい" / "ただいま" land on time
  (owner, 2026-09-13). Battery work and cadence tiers are means; the metric is seconds from
  leaving/arriving home to the greeting.
- Scope: `recall/Core/Location/*` (cadence, motion triggers, geofence events),
  `ConnectivityMonitor` (Wi-Fi name), telemetry payloads, `docs/pipeline.md` §8.
- Explicitly out: accuracy filter (BG 200 m / FG 100 m, owner-ruled), JumpGate, other streams.
- Status: implemented and deployed to kana; almost nothing measured yet (see caveat).

## The real cause of late greetings (oc-general, read from their scripts 2026-09-13)

The server decides departure from `current-location.json` distance checks, not from anything
recall sends as an event:

- home radius 30 m, accuracy gate 30 m; departure needs **3 consecutive samples over 180 s**
- `location-check` runs on a **60 s launchd interval**
- night guard (00:00-06:00 after 60 min dwell): **600 s and 5 samples**
- so the structural floor was **3-4 min, 10 min+ at night** — independent of our send cadence.

## What recall now does

- **Geofence events** (`GeofenceEventReporter`, 8e58f09): on CLCircularRegion enter/exit it
  POSTs `{device_id, type:"geofence_event", anchor, transition, occurred_at, accuracy_m, fix_id}`
  immediately, carrying the OS crossing time. oc-general is building the receiver; idempotency
  key is `(anchor, transition, occurred_at)`. Ordinary position POSTs continue as the slow
  never-miss path. iOS region radius stays 50 m (smaller radii fire unreliably); the server
  keeps its 30 m distance check.
- **Wake triggers out of the parked tier**: pedometer step updates, pedometer events, a 1 Hz
  accelerometer shake watch (0.12 g, parked only), and a 100 m geofence around the parked spot.
- **Cadence tiers** and the never-stop-updates rule: `docs/pipeline.md` §8.
- **Wi-Fi name** travels with each position (`wifi_ssid`, `wifi_ssid_age_seconds`) alongside the
  derived `wifi` home/away. `NEHotspotNetwork.fetchCurrent` mostly answers only in the
  foreground, so the last known name is kept with its age.
- **Departure latency logging**: `Departure: first accepted fix Xs after movement (acc, age)`
  then `Departure: first position sent Xs after movement`.

## Caveat on the 2026-09-13 early-morning logs

The owner was **on a plane**. No cellular (SOS), no usable GNSS in the cabin: every fix came
back at ~1.7 km and the 200 m filter rejected all of them, so `LAST FIX --` and the repeated
"No fixes ... restarting location updates" lines are the environment, not a defect. Do not
tune thresholds from that window.

## Open

1. Measure on the ground: trigger -> first accepted fix -> send, and end-to-end to the greeting
   once oc-general's event receiver is live (they can correlate if we also put `fix_id` on
   position POSTs — not implemented yet).
2. Wi-Fi home detection is dead in the background (0 home classifications all day). Fixing it
   would give the earliest possible doorway signal. Add a watchdog that warns when SSID-derived
   home detection has been zero for N days (oc-general's advice: a fast path needs its own
   liveness check).
3. Battery: no 24 h before/after comparison yet; baseline numbers in
   `docs/handoff/001-battery-cadence.md`.

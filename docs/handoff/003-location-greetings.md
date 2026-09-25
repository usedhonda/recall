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

## Done 2026-09-13

- **`fix_id` is now a real join key** (`bfde8d3`). Crossing events used to invent one, so
  nothing could be correlated. `LocationManager` issues an id when it accepts a fix and
  re-issues it only for a genuinely different fix (the forced send after a crossing replays
  the same `CLLocation`); positions and events both quote it. `TelemetrySample.id` stays
  unique per POST on purpose — the stationary heartbeat re-sends one fix every few minutes
  and a stable `id` would let the server dedupe the heartbeat away. Wire format is pinned by
  `Tests/recallTests/TelemetrySampleEncodingTests.swift`.
- **The Wi-Fi name is read on every foreground** (`abbd1d7`). It was only asked for on the
  join transition, which almost always happens in the background where iOS answers nil —
  hence zero home classifications on 09-12. The "home detection has been dead for N days"
  watchdog stays on the server: `wifi_ssid_age_seconds` already travels with every position,
  and a second copy of the same check on the device would be duplicated machinery.
- **Battery level goes into the activity log on change** (`abbd1d7`), riding the heartbeat
  tick, so the next power comparison can be stated in %/h.
- The event schemas were re-sent to oc-general (the earlier queued copy expired unsent).

## Owner ruling 2026-09-13: raw SSID, place resolution on the server

The owner chose to send the network name as-is rather than resolve it to a place label on
the device: "家と会社もだけど、家も海外にもあるので。OpenClaw がしってる". There are more
places than home and office, some of them abroad, and the table that maps names to places
already lives on the server side. So:

- `wifi_event.ssid` and the position POST's `wifiSSID` carry the raw name. No labelling.
- `AppSettings.homeSSID` holds **one** name, so the derived `wifi` ("home"/"away") calls an
  overseas home "away". It is a hint, not the authority — the server's table decides.
- oc-general is amending their own contract to accept the raw name; until then `wifi_event`
  answers 400, which recall logs and drops (no retry, no queue).

`geofence_event` went live on their side the same day: a good event answers
`{"geofenceEventReceived":true,"duplicate":false}`, `occurred_at` is kept verbatim and their
receipt time lands in a separate `received_at`, and duplicates are folded by parsed instant
rather than string match.

## Measured on the ground, 2026-09-25 (first real out-and-back in Singapore)

From the on-device log (JST): out 13:48 -> home 15:09, about 2.1 km away at the furthest.

- The fast path worked and was accepted: `wifi left: sfk841` at 13:48:08, a fresh-fix kick in
  the same second, `wifi_event left ... sent: HTTP 200` at **13:48:10 — two seconds after the
  doorway**. Arrival likewise at 15:10:21.
- Position kept flowing while away: 268 sends, largest gap 6 min, accuracy mostly 2-5 m.
- No greeting fired. oc-general had been looking at 15:10-18:25, i.e. **after the return**,
  where "inside, 6-20 m from home" is simply correct. They are re-checking 13:48-15:10 and
  have agreed to separate "HTTP 200" from "stored", and never to greet on Wi-Fi alone.

### The weakness this exposed: one witness only

`geofence_event` did not fire at all — the configured anchors are in Tokyo. The parked-circle
exit added for exactly this reason (`ef927db`) did not fire either: the circle is cleared and
re-armed on every small movement indoors (**40+ times on 2026-09-25**), and it happened not to
be armed at the moment of departure. So in Singapore the departure has **only the Wi-Fi drop**
as a witness, and Wi-Fi alone must not greet — the home network drops without anyone leaving
(observed the same day: left 06:37Z, rejoined 07:44Z, position unchanged).

Options, none implemented: keep the parked circle armed through small indoor movement (arm it
around the *home* rather than the last fix, or require a real exit before clearing); let the
owner add a Singapore anchor; or let the server treat "Wi-Fi drop + the next position beyond
N m" as two witnesses rather than one.

## Open

1. Measure on the ground: trigger -> first accepted fix -> send, and end-to-end to the
   greeting once oc-general's receiver is live.
2. **The app was dead for 5h04m on the morning of 09-12** (09-11T21:08:44Z -> 09-12T02:13:05Z,
   i.e. 06:08 -> 11:13 JST): no lines at all, then a silent relaunch. Audio was not running,
   so only the location stream was holding the process up. Nothing else can matter if the
   process is gone — this outranks every latency tuning below. Needs: a launch-time line
   recording how long the log had been silent, then a few days of data. See
   `docs/handoff/001-battery-cadence.md` for the numbers and the jetsam hypothesis.
3. The stationary heartbeat effectively lands every 600 s, not 300 s: in the parked tier iOS
   only services the timer when a fix arrives. Under our own target, but exactly on
   oc-general's 10 min gap threshold. The parked-probe fix below may change this, since a
   delivered fix is itself a wake.

## Fixed later the same day

- **The parked probe now returns a fix** (`f44aa60`). Each parked heartbeat opened a 30 s
  window at full accuracy, but left the 100 m distance filter on — and a phone that is not
  moving never travels 100 m, so iOS delivered nothing. The position being re-sent aged
  without bound (371 min, measured by oc-general on 09-12) and arrival stopped being
  decidable from freshness. The probe now drops the filter with the accuracy; the next tick
  restores it. Same for the window right after a relaunch, when no fix has been accepted yet.
- **Every launch says how long the log had been silent** (`d6bbfd2`). iOS never tells an app
  it was killed, so a termination's only trace is the hole. The alarm itself stays on the
  server: oc-general is adding a liveness measure from the receive time, because the payload
  `timestamp` is the fix's own time and an ageing fix cannot distinguish "alive and parked"
  from "dead".
- oc-general's side of the same story: `scripts/location-check:320` read `timestamp` first
  and never reached `receivedAt`, so their monitor had no liveness measure at all. They are
  splitting the alarm into "no word from the device" (always wrong) and "the fix is old"
  (normal while parked or airborne).
4. Battery: rates measured (see handoff 001). An actual %/h figure needs a day with the new
   logging, or the owner's Settings > Battery screen.

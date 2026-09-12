# Handoff: battery-cadence

- Goal / why: Owner observed fast battery drain while audio was not recording. On-device logs
  showed the independent streams (Health / Location / helpers) running at full cadence 24h a
  day with no change detection. Goal: cut each stream's own cost without coupling streams.
- Scope: `HealthKitManager`, `LocationManager` (send rule + heartbeat only), `UploadManager`
  (+ wake calls in `AudioRecordingEngine`, `ConnectivityMonitor`), `ServerHealthMonitor`,
  `ActivityLogger` (cherry-pick of 8d3522b), `docs/pipeline.md` §8.
- Explicitly out: GPS `desiredAccuracy` (owner ruling 2026-09-11: keep Best in FG and BG);
  `RecallApp.swift` forced-on Location/Health toggles; UI changes; consolidating the four
  location delivery paths (Phase 2, needs separate approval).
- Status: review — deployed to kana 2026-09-11 08:28Z; 24h before/after comparison pending.
- Done so far:
  - Health: 15 min supplementary poll (was 15 s), skipped while locked with one catch-up on
    unlock, unchanged snapshot not re-POSTed (keepalive after 40 min => effective ~45 min),
    per-type `empty` log lines removed.
  - Location: stationary re-send every 300 s (was 15 s); >= 20 m displacement still sends
    immediately (unchanged rule).
  - Upload queue: idle loop waits for a wake (chunk saved / network change) or 60 s (was 3 s,
    5 s when blocked).
  - Server probe: BG 300 s (was 120 s); network-change probes dropped within 30 s of the last.
  - ActivityLogger: file writes buffered (2 s / 16 KB / immediate on `.error`) — 8d3522b had
    only ever landed on feat/dat-glasses-photo, never on main.
- Files changed: see commits e4f1c03..2eee455 on main (7 commits, not yet pushed).
- Decisions:
  - Stationary location 5 min is the ceiling: oc-general's smallest location gap threshold is
    10 min (stationary-cluster continuity). Do not lengthen.
  - Health keepalive < 60 min: the PCE viewer marks health stale when the last received POST
    is > 60 min old.
  - Location payload `timestamp` is the fix's own time (`CLLocation.timestamp`).
- Rejected options: reverting BG accuracy to NearestTenMeters (owner chose Best);
  1 h health keepalive (viewer flicker at the 60 min boundary);
  letting location pause while stationary (`pausesLocationUpdatesAutomatically = true` or
  `liveUpdates`' stationary pause) — rejected for now: iOS may suspend the app while paused,
  which stops the 5 min stationary heartbeat and breaks oc-general's 10 min gap / 15 min
  freshness thresholds. This is the only remaining big GPS-power lever; owner trade-off.
- Commands run:
  - Simulator build: BUILD SUCCEEDED. `recallTests` (JumpGate): 4 tests, 0 failures.
  - `scripts/check-contract.sh`: PASS.
  - Device build first failed: "Provisioning profile ... doesn't include signing certificate".
    Fixed by one `xcodebuild ... -derivedDataPath build -allowProvisioningUpdates build`, then
    `~/.claude/apple-dev/bin/ios-build.sh device` installed and launched.
- Baseline (before, 2026-09-10 15:23 -> 09-11 15:23 JST, audio OFF the whole window):
  - HealthKit query cycles 240/h; health POST ~118/h (51 unique payloads / 24h);
    location sends ~179/h; total log lines ~6,300/h; upload `Queue health` ~12/h.
- First 8 min after deploy (08:28Z-08:36Z):
  - Health: 1 query cycle after launch -> "Unchanged since last POST — not sent".
  - Location: 3 `Sent` lines (08:31:26 x2 same second, 08:34:33), all from the 20 m
    distance rule on indoor jitter (accuracy 20-30 m), none from the heartbeat.
- Open issues / risks:
  - AUDIO WAS ON during the post-deploy window: engine started 2026-09-11 07:01:40Z
    (16:01 JST) before the deploy and kept recording; the deploy's foreground launch also
    auto-starts (userStopIntent reset on `.active`). How it came back on without a toggle tap
    is unknown (hypothesis: the foreground reset in `RecallApp.swift:44-52`). The 24h
    comparison is confounded unless audio is off — compare non-audio categories only.
  - FIXED in 87907b4 (Phase 2): the delegate and `liveUpdates` both delivered the same fix ->
    identical `Sent` twice in one second. `liveUpdates` removed; standard updates via the
    delegate are the single continuous path (FG and BG), `pausesLocationUpdatesAutomatically
    = false` set next to `startUpdatingLocation()`. Both paths dated from the initial
    scaffold (5d891f4) with no incident behind either.
  - Still to observe after 87907b4: BG delivery via the delegate path alone (`BG direct
    sent` / `BG heartbeat` lines once the phone is locked) and region enter/exit.
  - Indoor jitter >= 20 m counts as movement -> ~26 sends/h indoors instead of <= 12/h.
  - Launch race: `queryAndSendFull` and the first observer-driven query both POST the same
    snapshot at launch (launch-only, harmless).
  - LocationQueue debounce (a116ef1) is also branch-only, not on main.
- Next steps:
  1. Pull the on-device log >= 24h after 2026-09-11 08:28Z and count per hour, excluding
     [STATE]/[VAD]/[CHUNK] if audio was on:
     `xcrun devicectl device copy from --device <kana> --domain-type appDataContainer
     --domain-identifier com.example.recall --source Documents/logs/activity_<date>.log
     --destination <dir>`; then `grep -c` for `Queried `, `Telemetry POST (bg): health2`,
     `[HEALTH] Sent:`, `Unchanged since last POST`, `[LOC] Sent:` / `BG direct sent` /
     `BG heartbeat`, and total lines.
  2. Duplicate location delivery: owner ruled 2026-09-11 to fix it inside Phase 2 (location
     delivery-path consolidation), not as a standalone patch.
  3. Confirm with oc-general that location/health/channel_status receipt continues.
- Measured 2026-09-13 with `scripts/log-rates.py` over two full JST days of the on-device
  log (before = 09-10, the last complete pre-deploy day, audio OFF; after = 09-12, the first
  complete post-deploy day, audio ON). Per hour:

  | | before | after | target |
  |---|---|---|---|
  | total log lines | 6707 | 549 | <= 600 |
  | HealthKit query cycles | 240.9 | 11.7 | <= 10 |
  | health POST (bg) | 134.5 | 4.4 (+6.6 suppressed as unchanged) | <= 5 |
  | location sends, stationary hours | ~190 | 6 | <= 12 |
  | location sends, whole day | 190.6 | 32.2 | n/a (09-12 included a trip) |
  | upload queue health | 11.9 | 9.2 | n/a |

  Every target is met except HK cycles, which miss by 1.7/h on a day full of walking —
  the observer fires on new step data, which is the intended behaviour.
- Two things the measurement turned up, neither of them the cadence work misfiring:
  - **The stationary heartbeat lands every 600 s, not the intended 300 s** (20:48:44,
    20:58:44, 21:08:44 UTC, identical coordinates). In the parked tier iOS only wakes the
    app when a fix arrives, and the 60 s `Timer` is serviced on that wake, so the fix rate
    is the real floor. It is under the 12/h target, but it sits exactly on oc-general's
    10 min gap threshold — tell them, or shorten the parked distance filter.
  - **The app was terminated for 5h04m on 09-12** (last line 09-11T21:08:44Z, silent
    relaunch 09-12T02:13:05Z = 06:08 -> 11:13 JST). No error, no engine line: audio was not
    running, so only the location stream was holding the process up. FACT: the outage
    happened and no greeting could have fired in it. HYPOTHESIS (one day each, not proven):
    a quieter app is a better jetsam candidate. The old build's day shows no gap at all.
- Completion criteria remaining: 24h numbers vs targets (HK cycles <= 10/h, health POST
  <= 5/h, stationary location <= 12/h, log lines <= 600/h); owner battery comparison.
- Links: `docs/pipeline.md` §8, `docs/stream-independence.md`.

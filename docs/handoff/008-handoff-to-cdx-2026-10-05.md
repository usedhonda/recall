# Handoff: recall.cc -> recall.cdx (2026-10-05)

- Goal / why: location stream exists for Chi's greetings; audio feeds Chi's memory of the day.
  Battery work only matters within that (owner, binding). Details: handoffs 001-007.
- Status: everything below is pushed (main at the commit after `18a15e5`) and on the device
  except where marked. No code is in flight. Working tree: only untracked `.loop/`.

## Done since handoff 007 (all on main, device-reflected)

- Audio delivery was broken by a SwiftData predicate that force-unwraps an optional date
  (throws `unsupportedPredicate`, hidden by `try?`): pending audio, glasses media and the
  stalled-upload reset. Fixed by filtering in memory (`078634e`, glasses/stalled `d2e2632`).
  Failures to deliver a Hub original are now logged with their cause (`c733a2e`).
- Retained chunks failed to open after a reinstall (absolute path, container UUID moved):
  `repairMovedChunkPaths` at queue start (`d42eaa4`).
- A refused audio session (`!pri` 561017449) is now "wait", not "rebuild the engine": state
  signal `blocked:insufficientPriority` (`57e5415`). Not yet seen live.
- Derived capture interval for ordinary audio originals (`18a15e5`): `metadata.capture`,
  status known / basis derived, `precision_ms` 300 is an UNMEASURED estimate. Merged chunks
  and old rows carry none. Nothing recorded since the build was installed, so not yet seen
  arriving at the Hub.
- First natural audio reached the Hub and a consumer (40/40 stored with STT intent). Hub token
  was reissued and re-imported with no restart and no 401. All 8 routes live; legacy stops: none.
- Departure witnesses: owner chose "two witnesses on the server" (Wi-Fi drop + a fix beyond
  the exit radius). Receiver (chi.cc) implemented it, not yet in production. App side: nothing.
- The repository is PUBLIC. Personal values were removed from files and rewritten out of history
  (force push, protection toggled and restored). Originals live only in `.local/private-values.md`.

## Waiting on events (nothing for you to start)

1. First natural recording on the new build: confirm a `capture`-bearing original reaches the
   Hub; count `Capture: derived` vs `Capture: merged chunk` lines in the device log; measure
   `|elapsed - written|` from the `Capture: derived` lines, then set `precision_ms` and bump
   `AudioCaptureEvidence.methodVersion`. Report time + counts to data-hub.cc.
2. The first real `!pri` interruption: expect `blocked:insufficientPriority`, no hard reset.
3. Glasses media, geofence, now-playing natural receipts.
4. Brooklyn: when the owner is there for a week, extract "Wi-Fi left -> first fix beyond N m"
   from the device logs (7-day retention; ask before it expires) and send it to chi.cc.
   Method: last position before the drop as reference; counts and seconds only, no coordinates.
5. Per-route legacy stop: only after each consumer owner's GO. Never on your own.
6. Owner decision pending (Hub asks them): whether audio needs a sensitivity marker. The app has
   no such mechanism today.

## Traps found today (also in AGENTS.md section 7)

- Never force-unwrap an optional inside `#Predicate`; never swallow a fetch error silently.
- The device log is local: when it stops, the app stopped. Check the `Process start: log had
  been silent for N min` line on the next launch before concluding anything. I once read a
  stale pull and blamed "quiet surroundings"; the app had been terminated.
- The owner stops recording by hand for battery. `stopped:user` is information, never an alarm.
- Auto mode refuses: reading `.local/hub-provision`-style files with tokens, staging private
  config to the device, writing helper scripts into `~`, and some `devicectl launch` calls.
  Do not route around a denial; ask the owner to run it (`! cmd`, short lines with `\`).
- `devicectl install` is allowed; `launch` needs the phone unlocked. Deploy flow: contract
  check, commit, push, `scripts/safe-xcodebuild.py` device build, install, launch `--no-activate`.
- Pulling device files: `xcrun devicectl device copy from --device <id> --domain-type
  appDataContainer --domain-identifier com.example.recall --source ...` with explicit
  arguments (a shell variable holding the flags does not split in zsh). Outbox DB:
  `Library/Application Support/recall/hub-outbox.sqlite`.
- Do not read or print token-bearing files; counts and receipts only. Delete pulled logs after.
- Do not rewrite history again without an explicit owner order.

## Formal task

`bb6adddc-d324-437b-8cf3-f9555d870587` (Hub admission, R1) is at epoch 1 with recall.cc as
executor. A re-handoff to recall.cdx needs the owner (data-hub.cdx) to `prepare`, then me to
`release`, then you to `accept`. I have asked for it.

# Handoff: location-queue-refusals

- Goal / why: Location fixes were refused by the on-device location queue ("location queue
  admission rejected"). The owner asked to find the reason and fix it.
- Scope: `recall/Core/Location/LocationQueue.swift`.
- Explicitly out: accuracy filter (fixed BG 200 m / FG 100 m), any visible UI, the recording lane.
- Status: review (fix pushed and deployed; on-device proof pending).
- Done so far:
  - Cause: the actor gate `mutationInProgress` refused any mutator while another mutator was
    suspended across `await reserve(...)` (actor reentrancy). Queue drains overlapping with new
    fixes produced the refusals. No hub_gaps after 11/01, so `reserve` itself was not throwing.
  - Before the fix (one day's log): 35 refused vs 3 queued; 34 of the 35 refused fixes were
    delivered by direct send right after. One (a 12 m fix around 07:02:15Z, 11/02) is unconfirmed.
  - Fix 616758e: `enqueue`, `reconcileHubReservation`, `remove`, `markLegacyDelivered` now
    `await acquireMutation()` / `defer releaseMutation()` (FIFO waiter list) instead of
    refusing. Storage-health refusals are unchanged.
  - Pushed to origin/main (owner said "push"). Installed on the phone 10:39:30Z 11/02 with
    `--no-activate` + `RECALL_PRESERVE_OFF=1`; audio stayed `stopped:user`; Hub receipts on all
    lanes, send queue pending=0.
- Files changed: `recall/Core/Location/LocationQueue.swift` — writes wait their turn.
- Decisions: wait instead of refuse; no new unit test (no existing LocationQueue test harness).
- Rejected options: dropping refused fixes silently; widening the gate to skip reservation.
- Commands run: device build OK (`ios-build.sh device`); `scripts/check-contract.sh` PASS.
  No simulator build or unit test run for this change.
- Open issues / risks:
  - Not yet proven on device that refusals stopped (needs movement / queue activity).
  - Carried over: recording stopped in a cannotInterruptOthers state; owner decision on fixes
    rejected by the accuracy filter; plain-open verification of 3a25bf5 awaits the owner opening
    the app.
- Next steps:
  1. Pull the on-device log (UDID of the current phone is in the device list; the old one is gone)
     and count "location queue admission rejected" vs "queued (fallback)" since 10:39:30Z 11/02.
     Expect zero rejections not caused by storage health.
  2. Report to the owner in Japanese.
- Completion criteria remaining: on-device log shows no gate refusals after the deploy.
- Links: docs/stream-independence.md (binding), AGENTS.md §4 (deploy rules).

# Upload outcomes and Hub reconciliation

## Intent and boundaries

Correct non-upload outcomes that were counted as uploaded, and reconcile the current
capture-to-Hub path. Keep retention, queue limits, capture filters, UI layout, stream
independence, server configuration and producer routing unchanged. Server work is read-only.

## Implemented

`AudioChunk` now has terminal `discarded` plus optional raw reason: short, noise, empty,
expired or retry_exhausted. All five non-upload paths use it with no `uploadedAt`.
Only successful upload responses set uploaded. Counts exclude discarded; capacity
cleanup includes both terminal states, preserving existing deletion eligibility/timing.
Old uploaded rows are not reclassified. This means historical totals are not repaired.

## Reconciliation: UTC 2026-10-01 13:48:29 through 2026-10-02 13:48:29

On-device files cover the full window, with at most 11 seconds between log lines.
A continuous log is not a guarantee of continuous capture. There were 486 chunk starts,
440 finalizations and 440 successful upload responses (440 distinct filenames/IDs).
Every finalized filename matched an acknowledged upload. Five upload failure attempts
were logged; no explicit short/noise/empty/expiry/retry-exhaustion drops were logged.
Chunk starts that do not finalize are not uploaded files and are not counted as such.

| Acknowledged recording IDs | Count | Evidence |
|---|---:|---|
| Stored with existing primary original | 350 | VoiceLog row + file, matching Hub original |
| Merged into a stored primary | 39 | Worker merge IDs joined to stored primary |
| Expired | 51 | Jobs state + admission trimming; original/inbox file absent |
| Unclassified acknowledged IDs | 0 | All 440 IDs joined |

The API has 442 admissions: two extra IDs share filenames with acknowledged uploads
and both are stored (consistent with retries after an unknown response). One is an
alternate stored copy of an expired acknowledged ID. Thus **50 of 440 finalized source
filenames have expired admissions without a stored/merged alternative**, not 51.
This does not prove what speech was in those files. The 39 merged inputs have no
separate remaining original; transcript inclusion is evidenced by the successful merge,
but exact secondary source-byte retention is not promised by the primary original.
All 350 direct stored originals were found in Hub; all 341 nonempty direct stored
transcripts also had Hub transcript events. Empty transcription is not assumed lost.

Rotated api.err.1 plus current api.err cover the window; worker.err provides merge
provenance. Current-log-only monitoring had previously reported 49 drops in a partial
window. ID reconciliation corrects those 49 to **22 merged + 27 expired**. In the full
window, the 90 inbox eviction events split into 39 merged + 51 expired; the same 51
expired IDs also appear in queue-trimming logs. Never add those counts together.
The current server drop monitor therefore must not be used as a source-file loss metric.
Changing that other project's monitor is deferred, not silently performed here.

## Current runtime observations

- Server checkout: a76c03b, including pre-STT VAD gate. Configuration loader selects
  faster-whisper, no shadow engine, VAD gate ratio 0.05, max_queued 3, queue age 300 s,
  merge window 5 s, original retention enabled. Contemporary worker logs confirm
  faster-whisper execution; on-disk settings alone are not process-memory evidence.
- GPS measured 13:46:26Z and received 13:46:26.741Z; Health received 13:37:58.916Z.
  Values themselves are deliberately omitted from this report.
- Device reported blocked:cannotInterruptOthers at 01:15:20Z and again at 02:15:23Z;
  listening since 03:17:55Z reached server at 03:35:27.242Z. The stream was not simply
  silent: capture was blocked for about 2h03m. Receiver state matches the last report.
- channel-status last_chunk_at still predates this day's captured audio because steady
  capturing does not resend status. It is not a continuously refreshed last-chunk monitor.
- Hub route is still a mirror, not a Recall writer cutover. Gateway snapshots do not
  constitute a complete raw telemetry ledger. Notification delivery was not exercised.

## Verification and deployment

Focused simulator tests passed 4/4, including actual production transitions,
count exclusion and a nil-reason legacy-shaped row. Simulator and device builds succeeded.
Installed and launched on the physical device at 2026-10-02T13:57:30Z. The existing
SwiftData app-group store migrated with the new optional column and retained 81,462
historical uploaded rows with nil reason. The launch log reads those rows and starts
capture successfully. Historical uploaded counts intentionally remain uncorrected.

The shared device wrapper built successfully but parsed `(UDID)` as the device identifier
from the new devicectl table. Installation was completed directly by device name using
the already-built app; no repeat build or shared-tool edit was needed. At the last device-log sample (13:59:41Z), capture was listening but no new chunk
had finalized. Post-deploy natural upload therefore remains unverified; no artificial
capture or destructive expiry test was performed on the device. This is the only open
runtime acceptance item for the accounting change, not proof of an upload failure.

## Revisit only after this task

1. Preserve original input independently of real-time queue admission and merged jobs.
2. Correct server monitoring's merged/expired classification and retry deduplication.
3. Define offline retention and truthful committed ACK semantics before changing limits.
4. Revisit transient event outboxes, location greetings, capture interruption recovery,
   VAD quality and battery only with the new evidence. No such changes were made here.

Private ID joins, device logs and body-free server metadata are retained locally under
ignored audit storage; they are not committed. See docs/pipeline.md for current routing.

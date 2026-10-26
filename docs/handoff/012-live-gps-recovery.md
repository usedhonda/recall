# Live GPS After Network Recovery

The owner reported that selecting/deselecting VPN configurations in iOS settings
restored the connection. The decisive setting transition is not known; do not
attribute the repair to a specific profile, rule, or application change.

Natural Hub requests then returned HTTP 201 and verified storage receipts across
GPS, Health, status, and audio. The connection warning cleared and its one-outage
claim re-armed. The first 28 GPS receipts matched Hub storage and scoped reads
exactly, but all carried the previous day's source clock: this proves transport
and storage, not fresh location. Audio remained intentionally stopped by the owner
and must not be restarted as part of network recovery.

The phone's FIFO GPS outbox still had approximately 2,500 pending observations,
with current location behind old data. The recent request median was 2.268 seconds.
Thus restored connectivity alone did not restore timely live location.

The repair alternates newest-source-time GPS leasing with historical FIFO. GPS
selection uses the immutable envelope's `occurred_at`, not insertion time. Active
leases remain excluded; all bytes and receipt bindings remain unchanged. History
is retained and makes progress on alternate selections; audio and Health ordering
are untouched. The Hub receiver's current-location projection already selects by
occurrence time rather than ingestion order, so later historical delivery cannot
replace a newer fix. No test POST, manual replay, synthetic fix, or budget increase.

Verification uses the actual outbox source in a small native SQLite harness and
then natural requests on Kana. The known Simulator launch failure is not retried.
Device reflection must preserve the stored audio-OFF intent with the existing
`RECALL_PRESERVE_OFF=1` launch path, and fresh-receipt acceptance remains separate
from backlog receipts or a successful build.

The native source harness passes source-time rather than insertion-time priority,
alternate historical progress, active lease exclusion, unchanged pending bytes,
exact retry bytes after restart/expiry, and unchanged audio/Health FIFO. The signed
device build and Simulator compile-only `build-for-testing` pass; no Simulator was
booted or test session retried. The matching XCTest regression is compiled, not
reported as executed. Live reflection and a natural fresh receipt are the next
acceptance layer.

## Device And Fresh-Event Acceptance

Candidate `fce3652` was installed once from 15:41:14.389139Z and immediately
launched without activation by 15:41:19.222560Z. The 4.833-second operation is
not described as lossless capture. Preflight confirmed an unlocked device, no
open chunk, and persisted audio OFF; launch used `RECALL_PRESERVE_OFF=1`.
Post-launch preferences remained isRecording=false / userStopIntent=true, with
no engine start. A new channel-status record explicitly reported stopped:user.

The natural GPS worker verified 133 receipts by 15:42:57Z without a lease error.
A representative new measurement has source clock 15:41:20.047Z, Hub committed
receipt time 15:41:24.347352Z, and phone ACK time 15:41:24.446092Z: approximately
4.300 seconds to durable storage and 4.399 seconds to client verification.
Its event/external identity and sequence match Hub storage, and one regular
scoped get_event read verified the same identity, source clock, content hash,
and payload timestamp. The later verification age is not delivery latency.

This establishes fresh measurement -> natural delivery -> committed Hub storage
-> scoped read without a synthetic fix, test POST, or manual replay. Historical
observations remain queued/draining rather than discarded. No additional test,
build, installation, or repeated snapshot is needed for this acceptance.

Actual Chi consumer selection of that same event is a separate remaining check.
The Hub owner is checking existing consumer provenance read-only. A stale Chi
messaging endpoint is not a failed data receipt or revoked owner approval, and
must not be bypassed with another identity or duplicate task submission.

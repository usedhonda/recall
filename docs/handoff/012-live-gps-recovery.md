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

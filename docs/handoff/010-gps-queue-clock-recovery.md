# GPS queue clock recovery

## Goal And Scope

Restore natural GPS delivery without changing accuracy, route cutover, credentials,
retention budgets, or active recordings. Preserve both the Hub receipt contract
and the existing legacy acknowledgement requirement.

## Confirmed Cause

The millisecond ISO 8601 source queue rounded timestamps across second boundaries.
The archived telemetry payload had truncated the same original clock to whole
seconds. After queue reload, an already acknowledged observation reconstructed a
different payload and failed the immutable fingerprint check. The first conflict
aborted the entire batch, including exact neighbours and newer observations.

A read-only device snapshot contained 50 acknowledged observations at the head of
the GPS source queue: 28 exact reconstructions and 22 matching only the previous
second in `source_payload.timestamp`. The entire original fingerprint matched in
all recovered cases; identity, envelope time and other bytes were unchanged.
Only 15 also had durable legacy delivery confirmation.

## Repair

- Persist Date's original reference clock as an additive binary64 field, marked
  `timePrecision=reference`; preserve the timestamp string for older queue readers.
  Avoid Unix-epoch conversion, which can itself round across a second boundary.
- For an acknowledged legacy `ms` GPS row at a whole-second boundary only, try
  the prior-second payload timestamp and require the complete stored fingerprint.
  Do not run this compatibility search for new clocks or pending observations.
- Release individually dual-acknowledged source rows without waiting for neighbours.
  Keep Hub receipt/identity tombstones and all unacknowledged source rows.

## Verification And Remaining Work

The focused boundary regression passes on Simulator, including changed payload,
changed identity, non-boundary time, and lossless new-clock checks. Reconstruction
of the private device snapshot recovers all 50 acknowledged head observations.
Releasing the 15 dual-acknowledged source rows
recovers about 9 KB of reserved space without deleting Hub history or increasing
the budget. This is not proof of sustained capacity or restored network delivery.

The incident also has transport failures across multiple independent Hub lanes.
The installed Hub destination is in Keychain and is not established by legacy
preferences or source defaults. No credential export or new network probe is used.
Device reflection and a new natural GPS receipt followed by consumer acceptance
remain required. Protect an open recording during deployment and keep one device
operation owner. Long-term receipt-ledger capacity remains a separate decision.

The final reference-clock candidate passes the focused Simulator regression and
the device build. After the initial locked-device hold, the existing artifact was
installed and immediately launched without activation. The install-to-launch
operation lasted about 4.34 seconds; this is not claimed to be gap-free recording.
The pre-install state was Listening with finalized chunks, and the new process
returned to Listening. The source queue decreased from 4,527 to 4,512 rows,
confirming retirement of the 15 dual-acknowledged observations.

Natural current-GPS delivery is still unconfirmed. A post-install read showed no
new GPS receipt, while the Hub owner independently observed the phone's existing
tailnet peer offline. The remaining transport investigation is separate from the
verified queue recovery. Do not reinstall unchanged code or replay/delete pending data.

## Automatic Capacity Recovery

The owner subsequently requested correction of the iPhone software faults, including
the capacity dead end rather than holding code work behind device UI authentication.
This extends the earlier no-retention-change scope for safely retired local GPS
receipt records only; budgets, unacknowledged data, and route cutover remain unchanged.

The GPS lane previously retained acknowledged identity/receipt records forever,
in the same byte budget needed for new observations and legacy request files.
It now reclaims acknowledged GPS records with no source-queue, delivery-marker,
or pending legacy-batch owner at 70% usage, oldest first toward 50%. Candidate
selection precedes ownership snapshots so a concurrent later ACK stays protected.
Active foreground GPS calls claim their receipt inside the outbox actor and release
the claim on return. Claims begun after candidate selection are checked inside the
deletion transaction. Unknown identities and unreadable ownership are not eligible
for collection.
Recovery runs locally before positive reservations and before the worker's network
gate, at most once per 30 seconds. Other lanes and pending GPS bodies are untouched.

Dual-acknowledged source retirement also moves before the network gate and new
admissions; a failed neighbour no longer blocks that bookkeeping. Health batch
reconciliation remains independent of the existence of GPS samples.

The focused outbox and telemetry-ledger tests pass (27 tests). The new regression
reproduces a full lane refusing a 21,650-byte legacy reservation, recycles only
retired snapshot receipts, then admits that reservation while preserving a live
source receipt, pending body/lease, later ACK, unknown identity, and the audio lane.
At that test-only checkpoint, installation and natural receipt confirmation were
pending; the earlier 15-row runtime recovery belongs to the previous candidate.
Live capacity acceptance is recorded below.
The final claim/transport checkpoint passes its two affected regressions and the
signed device build; the unchanged 27-test batch was not repeated. The claim
regression covers candidate selection, a later claim, protected collection, and
collection after claim release when no other owner exists.

An isolated copy of the earlier device database recovers capacity from 33,544,572
to 16,777,163 charged bytes by reclaiming 28,372 retired GPS receipt records.
All 746 pending observations, their bodies, and existing reservations remain
unchanged; a 21,650-byte legacy request reservation then succeeds. This is a
copy-only proof, not live-device reclamation or network delivery evidence.

The post-VPN-operation snapshot independently confirms two new reference-clock
source rows and ongoing recording, but no new Hub ACK. The previous transport
collapsed URL loading errors into a generic unavailable error. The repair retains
only the fixed URL error code and lease/transport/receipt phase, never the URL,
description, userInfo, credential, or response body. This diagnostic correction is
independent of capacity recovery and does not claim the network route is restored.

## Live Capacity Acceptance

Commit `6f47e98` was installed once in a fresh unlocked, Listening window with all
opened chunks finalized. Installation and immediate non-activating launch spanned
11:58:43.157840Z to 11:58:45.349856Z (2.192 seconds, not a gap-free claim).
The process recorded automatic reclamation of 28,384 retired GPS receipts at
11:58:49Z and returned to Listening, still observed at 12:00:48Z.

Compared with the pre-install snapshot, charged GPS bytes fell from 33,550,565 to
16,910,671 while new work was admitted; free capacity rose from 3,867 to
16,643,761 bytes. The ACK ledger count fell by exactly the logged reclamation
count. All prior 1,170 unacknowledged rows across lanes retained identical
bodies, hashes, and original lengths. All prior 4,514 source rows remained,
with three new rows added; GPS Hub pending grew from 747 to 767. Reservation
keys remained; non-source reservations were unchanged and source reservation
growth reflected new samples. No post-install capacity rejection was observed
in that snapshot. This establishes live capacity recovery without pending loss.

Natural Hub delivery is separate: GPS at 12:00:29Z and other lanes at 12:00:31Z
reported transport `NSURLErrorDomain -1001` (timeout), with no verified receipt.
The observed VPN-on action is not negated and a timeout alone does not identify
VPN, DNS, TLS, endpoint, or server as its cause. Follow-on user-visible connection
diagnostics and once-per-outage alerts are tracked in `011-hub-connection-alert.md`.

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
the device build. Installation has not been performed: the immediate pre-install
device check required a passcode, so launchability was not established. The old
process remains running, with no deployment-induced gap. Continue from the existing
built artifact after a physical unlock and a fresh Listening/finalization check;
do not repeat unchanged builds or replace the app while it cannot be launched.

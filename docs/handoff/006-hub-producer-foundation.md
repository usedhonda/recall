# Hub producer foundation — not activated

## Implemented

- `HubProducerContract`: canonical route IDs, immutable JSON envelope preserving
  source-payload numeric literals, full JSON byte limit, original hash/length,
  strict receipt types and source/event binding checks.
- `HubDurableOutbox`: SQLite FULL-synchronous storage with atomic admission,
  recoverable leases, and receipt/body-release transitions. Same content retries
  are idempotent; changed bodies conflict even after ACK. Expectations are read
  from the stored row. Independent, explicitly supplied lane budgets reserve
  bounded future receipt slots, without expiry or silent pending deletion.
- `HubIngressTransport`: store-only HTTPS transport with explicit configuration,
  no redirects or Gateway credential fallback, and strict 200/201 receipt checks.

## Deliberately not activated

No runtime producer calls this foundation yet. Existing capture, expiry, upload,
Gateway/VoiceLog dispatch, UI, and delivery remain unchanged. Do not describe this
commit as full coverage, protected production outboxes, or a completed cutover.
The old code paths still have the migration gaps recorded in handoff 005.

## Next integration inputs

1. Explicit independent metadata/glasses/control capacity and reserve values.
   The audio-only setting must not be reused as a global budget.
2. Private source-specific Hub endpoint/token device provisioning. Existing QR
   configuration targets Gateway, not independent Hub authentication.
   Recall owns this missing workflow; the Hub has no device installer. Operator
   connection preflight does not provision the device. Copy only the approved
   source credential through private setup, never the complete Hub policy.
3. Per-route finalized immutable payload capture and durable admission before
   legacy overwrite/expiry. Audio also needs original-file reservations and a
   processing-owner commit-to-dispatch contract.
   Audio release is a pending user choice: A = durable storage receipt plus
   downstream durable inbox recovery; B = storage plus separate adapter admission
   ACK before release. The Hub's `audio-dispatch-boundary.md` is the current
   decision record; the old adapter ledger is candidate B, not direct ingress.
   Neither handoff is accepted. The VoiceLog integration owner has since
   acknowledged API/queue/worker/dispatch-ledger responsibility. See
   [audio-source-provenance.md](../audio-source-provenance.md) for the current
   field partition proposal and capture-clock limits; neither was implemented
   by the generic foundation commit.
4. Startup/normal-operation reconciliation with receipt persistence before
   deletion, accounting for physical writes and gap-report failures.
5. Natural event receipt -> scoped MCP read -> consumer evidence, then explicit
   consumer-owner synchronization before disabling old delivery.

No new permission for the existing implementation scope is required. The missing
numeric policies and audio release alternative are choices, not a mechanical
task-carry approval requirement. The Hub owner reports already presenting A/B;
do not duplicate that user question. No existing audio deletion behavior changes.
No infinite queue or automatic tombstone-pruning policy was invented. Logical
pending JSON byte accounting does not measure total SQLite or capture disk use.

## Verification

Simulator build and 16 focused contract/outbox/transport cases have passing
evidence. One fixture needed correction and only that case was rerun. Contract
and Intent Drift checks passed. This is local implementation evidence, not
device deployment or actual producer-to-consumer acceptance.

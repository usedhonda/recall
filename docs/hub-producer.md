# Hub producer adoption

This document describes the producer foundation, not a completed migration.
Existing runtime upload and telemetry paths remain unchanged until each route
has a configured budget, private provisioning, and consumer acceptance.

## Storage contract

The Hub-owned `recall-producer-v1` profile is the wire authority. New observations
use source `recall` and external ID
`v1:<route>:<base64url(device_id)>:<base64url(observation_id)>`, without padding,
case folding, or Unicode normalization. The complete ID is limited to 512 ASCII
characters. An observation's original bytes, source payload, and full encoded
envelope are fixed before its first attempt and reused unchanged on retries.
Fix identity and GPS delivery identity are different. Health snapshots do not
imply collection of all raw HealthKit samples. Reaction settings are commands,
not archival observation fields.

The complete UTF-8 JSON request, including base64 originals, must fit 20,971,520
bytes. Oversize, conflict, timeout, or any failed receipt check does not authorize
deletion. Chunked upload is not implemented in this client foundation.

Only HTTP 201/200 with a matching storage receipt establishes Hub storage.
Validate version, source, external ID, original hash and byte length, canonical
event UUID, and positive ingest sequence. Bind the first event ID durably and
require the same binding on later receipts. A metadata-only receipt cannot
acknowledge an original. Storage is not ASR completion or notification delivery.

`HubIngressTransport` accepts an explicitly provisioned HTTPS endpoint and
source credential. It does not borrow Gateway credentials, follow redirects,
dispatch work, or log bodies. Transport errors leave recovery to the durable
outbox. Endpoint configuration alone does not prove tailnet-only deployment.

`HubDurableOutbox` stores immutable envelopes in SQLite with `synchronous=FULL`.
Admission checks and insert, lease selection and update, and receipt validation
and body release each execute in a transaction. Expired leases recover the same
bytes after restart. Same-ID/body admission is idempotent; a content change
conflicts even after ACK, using a retained body fingerprint. ACK expectations
and previous event bindings come from the durable row, never caller overrides.
The queue reserves a bounded receipt slot when accepting each pending item.
Receipt tombstones are not automatically pruned; reaching their explicit limit
rejects new admissions without preventing ACK of already accepted items.

## Capacity and activation boundaries

Preserve the existing `storageCapMB` setting's audio-only meaning. It is not a
shared metadata, glasses, or control budget. Its existing enforcement helper
has no runtime caller; a configured setting is not proof of enforced admission.
Count original bytes once, including existing retained audio and in-progress
reservations. Do not delete unACKed originals to create capacity.

Metadata lanes, glasses, and control records need explicit independent limits
before activation. No zero or unlimited default is implied. Full audio must
not stop GPS, Health, or status. A failed physical write must propagate failure;
if a gap cannot be persisted, do not claim a durable gap record or successful
admission. Logical queue accounting does not measure filesystem overhead,
SQLite journals, temporary files, or original capture reservations.

## Remaining integration

- Freeze and persist each route's actual source payload before first delivery.
- Wire independent admission, capture backpressure, and recoverable gap reporting
  using approved budgets; protect originals from legacy expiry/removal paths.
- Provision a distinct Hub endpoint and Recall source token through a private
  device configuration path. The existing Gateway QR/token is not this path.
- Start the outbox reconciler at app startup and during normal operation; keep
  leased items until matching receipts are persisted.
- Audio needs an owner-provided durable commit-to-dispatch bridge, stable legacy
  recording ID, and deduplicated processing jobs. Do not replay expired reactions.
- Prove each route using actual producer ID -> Hub receipt -> scoped MCP read ->
  required consumer correlation, without publishing personal payload values.
- Stop old delivery only after the consumer owner's synchronized per-route GO.
  While parallel, Hub ingestion is store-only; legacy delivery owns reactions.

No runtime route is accepted by compilation or unit tests alone. No retention,
collection consent, visible UI, or existing delivery policy is changed here.

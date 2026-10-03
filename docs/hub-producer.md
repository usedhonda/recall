# Hub producer adoption

This document describes the producer foundation and opt-in runtime integration,
not a completed migration. No device provisioning or natural route acceptance
is established by this document. Legacy delivery remains enabled until each
route has consumer acceptance and an explicit cutover configuration.

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

### Request bytes versus Hub read representation

The producer wrapper uses Foundation `JSONSerialization` with sorted keys, while
`source_payload` is inserted from its validated original UTF-8 object bytes.
This preserves that input's numeric literals locally; it does not define a
cross-language canonical JSON format. The complete encoded request is stored as
a SQLite BLOB, returned unchanged by leasing, and assigned directly to HTTP
body on retry. Rebuilding the envelope on retry is not the supported path.
The opt-in audio adapter freezes persisted chunk fields and explicit unknown
capture evidence. It excludes mutable reaction/language commands and current
location/timezone from archival audio observations. Legacy multipart numeric
fields remain strings; the archive does not silently convert their types.

Three hashes have different meanings: the outbox body fingerprint covers complete
POST bytes, the original SHA-256 covers blob bytes, and the Hub content hash is
Hub-owned canonical event identity/content checking. They are not interchangeable.

Code inspection at Hub `d28455e` found HTTP JSON parsing (`hub/http.py:141`),
canonical parsed-metadata serialization (`hub/store.py:128-130`), and metadata
parsing/reserialization on read (`hub/store.py:301`, `hub/__main__.py:153,177`).
Consequently, MCP read does not promise the producer's original JSON bytes or
number spelling. Saving an inbox's received representation is not proof of
original-request byte equality. Downstream comparisons must use the Hub-owned
read/content contract, not a guessed reconstruction of producer bytes or a
separately implemented Hub canonicalizer.

The resolved authority is the Hub's `docs/contracts/event-content.md` (owner
release `c290e23`). `get_event` exposes stored `content_sha256` with
`content_hash_scheme="hub-event-v1"` on both complete and paginated metadata.
An inbox binds `(source, external_id)` to event ID, scheme, content fingerprint,
and blob hash; subsequent differences conflict. Require matching event identity
and fingerprint on every page and complete metadata reassembly before admission.
Missing or unsupported schemes are unmet admission, not a local hash-generation
fallback. List summaries and storage receipt v1 are unchanged; producer receipt
validation therefore needs no change. These values add no blob permissions,
signature guarantee, or evidence of processing completion.

For binary64 consumers the portable integer range is `[-(2^53-1), 2^53-1]`.
Floats have binary64 precision, not arbitrary-precision decimal fidelity:
`0.10000000000000001` can collapse to `0.1`, while integer `1` and float `1.0`
can have different Hub fingerprints. New nonfinite writes are rejected; that
does not certify or rewrite historical rows. A route requiring exact decimals,
larger integers, or original UTF-8 needs an explicit owner-agreed representation
before admission, with no automatic string conversion or raw-JSON reconstruction.
Original byte length comes from a validated receipt or authorized original bytes,
never from interpreting the event-content fingerprint.

## Capacity and activation boundaries

Approved independent limits are GPS 32 MiB, Health aggregate snapshots 64 MiB,
status 32 MiB, glasses 512 MiB and control 16 MiB. Audio retains the existing
`storageCapMB` setting. Outbox bodies use their actual encoded byte length;
each retained identity reserves 4096 bytes for receipt/fingerprint bookkeeping.
Tombstones are not silently pruned. Full lanes reject new admissions and retain
previous unACKed items. These logical limits are not measurements of SQLite
page/journal overhead or a guarantee against physical disk exhaustion.

The audio writer start guard and exclusive writer token do not prove a maximum
encoded-chunk reservation. That capture staging boundary remains unaccepted;
do not activate audio based on the guard alone. Pending buffers are preserved
when capacity prevents finalization. Glasses import reserves source bytes plus
base64 expansion and metadata headroom before copying. Final outbox admission
still checks the actual serialized envelope size, not an estimated raw limit.

Gap counters are bounded local control records. Failed admission or physical
writes do not produce a receipt. If recording the gap also fails, logs explicitly
say that the gap was not persisted. No lane borrows another lane's capacity.

## Runtime and provisioning

`HubProvisioning` imports a private device-bound configuration into a dedicated
Keychain item before producer startup. The configuration contains only Recall's
source token, independent HTTPS endpoint, device identity, enabled routes and
per-route legacy-disable latches. It never copies the Hub's full source policy
or borrows Gateway authentication. A missing/unreadable credential does not
clear previously activated route latches or restore disabled legacy delivery.

`scripts/provision-hub.py --config <private-file> --device <device>` stages the
mode-600 configuration without printing its contents. The app removes the import
file only after exact Keychain read-back. Staging alone is not proof of import,
authenticated transport, or route acceptance. Source-specific provisioning by
the operator remains required; endpoint/token values never belong in this repo.

The Hub source-only exporter schema is `{schema_version, source, base_url,
bearer_token, allowed_domains}`. Convert it explicitly to the device schema;
never treat domain allowance as permission to activate every route or stop legacy
delivery. Offline conversion uses `--source-export <private-export> --device-id
<bound-id> --enable-route <route> --output <new-private-file>`. No route is enabled
by default; each selected route must have an exact allowed domain. The output is
created exclusively with mode 0600, refuses existing files and symlinks, and always
sets `legacyDisabledRoutes` to an empty list. Conversion does not contact a device. The owner has announced source-export placement; its Recall-only profile was
privately retrieved and validated. This is not device Keychain enrollment.
Do not enable audio release from a source-code commit.
The Hub owner is still reviewing server compatibility; a deployment notice and
route evidence are separate requirements.

`HubDeliveryService` runs independently leased lanes at startup and retries
persisted request bytes. Original upload managers keep legacy delivery success
separate from Hub receipts. Expired audio may be stored, but never restarts a
legacy reaction after the existing ten-minute processing deadline. Restart
cleanup deletes only files whose durable model state already establishes ACK
and completed release, not merely a successful HTTP response.

The selected audio contract is Hub `audio-platform-completion.md` and
`stt-jobs.md`: Hub owns local STT for every admitted original. Device release
requires both matching original storage receipt v1 and a durable processing
intent receipt. The immutable job/original/pipeline binding is stored atomically
with local ACK; mutable job state is not ASR success. This supersedes historical
A/B alternatives; there is no outstanding user A/B or capacity question.
Capture end remains unknown. `startedAt + duration`, DB creation, upload time,
and Hub receive time cannot substitute for an actual capture end.

## Remaining acceptance

- Complete and prove original capture staging reservations before audio activation.
- Import Recall-only private configuration and verify its device Keychain receipt.
- Prove each route using natural producer ID -> verified Hub receipts -> scoped
  MCP read -> required consumer correlation, without publishing personal values.
- Verify Hub job binding/recovery and preserve capture uncertainty in consumers.
- Stop each old delivery only after its consumer owner's synchronized GO.

No runtime route is accepted by compilation or unit tests alone. Retention,
collection consent, visible UI, and foreground/read-state behavior are unchanged.

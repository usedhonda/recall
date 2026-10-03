# Hub runtime admission checkpoint

Task: complete approved Recall producer integration, with independent source
credentials, immutable outboxes, and no premature consumer cutover.

## Implemented, not device-accepted

- Startup private configuration import into a device-bound dedicated Keychain
  item; explicit route activation/cutover latches; no Gateway credential fallback.
- Immutable metadata and original adapters; independent leased HTTPS delivery;
  existing network data policy is preserved for each lane.
- GPS source queue and Hub outbox share atomic SQLite budget reservations. Queue
  mutation is serialized across reservation awaits. Corrupt source files and
  persistence failures fail closed; legacy success has separate durable IDs.
- Storage plus durable STT intent validation for audio, persisted atomically with
  job/original/pipeline binding before request-body release. Mutable processing
  state is not transcription success. Storage-only audio ACKs cannot release.
- Original managers preserve unACKed files and separate legacy delivery success.
  Audio expiry suppresses old reactions without expiring Hub originals. Restart
  cleanup handles ACKed files left between model save and file deletion.
- Finite per-lane logical bytes, receipt bookkeeping and bounded gap records.
  No unACKed eviction, arbitrary tombstone pruning or old-store fallback.

## Verification

Simulator build and 18 affected contract/outbox/provisioning tests passed.
Contract check and whitespace check passed. These do not prove natural delivery.
No synthetic production event, device configuration import, route activation,
old-route stop, or consumer acceptance was performed for this checkpoint.

## Remaining exact dependencies / work

1. Obtain Recall-only endpoint/token through the Hub owner's private procedure,
   not the full source policy. The source-only export was placed and privately
   retrieved; schema/permissions were validated without exposing values. A private
   device-bound configuration was generated from the existing device identity,
   with zero enabled routes and zero legacy stops. Device transfer and Keychain
   import are not yet established. Configure routes only after acceptance.
2. Complete strict audio capture staging reservation. The current exclusive
   writer token + start guard is not a byte bound on an encoded future chunk.
   It must not be described as full `storageCapMB` enforcement or used alone
   as audio-activation proof. Preserve format/chunking and existing capture scope.
3. Prove glasses import/outbox combined capacity across asynchronous boundaries;
   the current import reservation is local in-memory bookkeeping, not a shared
   durable transaction with source file creation. Oversize envelopes remain
   unACKed; chunked upload is not implemented.
4. Verify natural per-route IDs/receipts/blob hashes against scoped MCP reads and
   required consumers, then synchronize legacy stop separately per route.
5. Device deployment and on-device behavior/log validation remain outstanding.

Capacity numbers and the old A/B device-release choice are resolved; do not ask
again. Hub `audio-platform-completion.md` and `stt-jobs.md` are the selected audio
contract. Actual capture end remains unknown; receive/upload/DB clocks cannot
fill it. The transport and source integration do not authorize late notifications.

## Confirmed owner update

The Hub owner confirmed processing receipt v1 and archive capture-unknown
semantics. The server implementation is still undergoing compatibility review;
its code/contract presence is not a deployment notice. Do not enable device
audio release before that notice. The existing Recall validator matches the
announced binding and initial pipeline.

The source-only provision export uses `schema_version`, `source`, `base_url`,
`bearer_token`, and `allowed_domains`. These are not the device import schema.
Conversion must enforce source/domain restrictions, explicit device identity and
route selection, and produce no legacy-disable flags. No credential values or
full Hub policy belong in messages or tracked artifacts.

### Private provisioning progress

The deployed source export and the still-unreflected processing receipt are
separate states. Only the source export was retrieved. The device preference
read confirmed no existing Hub activation/cutover latches. Its Recall process
is running; the available process API does not report foreground state. No app
replacement, launch, device-file transfer, or foreground change was performed.
Do not equate the locally prepared private config with Keychain enrollment.

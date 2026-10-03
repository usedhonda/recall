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
semantics. The owner subsequently confirmed production reflection, and an authenticated
operator capability read matched the source, processing receipt version and
initial pipeline. This is server/operator evidence, not device receipt evidence. The existing Recall validator matches the
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

### Deployed receipt contract integration

The processing job identifier now requires a canonical lowercase UUID, matching
the deployed owner's validation requirement. The two affected receipt regressions
passed. Hub configuration/recovery startup moved from the SwiftUI scene task to
AppDelegate before background HealthKit observers. Simulator and signed device
builds passed; no foreground/recording-intent code was changed.

Device lock-state reported passcode required. No app replacement or launch was
attempted, preserving the running recorder. Device configuration remains local
and disabled. Source-capacity acceptance, device reflection, Keychain import and
natural producer-to-consumer evidence remain outstanding.

## Current device checkpoint (supersedes local-only state above)

- Fixed the active glasses handoff copy/outbox admission race using one shared
  lane gate; protected filename collisions from overwriting retained originals.
  One focused contention regression and Simulator/device builds passed.
- Installed the signed build and launched with `--no-activate`, without
  terminating first or manipulating foreground/read-state settings. The prior
  lock-state observation was not sufficient to declare background launch blocked;
  the actual launch operation succeeded.
- Private Keychain import is confirmed in the authoritative device log. Seven
  non-audio routes enabled; audio disabled; all legacy-stop flags remain empty.
- Natural durable device ACKs: GPS 2, Health aggregate 1, Wi-Fi 1. Copied SQLite
  quick_check passed; each receipt matched its stored source external ID.
- Sent event references to the Hub owner for scoped MCP and required consumer
  correlation. That response is pending, not MCP/consumer acceptance.
- No synthetic observation or forced geofence/media/glasses event was emitted.
  Channel report, now-playing, geofence and glasses natural receipt evidence
  remains to be collected. Audio capture byte reservations remain unresolved.

The retired PhotoKit scanner is not started by the app and was not re-enabled.
Glasses headroom estimates never replace actual serialized envelope limits.

## Local completion after the device checkpoint

- Build subprocesses now use `scripts/safe-xcodebuild.py`: fixed/minimal
  environment, private ignored logs and entire assignment-line suppression.
  Four focused Python tests passed. This prevents the known environment-dump
  path; it does not retract previous tool output or resolve credential exposure.
- Bounded audio CAF encoding and durable source/outbox reservations are now
  implemented. Three codec/file tests, one reservation/restart test and the
  Simulator build passed. No bitrate estimate is used as a physical byte bound.
- Fixed channel report timestamps: the reporter emits whole-second ISO8601,
  while its former fractional-only parser rejected that format. Both forms now
  pass two focused tests. Send policy and collection scope are unchanged.
- Hub owner reported the four natural non-audio events matched scoped MCP reads.
  Consumer-owner evidence additionally covers two GPS inputs, seven supported
  Daily health metrics and Wi-Fi status projection. This is reported peer
  evidence, not a new local execution or proof of direct-producer live selection.
  Latest live selection still used a newer legacy snapshot; unit correction was
  pending. No legacy-stop approval has been issued.

The signed device build passed and its signature verified. A private eight-route
configuration was prepared locally from the existing source-only profile, with
all seven prior routes preserved and zero legacy-stop flags. It has NOT been
transferred or activated. No credentials were printed or changed.

Remaining: resolve incident credential/restart
conditions before device reflection; collect natural audio/storage+STT intent
and remaining route receipts; obtain actual live consumer selection and per-route
cutover acceptance. Audio remains disabled on the device. No synthetic production
event, credential rotation, or legacy stop is authorized by these local results.

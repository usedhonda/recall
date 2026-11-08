# Direct smart-ring capture

## Source ownership

| Source | Control | Data and meaning |
| --- | --- | --- |
| Apple Health | Existing top-screen Health toggle | Existing HealthKit samples, summaries, sleep and workout reads; unchanged |
| Direct ring | Settings → Smart Ring → Direct ring sync | SmartRingKit HRV-history records: device-labelled HRV/stress, heart rate and original bytes |

The ring switch defaults OFF and does not require HealthKit authorization. It
does not change the Health toggle, Audio, Location, Glasses or Media. The existing
Health channel-status heartbeat still describes HealthKit, not the ring. No
HealthKit writes or vendor-source exclusions are introduced.

The dependency is [SmartRingKit 0.4.0](https://github.com/usedhonda/smart-ring-kit/releases/tag/v0.4.0),
pinned exactly. This is an experimental FFF0 driver whose read protocol was
observed on one issin Smart Recovery Ring with firmware 0.7.5.0. Support for
other rings/firmware, concurrent vendor-app reads, and live measurement is not
established.

The ring-first hybrid implementation is in progress. Acquisition now uses the
SDK all-history reader and preserves each per-history capture locally in protected,
backup-excluded storage before the next history is attempted. Partial histories
remain evidence, not accepted measurements. The existing HRV projection continues
to use completed HRV history. Capture files and HRV identities share the existing
10,000-entry admission ceiling; no automatic eviction is introduced.
General sensor/sleep projection, interval-level HealthKit sleep supplementation,
restorable BLE transport and background scheduling are not implemented yet.
This acquisition checkpoint has not been deployed to the phone.

## Capture and settings

1. Enable Direct ring sync in Settings. Bluetooth permission belongs to Recall.
2. Find rings and select the device you own. An SRR name or FFF0 service is only
   a discovery candidate, not proof of protocol compatibility.
3. Explicitly choose the time zone used by the ring's clock. It is not inferred
   from the phone's current zone. Changing the interpretation affects newly
   imported identities; previously saved records retain their original zone.
4. Sync now. After setup, sync also runs on foreground entry and every 15 minutes
   while the scene is active. Each pass releases its BLE connection on completion.

Inactive/background scenes cancel only ring work and its timer. No new background
mode, continuous radio connection, automatic pairing reset or firmware change is
introduced. This cadence is an opportunity to read existing history, not a request
for the ring to measure more frequently. The initial history had mostly hourly
gaps. Historical travel, clock resets and ambiguous daylight-saving times cannot
be reconstructed from a timestamp with no zone; the original clock fields remain
available for later interpretation.

## Storage, identity and upload

The separate `smart-ring-history.json` archive in Application Support is written
atomically with iOS protection until first user authentication and excluded from
device backup. It holds up to 10,000 records, including queued identities. At
capacity it refuses new data visibly instead of evicting records or forgetting
deduplication history. The archive is not part of the audio-storage cap.

An observation UUID is `ring-<SHA256>` over the hashed CoreBluetooth peripheral
identifier, explicit clock time zone and record bytes 3–14. Download sequence
bytes 1–2 do not make a new observation. A repeated download keeps the first
saved body/metadata. Changed values or a changed clock interpretation get a
different identity. Device names and raw CoreBluetooth UUIDs are not uploaded;
the per-device hash is a pseudonymous identifier, not anonymization.

New records reach the archive before Hub admission. Ring radio errors do not
prevent saved records entering the outbox, and unavailable/full upload queues
do not prevent local capture. A failed admission remains pending. Batch membership
is persisted before admission so a crash plus new capture cannot change a retry's
body, observation ID or captured-at time. Queued means **local durable outbox
admission**, not remote receipt or reader acceptance. Existing receipt validation,
network policy and retries remain the delivery authority.

The existing `recall.health-samples.v1` route and `metadata-raw` lane carry ring
items; no new Hub route/provisioning is introduced. A provisioned health-samples
route is still required for upload, independently of the HealthKit toggle. With
no route/configuration, records remain local. Like the existing raw-health policy,
records older than the first ring archive creation minus 14 days are retained
locally and held from admission pending a retention decision. The UI counts held
records separately within pending records. The boundary persists across restarts.

## Item shape and overlap with HealthKit

The receiver-facing metric, source and interpretation contract is in
[smart-ring-hub-contract.md](smart-ring-hub-contract.md).

Each item has `uuid`, `type: "smart_ring.hrv_history"`, `start`, `end`,
`source: "SmartRingKit"`, `sourceVersion: "0.1.0"`, `deviceModel: "FFF0 ring"`,
and a `ring` object containing `deviceID`, `firmware`, `clockTimeZone`,
`deviceTime`, `hrvRaw`, `heartRateBPM`, `stressRaw` and `rawBytes`.
The envelope uses `time_basis: "ring_captured_at"`; `occurred_at` is the first
record's capture time in the frozen batch. Item `start`/`end` use the selected
interpretation of the device clock.

There is no scalar `value`/`unit` claiming a standard HealthKit quantity. HRV
algorithm/unit and stress scale are unknown. In particular, `hrvRaw` must not
be treated as HealthKit SDNN. Zero values remain raw, without an inferred validity
judgment. Full bytes preserve uninterpreted fields for later research.

## Unified health snapshot

The app combines both inputs in the existing health-snapshot payload. `records`
contains the selected representative for each metric. A positive direct-ring
heart-rate reading is preferred when it is at or after the HealthKit aggregate's
interval start (or is at least as new as an existing point measurement). Otherwise
HealthKit remains the representative. Future-dated ring observations are not
selected. A ring reading is a point measurement, not an average of the HealthKit
interval; its `aggregation`, measurement time and source describe that distinction.

`sourceRecords` retains both original candidates when ring data is available;
it is provenance, not another list to sum or average. Direct records include the
original pseudonymous source device and observation identifiers. Sleep, daily
heart-rate aggregates, steps and other unsupported ring quantities still come
from HealthKit. Raw HRV and stress use `smart_ring.hrv_raw` and
`smart_ring.stress_raw` with unit `raw`, never an SDNN identifier or unit `ms`.

HealthKit collection publishes this integrated payload. A foreground ring sync
also admits a health snapshot directly to the existing Hub route, even when
HealthKit is OFF; in that case it includes no cached HealthKit data. This does
not turn on HealthKit, require its authorization, or write into Apple Health.
Ring radio/raw capture and snapshot admission remain independently retryable.
The same persisted history-retention floor applies to the snapshot projection;
held old ring data cannot bypass it through the aggregate route.

HealthKit may later receive overlapping readings from a companion app. Both
provenance paths are retained; a timestamp match does not prove equivalence and
does not authorize deleting either source. Standard health dashboards continue
using HealthKit data. Ring raw-data readers must select the `smart_ring.*` type
and deduplicate by `uuid`; they must not sum or average it into HealthKit metrics
automatically. Unified `records` supplies the preferred view without deleting
either raw source. Hub readers need to recognize this new item variant. Local
contract acceptance is tested; receiver/reader acceptance is not established.

## Verification boundary

Synthetic tests cover raw-value provenance, retry identity, persistence, repeated
downloads, capacity and retention holds. Simulator build and contract checks
verify integration. They do not prove Bluetooth behavior, simultaneous vendor
connections, background collection or end-to-end Hub delivery. This change is
was originally submitted as PR 12 only. On owner-directed adoption, the combined
health projection passed the integrated 12-test batch; the retention projection
case then passed alone after that boundary was extended. The signed build was
installed once and immediately launched without activation, preserving audio OFF.
Natural Health/GPS/raw receipts were verified afterward, with direct ring still
OFF pending explicit clock-zone selection. This is not real ring BLE or ring
receipt/reader acceptance.

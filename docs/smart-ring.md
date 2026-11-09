# Direct smart-ring capture

The consumer pins the released SmartRingKit 0.7.1 exactly.
Before metadata and each history request, passive admission requires five quiet
seconds, within a thirty-second budget. An observed unfinished history remains
busy until its terminator, rather than being mistaken for idle during pagination.
Busy defers the pass without advancing its successful-sync clock or backfill
cursor. Observed passive bytes are saved in the protected, backup-excluded
capture archive, never normalized as a requested health record. Previously
stored observations still drain to the outbox. This is not an inter-app mutex;
another reader can begin afterward, so response conflicts still fail the pass.
No vendor settings, sensor cadence or ring clock are changed.

## Source ownership

| Source | Control | Data and meaning |
| --- | --- | --- |
| Apple Health | Existing top-screen Health toggle | Existing HealthKit samples, summaries, sleep and workout reads; unchanged |
| Direct ring | Settings → Smart Ring → Direct ring sync | SmartRingKit histories: profile-qualified sensors/sleep, device-labelled raw values and original bytes |

The ring switch defaults OFF and does not require HealthKit authorization. It
does not change the Health toggle, Audio, Location, Glasses or Media. The existing
Health channel-status heartbeat still describes HealthKit, not the ring. No
HealthKit writes or vendor-source exclusions are introduced.

The dependency is [SmartRingKit 0.7.1](https://github.com/usedhonda/smart-ring-kit/releases/tag/v0.7.1),
including passive admission. This is an experimental FFF0 driver whose read protocol was
observed on one issin Smart Recovery Ring with firmware 0.7.5.0. Support for
other rings/firmware, concurrent vendor-app reads, and live measurement is not
established.

The ring-first hybrid implementation uses the
SDK all-history reader and preserves each per-history capture locally in protected,
backup-excluded storage before the next history is attempted. Partial histories
remain evidence, not accepted measurements. The existing HRV projection continues
to use completed HRV history. Capture files and HRV identities share the existing
10,000-entry admission ceiling; no automatic eviction is introduced.
Sensor/sleep projection, interval-level HealthKit supplementation and best-effort
background acquisition are implemented below. Installation alone does not prove
ring setup, BLE capture or Hub receipt.

## Capture and settings

1. Enable Direct ring sync in Settings. Bluetooth permission belongs to Recall.
2. Find rings and select the device you own. An SRR name or FFF0 service is only
   a discovery candidate, not proof of protocol compatibility.
3. Explicitly choose the time zone used by the ring's clock. It is not inferred
   from the phone's current zone. Changing the interpretation affects newly
   imported identities; previously saved records retain their original zone.
4. Sync now. After setup, sync also runs on foreground entry and every 15 minutes
   while the scene is active. Each pass releases its BLE connection on completion.

Inactive/background scenes stop the active timer and schedule bounded ring-only
work. Known-peripheral restoration and BGProcessing provide best-effort wake
opportunities; neither guarantees a fifteen-minute schedule. No automatic pairing
reset or firmware change is introduced. This cadence reads existing history, not a request
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

HRV items have `uuid`, `type: "smart_ring.hrv_history"`, `start`, `end`,
`source: "SmartRingKit"`, `sourceVersion`, `deviceModel: "FFF0 ring"`,
and a `ring` object containing `deviceID`, `firmware`, `clockTimeZone`,
`deviceTime`, `hrvRaw`, `heartRateBPM`, `stressRaw` and `rawBytes`.
New items use source version 0.7.1; frozen historical batches keep their original
body/version. Sensor and sleep variants are defined in the hybrid wire contract.
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
original pseudonymous source device and observation identifiers. Daily heart-rate
aggregates and unsupported ring quantities remain HealthKit-derived. Supported
spot pulse, oxygen, comparable daily steps and sleep follow the profile-qualified
selection described below. Raw HRV and stress use `smart_ring.hrv_raw` and
`smart_ring.native_fatigue_raw` with unit `raw`, never an SDNN identifier or unit
`ms`. The historical `smart_ring.stress_raw` name and raw `ring.stressRaw` field
refer to the native fatigue byte, not the vendor app's stress score. Previously
stored items and frozen batches retain their original names and bodies.

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
either raw source. Receiver projections have synthetic encoder-fixture acceptance;
that is separate from real ring receipt and display.

## Verification boundary

Synthetic tests cover raw-value provenance, retry identity, persistence, repeated
downloads, capacity and retention holds. Simulator build and contract checks
verify integration. They do not prove Bluetooth behavior, simultaneous vendor
connections, background collection or end-to-end Hub delivery. The completed
hybrid implementation passed its focused integration batch and affected boundary
checks. Its signed build was installed once and immediately launched without
activation, preserving audio OFF. Direct ring has subsequently been configured
through USB UI automation. Real HRV/sleep capture, producer committed receipts and
same-observation Hub health-view data are confirmed. Other histories stopped after
a conflicting command response. Full-category/background acquisition, pixel display
and full Chi reader consumption remain unverified; the actual snapshot exceeds
that reader's existing metadata hydration cap. See the current
[handoff](handoff/014-ring-first-hybrid.md) for the implementation checkpoint.

## Ring-first hybrid implementation

SDK 0.4 acquisition now captures all ten histories; selected decoded sensor and
sleep records share the existing durable archive, IDs, frozen batches and history
floor. Old HRV entries decode unchanged. Raw unknown/partial transfers and snapshot
firmware/clock context remain in protected local capture storage. Unsupported
units are never promoted to HealthKit quantities. Structured identities are only
admitted inside the existing retention floor, without discarding full local captures.

The matching issin 0.7.5.0 profile enables spot pulse, automatic oxygen and
same-day comparable step totals. Unconfirmed models/firmware retain raw sensor
measurements without normalized interpretations. Ring sleep uses its exact profile,
keeps light separate from HealthKit core and preserves unknown/conflicting samples.
Only missing/uncovered time intervals fall back to HealthKit. Existing fourteen-day
HealthKit sleep queries now also return their original segments without a second
query. `sleepSessions` is the selected aggregate; `sleepTimeline` records source and
quality. Source candidates are never added again. See
[the hybrid wire contract](smart-ring-hybrid-contract.md).

A Recall-owned restoration Central observes only connection/wake state; the SDK
alone issues history commands; Recall does not duplicate its decoder.
AppDelegate registers it independently of audio and HealthKit. The
background modes are bluetooth-central and processing. BGProcessing and restored
known-peripheral connection events request single-flight work. Each background
opportunity prioritizes spot heart rate and HRV, then one rotating backfill category,
subject to OS expiry. Each category is saved before the next starts; the backfill
index advances only after that category is persisted. No unfiltered background
ring discovery or exact fifteen-minute wake promise is made. Foreground still
supports full-history capture, manual sync and the existing active timer.

The raw capture and aggregate selection count shared archive slots and never evict
pending data. Sleep correction windows explicitly replace overlapping selections
when later data corrects session boundaries. Day-only steps carry day/timeZone and
ring_day precision; captured-at only breaks same-measurement revision ties.

## SDK 0.7 incremental reads and experimental analysis

Foreground acquisition reads the same ten categories, placing spot pulse/HRV first
and dynamic heart rate last. Completed categories are merged immediately; any
interrupted category ends the pass rather than issuing a different command into
an uncertain shared transfer. Saved records still enter the outbox. Device info
and the optional device clock are read once on a separate metadata client; history
reads never immediately reconnect that same client after a clock failure.
Foreground uses full history
for broader backfill. Background spot pulse, HRV and ordinary temperature can
resume from the second-newest persisted, same-device/firmware/zone record timestamp.
Hints overlap and are not date filters: full-history fallback and older responses
still pass through the existing identity deduplication. Partial captures never
advance an observation-derived anchor. Original captures retain request start,
completion/availability time, clock metadata, hint, unexpected packets and failure.

Explicit `availableAt` records the first known completed receipt under this
integration. Legacy records without it are excluded from model inputs until
re-observed. Adding receipt metadata does not rewrite their raw bodies, IDs or
frozen batches. Per-metric age uses measurement time, not another category's read.

The research input assembler preserves missing/stale/conflicting categories and
uses an explicit ten-minute engineering age limit. It does not guess a sleep
window. Experimental native-fatigue estimation defaults OFF; the owner explicitly
selects carry-forward, regression, residual or learned-decay mode in settings.
Only independently received spot-pulse BPM enters the current model; the entire
HRV/fatigue event is excluded from features. SDK defaults govern training/age
limits, not medical thresholds. Insufficient data or calibration, conflicts and
extrapolation remain unavailable, never zero. A carry-forward result is an
estimated hold, not a fresh native measurement.

If enabled, the single current `nativeFatigueEstimate` is optional snapshot
metadata carrying source device/firmware/clock zone and a nested `estimate` with
original query/knowledge/anchor clocks, method/model/training
metadata and `experimental_unvalidated` status. It is never inserted into measured
`records`, never called vendor stress and never added to daily rollups. Research
contexts stay local rather than enlarging snapshots with another raw timeline.
No ten-minute execution schedule, new sensor cadence or medical validity is
promised. The SDK's ten-minute replay is not automatic hardware measurement.

## Independent estimated stress

When direct ring capture is enabled for a supported profile, snapshots carry a
separate optional `stressEstimate`; it is never a measured `records` entry or a
native-fatigue estimate. The first method is `heart-rate-median-mad-v1`:
`(current spot BPM - prior personal median BPM) / prior median absolute deviation`.
The signed unit is `personal_mad`, not percent, probability or a vendor scale.
Zero denotes the personal heart-rate median, not an absence of stress. Negative
values remain negative. There are no low/high stress thresholds or clinical claims.

Only independently received `0x55` spot-heart-rate samples from the selected
source device, firmware and historical clock zone contribute. Actual availability
must be at or before computation. The seven-day reference excludes the current
observation and conflicting timestamps. A minimum of 24 reference observations
and a maximum current-input age of 1,800 seconds are engineering policies, not
validated physiological thresholds. Missing/stale/conflicting input, insufficient
reference or zero/unusable MAD yields `status=unavailable`, an explicit `reason`
and no numeric `value`; it is never imputed as zero.

The payload includes `estimatedAt`, `inputMeasuredAt`, `inputAvailableAt`, source
observation/device, firmware/zone, baseline window/count/median/MAD and a digest
of reference observation identities. A digest is provenance, not a new retrieval
API. All estimates are `experimental_unvalidated`, explicitly heart-rate-only,
without activity or sleep correction. Exercise, illness, posture and other factors
may affect heart rate; this proxy does not identify psychological causes, imitate
Welly, or reinterpret unknown HRV/fatigue units. The prior research basis is
[Neigel et al.](https://doi.org/10.3389/fcomp.2025.1575404), not validation of this
specific median/MAD method or individual short-interval inference. No pretrained
weights, invented fusion coefficients or new ring configuration are introduced.

The existing Health and ring snapshot paths both attach this separate result.
Receiver projections keep it live-only and distinct from raw native fatigue,
legacy `stress_raw`, measured records and coarse daily rollups. No new long-term
retention or compact-snapshot cutover is part of this change.

## Ten-minute owner-selected cadence

The foreground acquisition timer and background request/debounce policy use one
600-second interval. Each acquisition refreshes the independent stress estimate
from actual received spot-heart-rate inputs; repeating a query is not a new
measurement. iOS decides background execution, so this is not a promise of a
snapshot or estimate every ten minutes while suspended. Retained device histories
are recovered at their original measurement clocks when execution resumes.

Separately, the owner explicitly selected ten-minute native HRV/fatigue monitoring
on the already verified firmware. This device setting is applied only through a
bounded private maintenance operation with identity/firmware checks, preservation
of all other fields and exact readback. It is not a public SDK setter or a write
performed on ordinary sync/startup. Higher sampling may increase battery use.
The app never fabricates missing ten-minute measurements or interpolates fatigue
and calls it measured data. Native fatigue and the heart-rate stress proxy remain
separate. Deployment logs carry the actual setting/readback evidence.

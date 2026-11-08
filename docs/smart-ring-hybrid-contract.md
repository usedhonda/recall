# Ring-first hybrid health contract

This extends existing health-snapshot and health-samples routes; no new API, grant,
medical interpretation or raw retention is implied.

## Selected sleep and provenance

`sleepSessions` is the selected aggregate; `sleepTimeline` is its source/quality
explanation and is never added again. `sourceSleep`, `sourceSleepSessions` and
`healthKitSleepTimeline` are original HealthKit candidates, never extra sleep.

Each selected session has optional `sessionID`, `sourceDeviceID` (hash),
`clockTimeZone`, `day` (wake date in that zone), `conflicting`, `lightMinutes`,
`unknownMinutes` and `missingMinutes`, alongside existing fields. New sessions
emit numeric zero for measured absent stages; old sessions lacking a new field
retain unknown/not-collected semantics, not an invented zero.

`totalMinutes` includes ring light/deep/rem plus HK asleepCore/asleepREM/
asleepDeep/asleepUnspecified, counted once. Awake, unknown and missing are excluded.
Ring light and HealthKit core stay distinct. Session splitting uses the existing
three-hour gap; no sleep score or fixed night boundary is inferred.

Timeline fields: start/end, stage, source, sourceDeviceID, conflicting. Ring
stages are light/deep/rem/awake/unknown/missing; fallback HealthKit stages retain
their original names. Only missing/uncovered intervals use HealthKit. Unknown
ring codes or conflicting ring overlaps stay unknown, not secretly overwritten.

`sleepReplacementWindow: {start,end}` is the source-time correction interval.
A reader replaces previously selected sessions overlapping this interval before
inserting incoming selected sessions, including when the earliest session start
was corrected. Other periods remain unchanged. sessionID hashes device+zone+start;
start corrections can change ID, hence replacement is interval-based, not ID-only.

## Other metrics

Selected `records` contains ring-first canonical spot heart rate (count/min),
automatic oxygen (%) and directly comparable day-total steps (count). A 24-hour
measurement window is used for latest values; arrival time is not measurement time.
Day-only steps carry measurementTimeBasis=ring_day, day and timeZone. They are
not rebinned into an unrelated timezone or added to a HealthKit daily total.
Unknown temperature, calories/distance/mode values remain smart_ring.* metrics,
with unit raw where the physical unit is unestablished. Unknown-spacing series
remain in raw sensor observations, never given fabricated per-sample dates.

Direct records retain sourceObservationID/sourceDeviceID and measurementTimeBasis.
Raw items use smart_ring.sensor.<decimal-command> with sensor payload, and
smart_ring.sleep_history with sleep payload; HRV retains its established shape.
Ring metadata fields hrvRaw/heartRateBPM/stressRaw are omitted on non-HRV items.
Original bytes remain present. No decoder reinterpretation belongs in Hub.

## Reader and retention boundary

Add light/unknown/missing to live sleep presentation without treating coverage as
sleep. Show selected current pulse and oxygen separately from unchanged daily
heart-rate aggregates. Preserve selected source/time/day labels.

Existing daily/monthly rollups must explicitly retain only their previously
approved coarse fields. Do not put new stage detail, IDs, provenance timelines,
source candidates or unknown-unit values into longer-lived events implicitly.
Receiver validation uses the actual encoder-generated synthetic fixture, never
production synthetic health POST. Production reload, real ring capture, phone
receipt, scoped reader and visible real measurements remain separate acceptance.

When day totals are restated with the same measurement day, optional
sourceCapturedAt identifies the acquisition revision. It is only a tie-breaker
for equal measurement clocks; it must never make an old measurement newer than
another measurement. Existing payloads without it remain compatible.

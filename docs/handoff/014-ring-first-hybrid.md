# Ring-first hybrid implementation

## Binding owner plan

Owner approved the whole hybrid plan, including interval-level HealthKit filling
of missing ring sleep and background BLE synchronization. Ring is preferred for
supported meaningful metrics; preserve source provenance and independent toggles.
No public push, retention expansion, forced recording, guessed clock zone,
clinical stress scale or raw HRV-to-SDNN conversion.

## Implemented checkpoint

Recall commit `d8ee9cd` implements:

- SDK 0.4.0 all-history foreground capture, original per-history progress/context,
  shared 10,000-entry ceiling, historical IDs/frozen batches/retention floor.
- Exact model/firmware-qualified spot pulse, oxygen and comparable daily steps;
  other values retain original names/units without invented medical meaning.
- Ring-first disjoint sleep intervals; only missing/uncovered intervals use HK.
  Unknown/conflicting ring stages stay unknown; ring light and HK core stay separate.
- Selected sessions, correction windows and provenance in existing health snapshots;
  source candidates are never added again. Existing 14-day HK query supplies segments.
- Recall-owned restoration/wake Central with SDK-owned history commands; independent
  BGProcessing and resumable single-category background work, without schedule guarantees.
- Explicit model/clock-zone settings; no ring reset, firmware or clock writes.

The integrated focused batch passed 14 cases. Two affected boundary cases passed
after correction-window/shared-capacity changes, and the sensor case passed after
wire-fixture/revision-tie updates. Simulator build, signed device build and contract
check passed. Do not rerun unchanged tests to reconstruct evidence.

## Runtime reflection and unfinished acceptance

The signed build was installed once and immediately launched without activation,
preserving the stored audio OFF intent. Subsequent phone logs confirm silent launch
and ordinary Health/status/GPS/raw activity. This does not establish ring delivery.

Direct ring is not configured yet. Foreground BLE capture, background capture and
same-observation Hub receipt/read/display remain unverified. Phone Mirroring reported
that the phone was in use and required a physical lock; the owner was asked for that
single physical action. Do not repeat installation or toggle audio to clear this.

The library's ignored original sleep-analysis proof records an explicit clock zone;
use that evidence rather than guessing from current phone location. Establish the
selected physical ring's identity before applying it. Device-specific details and
private evidence paths stay in ignored local reports.

## Receiver coordination

Existing data-hub task 2124c96b supplies selected sleep, separate light/core/coverage,
canonical sensors and unknown raw display in existing health views, with old coarse
rollup fields explicitly whitelisted. Final packet initially named `3741518`.
Parent reviewed its integrated diff and representative synthetic rendering.
Follow-up `a41e019` clears stale ring day provenance when later HK steps replace
the selected total. Parent confirmed that source diff; the worker reports its
single affected regression passed. Runtime reflection of this correction is still
pending, so receiver acceptance is not closed. Synthetic fixture acceptance is
not real ring receipt/display acceptance.

## Resume

1. Configure the known ring/model/explicit clock zone through the existing UI once
   phone control is available; preserve every other stream's setting.
2. Capture real foreground history, then observe an actual background opportunity.
3. Match a real observation across producer and ordinary authorized Hub read/display.
4. Confirm runtime reflection of the reviewed receiver correction, then verify/report
   its existing task without repeating unchanged suites.
5. Keep public push separate; none was performed for this implementation.

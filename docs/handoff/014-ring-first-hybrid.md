# Ring-first hybrid implementation

## Binding owner plan

Owner approved the whole hybrid plan, including interval-level HealthKit filling
of missing ring sleep and background BLE synchronization. Ring is preferred for
supported meaningful metrics; preserve source provenance and independent toggles.
No retention expansion, forced recording, guessed clock zone,
clinical stress scale or raw HRV-to-SDNN conversion.
Public push requires owner instruction; the owner subsequently ordered push and
the implementation through `81b9cac` is on origin/main.

## Implemented checkpoint

Ten-minute cadence checkpoint: owner explicitly selected native HRV/fatigue
monitoring at ten minutes. A bounded private operation verified existing active
ten-minute heart monitoring, changed only the HRV interval from sixty to ten,
and verified exact readback with all other fields preserved. This supersedes the
older temporary experiment's restored setting; it is not an automatic SDK write.
Recall `c6b8f15` shares a 600-second foreground timer, background earliest request
and wake debounce. Estimated stress updates from real received heart samples;
background execution remains OS-controlled, not a guaranteed ten-minute delivery.
Both builds and contract passed; deployed with audio OFF preserved. Local log1043
holds private configuration proof and subsequent natural-cadence acceptance.
Two new actual native-fatigue records were recovered with a 600-second gap;
this is device storage evidence, not a promise of background app execution.
Heart/HRV acquisition succeeded, but a different dynamic-HR history still saw
conflicting spot-HR traffic. That partial-pass failure remains explicit and does
not discard the saved target observations or their health snapshot.

Current estimate checkpoint: Recall `06b2e58` pins released SDK 0.7.1 and adds an
independent `stressEstimate` to both existing health snapshot paths. It is a
heart-rate-only personal median/MAD deviation, not a probability, Welly stress,
native fatigue or clinical scale. Zero and negative values remain meaningful
signed deviations; unavailable has no numeric value. Source/availability clocks,
baseline statistics and limitations travel separately from measured records.
The owner explicitly requested estimates and receiver display wiring. Formal
receiver task `865a89dd-bcf9-492d-9530-7d77af731f2e` is verified: receiver
`98b6225` independently projects the estimate, displays fatigue separately and
expires stale inputs using their measurement clock. Parent inspected its diff,
representative rendering and natural same-observation receipt proof. Natural
producer/view source, value and clocks match. This does not establish independent
psychological validity, vendor-score reproduction or actual Chi consumption.
The focused actual-source fixture harness passed; both consumer builds passed.
Local log 1041 carries deployment/receipt acceptance. Existing audio OFF remains
binding. No SDK setting or new retained rollup is introduced.

Transport stability correction was developed on isolated local branches: Recall
`fix/ring-reader-isolation` (`7ea6a9e`, `3b5b1cf`) and SmartRingKit
`fix/history-quiescence-pinned` (`8350ec1`, based on 0.7.0). The verified Recall
corrections and stress estimate are included in this revision. The SDK correction
was integrated and publicly released as 0.7.1. The unknown original-worktree index
lock was preserved throughout verification and publication; the isolated worktree
provides the publication source without altering that locked index.

The installed correction stops a failed category pass, isolates metadata once
per pass, and passively waits for history quiescence before requests. Unfinished
observed history cannot become idle merely through silence; passive evidence is
protected and never treated as a selected health reading. Existing stored data
still drains on busy/failure. No sampling, clock, firmware or permanent vendor
settings were changed. SDK suite and both consumer builds passed.

A full ten-category pass succeeded with the three other reader processes absent;
after the correction another full pass succeeded with them running normally.
Audio OFF was preserved. This is actual full acquisition evidence, not proof of
inter-app mutual exclusion or future contention-free operation. The normal pass
had no traffic in its passive windows, so live busy/defer remains unobserved.
Private runtime evidence and unresolved integration status: local log 1037.

Latest SDK checkpoint: `1bd8e7a` adopts pinned0.7.0; `860dafb` preserves failures
before raw capture. Foreground prioritizes spot HR/HRV and persists each category;
background prioritizes those two before one rotating backfill. Supported resume
hints use overlapping persisted records, not arbitrary cutoffs. Native fatigue
is explicitly separate from vendor stress. Optional experimental estimation is
OFF by default, with explicit method selection and actual availability evidence.
No ring sampling configuration is changed. See docs/smart-ring.md for the contract.

Actual0.7 run grew the archive from341 to3757 records with pending local admission0;
temperature/oxygen/daily activity/dynamic-HR records were newly admitted. Spot HR
timed out with partial bytes preserved, so all-category success remains unproved.
Research estimation was not enabled. Simulator/device builds and affected checks
passed; device UI automation failed twice before test execution while enabling
automation mode. Do not equate that infrastructure failure with predictor failure
or claim a successful0.7 UI observation. Private logs contain deployment details.

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

The SDK 0.4.1 build (`81b9cac`) is installed and launched with audio OFF preserved.
Direct ring is now enabled with selected device, explicit model and evidence-backed
clock zone. USB XCUITest reached the existing settings after mirrored scrolling
failed; its standalone runner does not reinstall Recall.

Real foreground acquisition completed HRV and sleep histories and admitted retained
records. Producer receipts and the receiver's same-observation health-view projection
are confirmed. All-category acquisition is incomplete: a different history command
arrived during dynamic-heart-rate reading, and the SDK stopped remaining categories.
Welly realtime communication was temporarily paused and restored through its own UI;
the same conflict remained, so that switch alone is not a proven solution. No vendor
force-quit, reset or unpairing has been performed. An explicit owner question about a
temporary Welly termination/restart is pending. Do not retry unchanged acquisition.
Actual background acquisition and full consumer read/display remain unverified.

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
single affected regression passed. Receiver task is verified following integrated
diff/rendering review and natural same-observation health-view evidence.

The canonical Chi reader remains incomplete for the actual snapshot: metadata
149472 characters exceeds its existing 131072-character hydration cap. This is
not a permission denial. Do not silently omit source candidates, increase caps or
grant access as a workaround. Receiver view-data acceptance does not establish
full Chi consumption, pixel observation or medical interpretation.

## Resume

1. Resolve the actual multi-client history collision without resets or data loss;
   retain owner control of the pending vendor termination decision.
2. Complete remaining categories and observe an actual background opportunity.
3. Resolve bounded Chi reading with its owning project; preserve all source data,
   existing permission boundaries and the observed reader-size limit.
4. Report the verified receiver task separately from remaining radio/consumer work.
5. Keep any further public push separate from the already completed owner-ordered push.

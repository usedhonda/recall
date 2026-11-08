# Ring-first hybrid implementation

## Binding owner plan

Owner approved implementing the full proposed hybrid plan, including interval-level
HealthKit supplementation of missing ring sleep and background BLE synchronization.
Ring is preferred for supported meaningful metrics; preserve all source provenance.
No public push, raw-retention expansion, forced recording, guessed time zone,
clinical stress scale or raw HRV-to-SDNN conversion.

## Current acquisition checkpoint

- Dependency pinned 0.4.0; SDK all-history capture replaces HRV-only radio requests.
- Per-history original capture persisted locally with protection/exclusion from backup.
- Capture files and HRV identity records share 10,000-entry ceiling; retries of
  identical raw capture do not overwrite the first stored capture.
- Completed HRV is still projected through the existing integration/outbox.
- Initial six SmartRing tests passed. Final changes compile on Simulator; exact
  final build result is in ignored ring-integration logs.
- No phone install, ring activation, Hub schema change or library edits in this checkpoint.

## Remaining approved work (not optional and not completed)

1. Preserve full snapshot device/firmware/clock metadata alongside per-history progress;
   migrate structured archive without losing old IDs, frozen pending batches or retention floor.
2. Normalize spot pulse, automatic oxygen, comparable daily steps and raw-only unknown units.
3. Device-profile-qualified sleep timeline; fill only missing intervals with HealthKit.
   Keep unknown/conflicting stages visible, light separate from HealthKit core,
   and use existing three-hour session-gap rule without double counting.
4. Latest point window24h, same-period ring preference; do not re-date unknown-spacing
   series or combine incompatible date-only daily totals.
5. SDK optional restoration ID/shared Central client, AppDelegate BLE restoration,
   bluetooth-central/BGProcessingTask and bounded resumable single-flight work.
6. Coordinate new source shapes and integrated sleep/health view with existing Hub peer.
7. Focused regression, signed build, safe phone install/launch preserving audio intent,
   foreground/locked background capture and same-observation Hub/read/display evidence.

Explicit ring clock time zone is still unanswered; do not infer it from phone time.
The approved plan itself remains authoritative; this checkpoint does not replace
it with acquisition-only scope or claim completion.

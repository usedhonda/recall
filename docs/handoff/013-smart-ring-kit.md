# Handoff: SmartRingKit integration PR

## Original PR scope (superseded by owner-directed adoption below)

- Goal: Add an opt-in direct-ring reader using SmartRingKit, with clear separation from HealthKit.
- Scope: Pinned package, independent settings/foreground lifecycle, protected ring archive, raw-health admission and documentation.
- Explicitly out: Merge, deployment/app restart, changes to existing HealthKit reads or other streams, background BLE/firmware modification.
- Status: Owner requested PR adoption plus unified HealthKit/ring health snapshots. Local integration verified; device reflection recorded below. Public push is not authorized.
- Decisions: Existing Health toggle remains the HealthKit authority; direct ring defaults off with its own switch. Preserve both sources, never write raw HRV into SDNN or dedupe across sources by clock alone. Existing health-samples route carries a namespaced item variant.
- Persistence: Stable observation IDs omit transfer sequence; archive precedes outbox admission; frozen batches survive crashes; retain queued identities; hard 10,000-record bound without eviction. Older-than-initial-14-day history remains local pending retention policy.
- Rejected: Vendor-source filtering in HealthKit, clock-zone inference from current location, continuous/background sync claims, new Hub lanes without a receiver contract.
- Verification: Simulator build passed. SmartRingTests 5/5, HealthSampleLedgerTests 4/4 and HubRawEventTests 2/2 passed (11 total). scripts/check-contract.sh PASS. No device installation, real BLE transfer or network delivery was performed.
- Open risks: Experimental BLE driver; concurrent vendor-app reads unverified; HRV/stress semantics unknown; historical clock changes unknown; Hub reader acceptance of smart_ring.hrv_history must be tested before device enablement.
- Next: Review the PR and confirm the namespaced item contract with Hub readers before opting in on a device. Merge/deployment remain outside this request.

## Owner-directed adoption

The owner subsequently requested adopting PR 12, preferring direct ring data where
supported, and treating HealthKit plus ring as one health dataset. The owner is
asking the library side about sleep; do not continue sleep protocol work here.

`HealthDataIntegrator` selects direct ring pulse within the HealthKit interval,
retains original candidates in `sourceRecords`, and leaves sleep/steps/other
quantities with HealthKit. HRV/stress are namespaced raw values, never SDNN.
HealthKit queries and ring sync both publish this combined view; a ring sync with
HealthKit OFF includes no cached HealthKit records. Existing toggles remain
independent. Raw archive/identity and the initial history-retention floor remain
authoritative for both raw batches and snapshot selection.

Integrated Simulator tests: 12 passed, including the unified-view regression.
After adding the retention-floor projection check, only that affected case was
rerun and passed. Signed device build and signature verification passed; no
unchanged full-suite rerun. The first dependency resolution failed because a
restricted PATH omitted git-lfs; using an explicit minimal PATH corrected the
environment without changing Git hooks. Contract and whitespace checks passed.

Ring clock time zone is awaiting the owner's answer. Ring defaults OFF; no BLE
capture, receiver acceptance or ring delivery is claimed by these checks.

`f3d5a66` was installed once and launched immediately without activation between
04:34:22Z and 04:34:25Z on 2026-11-08 (operation window, not a gap-free claim).
Fresh preflight confirmed unlocked and saved audio OFF, with stopped:user logs.
Post-launch App Group retained userStopIntent=true / isRecording=false. Natural
metadata-health receipt at 04:34:32Z and GPS/raw receipts confirm continued
independent-stream delivery, not ring capture. Direct ring remains OFF with no
selected device or time zone. No public push was performed.

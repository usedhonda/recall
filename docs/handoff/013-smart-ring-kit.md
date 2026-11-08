# Handoff: SmartRingKit integration PR

- Goal: Add an opt-in direct-ring reader using SmartRingKit, with clear separation from HealthKit.
- Scope: Pinned package, independent settings/foreground lifecycle, protected ring archive, raw-health admission and documentation.
- Explicitly out: Merge, deployment/app restart, changes to existing HealthKit reads or other streams, background BLE/firmware modification.
- Status: Ready for PR review; not merged or deployed.
- Decisions: Existing Health toggle remains the HealthKit authority; direct ring defaults off with its own switch. Preserve both sources, never write raw HRV into SDNN or dedupe across sources by clock alone. Existing health-samples route carries a namespaced item variant.
- Persistence: Stable observation IDs omit transfer sequence; archive precedes outbox admission; frozen batches survive crashes; retain queued identities; hard 10,000-record bound without eviction. Older-than-initial-14-day history remains local pending retention policy.
- Rejected: Vendor-source filtering in HealthKit, clock-zone inference from current location, continuous/background sync claims, new Hub lanes without a receiver contract.
- Verification: Simulator build passed. SmartRingTests 5/5, HealthSampleLedgerTests 4/4 and HubRawEventTests 2/2 passed (11 total). scripts/check-contract.sh PASS. No device installation, real BLE transfer or network delivery was performed.
- Open risks: Experimental BLE driver; concurrent vendor-app reads unverified; HRV/stress semantics unknown; historical clock changes unknown; Hub reader acceptance of smart_ring.hrv_history must be tested before device enablement.
- Next: Review the PR and confirm the namespaced item contract with Hub readers before opting in on a device. Merge/deployment remain outside this request.

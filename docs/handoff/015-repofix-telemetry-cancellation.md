# Handoff: Location attempt cancellation

- Goal / why: preserve independent Health uploads when the Location background execution lease expires.
- Scope: `TelemetryUploader.triggerUpload()` Lane A cancellation and pipeline documentation.
- Explicitly out: stream toggles, payload schemas, receipt/queue ownership, Lane B policy, UI, device deployment.
- Status: review; native build and overlapping-request execution remain unverified.
- Evidence: baseline `cb4d590396b9eb685302f3a46afa01c3c2fa1023` uses one `immediateSession` for both `uploadHealthOnly()` and `triggerUpload()`. The latter's expiration callback enumerates and cancels every session task, so a concurrent Health request is included. This is a source-verified cancellation-scope defect, not an observed device incident.
- Change: the Location attempt now owns a Swift task wrapping `uploadImmediate()`. Its lease-expiration callback cancels only that task. `withTaskCancellationHandler` also forwards cancellation from the calling task. Existing failure handling still schedules the frozen Lane B batch.
- Basis: Apple's [Use async/await with URLSession, cancellation section](https://developer.apple.com/videos/play/wwdc2021/10095/?time=284) documents cancellation of a Swift task propagating to its current URLSession async request. Checked 2026-11-09.
- Test accounting: added 0 / removed 0 / consolidated 0. Existing native test suites are retained. No wrapper or source-string test was added solely to restate `Task.cancel()`; such a check would not establish URLSession or iOS expiration behavior.
- Validation: source/control-flow review and `bash scripts/check-contract.sh` passed in the Linux editing environment. No Swift compiler, Xcode, iOS SDK or device is available here; no native build, XCTest run, microphone access, upload, install or deployment was performed.
- Completion criteria remaining: build the app and use controlled overlapping Location and Health requests to expire the Location lease. Confirm Location cancels/falls back while Health completes normally; also check normal completion and caller cancellation.
- Rollback: revert this source/documentation change. No data migration or persisted-state change.
- Model/API review: no model, provider, endpoint, payload or dependency change in this patch; it uses the existing URLSession async API.

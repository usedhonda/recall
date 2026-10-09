# Handoff: Issue 10 remaining stop/finalization races

- Goal: finish the concrete lifecycle gaps after `6a0c984503d21803df2a1a5692e450cddad16691`.
- Scope: AudioRecordingEngine capture boundary, deterministic source-extracted fixture,
  existing ring snapshot/cursor tests, pipeline documentation.
- Status: draft review; no deployment, microphone access, private recordings or uploads.
- Latest developer work: local main and remote main were both `6a0c984`; no open PRs.
  Original checkout's untracked `.loop/` and active processes were preserved.
- Changes: invalidate/cancel old processing; wait for it before finalizing; wait for old
  finalization before new processing; post-await generation/state/cancellation guards;
  release stale reservations; drain/freeze accepted tail with the old tap rate; reset ring
  across interruption/restart. Keep existing empty/short/pending policy.
- Evidence method: `scripts/test-audio-stop-lifecycle.py` extracts actual lifecycle methods
  from the engine and compiles them with the production RingBuffer and inert controlled
  capacity/URL/VAD/writer dependencies. It tests Swift scheduling and buffer ownership,
  not AVFoundation encoding, microphone capture, model inference or delivery.
- Red evidence: the same fixture against `6a0c984` reports 7 failures, including late writer
  installation after stop and tail count 160000 instead of 161600. The finish gate permits
  multiple waiters so duplicate old finish calls fail deterministically without hanging.
- Green evidence: 12 lifecycle assertions + 6 existing ring-buffer XCTest cases; 10 seconds + 4800 accepted 48kHz samples becomes
  161600 samples at 16kHz exactly once, with new-rate restart audio excluded. Covers
  uncancelled stale VAD by generation, repeated stop, stop before task begins, writer finish
  during restart, interruption, and empty/0.25s/2s/4s policy.
- Gates: `scripts/check-contract.sh` PASS; `git diff --check` clean.
- Build: XcodeGen with empty ignored local overlay, local dependency copies, isolated
  derived data, signing disabled; iPhone 15 / iOS 17.5 simulator build succeeds.
- Remaining limits: no real-device runtime/encoding/delivery claim; owner scope forbids
  production app replacement. Review/merge and authorized device verification remain.
- Link: https://github.com/usedhonda/recall/issues/10

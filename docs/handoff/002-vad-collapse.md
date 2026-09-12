# Handoff: vad-collapse

- Goal / why: Owner observed "recording is ON but no audio reaches the server". Server ingest
  history (VoiceLog jobs, kana): detection normal after each launch, then collapsing within
  1-3 h (8/30 00-01h ~250/h -> 04h 4; 9/3 00-03h 110-180/h -> ~0; 9/11 16h 174 -> 17h 7).
- Scope: `recall/Core/Audio/VADService.swift`, `AudioRecordingEngine.processCurrentAudio`,
  watchdog log line, `docs/pipeline.md` §2.
- Explicitly out: thresholds (vadThreshold 0.25, RMS gate), chunk writing / upload / noise-skip
  rule, visible UI layout, server-side queue policy.
- Status: review — VAD fix b51b646 (2026-09-11 20:02 JST), chunk length 46af9dd and Control
  Center toggle cf8f06e (2026-09-12 16:08 / 16:11 JST) all deployed to kana. Long-run VAD
  check still pending: the owner stopped recording at 20:12 JST on 09-11, ten minutes after
  the fix, so only ~10 min of live recording has been observed.
- Done so far:
  - Root cause (code + library source): FluidAudio 0.12.6 Silero VAD expects 4096 contiguous
    samples (256 ms @ 16 kHz) per inference (`VadManager.swift:21-22`) and pads shorter input
    with the last sample (`:171-182`). recall streamed a 100 ms ring-buffer snapshot every
    100 ms tick into one recurrent state that was never reset (`VADService.reset()` had no
    call site). Every call = 100 ms audio + 156 ms flat padding; the state drifted.
  - Live repro 19:44 JST: owner spoke 10 s at the phone; one trigger, 2.5 s chunk with
    vad=0.03 mcv=0 vfr=0.00 -> "Skipped noise chunk" (never uploaded). Mic was fine
    (UI SYS.RMS 0.005-0.008 idle; iOS mic-in-use indicator = recall).
  - Fix: each tick evaluates the latest 256 ms window from a fresh state
    (`VADService.evaluate(window:)`); RMS on the newest 100 ms; watchdog line now logs
    `rms= nf= vad=` every 10 s.
  - After deploy (UDP mirror, 20:02-20:05 JST): continuous detection, chunks 49.6 s / 50.3 s /
    28.5 s with vad 0.30-0.40, vfr 0.51-0.71, all uploaded.
- Decisions: stateless 256 ms windows over true streaming (the 100 ms control loop, 3-frame
  guard and voice-island metrics stay in 100 ms units; overlapping windows cannot share one
  recurrent state).
- Rejected options: resetting the stream state periodically while keeping 100 ms padded
  input (keeps the contract violation).
- Commands run: simulator build OK; `scripts/check-contract.sh` PASS; `ios-build.sh device`
  deployed. `devicectl copy from` of the day log failed twice with "socket was closed
  unexpectedly" (kana on network CoreDevice, large file) -> used the macmini UDP mirror
  `~/logs/recall-udp/recall_2026-09-11.log` instead.
- Open issues / risks:
  - Morning of 9/11 the engine never started although the owner says the mic was ON in recall
    (app was never foreground before 17:28; start() never ran). Which control was used is still
    unanswered; both suspected mechanisms are fixed in cf8f06e (see follow-ups below).
  - 9/4-9/7 near-zero ingest while (probably) ON matches the same VAD collapse.
- 2026-09-12 follow-ups (owner: "make it the spec it should obviously be"):
  - `AppSettings.chunkDurationSeconds` is now a 30 s constant (46af9dd). kana held a stale
    stored 60 s, so chunks ran ~50 s once detection worked again; nothing writes the key.
  - Control Center toggle (cf8f06e): the Darwin observer moved from a SwiftUI `.task` to
    AppDelegate (process lifetime) against `RecordingViewModel.shared`, every outcome is
    logged (`External toggle: starting / stopping / ignored / no container`), and
    `isActive` is false when the engine is nil. Verified end to end without the owner:
    `xcrun devicectl device notification post --name com.example.recall.recordingStateChanged`
    produced `External toggle: ignored — already recording` at 16:11:19 JST.
- Next steps:
  1. >= 3 h after 20:02 JST, confirm detections continue: UDP mirror or device log, look at
     `WD ... vad=` values and `[#] Voice detected` / `Uploaded` counts per hour.
  2. Confirm a long speech now splits at 30 s (look for `Chunk duration limit — splitting`
     30 s after `New chunk`).
  3. The 9/11 morning start path stays unexplained; with cf8f06e a repeat would leave an
     `External toggle:` line in the activity log.
- Links: `docs/pipeline.md` §2, `docs/handoff/001-battery-cadence.md`.

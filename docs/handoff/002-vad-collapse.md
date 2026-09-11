# Handoff: vad-collapse

- Goal / why: Owner observed "recording is ON but no audio reaches the server". Server ingest
  history (VoiceLog jobs, kana): detection normal after each launch, then collapsing within
  1-3 h (8/30 00-01h ~250/h -> 04h 4; 9/3 00-03h 110-180/h -> ~0; 9/11 16h 174 -> 17h 7).
- Scope: `recall/Core/Audio/VADService.swift`, `AudioRecordingEngine.processCurrentAudio`,
  watchdog log line, `docs/pipeline.md` §2.
- Explicitly out: thresholds (vadThreshold 0.25, RMS gate), chunk writing / upload / noise-skip
  rule, UI, Control Center toggle path.
- Status: review — fix b51b646 deployed to kana 2026-09-11 20:02 JST; long-run check pending.
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
  - Separate, unresolved: morning of 9/11 the engine never started at all although the owner
    says the mic was ON in recall (app was never foreground before 17:28; start() never ran).
    Suspect the Control Center toggle path: `ToggleRecordingIntent` only writes an App Group
    flag + Darwin notification; the app's observer lives in a SwiftUI `.task`
    (`RecallApp.swift:40-43`) and `handleExternalToggle` logs only to os_log. Awaiting which
    control the owner used.
  - `RecordingViewModel.isActive` is `engine?.state != .idle` -> true when engine is nil.
  - 9/4-9/7 near-zero ingest while (probably) ON matches the same VAD collapse.
- Next steps:
  1. >= 3 h after 20:02 JST, confirm detections continue: UDP mirror or device log, look at
     `WD ... vad=` values and `[#] Voice detected` / `Uploaded` counts per hour.
  2. Resolve the morning start path once the owner answers.
- Links: `docs/pipeline.md` §2, `docs/handoff/001-battery-cadence.md`.

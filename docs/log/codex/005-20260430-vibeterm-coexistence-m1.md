# vibeterm coexistence M1 implementation

Task: `vibeterm-29625225-01`  
Date: 2026-04-30 JST  
Scope: one-line recall startup ordering fix + docs log. No build/install.

## Task Intent

Implement audit `docs/log/codex/004-20260430-vibeterm-coexistence-audit.md` M1 to reduce recall startup audible pop in vibeterm coexistence by removing the early keepalive player start before audio session activation.

## Change

Removed the early launch-task call:

```swift
BackgroundKeepAlive.shared.start()
```

from `recall/App/RecallApp.swift` immediately before the auto-start recording path.

## Rationale

Audit 004 identified the highest-risk startup ordering as:

1. `RecallApp.swift` started `BackgroundKeepAlive.shared.start()` first.
2. `BackgroundKeepAlive` created and played an `AVAudioPlayer` under the pre-config/default session state.
3. The same launch task immediately called `recordingViewModel.start(...)`.
4. `AudioRecordingEngine.start()` then configured `.playAndRecord` + `setActive(true)` and started the input engine.

That sequence can force player-start -> category promotion -> input graph start in rapid succession while vibeterm already owns a mixable playback graph. Removing the early keepalive start leaves the existing engine-owned call site intact: `AudioRecordingEngine.start()` starts keepalive only after session configuration, tap installation, and engine start.

## Scope Confirmation

Touched:

- `recall/App/RecallApp.swift`: removed early keepalive call and its now-stale comment.

Intentionally not touched:

- `recall/Core/Audio/BackgroundKeepAlive.swift`
- `recall/Core/Audio/AudioSessionManager.swift`
- `recall/Core/Audio/AudioRecordingEngine.swift`
- `recall/Features/Recording/RecordingViewModel.swift`
- watchdog / restart / audio tap / AVAudioSession options

## Expected Startup Flow After Change

```text
RecallApp .task
  -> RecordingStateManager.shared.isRecording = true
  -> await recordingViewModel.start(...)
     -> AudioRecordingEngine.start()
        -> AudioSessionManager.configure()
           -> setCategory(.playAndRecord, mode: .default, options: mix/defaultToSpeaker/A2DP)
           -> setActive(true)
        -> safeInstallTap(...)
        -> audioEngine.start()
        -> BackgroundKeepAlive.shared.start()
```

## Verification

Static verification only, per task constraint:

- Confirmed `RecallApp.swift` no longer starts `BackgroundKeepAlive` before recording startup.
- Confirmed existing keepalive call site remains in `AudioRecordingEngine.start()` by leaving that file untouched.
- Build/install intentionally not run; recall.cc owns runtime verification.

## Intent Drift Check

Pass. Implementation is limited to M1 one-line startup ordering fix plus this docs log.

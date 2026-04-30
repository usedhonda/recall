# vibeterm coexistence audit: recall startup audio pop

Task: `vibeterm-29625185-01`  
Date: 2026-04-30 JST  
Scope: read-only source audit. No code changes, no build, no install.

## Task Intent

Identify, at source level, how recall startup audio-session activation can create an audible pop in a vibeterm coexistence setup, and list recall-side mitigation candidates without implementing them.

## Executive Summary

The highest-risk source-level finding is launch ordering:

1. `RecallApp` starts `BackgroundKeepAlive.shared.start()` first.
2. `BackgroundKeepAlive` creates and starts an `AVAudioPlayer` silent WAV immediately.
3. Only after that does `recordingViewModel.start(...)` call `AudioRecordingEngine.start()`.
4. `AudioRecordingEngine.start()` calls `AudioSessionManager.configure()`.
5. `AudioSessionManager.configure()` changes the shared `AVAudioSession` to `.playAndRecord` with `[.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]`, then calls `setActive(true, options: [])`.
6. The engine then installs an input tap and starts `AVAudioEngine`, and finally calls `BackgroundKeepAlive.shared.start()` again.

That means recall launch can first start a playback object under the pre-existing/default session state, then immediately promote the process to `.playAndRecord` and open microphone input. In a coexistence environment where vibeterm is already running `.playback + .mixWithOthers` with active looping players, this is a plausible trigger for system mixer / HAL / route reconfiguration and an audible one-shot pop.

## Source-Level Facts

### 1. App launch entry points

| Fact | Source |
|---|---|
| `RecallApp` is the SwiftUI `@main` app. | `recall/App/RecallApp.swift:4-6` |
| `AppDelegate.didFinishLaunching` starts connectivity and HealthKit background delivery only; no `AVAudioSession` category/activation is called there. | `recall/App/AppDelegate.swift:7-18` |
| Main SwiftUI `.task` starts `BackgroundKeepAlive.shared.start()` before recording startup. | `recall/App/RecallApp.swift:23-29` |
| The same `.task` unconditionally sets `RecordingStateManager.shared.isRecording = true` and calls `await recordingViewModel.start(...)` on launch. | `recall/App/RecallApp.swift:27-29` |

Relevant snippet order:

```text
RecallApp.body WindowGroup.task
  line 25: BackgroundKeepAlive.shared.start()
  line 28: RecordingStateManager.shared.isRecording = true
  line 29: await recordingViewModel.start(modelContainer: sharedModelContainer)
```

### 2. Audio session activation path

| Fact | Source |
|---|---|
| `RecordingViewModel.start` creates `AudioRecordingEngine` if nil, then calls `try await engine?.start()`. | `recall/Features/Recording/RecordingViewModel.swift:131-140` |
| `AudioRecordingEngine.start` calls `try sessionManager.configure()` before VAD initialization, tap install, or engine start. | `recall/Core/Audio/AudioRecordingEngine.swift:138-147` |
| `AudioSessionManager.configure()` sets category `.playAndRecord`. | `recall/Core/Audio/AudioSessionManager.swift:36-47` |
| Mode is `.default`. | `recall/Core/Audio/AudioSessionManager.swift:43-46` |
| Default options are `.mixWithOthers`, `.defaultToSpeaker`, `.allowBluetoothA2DP`. | `recall/Core/Audio/AudioSessionManager.swift:36-39` |
| `.allowBluetooth` is added only when `desiredMicMode == .bluetoothHFP`. Default `desiredMicMode` is `.builtIn`. | `recall/Core/Audio/AudioSessionManager.swift:15`, `recall/Core/Audio/AudioSessionManager.swift:40-42` |
| iOS 17+ calls `setPrefersInterruptionOnRouteDisconnect(false)`. | `recall/Core/Audio/AudioSessionManager.swift:49-51` |
| Activation is `try session.setActive(true, options: [])`; no activation option such as `.notifyOthersOnDeactivation` is used on activation. | `recall/Core/Audio/AudioSessionManager.swift:53` |
| Deactivation, when used, calls `setActive(false, options: .notifyOthersOnDeactivation)`. | `recall/Core/Audio/AudioSessionManager.swift:68-70` |
| Interruption ended path may also call `setActive(true, options: [])`. | `recall/Core/Audio/AudioSessionManager.swift:142-145` |

### 3. BackgroundKeepAlive player path

| Fact | Source |
|---|---|
| `BackgroundKeepAlive` owns an `AVAudioPlayer?`. | `recall/Core/Audio/BackgroundKeepAlive.swift:14` |
| `start()` returns if a player is already playing. | `recall/Core/Audio/BackgroundKeepAlive.swift:27-31` |
| `start()` generates a silent WAV, creates `AVAudioPlayer(data:)`, sets infinite loop, sets `volume = 0.01`, then calls `p.play()`. | `recall/Core/Audio/BackgroundKeepAlive.swift:33-39` |
| Silent WAV is 1-second, 16 kHz, mono, 16-bit PCM, zero-filled. | `recall/Core/Audio/BackgroundKeepAlive.swift:78-110` |
| `BackgroundKeepAlive` intentionally does not set NowPlayingInfoCenter. | `recall/Core/Audio/BackgroundKeepAlive.swift:48-49` |
| `AudioRecordingEngine.start()` calls `BackgroundKeepAlive.shared.start()` again after `audioEngine.start()`, but this is guarded by `player?.isPlaying`. | `recall/Core/Audio/AudioRecordingEngine.swift:204-215`, `recall/Core/Audio/BackgroundKeepAlive.swift:27-31` |
| Watchdog resumes keepalive if it stops. | `recall/Core/Audio/AudioRecordingEngine.swift:307-311` |

### 4. AVAudioEngine launch path

| Fact | Source |
|---|---|
| `AudioRecordingEngine` owns one `AVAudioEngine`. | `recall/Core/Audio/AudioRecordingEngine.swift:42` |
| `start()` installs an input tap via `safeInstallTap(on:source:"start")`. | `recall/Core/Audio/AudioRecordingEngine.swift:180-185` |
| `start()` then calls `audioEngine.prepare()` and `try audioEngine.start()`. | `recall/Core/Audio/AudioRecordingEngine.swift:204-205` |
| After engine start, state becomes `.listening`, input route UID is captured, then keepalive starts/resumes. | `recall/Core/Audio/AudioRecordingEngine.swift:207-215` |
| Route changes restart the engine only when the input route UID changes, output-only changes are ignored. | `recall/Core/Audio/AudioRecordingEngine.swift:819-840` |
| Restart path calls `sessionManager.configure()` again, reinstalls tap, starts `AVAudioEngine`, then resumes keepalive. | `recall/Core/Audio/AudioRecordingEngine.swift:951-1000` |

### 5. Hardware route / preference operations

| Operation | Present? | Source |
|---|---:|---|
| `overrideOutputAudioPort(.speaker/.none)` | No occurrences found. | `rg overrideOutputAudioPort` returned no matches. |
| `setPreferredInput(...)` | Yes, only mic selection / music auto-switch paths. | `recall/Core/Audio/AudioSessionManager.swift:95-101`, `recall/Features/Recording/RecordingViewModel.swift:31-75`, `recall/Features/Recording/RecordingViewModel.swift:109-117` |
| `setPreferredSampleRate` | No occurrences found. | `rg setPreferredSampleRate` returned no matches. |
| `setPreferredIOBufferDuration` | No occurrences found. | `rg setPreferredIOBufferDuration` returned no matches. |
| `setCategory` | Yes, only `AudioSessionManager.configure()`. | `recall/Core/Audio/AudioSessionManager.swift:43-47` |
| `setActive(true)` | Yes, `configure()` and interruption-ended reactivation. | `recall/Core/Audio/AudioSessionManager.swift:53`, `recall/Core/Audio/AudioSessionManager.swift:142-145` |

### 6. Additional audio instances at launch

| Instance | Launch activity | Source |
|---|---|---|
| `AVAudioPlayer` keepalive | Yes. Started at `RecallApp` launch task before recording start. | `recall/App/RecallApp.swift:23-29`, `recall/Core/Audio/BackgroundKeepAlive.swift:33-39` |
| `AVAudioEngine` input tap | Yes. Started by auto-start recording path. | `recall/App/RecallApp.swift:27-29`, `recall/Core/Audio/AudioRecordingEngine.swift:138-215` |
| `NowPlayingManager` | Not part of immediate audio startup unless telemetry/settings later enables it; separate from keepalive. | `recall/Core/Telemetry/TelemetryService.swift:38-79`, `recall/Core/Media/NowPlayingManager.swift` |
| Notification/startup sound | No source-level evidence found. | `rg AVAudioPlayer/AVPlayer/play` only found keepalive path. |
| Microphone preview | No separate preview path found; microphone input is the production `AVAudioEngine` tap. | `recall/Core/Audio/AudioRecordingEngine.swift:180-205` |

## Launch Sequence Timing Diagram

Static source can prove ordering but not exact milliseconds. Typical elapsed time below is qualitative and should be treated as a hypothesis until instrumented.

```text
T0    process launch
      -> SwiftUI @main RecallApp constructed

T0+   AppDelegate.application(_:didFinishLaunching:)
      -> ConnectivityMonitor.shared.start()
      -> HealthKit background delivery setup
      -> no AVAudioSession category/active call
      Source: AppDelegate.swift:7-18

T1    WindowGroup .task begins
      -> BackgroundKeepAlive.shared.start()
      -> creates AVAudioPlayer(data: 16kHz mono silent WAV)
      -> p.volume = 0.01
      -> p.play()
      Source: RecallApp.swift:23-25, BackgroundKeepAlive.swift:33-39

T1+   same .task immediately auto-starts recording
      -> RecordingStateManager.shared.isRecording = true
      -> await recordingViewModel.start(...)
      Source: RecallApp.swift:27-29

T2    RecordingViewModel.start
      -> creates AudioRecordingEngine if nil
      -> try await engine.start()
      Source: RecordingViewModel.swift:131-140

T3    AudioRecordingEngine.start
      -> AudioSessionManager.configure()
      -> setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
      -> setActive(true, options: [])
      Source: AudioRecordingEngine.swift:145-147, AudioSessionManager.swift:36-53

T4    AudioRecordingEngine.start continued
      -> install input tap
      -> audioEngine.prepare()
      -> audioEngine.start()
      -> BackgroundKeepAlive.shared.start() again, usually no-op if already playing
      Source: AudioRecordingEngine.swift:180-215
```

Most relevant timing risk: T1 `AVAudioPlayer.play()` and T3 `setCategory(.playAndRecord)` / `setActive(true)` occur in the same launch task, with no intentional delay, backoff, or coexistence guard.

## Pop Mechanism Hypotheses

These are hypotheses, not proven runtime facts. User observation that a pop occurs on recall launch is treated as fact.

### H1: Category promotion after keepalive player start causes mixer/HAL reconfiguration

Evidence:

- Keepalive playback starts before recall configures `.playAndRecord`.
- Then recall changes category to `.playAndRecord` and activates session.
- vibeterm already has active playback players and `MPNowPlayingSession`.

Mechanism:

- recall starts an `AVAudioPlayer` under whatever session state exists before explicit category configuration.
- milliseconds later, recall promotes the process to `.playAndRecord`, opens input capability, sets default speaker/A2DP options, and activates.
- iOS may rebuild the mixed output graph or hardware I/O graph. A one-buffer discontinuity can be audible as a pop/click in another mixed app.

Confidence: high as a source-level candidate.

### H2: Opening microphone input via `.playAndRecord` + `AVAudioEngine.inputNode` forces hardware format/route negotiation

Evidence:

- `configure()` uses `.playAndRecord`; `AudioRecordingEngine.start()` immediately reads input format, installs tap, prepares, and starts engine.
- recall explicitly keeps `.mixWithOthers`, so it is not trying to interrupt vibeterm, but mixable sessions can still share hardware and trigger format negotiation.

Mechanism:

- vibeterm is output-only `.playback`; recall adds full-duplex input/output session.
- System may change I/O buffer duration, sample rate, route, or voice-processing graph internals even if category is mixable.
- That transition can create a short discontinuity in already-playing silent/near-silent loops.

Confidence: medium/high.

### H3: 16 kHz mono keepalive player itself contributes a resampler graph edge

Evidence:

- Keepalive WAV is 16 kHz mono PCM and volume 0.01.
- vibeterm keepalive stack reportedly uses 30 Hz silent WAV and another AVAudioPlayer.

Mechanism:

- Even though recall's WAV payload is zero-filled, creating/starting another low-rate player can add a new resampler/mixer input to the system graph.
- The zero samples mean waveform discontinuity is unlikely to be the direct source; graph start/reconfiguration is more plausible than sample content.

Confidence: medium.

### H4: Route preference flags interact with existing playback route

Evidence:

- recall options include `.defaultToSpeaker` and `.allowBluetoothA2DP`.
- No `overrideOutputAudioPort` exists, but `.defaultToSpeaker` still expresses route preference for `.playAndRecord`.

Mechanism:

- On launch, iOS may reconsider speaker/A2DP routing for recall's new full-duplex session while vibeterm owns playback.
- If Bluetooth/A2DP/speaker route is active, route graph renegotiation may be audible.

Confidence: medium.

## Mitigation Candidates (recall-side only, not implemented)

### M1. Configure audio session before starting `BackgroundKeepAlive`

Change candidate:

- Move `BackgroundKeepAlive.shared.start()` after `recordingViewModel.start(...)`, or remove the early call in `RecallApp` and rely on `AudioRecordingEngine.start()` line 215.

Why:

- Avoids `AVAudioPlayer.play()` under pre-configured/default session followed by immediate category promotion.
- Current engine path already starts keepalive after `audioEngine.start()`.

Tradeoff:

- If recording startup is slow due to VAD initialization, keepalive begins later.
- But during normal launch, always-on recording is the primary background ownership path anyway.

Risk: low/medium.

### M2. Delay full audio activation when another app is already playing

Change candidate:

- At launch, check `AVAudioSession.sharedInstance().isOtherAudioPlaying` before full recording activation.
- If true, delay `recordingViewModel.start(...)` by a short grace window or stage activation after UI/telemetry startup.

Why:

- Reduces chance of colliding with vibeterm's lock-screen ownership stack at exact launch boundary.

Tradeoff:

- Delays always-on recording by the grace interval.
- Must not violate recall's always-on recording requirement unless user/owner accepts that tradeoff.

Risk: product-sensitive.

### M3. Stage startup into one session transition

Change candidate:

- Explicitly configure `.playAndRecord` first, then start `AVAudioEngine`, then start keepalive once.
- Avoid multiple immediate audio graph mutations: player start -> category set -> active -> engine start -> player no-op.

Why:

- The current order has at least two graph-affecting actions before stable listening: keepalive player start, then category/activation/input engine start.

Tradeoff:

- Needs careful testing around background survival and prior retry-storm fixes.

Risk: medium.

### M4. Make keepalive even gentler

Change candidate:

- Use `volume = 0.0` if iOS still treats it as playback, or fade from 0.0 to 0.01 over several hundred ms.
- Keep first buffer zero-crossing / zero-filled.

Why:

- If any pop is caused by player graph insertion at nonzero output gain, reducing initial gain can help.

Tradeoff:

- iOS may treat zero-volume playback differently; must be verified.
- Since data is already zero-filled, this may not address the primary graph reconfiguration pop.

Risk: low for fade-in, unknown for permanent 0.0.

### M5. Consider `.measurement` mode only if VAD quality and coexistence improve

Change candidate:

- Test `.playAndRecord` mode `.measurement` instead of `.default`.

Why:

- Measurement mode can reduce voice-processing behavior and may be less invasive than voice-chat style processing.

Tradeoff:

- It may alter input behavior, echo cancellation expectations, route behavior, or background stability.
- Requires real-device validation with recall/vibeterm/Spotify.

Risk: medium.

### M6. Avoid `.defaultToSpeaker` unless needed

Change candidate:

- Evaluate removing `.defaultToSpeaker` for built-in mic mode if output routing should be left to system/vibeterm.

Why:

- recall is primarily recording; forcing speaker preference on a mixable full-duplex session may be unnecessary in coexistence.

Tradeoff:

- Could change recall output route expectations for keepalive or any future playback.

Risk: medium.

### M7. Instrument before and after each audio graph mutation

Change candidate:

- Log monotonic timestamps and `AVAudioSession` snapshots around:
  - `BackgroundKeepAlive.start()` before/after `p.play()`
  - `AudioSessionManager.configure()` before/after `setCategory` and `setActive`
  - `audioEngine.start()`

Why:

- Static source cannot provide millisecond deltas or prove which edge creates the pop.
- Current ActivityLogger already logs post-configure snapshot, but not pre-keepalive or per-step timing.

Tradeoff:

- Logging only; low behavioral risk.

Risk: low.

## Answers To Requested Scope

1. App launch AVAudioSession activation path:
   - No AVAudioSession activation in AppDelegate.
   - Activation occurs via `RecallApp.swift:29` -> `RecordingViewModel.swift:139` -> `AudioRecordingEngine.swift:146` -> `AudioSessionManager.swift:53`.
   - `BackgroundKeepAlive.start()` is called before this activation at `RecallApp.swift:25`.
   - Startup is unconditional in the `.task`: it always starts keepalive and auto-starts recording.

2. AVAudioSession config:
   - Category: `.playAndRecord`.
   - Mode: `.default`.
   - Options: `.mixWithOthers`, `.defaultToSpeaker`, `.allowBluetoothA2DP`; `.allowBluetooth` only for Bluetooth HFP mic mode.
   - Activation: `setActive(true, options: [])`; no `.notifyOthersOnDeactivation` on activation.
   - Deactivation: `.notifyOthersOnDeactivation` only in `deactivate()`.

3. Hardware route operations:
   - No `overrideOutputAudioPort` found.
   - `setPreferredInput` exists for mic switching and music auto-switch, not initial default launch unless saved preferred mic mode triggers restore.
   - No preferred sample rate or IO buffer duration calls found.

4. Additional audio instances:
   - Launch starts `AVAudioPlayer` keepalive and `AVAudioEngine` input tap.
   - No startup notification sound or separate mic preview found.
   - NowPlayingInfoCenter is intentionally not set by BackgroundKeepAlive.

5. Launch sequence timing:
   - Static ordering is proven; exact ms is not available from source.
   - Highest-risk adjacency is keepalive `p.play()` immediately followed by `.playAndRecord` category/activation and input engine start in the same SwiftUI launch task.

6. Mitigations:
   - Highest-value first candidate: remove/reorder the early `BackgroundKeepAlive.shared.start()` so session category/activation happens before any recall `AVAudioPlayer.play()`.
   - Next candidates: staged activation, short coexistence delay when `isOtherAudioPlaying`, keepalive fade-in, evaluate `.defaultToSpeaker` necessity, add timing instrumentation.

## Intent Drift Check

Pass. This audit is docs-only and source-level. No source code, build, install, or runtime state was changed.

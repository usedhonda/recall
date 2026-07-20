@AGENTS.md

# recall — CLAUDE.md

## Project Overview

**recall** is an always-on voice recording iOS app for lifelogging.

- Always-on recording — starts on app launch, continues in background
- Voice Activity Detection (VAD) — only saves segments with actual speech, skips silence
- Chunk-based upload — compressed audio chunks uploaded to Tailscale peers via HTTP

Concept: Rewind / Limitless style lifelogging. Record everything, keep only what matters.

## Language Policy

- Development conversation: Japanese
- UI / code / comments / docs: English

## Tech Stack

| Item | Choice |
|------|--------|
| Language | Swift |
| UI | SwiftUI |
| Min iOS | 17.0+ |
| Architecture | MVVM |
| Audio Recording | AVAudioEngine (realtime audio analysis for VAD) |
| Voice Detection | 2-stage VAD: RMS power gate + Silero VAD via FluidAudio (CoreML/ANE) |
| Data Storage | SwiftData (metadata) + FileManager (audio files) |
| Audio Format | AAC-LC (.m4a) — 16kHz / 32kbps / mono |
| Background | Background Modes (audio) + BGTaskScheduler |
| Network | URLSession / Network.framework |

## Architecture

```
┌─────────────────────────────────────────┐
│                   App                    │
├─────────────────────────────────────────┤
│  Features                               │
│  ├── Recording/   (record UI & control) │
│  ├── Upload/      (upload queue & status)│
│  └── Settings/    (thresholds, peers)   │
├─────────────────────────────────────────┤
│  Core                                   │
│  ├── Audio/    (AVAudioEngine, VAD)     │
│  ├── Upload/   (HTTP upload, retry)     │
│  ├── Storage/  (file & metadata mgmt)   │
│  └── Network/  (connectivity monitor)   │
├─────────────────────────────────────────┤
│  Models        (SwiftData entities)     │
└─────────────────────────────────────────┘
```

## Directory Structure

```
recall/
├── project.yml                # XcodeGen project spec
├── recall/
│   ├── App/                   # App entry point, lifecycle
│   ├── Features/
│   │   ├── Recording/         # Recording UI & view models
│   │   ├── Upload/            # Upload queue UI & view models
│   │   └── Settings/          # Settings UI & view models
│   ├── Core/
│   │   ├── Audio/             # AVAudioEngine, VAD, chunk writer
│   │   ├── Upload/            # HTTP upload manager, retry logic
│   │   ├── Storage/           # File management, cleanup
│   │   └── Network/           # NWPathMonitor, connectivity
│   ├── Models/                # SwiftData models
│   └── Resources/             # Assets, Info.plist
├── Tests/
└── docs/
```

## Coding Standards

- **Architecture**: MVVM — View ↔ ViewModel ↔ Service/Manager
- **Naming**: PascalCase (types), camelCase (properties/methods)
- **State**: `@Observable` macro for ViewModels
- **Views**: Keep views thin, logic in ViewModels
- **Concurrency**: Swift Concurrency (async/await, actors)

## Build

XcodeGen-based. Use `/ios-build` skill.

```bash
# Generate & build (simulator)
/ios-build

# Device build
/ios-build --device
```

Build config is stored in `.local/project.yml` (gitignored).

## Technical Notes

### Stream Independence Contract (BINDING — owner ruling 2026-07-20)

Every top-screen toggle (Audio / Location / Health / Glasses / Media) is an independent
stream, and each toggle is the SOLE authority over its own stream. Stopping one stream must
never stop, gate, defer, or degrade another. `userStopIntent` and `LaunchContext.shouldStaySilent`
belong to the recording lane only; location/health/media/glasses/upload code must never
reference them. Silent (background) launch suppresses recording auto-start only — all
independent streams start on every launch. Full contract, incident history, and review
checklist: `docs/stream-independence.md`. Changing this contract requires explicit owner
approval; never alter it as a side effect of another task.

### Operating Model: Always-On Recording

- App launch = recording starts. Runs until explicitly stopped.
- Microphone input is continuously monitored via AVAudioEngine tap.
- **Silent segments**: Not saved (saves disk & battery).
- **Voice segments**: Saved as chunk files → queued for upload.
- Pre/post margin (default 2s) ensures speech beginnings/endings are not clipped.

### VAD (Voice Activity Detection) — 2-Stage Design

Two-stage pipeline distinguishes human speech from environmental sounds (TV, music, traffic).

**Stage 1: RMS Power Gate (always-on, ultra-lightweight)**
- `AVAudioEngine.installTap` provides realtime audio power levels.
- RMS below threshold → immediate skip (no ML inference).
- Saves battery during silence (night, quiet rooms).

**Stage 2: Silero VAD via FluidAudio (CoreML/ANE)**
- Neural VAD classifies "human voice" vs "non-voice" (TV, music, ambient noise).
- FluidAudio: Silero VAD CoreML Swift Package (MIT, ~2MB).
- Runs on ANE (Apple Neural Engine) → near-zero CPU load.
- 256ms batch processing (8x32ms frames) for efficient inference.
- Designed for always-on workloads / ambient computing.
- iOS 17.0+ compatible.
- Precision: TPR 87.7% @ 5% FPR (far superior to RMS-only or WebRTC VAD).

**Ring Buffer Design**
- AVAudioEngine tap continuously writes to a 3-second ring buffer.
- Stage 2 detects voice → retrieve 2s of audio from ring buffer (pre-margin).
- Ensures conversation beginnings are never clipped.

**State Machine**
- `Listening` (silent) → Stage 1 passes → Stage 2 confirms voice → `Recording`
- `Recording` → silence for N seconds (default 3s) → `Listening`
- Voice start → begin file write (+ pre-margin from ring buffer).
- Voice end → end file write (+ post-margin).

### Background Operation (Critical Requirement)

- **Must record in both foreground and background continuously.**
- Background Modes: `audio` enabled in Info.plist (`UIBackgroundModes`).
- AVAudioSession category: `.playAndRecord`, options: `.defaultToSpeaker`, `.allowBluetooth`.
- `AVAudioSession.setActive(true)` on launch, maintained until explicit stop.
- Interruption handling: observe `AVAudioSession.interruptionNotification`, auto-resume after interruption ends.
- Lock screen recording guaranteed by `audio` background mode.
- Low battery option: reduce recording quality below 20%.

### Lock Screen / NowPlaying Prohibition (vibeterm Priority)

**recall must NEVER write to NowPlayingInfoCenter or register MPRemoteCommandCenter handlers.**

Same-device app vibeterm uses Live Activity on the lock screen for voice chat. iOS limits concurrent NowPlaying sessions, and recall occupying NowPlayingInfoCenter prevents vibeterm's Live Activity from appearing.

Prohibited:
- `MPNowPlayingInfoCenter.default().nowPlayingInfo = [...]` (setting info)
- `MPRemoteCommandCenter.shared().playCommand.addTarget` (registering handlers)
- Any code that makes recall appear as a "media player" on the lock screen or Control Center

Allowed:
- `MPNowPlayingInfoCenter.default().nowPlayingInfo = nil` (defensive cleanup on stop)
- `MPMusicPlayerController.systemMusicPlayer` read-only observation (for NowPlaying telemetry)
- Silent audio playback via AVAudioPlayer for background keep-alive (without NowPlaying registration)

Background survival must rely solely on `UIBackgroundModes: audio` + AVAudioEngine tap, not NowPlaying tricks.

### Power Efficiency

- AVAudioEngine tap is always active, but file I/O only during voice (VAD-gated).
- Minimize screen updates during recording.
- Stop all UI updates when backgrounded.
- Upload only on WiFi (avoid cellular drain).

### Audio Compression

Voice-only content allows aggressive compression:

- **Format**: AAC-LC (.m4a) — hardware encoder, power-efficient
- **Sample rate**: 16kHz (sufficient for voice, ~1/3 size of 44.1kHz)
- **Bitrate**: 32kbps
- **Channels**: Mono
- **Result**: ~1.4MB/5min, ~17MB/hour
- Future candidate: Opus (higher compression, but no native iOS support)

### Chunk Management

- Configurable interval (default 5 min) splits audio into chunk files.
- Filename format: `YYYYMMDD_HHmmss.m4a`
- Double-buffering to minimize gaps during chunk transitions.

### Upload Design

- **WiFi only**: Default — uses `NWPathMonitor` to detect connectivity.
- **Target**: Tailscale peer via HTTP POST.
- **Retry**: Exponential backoff on failure, managed via upload queue.
- **Concurrency**: Max 1 parallel upload (default). Background: `URLSession` background transfer.
- **Order**: Timestamp-ordered upload.

### Storage Management

- Auto-delete local files after successful upload.
- Storage cap (default 1GB) — oldest files deleted first on overflow.
- Upload-pending files are protected from cleanup.

### Privacy & Permissions

- `NSMicrophoneUsageDescription` required.
- iOS system recording indicator (orange dot) is always visible during recording.
- Local network permission required for Tailscale peer connections.

### Multilingual Support

- STT handled server-side by faster-whisper — natively supports 99 languages including Japanese and English.
- VoiceLog server uses `language: auto` — automatic language detection per segment.
- Handles Japanese-English mixed conversations (Japanese base with English technical terms).
- recall iOS is language-agnostic — sends raw audio without language metadata.

### Voice Pipeline (End-to-End)

```
iOS (recall)          VoiceLog (Mac mini :8300)         Gateway (OpenClaw :18789)
─────────────         ──────────────────────            ──────────────────────────
AVAudioEngine tap     POST /ingest                      POST /api/voice-transcript
  ↓                     ↓                                 ↓
RMS gate (adaptive)   Save to inbox                     shouldCommentNow() scoring
  ↓                     ↓                                 ↓
Silero VAD (ANE)      Worker picks up                   score >= threshold
  ↓                   ├─ normalize (ffmpeg)                ↓
3-frame guard         ├─ STT (faster-whisper small)     subagent.run (voice-react)
  ↓                   ├─ diarize (pyannote 3.1)           ↓
Chunk finalize        ├─ speaker ID (optional)          LINE / Vibeterm delivery
  ↓                   └─ store (SQLite + FTS5)
Voice island filter     ↓
  ↓                   POST transcript → Gateway
Upload (HTTP)
```

### Chunk Strategy

- Conversation-segment based: 1.5s silence ends chunk, 30s max forced split.
- No user-facing settings — fully automatic.
- Pre-margin 3s (RingBuffer lookback); chunk end is governed by the 1.5s silence timeout (no separate post-margin setting).
- 3-frame consecutive guard: VAD must pass 3 consecutive frames (300ms) to start recording.

### Upload Filter (iOS)

- Voice island metrics computed per chunk (zero additional cost):
  - `maxContinuousVoiceMs`: longest continuous voice run (with 300ms gap fill)
  - `voiceFrameRatio`: voice frames / total frames
- Drop condition: MCV < 200ms AND VFR < 5% (both must be true).
- Everything else is uploaded (false negative avoidance is priority).

### Upload Metadata

| Field | Purpose |
|-------|---------|
| `device_id`, `started_at`, `timezone` | Basic identification |
| `avg_rms`, `vad_avg_prob`, `noise_floor_rms` | Audio quality metrics |
| `is_speech: "true"` | Server VAD skip hint |
| `chunk_start_utc` | Absolute timestamp for offset calculation |
| `language: "ja"` | Language detection skip hint |

### Server Processing (VoiceLog)

- `/ingest` always accepts (never returns 429).
- Newest-wins eviction: MAX_INBOX_WAITING=1, QUEUED >300s → EXPIRED.
- Merge: same device_id jobs within 10s are ffmpeg-concatenated before processing.
- Worker: 5s poll interval, ~30s per job (STT + diarization on CPU).
- Realtime principle: if processing can't keep up, old chunks are dropped.
- VoiceLog project: ~/projects/Mac/voicelog/ (independent service on Mac mini).
- No TLS required (Tailscale WireGuard encryption).

### Reaction Pipeline (Gateway)

- voice-transcript handler receives STT results from VoiceLog.
- `shouldCommentNow()`: warmup 5 entries → score-based decision.
  - Minimum interval: 60s between reactions.
  - Scoring signals: lexical_novelty, question_or_decision, etc.
- `subagent.run(voice-react)` → LINE + Vibeterm delivery.
- All STT results accumulate in DB; reactions reference the full context when triggered.
- Transcripts are never discarded — only upload chunks may be dropped by eviction.

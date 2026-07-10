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

### Server Integration (VoiceLog)

- recall uploads audio chunks via HTTP POST to VoiceLog server on Mac mini (Tailscale peer).
- Endpoint: `POST /ingest` (multipart/form-data).
- Payload: audio file (.m4a) + metadata JSON (device_id, started_at, timezone).
- Response: `{ "recording_id": "..." }`.
- Health check: `GET /health`.
- No TLS required (Tailscale WireGuard encryption).
- VoiceLog project: ~/projects/Mac/voicelog/ (independent service).
- VoiceLog processes: STT (faster-whisper) + speaker diarization + speaker ID.
- Output: searchable text in SQLite + FTS5.

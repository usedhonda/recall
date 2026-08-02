# recall — Capture & Delivery Pipeline (reference)

Read this before touching capture, upload, or server-contract code. Facts here are
code-verified; update this doc in the same change that alters them.

## 1. End-to-end diagram

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

## 2. Capture & VAD detail

**Operating model — always-on.** App launch starts recording; it runs until explicitly
stopped. The microphone is continuously monitored via an `AVAudioEngine` tap. Silent
segments are not saved (saves disk and battery); voice segments are saved as chunk files
and queued for upload.

**Two-stage VAD** distinguishes human speech from environmental sound (TV, music, traffic):

- **Stage 1 — RMS power gate (always-on, ultra-lightweight).** The `AVAudioEngine.installTap`
  provides realtime power levels. RMS below the (adaptive, noise-floor-tracking) threshold is
  skipped immediately with no ML inference — this is what saves battery during silence.
- **Stage 2 — Silero VAD via FluidAudio (CoreML / ANE).** Neural VAD classifies "human voice"
  vs "non-voice". FluidAudio is the Silero VAD CoreML Swift package (MIT, ~2 MB), pinned to
  exactly 0.12.6. It runs on the Apple Neural Engine (near-zero CPU), processes 256 ms batches
  (8×32 ms frames), and is designed for always-on / ambient workloads. iOS 17.0+.
  Precision: TPR 87.7% @ 5% FPR (far superior to RMS-only or WebRTC VAD).

**Ring buffer.** The tap continuously writes to a 3-second ring buffer. When Stage 2 confirms
voice, the pre-margin (3 s) is retrieved from the ring buffer so conversation beginnings are
never clipped.

**3-frame consecutive guard.** VAD must pass 3 consecutive frames (300 ms) before recording
starts — this rejects transient noise spikes.

**State machine.**
- `Listening` (silent) → Stage 1 passes → Stage 2 confirms voice → `Recording`.
- `Recording` → silence for the timeout → `Listening`.
- Voice start begins file write (+ 3 s pre-margin from the ring buffer); voice end finalizes
  the chunk (governed by the 1.5 s silence timeout — there is no separate post-margin setting).

**Audio format (code is truth).** Opus in a `.caf` container — 48 kbps, 16 kHz, mono.
16 kHz is sufficient for voice; Opus at 48 kbps keeps voice-only content small. (Source:
`recall/Core/Audio/ChunkWriter.swift`.)

**Background operation.** Recording must continue in both foreground and background.
`UIBackgroundModes: audio` is enabled in Info.plist. The `AVAudioSession` category is
`.playAndRecord` with options `[.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]`;
`.allowBluetooth` (HFP) is inserted only when the user selects HFP mic mode — HFP forces
16 kHz mono system-wide and degrades other apps' audio, so it is opt-in. The session is
activated on launch and held until an explicit stop. Interruptions are observed via
`AVAudioSession.interruptionNotification` and auto-resumed when the interruption ends.
Lock-screen recording is guaranteed by the `audio` background mode — not by any NowPlaying
trick (see `docs/stream-independence.md` and AGENTS.md §5 for the NowPlaying prohibition).

## 3. Chunking & upload filter

**Chunking (fully automatic, no user-facing settings).** Conversation-segment based:
a 1.5 s silence gap ends the current chunk; a 30 s maximum forces a split. Each chunk carries
its 3 s pre-margin (ring-buffer lookback). Filename format: `yyyyMMdd_HHmmss.caf`.

**Upload filter (iOS).** Voice-island metrics are computed per chunk at zero extra cost:
- `maxContinuousVoiceMs` (MCV): longest continuous voice run, with 300 ms gap fill.
- `voiceFrameRatio` (VFR): voice frames / total frames.

Drop condition: `MCV < 200ms AND VFR < 5%` (both must be true). Everything else is uploaded —
avoiding false negatives is the priority.

**Upload transport.**
- WiFi only by default (`NWPathMonitor` detects connectivity) — avoids cellular drain.
- Target: a Tailscale peer via HTTP POST (no TLS; WireGuard already encrypts).
- Retry: exponential backoff on failure, managed by the upload queue.
- Concurrency: max 1 parallel upload; background transfers via `URLSession`.
- Order: timestamp-ordered.
- Storage: local files auto-delete after successful upload; a storage cap (default 1 GB)
  deletes oldest first on overflow; upload-pending files are protected from cleanup.
- Stopping recording does not stop the upload queue: chunks already recorded keep draining.

## 4. Upload metadata

| Field | Purpose |
|-------|---------|
| `device_id`, `started_at`, `timezone` | Basic identification |
| `avg_rms`, `vad_avg_prob`, `noise_floor_rms` | Audio quality metrics |
| `is_speech: "true"` | Server VAD skip hint |
| `chunk_start_utc` | Absolute timestamp for offset calculation |
| `language: "ja"` | Language detection skip hint |

recall itself is language-agnostic — it sends raw audio; server-side STT (faster-whisper)
natively supports 99 languages and VoiceLog runs `language: auto`, so Japanese-English mixed
conversations are handled without per-segment language metadata from the client.

## 5. VoiceLog contract (Mac mini)

recall uploads audio chunks to the VoiceLog server on the Mac mini (Tailscale peer).
VoiceLog is an independent service at `~/projects/Mac/voicelog/`.

**Endpoint.** `POST /ingest` (multipart/form-data): the `.caf` audio file plus the metadata
JSON above (`device_id`, `started_at`, `timezone`, …). Health check: `GET /health`.
No TLS required (Tailscale WireGuard encryption).

**Intake and backpressure.**
- `/ingest` always accepts — it never returns 429.
- Newest-wins eviction: `MAX_INBOX_WAITING=1`; a job `QUEUED` for >300 s becomes `EXPIRED`.
- Merge: same-`device_id` jobs within 10 s are ffmpeg-concatenated before processing.
- Worker: 5 s poll interval, ~30 s per job (STT + diarization on CPU).
- Realtime principle: if processing can't keep up, old chunks are dropped rather than queued.
  (Do not try to fix this backpressure client-side — dropping is by design.)

**Processing pipeline.** normalize (ffmpeg) → STT (faster-whisper small) → diarize
(pyannote 3.1) → optional speaker ID → store as searchable text in SQLite + FTS5. VoiceLog
then POSTs the transcript to the Gateway.

## 6. Gateway reaction pipeline (OpenClaw)

- The `voice-transcript` handler receives STT results from VoiceLog at
  `POST /api/voice-transcript`.
- `shouldCommentNow()`: warmup 5 entries, then a score-based decision.
  - Minimum interval: 60 s between reactions.
  - Scoring signals: `lexical_novelty`, `question_or_decision`, etc.
- On `score >= threshold`: `subagent.run(voice-react)` → LINE + Vibeterm delivery.
- All STT results accumulate in the DB; reactions reference the full context when triggered.
- Transcripts are never discarded — only upload chunks may be dropped by eviction.

## 7. Channel-status heartbeat

recall reports per-channel on/off state (no coordinates, no health values) so the server can
tell "intentionally off" from "broken". Full server contract and send policy:
`docs/stream-independence.md` §Channel-status heartbeat.

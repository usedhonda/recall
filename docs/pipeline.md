# recall — Capture & Delivery Pipeline (reference)

Read this before touching capture, upload, or server-contract code. Facts here are
code-verified; update this doc in the same change that alters them.

## 1. End-to-end diagram

```text
Recall audio -> VoiceLog /ingest -> processing -> recordings / originals
                                  -> Gateway /api/voice-transcript -> consumers
Recall telemetry -> Gateway /api/telemetry -> materialized state -> consumers
VoiceLog recordings / originals --5-minute mirror--> Personal Data Hub
Gateway materialized state      --60-second mirror--> Personal Data Hub
Personal Data Hub -> scoped, read-only MCP readers
```

**Snapshot verified 2026-10-02.** Hub is an independent append-only store, not a
replacement Recall upload endpoint. Existing Gateway/VoiceLog producer routes remain
in service until each route passes live cutover acceptance. State snapshots are not a
complete raw telemetry ledger. Existing consumer delivery remains a separate check.
See oc-general's `docs/contracts/personal-realtime-data.md` for the server-owned contract.

## 2. Capture & VAD detail

**Operating model — always-on.** App launch starts recording; it runs until explicitly
stopped. The microphone is continuously monitored via an `AVAudioEngine` tap. Silent
segments are not saved (saves disk and battery); voice segments are saved as chunk files
and queued for upload.

**Capture gate and streaming VAD.** RMS uses an adaptive noise floor to decide
whether speech may open a chunk. Quiet frames still reach Silero so it can recognize
speech endings. `VADService.feed` consumes contiguous, non-overlapping windows with
recurrent state carried forward and uses FluidAudio's speech-start/end events. State
resets when capture stops/restarts. The overlapping fresh-state detector described in
older versions of this document was replaced in September; do not restore it.
FluidAudio remains pinned to 0.12.6.

**Ring buffer.** The tap continuously writes to a 3-second ring buffer. When Stage 2 confirms
voice, the pre-margin (3 s) is retrieved from the ring buffer so conversation beginnings are
never clipped.

**State machine.** Speech-start or an above-threshold probability may pass the
power gate; speech-end does not. Three consecutive passing inference results are
required to open a chunk. Do not infer a fixed 300 ms from the old tick-based comment:
streaming results come from complete model windows. Silence closes the chunk using
the timeout below, retaining the 3-second pre-margin.

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
Background survival relies on the `audio` background mode and active tap, not any NowPlaying
trick; interruptions can still block capture (see `docs/stream-independence.md` and AGENTS.md §5 for the NowPlaying prohibition).

## 3. Chunking & upload filter

**Chunking (fully automatic, no user-facing settings).** Conversation-segment based:
a 1.5 s silence gap ends the current chunk; a 30 s maximum forces a split. Each chunk carries
its 3 s pre-margin (ring-buffer lookback). Filename format: `yyyyMMdd_HHmmss.caf`.

**Upload filter (iOS).** Voice-island metrics are computed per chunk at zero extra cost:
- `maxContinuousVoiceMs` (MCV): longest continuous voice run, with 300 ms gap fill.
- `voiceFrameRatio` (VFR): voice frames / total frames.

Silence drop condition: `maxVadProb < 0.30 AND MCV < 200ms AND VFR < 5%`.
Chunks shorter than 1 second and zero-byte files are also skipped. These existing
filters are unchanged by the upload-outcome accounting fix.

**Upload transport.**
- WiFi only by default (`NWPathMonitor` detects connectivity) — avoids cellular drain.
- Target: a Tailscale peer via HTTP POST (no TLS; WireGuard already encrypts).
- Retry: exponential backoff on failure, managed by the upload queue.
- Concurrency: one active queue upload using a foreground `URLSession`; legacy background completion reconciliation remains.
- Order: timestamp-ordered.
- Storage: local files auto-delete after successful upload; a storage cap (default 1 GB)
  deletes oldest terminal records first on overflow. Pending files are excluded from cap
  cleanup but are still subject to the separate 10-minute expiry rule.
- Stopping recording does not stop the upload queue: chunks already recorded keep draining.

### Outcome accounting

- `uploaded` / `uploadedAt`: successful upload response only; this is not proof of
  downstream original storage, transcription, Hub commit, or consumer delivery.
- `discarded`: terminal non-upload result. Optional `discardReasonRaw` distinguishes
  `short`, `noise`, `empty`, `expired`, and `retry_exhausted`; `uploadedAt` is nil.
- Existing pending/failed chunks expire after 600 seconds measured from `startedAt`.
  Automatic retry stops at 10 attempts. These policies and file-deletion timing are unchanged.
- Discarded rows do not count as successful, pending, or retryable failed uploads.
  Capacity cleanup includes both uploaded and discarded terminal rows.
- Existing rows keep their status. Historical `uploaded` counts may include former
  skips; no retrospective reclassification is justified without individual evidence.
  The accounting boundary is the deployment of this change, not the date of a recording.

## 4. Upload metadata

| Field | Purpose |
|-------|---------|
| `device_id`, `started_at`, `timezone` | Basic identification |
| `avg_rms`, `vad_avg_prob`, `noise_floor_rms` | Audio quality metrics |
| `is_speech` | Measured sustained-voice hint (`true` or `false`), not a server-gate bypass guarantee |
| `chunk_start_utc` | Absolute timestamp for offset calculation |
| `language: "ja"` | Language detection skip hint |

The client sends audio and a Japanese language hint. Active ASR engine/language
policy belongs to VoiceLog; do not infer it from this client's defaults.

## 5. VoiceLog contract (Mac mini)

The independent Hub producer foundation, opt-in runtime adapters, private
provisioning and remaining acceptance boundaries are documented in
[hub-producer.md](hub-producer.md). Audio release requires matching storage and
durable Hub STT intent receipts. Existing routes below remain the reaction owners
until per-route consumer evidence authorizes their synchronized cutover.

recall uploads audio chunks to the VoiceLog server on the Mac mini (Tailscale peer).
VoiceLog is an independent service at `~/projects/Mac/voicelog/`.

**Endpoint.** `POST /ingest` (multipart/form-data): the `.caf` audio file plus the metadata
JSON above (`device_id`, `started_at`, `timezone`, …). Health check: `GET /health`.
No TLS required (Tailscale WireGuard encryption).

**Intake is not durable archive acceptance.** The endpoint returns a recording ID
after inbox/job creation. Queue expiry/eviction can follow the successful response.
The client currently deletes its file after that response. Do not equate this with a
recording row or preserved original, and do not change queue policy as part of accounting.

**Server snapshot, 2026-10-02:** the live checkout includes the pre-STT Silero gate;
the configuration loader selects `faster-whisper`, no shadow engine, VAD gate enabled
(minimum speech ratio 0.05), `max_queued=3`, queue age 300 seconds, and a 5-second merge
window. Contemporary worker logs also identify `faster-whisper`. These are dated
observations, not client-side constants or a claim that on-disk settings always equal
an already-running process's loaded settings.

Processing: normalize -> VAD gate -> diarize -> transcribe -> speaker identification
-> store -> optional shadow transcription. No-speech jobs retain a recording row but
skip transcription and webhook. Secondary merged jobs need correlation to their primary:
a missing secondary row is not by itself lost speech, but the primary's archived original
must not be assumed to contain every secondary input byte.

**Hub mirror.** VoiceLog originals and transcript revisions are mirrored every five
minutes over a rolling 30-day window. Existing originals only; missing bytes are not
reconstructed. Current imports explicitly mark recording capture time as unknown where
only DB creation time is available. Default Hub retention for audio/health is 30 days;
GPS/status need an explicit per-kind policy before cutover. Hub deletion does not delete
source stores. Preserve these boundaries until a separately approved policy change.

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

## 8. Stream cadences (battery budget)

**Location cadence tiers** (`LocationCadencePolicy`, decided per accepted fix):

| Tier | Entered when | Sends | GPS |
|---|---|---|---|
| `fast` | fix speed >= 5 m/s (18 km/h) — GPS speed alone, motion is not consulted | every 30 s | continuous, no distance filter |
| `walking` | motion activity says walking/running/cycling/automotive, or speed >= 0.7 m/s, or within 120 s of the last movement | on >= 20 m displacement, else 300 s | continuous, no distance filter |
| `parked` | motion says stationary and no movement for 120 s | 300 s heartbeat, each one also opening a 30 s window for one fresh fix | updates keep running at `kCLLocationAccuracyHundredMeters` / 100 m filter (Wi-Fi + cell, GPS chip mostly idle); **the 30 s probe drops both the accuracy and the distance filter** |

Leaving the parked circle is reported as a crossing with the anchor name `parked`. The
configured anchors are places the owner set up; the parked circle is wherever the phone came
to rest, so it is the only crossing that fires away from them — measured 2026-09-13, the
Tokyo anchors never fire at the owner's Singapore home.

**A stationary phone needs the distance filter off, not just a better accuracy.** It never
travels 100 m, so iOS delivers nothing and the probe returns no fix: the position being
re-sent ages without bound. Measured 2026-09-12: the last accepted fix was 20:08:44Z, every
later heartbeat re-sent it, and the server saw the fix age climb to 371 min. The payload
`timestamp` is the fix's own time, so an ageing fix says nothing about whether the app is
still alive — liveness belongs to the receive time, on the server side.

**Never stop location updates to save power.** Stopping them ends the location background
session; with audio off, iOS then suspends the app and every stream stops with it — measured
2026-09-13: the parked tier turned updates off at 00:08 and the app went silent for 23 min
(no heartbeat, no health, no uploads). Park by lowering accuracy and widening the distance
filter instead.

Motion comes from `MotionActivityMonitor` (CMMotionActivity — the same always-on
coprocessor that counts steps), with a parked-only accelerometer shake watch.
When motion is unavailable or the owner declines the permission, `isMoving` stays true, so
the lane behaves exactly as before (never parks on motion alone).


Independent streams keep running while recording is off, so each one must keep its own
steady-state cost low. Values verified in code (2026-09-11):

| Stream | Cadence | Where |
|---|---|---|
| Health queries | HKObserverQuery wake (60 s debounce) + 15 min supplementary poll; skipped while the device is locked, one catch-up run on unlock | `HealthKitManager` |
| Health POST | Only when snapshot content changes; an unchanged snapshot is re-sent after 40 min (effective ~45 min with the poll) | `HealthKitManager` |
| Location POST | Immediately on >= 20 m displacement from the last sent fix; stationary every 300 s (payload carries the fix's own timestamp) | `LocationManager` |
| Location capture accuracy | Best while moving/probing; HundredMeters while parked with a valid fix. Acceptance filter stays FG 100 m / BG 200 m | `LocationManager` |
| Upload queue (idle) | Sleeps until a chunk is saved or the network changes; 60 s fallback | `UploadManager` |
| Server probe | Foreground 60 s / background 300 s; network-change probes coalesced to >= 30 s apart | `ServerHealthMonitor` |
| Activity log file | Buffered; flushed every 2 s, at 16 KB, immediately on `.error`, and on day rollover | `ActivityLogger` |
| Channel status | On every edge + hourly while any channel is gated | `ChannelStatusReporter` |

Server-side limits (oc-general, 2026-09-11) — do not lengthen past these:
- Location: the smallest gap threshold is 10 min (stationary-cluster continuity), so the
  stationary cadence must stay <= 5 min.
- Health: the PCE viewer marks health stale when the last received POST is > 60 min old, so
  the unchanged-snapshot keepalive must stay under 60 min.

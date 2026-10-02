# Audio source payload and clock provenance

Code snapshot: Recall `1159b99`. The Hub foundation `945a04b` implements generic
envelope/receipt/outbox/transport primitives, not an adopted audio field partition
or runtime producer adapter. The following separates current code from a proposed
partition. It is not audio route acceptance or an A/B release decision.

## Current multipart fields

`recall/Core/Upload/UploadManager.swift`, `uploadChunk`, constructs a
`[String: String]` on every attempt. Preserve these source types unless a separately
versioned adapter contract explicitly defines a conversion.

| Fields | Current origin | Archival limitation |
| --- | --- | --- |
| `started_at`, `chunk_start_utc` | `AudioChunk.startedAt`, ISO8601 at second precision | Same source clock; not independently measured first-sample capture time |
| `avg_rms`, `vad_avg_prob`, `noise_floor_rms` | Persisted chunk fields, emitted only when positive | Missing is not a measured zero |
| `max_continuous_voice_ms`, `voice_frame_ratio`, `max_vad_prob` | Persisted chunk fields | Preserve source values and detector provenance |
| `is_speech` | `maxContinuousVoiceMs >= 300 && voiceFrameRatio >= 0.10` | Derived server hint, not independent speech ground truth |
| `device_id` | Current settings at upload attempt | Must be frozen for canonical identity before retry |
| `timezone` | Current timezone at upload attempt | Not necessarily recording-time timezone |
| `language` | Fixed ASR hint `ja` | Processing instruction |
| `reaction_mode` | Current settings at upload attempt | Mutable processing command |
| `latitude`, `longitude`, `location_accuracy` | Current location at upload attempt | Not necessarily recording-time position; changes across retries |

The current multipart wire does not include `AudioChunk.id`, `duration`, or a
capture-end field. The persisted UUID is available for a future immutable source
identity but has not been connected to this legacy wire.

## Start and duration are not a complete capture interval

`AudioRecordingEngine.startNewChunk` chooses
`effectiveStart = pendingChunkStartedAt ?? Date()` and saves that as the chunk
start. It then prepends a pending buffer, when present, and a ring-buffer
pre-margin. Therefore the ordinary `Date()` is a chunk-start wall-clock reading,
not the measured wall-clock time of the first prepended sample.

Short chunks can be retained in `pendingSegmentBuffer` and concatenated with a
later chunk. The implementation does not retain per-sample wall-clock spans,
continuity, gaps, or overlaps. `writeCurrentAudioToChunk` reads recent analysis
windows rather than persisting a capture-clock mapping for their sample ranges.

`ChunkWriter.appendSamples` increments `samplesWritten` after successful writes.
`finish` returns `duration = samplesWritten / sampleRate`; `saveChunkRecord`
persists that duration and the earlier start. This is written sample duration,
not measured wall-clock elapsed time. `startedAt + duration` cannot establish
actual capture end, particularly across pre-margin or pending concatenation.

There is no independent capture-end field in `AudioChunk` or the current wire.
Recall does not observe ASR completion. `createdAt`, `uploadedAt`, VoiceLog DB
creation time, and Hub receipt time must not substitute for capture end or
authorize a fresh-conversation notification. Any future clock estimate needs
an explicit basis, uncertainty/unknown state, and processing-owner acceptance.

## Proposed partition — not yet implemented

- Freeze persisted chunk observations, canonical identity, bytes, and complete
  envelope before first admission; retries must not reread mutable settings.
- Keep `language` and `reaction_mode` in the separate processing ledger.
- Treat `is_speech` as a versioned derived hint with its input provenance, or
  calculate it in the processor; do not promote it into a direct observation.
- Do not label upload-time timezone/location as recording-time observation.
  If retained, freeze the initial value with its actual acquisition basis and
  clock; do not invent a historical measurement timestamp.
- Do not invent capture-end values for existing chunks. Establish sample-span
  provenance before making a new capture-clock guarantee.

The current Hub decision authority is `docs/contracts/audio-dispatch-boundary.md`
in its repository (owner-reported commit `437284e`); its producer profile is
`docs/contracts/recall-producer-v1.md`. The VoiceLog integration owner has now
acknowledged API/queue/worker/dispatch-ledger responsibility. That ownership
acknowledgement does not prove a processing inbox, complete merge-parent linkage,
capture clocks, or a deployed handoff. Existing release/delivery behavior remains.

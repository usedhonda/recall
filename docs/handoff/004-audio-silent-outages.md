# Handoff: audio-silent-outages

- Goal / why: recall records everything the owner says so Chi can remember the day. On
  2026-09-17 three stretches were found where recording stopped **without anyone being able
  to see it** (one of them possibly deliberate) — the app stays alive, telemetry keeps flowing, and only the audio is gone.
- Scope: recording engine start/stop paths, audio session recovery, telemetry fields.
- Status: diagnosed. Nothing implemented yet — **waiting for the owner's GO** on the state
  signal and on the Audio tile behaviour. oc-general has agreed the receiving side.

## Stretch 1 — recording stopped from the Audio tile, then off for ~77 h

**Not necessarily a fault.** The owner stops recording themselves at times, for battery
(2026-09-17). The log proves which control stopped it, never why. An earlier version of this
note called these mis-taps; that was an assumption and it is withdrawn.

What is established: opening the app auto-starts recording, and within 1-3 seconds the Audio
tile stopped it.

| when (UTC) | foreground + auto-start | stop |
|---|---|---|
| 09-13 09:54:56 | yes | 09:54:58 `Engine stopped (user)` |
| 09-15 04:19:35 | yes | 04:19:38 `Engine stopped (user)` |
| 09-16 06:23:58 | yes | 06:23:59 stopped, 06:24:00 restarted and stayed |

Why the tile, not Control Center: `Engine stopped (user)` has exactly two callers, and the
Control Center path (`handleExternalToggle`) always logs `External toggle: stopping
recording` first. That line is absent; the only other caller is the tile
(`RecordingView.swift`, `viewModel.stop()`).

Server side agrees (oc-general): 09-13T01Z to 09-16T06Z, no POST /ingest at all, while the
5-minute HEAD /ingest kept arriving — app alive, recording off.

Still worth knowing: opening the app already starts recording, so "open the app and turn
recording back on" asks for a tap that stops it. If recording needs to come back, bringing the
app to the front is enough.

## Hole 2 — another app takes the audio session and recall cannot take it back

`Interruption — pausing`, then `resume blocked — cannotInterruptOthers (bg)` on every retry
until the owner brings recall to the front. During both episodes iOS reported other audio
playing on nearly every attempt (09-17: 27 of 29; 09-13: 11 of 12), and on 09-17 the
interruption ended with `shouldResume=false`. Which app it was is not logged.

- 09-13 05:02Z-05:54Z (then hole 1 took over)
- 09-17 01:19Z-03:08Z

## Hole 3 — the server discards half of what arrives

VoiceLog's `max_queued: 2` (config.local.yaml, oc-general's side). On 09-16 recall uploaded
256 chunks and got 200 for every one; 127 reached the database. 129 evicted as
`newer_arrived`, 116 trimmed. Order of arrival, not content, decides. This conflicts with
the owner's 09-13 ruling that input must not be reduced; oc-general is raising it.

## Proposed (agreed with oc-general, pending owner GO)

Add to the telemetry POST:

    audio_state:       "recording" | "listening" | "blocked:<reason>" | "stopped:user" | "stopped:internal"
    audio_state_since: ISO8601
    last_chunk_at:     ISO8601

The server alerts on `blocked:*` or `stopped:internal` lasting N minutes (N = 10 to start,
raised if it proves too short) — neither is the owner's choice. `stopped:internal` normally
lasts seconds while an engine is rebuilt, so only a long one alarms; recall rewrites the state
to `blocked:<reason>` whenever iOS refuses a resume, which means a `stopped:internal` that lasts
10 minutes is a recall bug, and the server's alert says so.
`stopped:user` is **information, not an alarm**: the owner turns recording off on purpose, and
what the server needs is to tell "recording was off" apart from "nobody spoke", not to nag. Also
count the stretches where the detector's peak stayed below the start threshold, so missed
quiet speech becomes measurable (it is otherwise invisible: unrecorded audio gets no label).

A guard that ignores a stop tap right after an auto-start was considered and dropped: it would
block exactly the deliberate battery stop the owner makes.

## The detector (context)

Measured on the surviving half of 09-16, same hours as the 09-13 baseline: real speech 50% ->
100% at 11h UTC (215 segments), 44% -> 100% at 12h (15). Details:
`docs/handoff/002-vad-collapse.md`.

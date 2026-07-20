# Stream Independence Contract

**Status: BINDING. Ruled by the project owner on 2026-07-20. Any change to this contract
requires explicit owner approval — it must never be altered as a side effect of another task.**

## The rule

Every stream shown as a toggle on the top screen (RecordingView `contextStreamsBar`) is an
**independent channel**. Each toggle is the *sole* authority over its own stream:

| Toggle (top screen) | Stream | Sole authority |
|---|---|---|
| Audio (`mic.fill`) | Microphone recording (engine, keep-alive, audio session) | Audio toggle / `userStopIntent` |
| Location (`location.fill`) | Location capture + location POSTs | Location toggle |
| Health (`heart.fill`) | HealthKit queries + health POSTs | Health toggle |
| Glasses (`sunglasses.fill`) | Glasses photo handoff import + media upload | Glasses toggle |
| Media (`music.note`) | NowPlaying observation | Media toggle |

Stopping one stream must never stop, gate, defer, or degrade another. Concretely:

- `RecordingStateManager.userStopIntent` and `LaunchContext.shouldStaySilent` belong to the
  **recording lane only**. They may gate: engine start/stop, BackgroundKeepAlive, audio
  session activation, and recording auto-start on launch. Nothing else.
- Location, health, media, glasses, and the upload queues must never reference
  `userStopIntent` or `shouldStaySilent`. (Enforcement check: `grep -rn userStopIntent recall/`
  must only hit RecordingViewModel / RecordingStateManager / LaunchContext / RecallApp;
  same idea for `shouldStaySilent`.)
- A background (silent) launch suppresses **recording auto-start only**. All independent
  streams start on every launch, silent or not (`RecallApp.startIndependentStreams()`).
- Stopping recording does not stop the upload queue: chunks already recorded keep draining.

## Why this is binding (incident history)

- 2026-07-10: a background relaunch read `userStopIntent=true` and tore down location —
  arrival notification delayed 2.5h.
- 2026-07-19/20: recording stopped at 12:04; the then-current gates suppressed location for
  **33.5 hours** while the owner physically moved Chiba → Tokyo. All of it was lost.
- Owner ruling (2026-07-20): "全部独立してくれないと困る。ヘルスデータなど、なんのために
  トップページに独立したボタンが並んでいるんだ。勝手に仕様をかえるな。" The top-screen
  toggles ARE the spec; the backend cross-wiring was an unauthorized spec change.

## Channel-status heartbeat (server contract)

So the server can tell "intentionally off" from "broken", recall reports channel state
(no coordinates, no health values) to the existing telemetry endpoint:

- `type: "channel_status"`, channels: `audio | location | health | glasses | media`,
  state: `active | gated_by_user`, plus per-channel `since` (ISO8601 UTC).
- Send on every state **edge**, plus once per hour while any channel is `gated_by_user`.
  All-active steady state sends nothing (the location POSTs themselves are the liveness signal).
- Receiver side (gateway `vibeterm-telemetry` ext, alert suppression, viewer display) is owned
  by the oc-general lane; the payload contract's canonical copy lives in oc-general
  `docs/contracts/`. Changes go through that contract doc, both lanes in agreement.

## Review checklist for future changes

Before merging anything that touches gating, launch paths, or send paths, ask:

1. Does any new guard reference a flag owned by a *different* stream? → contract violation.
2. Does a launch path start recording without the recording lane's own authority? → violation.
3. Does stopping stream X change observable behavior of stream Y? → violation.
4. If a gate must be "conservative", conservativeness may not create new cross-stream
   coupling — ask the owner instead of wiring streams together.

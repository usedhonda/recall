# recall — Project Contract (AGENTS.md)

This is the single source of truth for how agents work in this repo. Claude Code loads it via
the `@AGENTS.md` import in CLAUDE.md; Codex reads it natively. Keep it under ~200 lines / 32 KiB
— it is the contract, not the manual. Detailed, code-verified facts live in `docs/` (notably
`docs/pipeline.md` and `docs/stream-independence.md`); link to them instead of restating them.

## 1. Purpose & scope

**recall** is an always-on voice-recording iOS app for lifelogging (Rewind / Limitless style):
record everything, keep only what matters (voice segments), upload chunks to a Tailscale peer.

- `recall/` — the iOS app. Swift / SwiftUI, iOS 17+, MVVM, Swift Concurrency (async/await,
  actors). Views stay thin; logic lives in `@Observable` ViewModels.
- `openclaw-plugin/` — a Chrome extension (OpenClaw telemetry ingestion). **Bump
  `manifest.json` version on EVERY change** to the extension.
- Language: development conversation in Japanese; UI / code / comments / docs in English.

## 2. Architecture (summary — details: docs/pipeline.md)

Layers: `Features/` (Recording, Upload, Settings) → `Core/` (Audio, Upload, Storage, Network,
Telemetry) → `Models/` (SwiftData). Audio path: `AVAudioEngine` tap → RMS gate → Silero VAD
(ANE) → chunk writer → upload queue → VoiceLog `/ingest` → Gateway reaction.

**Verified facts (code is truth — do not "correct" these back to old claims):**

- Audio: **Opus in a `.caf` container, 48 kbps, 16 kHz, mono** (`Core/Audio/ChunkWriter.swift`).
  Earlier docs claimed a lossy container at a lower bitrate — that was stale; trust the code.
- Chunking: `1.5 s` silence ends a chunk; `30 s` max forces a split; `3 s` pre-margin from the
  ring buffer. Filename `yyyyMMdd_HHmmss.caf`. No user-facing chunk settings.
- `AVAudioSession`: `.playAndRecord` with `[.mixWithOthers, .defaultToSpeaker,
  .allowBluetoothA2DP]`. `.allowBluetooth` (HFP) is inserted **only when the user selects HFP
  mic mode** — HFP forces 16 kHz mono system-wide and degrades other apps, so it is opt-in.
- **A `recallTests` unit-test target exists** (XcodeGen, hosted by the `recall` app). It
  currently covers `JumpGate` — the pure location speed/jump-decision logic (streak-accept
  anti-lockup + the intl-flight bypass). On-device behavior + logs remain the primary
  verification for everything runtime; the suite guards only the pure logic it names.

## 3. Roles (tool-agnostic)

Any agent (Claude Code, Codex, a subagent, a future tool) may act as orchestrator, coder, or
reviewer, and roles may swap mid-task. What matters is the shared state, not who holds it.

- **Orchestrator:** fixes the Task Intent and scope, routes work, verifies results against a
  primary source, owns the final decision.
- **Coder:** implements exactly the scoped change, runs the verification in §4, commits.
- **Reviewer:** checks the diff against this contract and the binding constraints in §5.

Shared state lives in files, not conversation: `docs/handoff/` (copy `TEMPLATE.md` →
`NNN-slug.md`, keep it current). **If it is not in the handoff file or the repo, it does not
exist for the next agent.**

## 4. Commands & verification

Build is XcodeGen-based. Regenerate the project, then build:

```bash
xcodegen generate           # overlays .local/project.yml (gitignored) when present
xcodebuild -project recall.xcodeproj -scheme recall -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5' build
```

Device build / deploy to kana (real iPhone):

```bash
~/.claude/apple-dev/bin/ios-build.sh device
```

Unit tests (`recallTests`, currently `JumpGate` only):

```bash
xcodebuild -project recall.xcodeproj -scheme recall \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5' test
```

**Delivery truth = on-device logs, not a green build.** The authoritative record is the
on-device Documents log: `activity_YYYY-MM-DD.log` (UTC timestamps, 7-day retention). Pull it:

```bash
xcrun devicectl device copy from --domain-type appDataContainer \
  --domain-identifier com.example.recall ...   # copies the app Documents container
```

A remote mirror exists at `~/logs/recall-udp/` on the macmini (`ssh macmini`), but the
on-device file is authoritative — the mirror can lag or drop. A 200 / PASS / healthcheck is a
hint, not proof; confirm end-to-end from the on-device log.

**Before commit: run `scripts/check-contract.sh` (must pass).**

## 5. Binding constraints (owner-ruled; changing any of these needs explicit owner approval)

1. **Stream independence.** Every top-screen toggle (Audio / Location / Health / Glasses /
   Media) is an independent stream and the sole authority over itself; stopping one must never
   stop, gate, defer, or degrade another. `userStopIntent` / `shouldStaySilent` belong to the
   recording lane only. Full contract, incident history, and review checklist:
   `docs/stream-independence.md` (BINDING).
2. **NowPlaying prohibition.** recall must NEVER write `MPNowPlayingInfoCenter.nowPlayingInfo`
   with content, nor register `MPRemoteCommandCenter` handlers. Defensive `nowPlayingInfo = nil`
   cleanup on stop is allowed. vibeterm owns the lock screen (Live Activity). Background
   survival relies solely on `UIBackgroundModes: audio` + the `AVAudioEngine` tap — no
   NowPlaying tricks.
3. **Visible UI changes require owner approval.** Never remove or alter a user-visible element
   (a toggle, a screen) as a side effect of another task, and never let a "remove this route"
   instruction bleed into deleting UI.
4. **Location accuracy filter is fixed:** background 200 m / foreground 100 m. Do not relax it.
5. **Direct pushes to `main` are allowed;** the branch-protection bypass warning is normal.
   Commits are conventional and in English (`feat:`, `fix:`, `docs:`, …); no `Co-Authored-By`.

## 6. Completion & docs

A task is **done** only when: the simulator build passes; the change is deployed/verified where
it actually matters (on-device behavior + log for anything runtime); `scripts/check-contract.sh`
prints PASS; and the report is factual (reflect + minimal verification + result).

**Update docs in the same change that alters them** when the change touches: audio format /
chunking / session options (→ `docs/pipeline.md` + §2 here); the server/upload contract (→
`docs/pipeline.md` §5); a binding constraint (→ the relevant doc + §5, owner approval required);
or a hard-won sharp edge (→ §7).

## 7. Sharp edges (hard-won; do not rediscover)

- **`installTap` throws an uncatchable Obj-C `NSException`** (not a Swift error) on format
  mismatch. Validate the tap format *before* installing; you cannot `try/catch` your way out.
- **SwiftData `#Predicate` cannot resolve nested enum members.** Store a raw `String`
  (`uploadStatusRaw`) and expose a computed enum wrapper (`uploadStatus`).
- **FluidAudio is pinned to exactly `0.12.6`** (Swift 6 concurrency fix). Do not float it.
- **VoiceLog `/ingest` never returns 429 and transcripts are never discarded** — only upload
  chunks may be dropped by newest-wins eviction, by design. Do not "fix" backpressure
  client-side.
- **Secrets never go in tracked files.** `.local/`, `.codex/`, `.claude/` are gitignored on
  purpose — server URLs, tokens, and personas live there, not in the repo.

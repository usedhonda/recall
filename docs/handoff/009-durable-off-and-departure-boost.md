# Handoff: durable audio OFF deploy + Wi-Fi departure boost

- Goal / why: keep the owner's audio switch choice durable across Control Center and deploys, and
  make the first position after leaving a registered Wi-Fi network go out fast (greeting timeliness).
- Scope: recall/App (LaunchContext, RecallApp), RecordingControl, Core/Audio (engine start join),
  Core/Telemetry (ChannelStatusReporter ack ledger), Core/Location (departure window),
  Core/Network (ConnectivityMonitor), GeofenceEventReporter (wifi_event payload), docs/pipeline.md.
- Explicitly out: recording ON/OFF decisions (owner only), accuracy filter (fixed FG 100 m / BG 200 m),
  server-side departure logic (chi), Hub/STT consumers (data-hub).
- Status: review done; d98bfaf deployed; 5fa7274 built, not installed.
- Done so far:
  - d98bfaf (durable OFF W1, deploy-preserved OFF W2, channel ack ledger W3) installed on the
    device 2026-10-17 05:32Z (one install, launch --no-activate first try). New process started
    location, health and channel status; Hub receipts for gps/health/status followed.
  - Audio after deploy: a spoken test at 07:27Z produced chunks that reached Hub audio-original
    receipts with capture metadata (elapsed == written). STT outcome is data-hub's.
  - Departure boost: f2443ee + 1742bb4 + 1cd6fb5 + 75bb495 + 5fa7274, KAI static review closed
    (no concrete defect left in the reviewed diffs).
- Files changed: see `git log f7498f9..5fa7274`.
- Decisions:
  - wifi_event `ssid` carries only a name confirmed on the ended connection, plus `ssid_confirmed`;
    unconfirmed `left` sends `last_known_ssid` separately (agreed with chi 2026-10-18; the server
    matches only `ssid`).
  - Departure window: one immediate attempt per window, in-flight reservation, 10 s paced retry
    after a failed attempt; a queue refusal is not counted as sent.
  - Ordinary location throttle still advances on a refused queue (avoids a direct send per fix offline).
- Rejected options: reading the SSID on every Wi-Fi join regardless of registration (kept the
  narrower "do a read requested before Wi-Fi on the next join").
- Commands run: focused unit tests (LocationCadenceTests, GeofenceEventPayloadTests,
  DurableOffAndChannelAckTests) on the iPhone 15 / iOS 17.5 simulator, all passing;
  scripts/check-contract.sh PASS; signed device builds with private witnesses in `.local/`.
- Open issues / risks:
  - 2026-10-17: the build before d98bfaf did not persist a Control Center OFF; the deploy launch
    restarted recording against the owner's last choice. Read the audio state from a log pulled
    immediately before any install.
  - Device installs/launches from the agent session are currently denied by the agent host's
    automatic permission review; the owner decides how that is resolved.
  - Not verified on the device: Control Center OFF persistence on the new build, OFF during a
    pending start, channel status resend after a real network failure, departure boost wiring,
    iOS fix arrival and greeting timing.
  - Existing residuals (not regressions): heartbeat send paths read the fix id at task time;
    late completions of an old await are not generation-isolated.
  - GPS recovery cause during the 2026-10-16 flight is unproven.
- Next steps:
  1. Owner choice (via chi): install 5fa7274 now (interruption 3-56 s estimated from past log gaps,
     open chunk up to 30 s at risk) or postpone; owner resolves the install permission; owner orders push.
  2. Install: pull log -> audio state -> artifact digest -> lockState -> install -> launch
     --no-activate with RECALL_PRESERVE_OFF=1 -> new-process log -> private witness.
  3. Natural acceptance items above, each recorded separately.
- Completion criteria remaining: steps 1-3.
- Links: docs/stream-independence.md, docs/pipeline.md section 8, AGENTS.md section 4.

# Handoff: durable audio OFF deploy + Wi-Fi departure boost

- Goal / why: keep the owner's audio switch choice durable across Control Center and deploys, and
  make the first position after leaving a registered Wi-Fi network go out fast (greeting timeliness).
- Scope: recall/App (LaunchContext, RecallApp), RecordingControl, Core/Audio (engine start join),
  Core/Telemetry (ChannelStatusReporter ack ledger), Core/Location (departure window),
  Core/Network (ConnectivityMonitor), GeofenceEventReporter (wifi_event payload), docs/pipeline.md.
- Explicitly out: recording ON/OFF decisions (owner only), accuracy filter (fixed FG 100 m / BG 200 m),
  server-side departure logic (chi), Hub/STT consumers (data-hub).
- Status: review done; 5fa7274 installed and launched; natural acceptance remains partial.
- Done so far:
  - d98bfaf (durable OFF W1, deploy-preserved OFF W2, channel ack ledger W3) installed on the
    device 2026-10-17 05:32Z (one install, launch --no-activate first try). New process started
    location, health and channel status; Hub receipts for gps/health/status followed.
  - Audio after deploy: a spoken test at 07:27Z produced chunks that reached Hub audio-original
    receipts with capture metadata (elapsed == written). STT outcome is data-hub's.
  - Departure boost: f2443ee + 1742bb4 + 1cd6fb5 + 75bb495 + 5fa7274, KAI static review closed
    (no concrete defect left in the reviewed diffs).
  - 5fa7274 deployed on 2026-10-17: prepared binary digest matched the existing signed-build
    witness; a fresh six-second-old watchdog showed listening with no later voice/start event,
    and the phone was launchable. One install and immediate no-activate launch succeeded.
    The new process reported listening; GPS, Health and status durable receipts followed.
    Recording controls were not changed. The private witness binds source, artifact and operations.
  - Natural audio originals arrived at 17:34Z and 17:41Z without an engine restart. Voice detection,
    chunk finalization and audio-original receipts resumed. This does not identify whether the
    preceding interval was silence or an intermittent detection issue.
    Hub read-only correlation confirmed both originals and their STT results; the individual
    results passed the consumer normalizer. This is not whole-reader acceptance: an older invalid
    result keeps the reader fail-closed until its existing time window expires (Hub-owned).
    The three supplied post-deploy GPS, Health and channel-report references also matched Hub storage.
  - Reviewed changes and this handoff were pushed through eaf4293; no source tests were repeated.
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
  - A prior session's automatic permission review denied install/launch. The subsequent normal
    deployment succeeded without bypassing that rejection or changing permission settings.
  - Not verified on the device: Control Center OFF persistence on the new build, OFF during a
    pending start, channel status resend after a real network failure, departure boost wiring,
    iOS fix arrival and greeting timing.
  - Existing residuals (not regressions): heartbeat send paths read the fix id at task time;
    late completions of an old await are not generation-isolated.
  - GPS recovery cause during the 2026-10-16 flight is unproven.
- Next steps:
  1. Keep the completed five-reference Hub correlation separate from whole-reader and new-build
     natural audio acceptance; do not repeat the same-event checks.
  2. Natural acceptance items above, each recorded separately. Do not toggle recording or
     manufacture a Wi-Fi departure/network failure to produce evidence.
  3. At any future install, repeat the current-state preflight rather than relying on this history.
- Completion criteria remaining: applicable natural/device and consumer acceptance, not code review.
- Links: docs/stream-independence.md, docs/pipeline.md section 8, AGENTS.md section 4.

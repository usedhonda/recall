#!/bin/bash
# Contract checks for recall (AGENTS.md §5). Run before every commit. Exit 1 on violation.
set -u
fail=0
say() { echo "check-contract: $1"; }

# 1. Recording-lane flags must not leak into independent streams
# ChannelStatusReporter is an allowed READ-ONLY observer (reports channel state; gates nothing).
hits=$(grep -rln "userStopIntent\|shouldStaySilent" recall/ \
  | grep -v -e RecordingViewModel.swift -e RecordingStateManager -e LaunchContext.swift -e RecallApp.swift -e ChannelStatusReporter.swift)
if [ -n "$hits" ]; then say "FAIL stream-independence: $hits"; fail=1; fi

# 2. NowPlaying prohibition (writes and handler registration; nil-cleanup allowed)
if grep -rn "MPRemoteCommandCenter" recall/ --include=*.swift | grep -v "read-only"; then
  say "FAIL NowPlaying: MPRemoteCommandCenter reference"; fail=1; fi
if grep -rn "nowPlayingInfo = \[" recall/ --include=*.swift; then
  say "FAIL NowPlaying: nowPlayingInfo write"; fail=1; fi

# 3. Doc drift tripwires (stale claims must not come back)
if grep -ln "AAC-LC\|32kbps\|\.m4a" AGENTS.md CLAUDE.md README.md 2>/dev/null; then
  say "FAIL doc-drift: stale audio-format claim"; fail=1; fi

[ $fail -eq 0 ] && say "PASS"
exit $fail

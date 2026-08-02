@AGENTS.md

# recall — Claude Code adapter

Everything project-level lives in AGENTS.md (imported above) and docs/. This file holds
Claude-Code-specific notes only. Do not restate AGENTS.md content here — imports load in
full and duplicates double the context.

- Build/deploy: prefer the `/ios-build` skill (`--device` for kana); it wraps the same
  `ios-build.sh` referenced in AGENTS.md §4.
- Auto memory (`~/.claude/projects/.../memory/`) is Claude-private. Any knowledge Codex
  or a future agent must share belongs in AGENTS.md §5/§7 or docs/, not in memory.
- When a task ends mid-flight, write/refresh the handoff file (docs/handoff/) before
  the session ends — conversation context does not transfer to other tools.

# Recall Telemetry - OpenClaw Plugin

Receives recall iOS telemetry via `POST /api/telemetry`.

Important naming note:

- Product name: `recall`
- Current OpenClaw plugin display name / manifest: `Recall Telemetry`
- Current install directory and config namespace: `vibeterm-telemetry` (legacy compatibility)

This repository no longer uses `vibeterm` as the product name. The legacy plugin ID / config namespace remains in install and host config paths for compatibility with existing OpenClaw setups.

Supported telemetry:

- location events (`events`) and legacy location samples (`samples`)
- health summary (`health`)

The plugin deduplicates location events, stores runtime state in memory, persists latest snapshots to disk, and writes diary lines for OpenClaw context.

## Prerequisites

- OpenClaw gateway installed and running
- Node.js 18+
- Access to the host where OpenClaw runs (local terminal or SSH)

## Security Model

- Endpoint auth uses OpenClaw gateway bearer token.
- Do not commit real tokens, hostnames, or private network details.
- Use local-only env files (`.env.local`) for test convenience.

Create local env file from template:

```bash
cp .env.local.example .env.local
```

## Quick Install

```bash
./install.sh
```

Default behavior:

1. Copies plugin files into `~/.openclaw/extensions/vibeterm-telemetry/`
2. Backs up `~/.openclaw/openclaw.json`
3. Registers `plugins.entries.vibeterm-telemetry.enabled = true` (legacy namespace, still expected today)
4. Restarts OpenClaw gateway (unless disabled)

## Installer Options

```bash
./install.sh --dry-run
./install.sh --no-restart
./install.sh --backup-config
./install.sh --rollback
```

- `--dry-run`: Print planned actions only.
- `--no-restart`: Skip gateway restart.
- `--backup-config`: Force config backup before mutation.
- `--rollback`: Restore latest installer-created backup and restart gateway.

## Manual Install

Manual install still uses the legacy namespace below. That is intentional today because `install.sh` and existing OpenClaw hosts still expect `vibeterm-telemetry`.

### 1. Copy plugin files

```bash
mkdir -p ~/.openclaw/extensions/vibeterm-telemetry
cp -R openclaw-plugin/* ~/.openclaw/extensions/vibeterm-telemetry/
```

### 2. Register plugin

Update `~/.openclaw/openclaw.json` and enable the legacy namespace key:

```json
{
  "plugins": {
    "entries": {
      "vibeterm-telemetry": {
        "enabled": true
      }
    }
  }
}
```

### 3. Restart gateway

```bash
openclaw gateway stop
openclaw gateway start
```

## Verify

Verification should also assume the current compatibility state:

- Endpoint path is `POST /api/telemetry`
- Auth token comes from `gateway.auth.token`
- Preferred location payload is `events`
- Legacy `samples` payload is still accepted for older clients

### 1) Location only (`events`, preferred)

```bash
TOKEN=$(python3 -c "import json; print(json.load(open('$HOME/.openclaw/openclaw.json'))['gateway']['auth']['token'])")

curl -s -X POST http://localhost:18789/api/telemetry \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"events":[{"type":"location","id":"test-loc-001","timestamp":"2026-01-01T00:00:00Z","data":{"lat":35.6762,"lon":139.6503,"accuracy":10}}]}'
```

Expected response:

```json
{"received":1,"healthReceived":false,"nextMinIntervalSec":60}
```

### 2) Health only

```bash
curl -s -X POST http://localhost:18789/api/telemetry \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"health":{"periodStart":"2026-01-01T00:00:00Z","periodEnd":"2026-01-01T01:00:00Z","steps":7000,"heartRateAvg":72}}'
```

Expected response:

```json
{"received":0,"healthReceived":true,"nextMinIntervalSec":60}
```

### 3) Mixed payload

```bash
curl -s -X POST http://localhost:18789/api/telemetry \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"events":[{"type":"location","id":"test-mix-001","timestamp":"2026-01-01T01:00:00Z","data":{"lat":35.68,"lon":139.66,"accuracy":12}}],"health":{"steps":7100,"heartRateAvg":70}}'
```

Expected response:

```json
{"received":1,"healthReceived":true,"nextMinIntervalSec":60}
```

## Data Behavior

### Runtime state

- Location dedup cache with 1-hour TTL
- Location history ring buffer (last 100 samples)
- Latest location snapshot in memory
- Latest health summary in memory

### Persisted state

- `~/.openclaw/workspace/memory/current-location.json`
- `~/.openclaw/workspace/memory/health-state.json`

### Diary writes

Path:

- `~/.openclaw/workspace/memory/YYYY-MM-DD.md`

Entry types:

- location: `📍 HH:MM-HH:MM 集計: N件/ユニークM点 | 移動 X.Xkm | 最終 lat, lon (avg acc Xm)`
- health: `❤️ HH:MM - steps | HR | RHR | ...`

Throttle:

- location: 30分ウィンドウで事前集計し、移動200m以上または継続30分以上のウィンドウのみ記録
- health: max 1 write per 30min

## Troubleshooting

### Plugin not loading

- Check `~/.openclaw/logs/gateway.log`
- Confirm `~/.openclaw/extensions/vibeterm-telemetry/openclaw.plugin.json` exists
- Confirm `plugins.entries.vibeterm-telemetry.enabled = true` in `~/.openclaw/openclaw.json`
- The `vibeterm-telemetry` directory/key is legacy naming and is still correct today

### 401 Unauthorized

- Verify bearer token matches `gateway.auth.token` in `~/.openclaw/openclaw.json`
- Token may rotate after gateway reset

### Connection refused

- Confirm gateway is running: `openclaw gateway status`
- Confirm gateway port (default 18789)

### Rollback

```bash
./install.sh --rollback
```

The installer restores the latest backup under:

- `~/.openclaw/backups/vibeterm-telemetry/`

## Migration Plan (Draft)

### Phase 1: Document the compatibility state

- Keep product naming as `recall` in docs and UI
- Keep install directory and host config namespace as `vibeterm-telemetry`
- Treat the legacy namespace as expected behavior, not a user mistake

### Phase 2: Add dual-read compatibility

- Teach plugin discovery / host config loading to accept both `recall-telemetry` and `vibeterm-telemetry`
- Prefer `recall-telemetry` as the canonical name in logs and docs
- Keep legacy read compatibility so existing hosts continue to boot without manual edits

### Phase 3: Ship migration tooling

- Update installer to detect an existing `vibeterm-telemetry` install and migrate it to `recall-telemetry`
- Migrate `plugins.entries.vibeterm-telemetry` to `plugins.entries.recall-telemetry`
- Preserve backups and rollback instructions so hosts can recover if migration fails
- During this phase, keep compatibility reads enabled for both names

### Phase 4: Remove the legacy namespace

- Only set a hard removal date after dual-read support and migration tooling have shipped
- Keep the legacy read path for at least one release cycle or 30 days, whichever is longer
- Before removal, warn in release notes and docs that `vibeterm-telemetry` will stop loading
- After the deadline, remove legacy reads and treat `recall-telemetry` as the only supported namespace

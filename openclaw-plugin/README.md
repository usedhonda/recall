# Vibeterm Telemetry - OpenClaw Plugin

Receives Vibeterm iOS telemetry via `POST /api/telemetry`.

Supported telemetry:

- location samples (`samples` / `events`)
- health summary (`health`)

The plugin deduplicates location events, stores latest snapshots in memory, and writes diary lines for OpenClaw context.

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
3. Registers `plugins.entries.vibeterm-telemetry.enabled = true`
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

### 1. Copy plugin files

```bash
mkdir -p ~/.openclaw/extensions/vibeterm-telemetry
cp -R openclaw-plugin/* ~/.openclaw/extensions/vibeterm-telemetry/
```

### 2. Register plugin

Update `~/.openclaw/openclaw.json`:

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

### 1) Location only

```bash
TOKEN=$(python3 -c "import json; print(json.load(open('$HOME/.openclaw/openclaw.json'))['gateway']['auth']['token'])")

curl -s -X POST http://localhost:18789/api/telemetry \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"samples":[{"id":"test-loc-001","lat":35.6762,"lon":139.6503,"accuracy":10,"timestamp":"2026-01-01T00:00:00Z"}]}'
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
  -d '{"samples":[{"id":"test-mix-001","lat":35.68,"lon":139.66,"accuracy":12,"timestamp":"2026-01-01T01:00:00Z"}],"health":{"steps":7100,"heartRateAvg":70}}'
```

Expected response:

```json
{"received":1,"healthReceived":true,"nextMinIntervalSec":60}
```

## Data Behavior

### In-memory state

- latest location snapshot
- location history ring buffer
- latest health summary

### Diary writes

Path:

- `~/.openclaw/workspace/memory/YYYY-MM-DD.md`

Entry types:

- location: `📍 HH:MM-HH:MM 集計: N件/ユニークM点 | 移動 X.Xkm | 最終 lat, lon (avg acc Xm)`
- health: `❤️ HH:MM - steps | HR | RHR | ...`

Throttle:

- location: 30分ウィンドウで事前集計し、移動200m以上または継続30分以上のウィンドウのみ記録
- health: max 1 write per 30min

## API Reference

Full specification:

- `docs/openclaw-telemetry-api.md`

## Troubleshooting

### Plugin not loading

- Check `~/.openclaw/logs/gateway.log`
- Confirm `~/.openclaw/extensions/vibeterm-telemetry/openclaw.plugin.json` exists
- Confirm plugin enabled in `~/.openclaw/openclaw.json`

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

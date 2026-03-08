#!/bin/bash
# install.sh - Install vibeterm-telemetry plugin into OpenClaw
#
# Usage:
#   ./install.sh [--dry-run] [--no-restart] [--backup-config]
#   ./install.sh --rollback [--dry-run]

set -euo pipefail

PLUGIN_ID="vibeterm-telemetry"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXTENSIONS_DIR="$HOME/.openclaw/extensions"
DEST_DIR="$EXTENSIONS_DIR/$PLUGIN_ID"
CONFIG_FILE="$HOME/.openclaw/openclaw.json"
BACKUP_DIR="$HOME/.openclaw/backups/$PLUGIN_ID"

DRY_RUN=0
NO_RESTART=0
BACKUP_CONFIG=1
ROLLBACK=0

usage() {
  cat <<USAGE
Usage:
  ./install.sh [options]

Options:
  --dry-run        Print actions without changing files
  --no-restart     Skip gateway restart
  --backup-config  Backup openclaw.json before updating (default: on)
  --rollback       Restore latest backup and restart gateway
  -h, --help       Show this help
USAGE
}

run() {
  echo "+ $*"
  if [ "$DRY_RUN" -eq 0 ]; then
    eval "$@"
  fi
}

require_file() {
  if [ ! -f "$1" ]; then
    echo "ERROR: required file not found: $1" >&2
    exit 1
  fi
}

restart_gateway() {
  if [ "$NO_RESTART" -eq 1 ]; then
    echo "[restart] skipped (--no-restart)"
    return 0
  fi

  echo "[restart] restarting OpenClaw gateway ..."
  if command -v openclaw >/dev/null 2>&1; then
    run "openclaw gateway stop >/dev/null 2>&1 || true"
    run "sleep 2"
    run "openclaw gateway start >/dev/null 2>&1 || true"
    echo "[restart] done via openclaw CLI"
    return 0
  fi

  if launchctl list ai.openclaw.gateway >/dev/null 2>&1; then
    run "launchctl stop ai.openclaw.gateway >/dev/null 2>&1 || true"
    run "sleep 2"
    run "launchctl start ai.openclaw.gateway >/dev/null 2>&1 || true"
    echo "[restart] done via launchctl"
    return 0
  fi

  echo "WARNING: could not restart automatically." >&2
  echo "Please run manually: openclaw gateway stop && openclaw gateway start" >&2
}

latest_backup_path() {
  ls -1t "$BACKUP_DIR"/openclaw.json.*.bak 2>/dev/null | head -n 1
}

perform_rollback() {
  local backup
  backup="$(latest_backup_path || true)"
  if [ -z "$backup" ]; then
    echo "ERROR: no backup found in $BACKUP_DIR" >&2
    exit 1
  fi

  echo "[rollback] restoring: $backup"
  run "cp '$backup' '$CONFIG_FILE'"
  restart_gateway

  echo "[rollback] complete"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --no-restart)
      NO_RESTART=1
      ;;
    --backup-config)
      BACKUP_CONFIG=1
      ;;
    --rollback)
      ROLLBACK=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

echo "=== Vibeterm Telemetry Installer ==="

echo "[preflight] validating environment ..."
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required" >&2
  exit 1
fi

if [ "$ROLLBACK" -eq 1 ]; then
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: $CONFIG_FILE not found" >&2
    exit 1
  fi
  perform_rollback
  exit 0
fi

require_file "$SCRIPT_DIR/index.js"
require_file "$SCRIPT_DIR/package.json"
require_file "$SCRIPT_DIR/openclaw.plugin.json"
require_file "$SCRIPT_DIR/src/handler.js"
require_file "$SCRIPT_DIR/src/store.js"
require_file "$SCRIPT_DIR/src/auth.js"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: $CONFIG_FILE not found. Is OpenClaw installed?" >&2
  exit 1
fi

echo "[1/3] copying plugin files to $DEST_DIR"
run "mkdir -p '$DEST_DIR/src'"
run "cp '$SCRIPT_DIR/index.js' '$DEST_DIR/index.js'"
run "cp '$SCRIPT_DIR/package.json' '$DEST_DIR/package.json'"
run "cp '$SCRIPT_DIR/openclaw.plugin.json' '$DEST_DIR/openclaw.plugin.json'"
run "cp '$SCRIPT_DIR/src/handler.js' '$DEST_DIR/src/handler.js'"
run "cp '$SCRIPT_DIR/src/store.js' '$DEST_DIR/src/store.js'"
run "cp '$SCRIPT_DIR/src/auth.js' '$DEST_DIR/src/auth.js'"

echo "[2/3] registering plugin in $CONFIG_FILE"
if [ "$BACKUP_CONFIG" -eq 1 ]; then
  timestamp="$(date +%Y%m%d-%H%M%S)"
  backup_path="$BACKUP_DIR/openclaw.json.$timestamp.bak"
  run "mkdir -p '$BACKUP_DIR'"
  run "cp '$CONFIG_FILE' '$backup_path'"
  echo "[backup] created: $backup_path"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "+ python3 update of openclaw.json (dry-run skipped)"
else
  python3 <<PY
import json
from pathlib import Path

config_path = Path(r"$CONFIG_FILE")
with config_path.open("r", encoding="utf-8") as f:
    cfg = json.load(f)

plugins = cfg.setdefault("plugins", {})
entries = plugins.setdefault("entries", {})
entry = entries.setdefault("$PLUGIN_ID", {})
entry["enabled"] = True

with config_path.open("w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
fi

echo "[3/3] restarting gateway"
restart_gateway

cat <<MSG

=== Installation complete ===

Verify with:
  TOKEN=\$(python3 -c "import json; print(json.load(open('\$HOME/.openclaw/openclaw.json'))['gateway']['auth']['token'])")
  curl -s -X POST http://localhost:18789/api/telemetry \\
    -H "Authorization: Bearer \$TOKEN" \\
    -H "Content-Type: application/json" \\
    -d '{"health":{"steps":7000,"heartRateAvg":72}}'

Expected:
  {"received":0,"healthReceived":true,"nextMinIntervalSec":60}

Rollback:
  ./install.sh --rollback
MSG

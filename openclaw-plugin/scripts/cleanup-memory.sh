#!/bin/bash
# cleanup-memory.sh - Clean up old diary files and rotate location history
#
# Usage:
#   ./cleanup-memory.sh [--dry-run]

set -euo pipefail

MEMORY_DIR="$HOME/.openclaw/workspace/memory"
DIARY_RETENTION_DAYS=90
HISTORY_RETENTION_DAYS=14
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      echo "Usage: $0 [--dry-run]"
      echo "  --dry-run  Show what would be deleted without making changes"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ ! -d "$MEMORY_DIR" ]; then
  echo "[cleanup] memory dir not found: $MEMORY_DIR"
  exit 0
fi

echo "[cleanup] $(date '+%Y-%m-%d %H:%M:%S') starting memory cleanup"

# --- 1. Delete diary files older than 90 days ---
echo "[diary] scanning for files older than ${DIARY_RETENTION_DAYS} days ..."
DIARY_COUNT=0
while IFS= read -r file; do
  DIARY_COUNT=$((DIARY_COUNT + 1))
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[diary][dry-run] would delete: $file"
  else
    rm "$file"
    echo "[diary] deleted: $file"
  fi
done < <(find "$MEMORY_DIR" -maxdepth 1 -name "????-??-??.md" -mtime +${DIARY_RETENTION_DAYS} 2>/dev/null)

if [ "$DIARY_COUNT" -eq 0 ]; then
  echo "[diary] no files older than ${DIARY_RETENTION_DAYS} days"
else
  echo "[diary] ${DIARY_COUNT} file(s) processed"
fi

# --- 2. Rotate location-state.history.jsonl (keep last 14 days) ---
JSONL="$MEMORY_DIR/location-state.history.jsonl"
if [ -f "$JSONL" ]; then
  BEFORE_SIZE=$(wc -c < "$JSONL" | tr -d ' ')
  BEFORE_LINES=$(wc -l < "$JSONL" | tr -d ' ')
  echo "[location] rotating $JSONL (${BEFORE_SIZE} bytes, ${BEFORE_LINES} lines)"

  TMP="$JSONL.tmp.$$"
  if [ "$DRY_RUN" -eq 1 ]; then
    # dry-run: count lines that would be kept
    KEPT=$(python3 -c "
import json, sys
from datetime import datetime, timedelta, timezone
cutoff = datetime.now(timezone.utc) - timedelta(days=${HISTORY_RETENTION_DAYS})
kept = 0
with open('$JSONL') as f:
    for line in f:
        try:
            obj = json.loads(line)
            ts = obj.get('timestamp') or obj.get('state_updated_at_utc', '')
            if ts and datetime.fromisoformat(ts.replace('Z', '+00:00')) >= cutoff:
                kept += 1
        except:
            pass
print(kept)
")
    WOULD_DELETE=$((BEFORE_LINES - KEPT))
    echo "[location][dry-run] would keep ${KEPT} lines, remove ${WOULD_DELETE} lines"
  else
    python3 -c "
import json, sys
from datetime import datetime, timedelta, timezone
cutoff = datetime.now(timezone.utc) - timedelta(days=${HISTORY_RETENTION_DAYS})
with open('$JSONL') as f, open('$TMP', 'w') as out:
    for line in f:
        try:
            obj = json.loads(line)
            ts = obj.get('timestamp') or obj.get('state_updated_at_utc', '')
            if ts and datetime.fromisoformat(ts.replace('Z', '+00:00')) >= cutoff:
                out.write(line)
        except:
            pass
"
    mv "$TMP" "$JSONL"
    AFTER_SIZE=$(wc -c < "$JSONL" | tr -d ' ')
    AFTER_LINES=$(wc -l < "$JSONL" | tr -d ' ')
    SAVED=$((BEFORE_SIZE - AFTER_SIZE))
    echo "[location] rotated: ${BEFORE_LINES} -> ${AFTER_LINES} lines, saved ${SAVED} bytes"
  fi
else
  echo "[location] $JSONL not found, skipping"
fi

echo "[cleanup] done"

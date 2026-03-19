import { promises as fs } from "fs";
import { homedir } from "os";
import { join } from "path";

const MEMORY_ROOT = join(homedir(), ".openclaw", "workspace", "memory");
const SEEN_IDS_PATH = join(MEMORY_ROOT, "web-history-seen.json");

const DEDUP_TTL_MS = 24 * 60 * 60 * 1000; // 24 hours
const HISTORY_MAX = 100;
const PERSISTED_MAX = 2000;
const CLEANUP_INTERVAL_MS = 10 * 60 * 1000; // 10 minutes

/** @type {Map<string, number>} uuid -> first seen timestamp */
const seenIds = new Map();

/** @type {object[]} */
const history = [];

/** @type {object | null} */
let latestEntry = null;
let lastEntryAt = null;
let persistChain = Promise.resolve();

function cleanupSeenIds() {
  const cutoff = Date.now() - DEDUP_TTL_MS;
  for (const [id, seenAtMs] of seenIds) {
    if (seenAtMs < cutoff) {
      seenIds.delete(id);
    }
  }

  if (seenIds.size <= PERSISTED_MAX) {
    return;
  }

  const sorted = [...seenIds.entries()].sort((a, b) => b[1] - a[1]);
  for (const [id] of sorted.slice(PERSISTED_MAX)) {
    seenIds.delete(id);
  }
}

async function loadSeenIds() {
  try {
    const raw = await fs.readFile(SEEN_IDS_PATH, "utf-8");
    const parsed = JSON.parse(raw);
    const entries = Array.isArray(parsed?.entries) ? parsed.entries : [];
    const cutoff = Date.now() - DEDUP_TTL_MS;

    for (const entry of entries) {
      if (!entry || typeof entry.id !== "string" || typeof entry.seenAt !== "string") continue;
      const seenAtMs = Date.parse(entry.seenAt);
      if (!Number.isFinite(seenAtMs) || seenAtMs < cutoff) continue;
      seenIds.set(entry.id, seenAtMs);
    }

    cleanupSeenIds();
  } catch (err) {
    if (err?.code !== "ENOENT") {
      console.warn(`recall-web-history: failed to load persistent dedup: ${err.message}`);
    }
  }
}

async function writeSeenIds() {
  cleanupSeenIds();

  const entries = [...seenIds.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, PERSISTED_MAX)
    .map(([id, seenAtMs]) => ({
      id,
      seenAt: new Date(seenAtMs).toISOString(),
    }));

  const payload = {
    updatedAt: new Date().toISOString(),
    ttlSeconds: DEDUP_TTL_MS / 1000,
    entries,
  };

  await fs.mkdir(MEMORY_ROOT, { recursive: true });
  await fs.writeFile(SEEN_IDS_PATH, JSON.stringify(payload, null, 2), "utf-8");
}

export function flushSeenIds() {
  persistChain = persistChain
    .then(() => writeSeenIds())
    .catch((err) => {
      console.warn(`recall-web-history: failed to persist dedup state: ${err.message}`);
    });
  return persistChain;
}

function queueFlushSeenIds() {
  void flushSeenIds();
}

// Load persisted dedup state on startup (non-blocking)
loadSeenIds().catch((err) => {
  console.warn(`recall-web-history: startup load failed: ${err.message}`);
});

const cleanupTimer = setInterval(() => {
  cleanupSeenIds();
  queueFlushSeenIds();
}, CLEANUP_INTERVAL_MS);
cleanupTimer.unref?.();

export function storeEntry(entry) {
  if (!entry?.id || seenIds.has(entry.id)) return false;

  seenIds.set(entry.id, Date.now());

  const storedEntry = {
    ...entry,
    receivedAt: new Date().toISOString(),
  };

  history.push(storedEntry);
  if (history.length > HISTORY_MAX) {
    history.shift();
  }

  latestEntry = storedEntry;
  lastEntryAt = storedEntry.receivedAt;
  globalThis.__recallLatestWebHistory = storedEntry;
  queueFlushSeenIds();
  return true;
}

export function getLatest() {
  return latestEntry;
}

export function getStats() {
  return {
    dedupSize: seenIds.size,
    historySize: history.length,
    hasLatest: latestEntry !== null,
    lastEntryAt,
  };
}

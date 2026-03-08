/**
 * In-memory location store with UUID deduplication.
 *
 * - Dedup: UUID Set with 1-hour TTL (prevents Background URLSession retries
 *   from creating duplicate entries)
 * - History: circular buffer of last 100 samples
 * - Latest: most recent location for quick access
 */

const DEDUP_TTL_MS = 60 * 60 * 1000; // 1 hour
const HISTORY_MAX = 100;
const CLEANUP_INTERVAL_MS = 10 * 60 * 1000; // 10 minutes

/** @type {Map<string, number>} uuid -> timestamp */
const seenIds = new Map();

/** @type {object[]} */
const history = [];

/** @type {object | null} */
let latestLocation = null;

/** @type {object | null} */
let latestHealth = null;
let lastLocationNewAt = null;
let lastHealthAt = null;

// Periodic cleanup of expired dedup entries
setInterval(() => {
  const cutoff = Date.now() - DEDUP_TTL_MS;
  for (const [id, ts] of seenIds) {
    if (ts < cutoff) seenIds.delete(id);
  }
}, CLEANUP_INTERVAL_MS);

/**
 * Check if a sample ID has already been seen.
 * @param {string} id
 * @returns {boolean}
 */
export function isDuplicate(id) {
  if (!id) return false;
  return seenIds.has(id);
}

/**
 * Store a location sample (after dedup check).
 * @param {object} sample - { id, lat, lon, accuracy, timestamp, altitude?, speed?, bearing?, ... }
 * @returns {boolean} true if stored, false if duplicate
 */
export function storeSample(sample) {
  if (!sample.id) return false;
  if (seenIds.has(sample.id)) return false;

  seenIds.set(sample.id, Date.now());

  const entry = {
    ...sample,
    receivedAt: new Date().toISOString(),
  };

  history.push(entry);
  if (history.length > HISTORY_MAX) {
    history.shift();
  }

  latestLocation = entry;
  lastLocationNewAt = entry.receivedAt;
  globalThis.__vibetermLatestLocation = entry;
  return true;
}

/**
 * Get the most recent location.
 * @returns {object | null}
 */
export function getLatest() {
  return latestLocation;
}

/**
 * Get recent location history.
 * @param {number} [limit=10]
 * @returns {object[]}
 */
export function getHistory(limit = 10) {
  return history.slice(-limit);
}

/**
 * Store a health summary (no dedup needed - hourly aggregated data).
 * @param {object} summary - { steps, heartRateAvg, restingHeartRate, hrvAvgMs, ... }
 * @returns {boolean}
 */
export function storeHealth(summary) {
  const entry = {
    ...summary,
    receivedAt: new Date().toISOString(),
  };
  latestHealth = entry;
  lastHealthAt = entry.receivedAt;
  globalThis.__vibetermLatestHealth = entry;
  return true;
}

/**
 * Get the most recent health summary.
 * @returns {object | null}
 */
export function getLatestHealth() {
  return latestHealth;
}

/**
 * Get store stats for debugging.
 * @returns {{ dedupSize: number, historySize: number, hasLatest: boolean, hasHealth: boolean }}
 */
export function getStats() {
  return {
    dedupSize: seenIds.size,
    historySize: history.length,
    hasLatest: latestLocation !== null,
    hasHealth: latestHealth !== null,
  };
}

export function getLastSuccessTimes() {
  return {
    lastLocationNewAt,
    lastHealthAt,
  };
}

import { sendEntries, checkHealth } from "./lib/api.js";
import { count as getQueueCount, dequeueAll, enqueue } from "./lib/queue.js";
import { DEFAULT_RULES, evaluateRules, isTrackableUrl, migrateBlocklistToRules } from "./lib/filter.js";

const SETTINGS_KEY = "webHistorySettings";
const RECENT_ENTRIES_KEY = "webHistoryRecentEntries";
const SESSION_KEY = "webHistorySessionState";
const DEDUP_KEY = "webHistoryDedupMap";
const ALARM_NAME = "recall-web-history-sync";
const MAX_RECENT_ENTRIES = 100;
const IDLE_THRESHOLD_SECONDS = 60;
const MAX_ACTIVE_SECONDS = 1800;
const SESSION_FLUSH_DELAY_MS = 2000;
const DEDUP_TTL = 6 * 60 * 60 * 1000;

// --- URL normalization for dedup ---

const DEDUP_REMOVE_PARAMS = ["utm_source", "utm_medium", "utm_campaign",
  "utm_content", "utm_term", "ref", "gclid", "fbclid", "si", "s", "t"];

function normalizeUrl(urlString) {
  try {
    const url = new URL(urlString);
    url.hash = "";
    for (const p of DEDUP_REMOVE_PARAMS) url.searchParams.delete(p);
    return url.href.replace(/\/+$/, "");
  } catch {
    return urlString;
  }
}

// --- Dedup via chrome.storage.local (survives Worker restarts) ---

async function isDuplicate(url) {
  const key = normalizeUrl(url);
  const stored = await chrome.storage.local.get(DEDUP_KEY);
  const map = stored[DEDUP_KEY] || {};
  return !!(map[key] && (Date.now() - map[key]) < DEDUP_TTL);
}

async function markSent(url) {
  const key = normalizeUrl(url);
  const stored = await chrome.storage.local.get(DEDUP_KEY);
  const map = stored[DEDUP_KEY] || {};
  const now = Date.now();
  // Prune expired entries
  for (const [k, v] of Object.entries(map)) {
    if (now - v > DEDUP_TTL) delete map[k];
  }
  map[key] = now;
  await chrome.storage.local.set({ [DEDUP_KEY]: map });
}

const DEFAULT_SETTINGS = {
  enabled: true,
  serverURL: "",
  token: "",
  minDwellSeconds: 15,
  minContentChars: 200,
  rules: DEFAULT_RULES
};

function createEmptySessionState() {
  return {
    activeTabId: null,
    tabStates: {},
    contentCache: {}
  };
}

let sessionState = createEmptySessionState();
let hydratePromise = null;
let initializePromise = null;

// --- State serialization: all state mutations go through this chain ---
let stateChain = Promise.resolve();

function serializeState(fn) {
  stateChain = stateChain.then(fn, fn);
  return stateChain;
}

// --- Session persistence throttle ---
let sessionDirty = false;
let sessionFlushTimer = null;

function markSessionDirty() {
  sessionDirty = true;
  if (!sessionFlushTimer) {
    sessionFlushTimer = setTimeout(flushSessionState, SESSION_FLUSH_DELAY_MS);
  }
}

async function flushSessionState() {
  sessionFlushTimer = null;
  if (!sessionDirty) return;
  sessionDirty = false;
  try {
    await chrome.storage.session.set({ [SESSION_KEY]: sessionState });
  } catch {
    // Worker may be shutting down
  }
}

// Force-flush for boundary events (finalize, tab switch, tab close)
async function flushSessionStateNow() {
  if (sessionFlushTimer) {
    clearTimeout(sessionFlushTimer);
    sessionFlushTimer = null;
  }
  sessionDirty = false;
  try {
    await chrome.storage.session.set({ [SESSION_KEY]: sessionState });
  } catch {
    // Worker may be shutting down
  }
}

function tabKey(tabId) {
  return String(tabId);
}

function sanitizeSettings(raw = {}) {
  const minDwellSeconds = Number(raw.minDwellSeconds);
  const minContentChars = Number(raw.minContentChars);
  return {
    enabled: raw.enabled !== false,
    serverURL: typeof raw.serverURL === "string" ? raw.serverURL.trim() : "",
    token: typeof raw.token === "string" ? raw.token.trim() : "",
    minDwellSeconds: Number.isFinite(minDwellSeconds) ? Math.min(600, Math.max(5, Math.round(minDwellSeconds))) : DEFAULT_SETTINGS.minDwellSeconds,
    minContentChars: Number.isFinite(minContentChars) ? Math.min(5000, Math.max(0, Math.round(minContentChars))) : DEFAULT_SETTINGS.minContentChars,
    rules: Array.isArray(raw.rules)
      ? raw.rules
      : Array.isArray(raw.blocklist)
        ? migrateBlocklistToRules(raw.blocklist)
        : DEFAULT_RULES
  };
}

function sanitizeSessionState(raw = {}) {
  return {
    activeTabId: Number.isInteger(raw.activeTabId) ? raw.activeTabId : null,
    tabStates: raw.tabStates && typeof raw.tabStates === "object" ? raw.tabStates : {},
    contentCache: raw.contentCache && typeof raw.contentCache === "object" ? raw.contentCache : {}
  };
}

async function ensureHydrated() {
  if (!hydratePromise) {
    hydratePromise = chrome.storage.session
      .get({ [SESSION_KEY]: createEmptySessionState() })
      .then((stored) => {
        sessionState = sanitizeSessionState(stored[SESSION_KEY]);
      });
  }

  await hydratePromise;
}

async function getSettings() {
  const stored = await chrome.storage.local.get({ [SETTINGS_KEY]: DEFAULT_SETTINGS });
  return sanitizeSettings(stored[SETTINGS_KEY]);
}

async function saveSettings(nextSettings) {
  const settings = sanitizeSettings(nextSettings);
  await chrome.storage.local.set({ [SETTINGS_KEY]: settings });
  return settings;
}

async function getRecentEntries() {
  const stored = await chrome.storage.local.get({ [RECENT_ENTRIES_KEY]: [] });
  return Array.isArray(stored[RECENT_ENTRIES_KEY]) ? stored[RECENT_ENTRIES_KEY] : [];
}

function contentPreview(content, limit = 200) {
  if (!content || typeof content !== "string") return "";
  const normalized = content.replace(/\s+/g, " ").trim();
  if (normalized.length <= limit) return normalized;
  return `${normalized.slice(0, limit)}...`;
}

// Single-writer chain for Activity log — prevents read-modify-write races
let recentEntriesChain = Promise.resolve();

function recordRecentEntry(entry, status) {
  recentEntriesChain = recentEntriesChain.then(() => _writeRecentEntry(entry, status), () => _writeRecentEntry(entry, status));
  return recentEntriesChain;
}

async function _writeRecentEntry(entry, status) {
  const recentEntries = await getRecentEntries();
  const nextEntries = [
    {
      id: entry.id,
      url: entry.url,
      title: entry.title,
      domain: entry.domain,
      visitedAt: entry.visitedAt,
      dwellSeconds: entry.dwellSeconds,
      contentPreview: entry.contentPreview || contentPreview(entry.content),
      contentLength: entry.contentLength ?? (entry.content || "").length,
      engagement: entry.engagement || null,
      status
    },
    ...recentEntries.filter((item) => {
      if (item?.id === entry.id) return false;
      return true;
    })
  ].slice(0, MAX_RECENT_ENTRIES);

  await chrome.storage.local.set({ [RECENT_ENTRIES_KEY]: nextEntries });
}

async function ensureAlarm() {
  const alarm = await chrome.alarms.get(ALARM_NAME);
  if (!alarm) {
    chrome.alarms.create(ALARM_NAME, { periodInMinutes: 1 });
  }
}

function shouldHandleUrl(url, settings) {
  if (!settings.enabled || !isTrackableUrl(url)) return false;
  const result = evaluateRules(url, settings.rules || [], settings);
  return !result.blocked;
}

function createEngagementState() {
  const now = Date.now();
  return {
    visibleSince: now,
    activeSince: now,
    visibleMs: 0,
    activeMs: 0,
    scrollDepthPct: 0,
    isVisible: true,
    isIdle: false
  };
}

function flushEngagementTimers(tabState) {
  const now = Date.now();
  if (tabState.visibleSince) {
    tabState.visibleMs = (tabState.visibleMs || 0) + (now - tabState.visibleSince);
    tabState.visibleSince = null;
  }
  if (tabState.activeSince) {
    tabState.activeMs = (tabState.activeMs || 0) + (now - tabState.activeSince);
    tabState.activeSince = null;
  }
}

function computeEngagement(tabState) {
  const activeSeconds = Math.min(MAX_ACTIVE_SECONDS, Math.max(0, Math.round((tabState.activeMs || 0) / 1000)));
  const scrollDepthPct = tabState.scrollDepthPct || 0;
  const engaged = activeSeconds >= 10 || scrollDepthPct >= 75;

  const engagement = { activeSeconds, scrollDepthPct, engaged };

  if (tabState.viewedTweets?.length > 0) {
    engagement.viewedTweets = tabState.viewedTweets;
  }

  return { dwellSeconds: activeSeconds, engagement };
}

async function handleEngagementMessage(message, tabId) {
  await ensureHydrated();
  const key = tabKey(tabId);
  const tabState = sessionState.tabStates[key];
  if (!tabState) return;

  // Validate page identity — drop stale/mismatched engagement from orphaned content scripts
  if (message.pageUrl && tabState.url && message.pageUrl !== tabState.url) return;
  if (tabState.lastFinalizedAt && message.sentAt && message.sentAt < tabState.lastFinalizedAt) return;

  const now = Date.now();

  switch (message.type) {
    case "engagement:visibility": {
      if (message.hidden) {
        if (tabState.visibleSince) {
          tabState.visibleMs = (tabState.visibleMs || 0) + (now - tabState.visibleSince);
          tabState.visibleSince = null;
        }
        if (tabState.activeSince) {
          tabState.activeMs = (tabState.activeMs || 0) + (now - tabState.activeSince);
          tabState.activeSince = null;
        }
        tabState.isVisible = false;
      } else {
        tabState.visibleSince = now;
        if (!tabState.isIdle) {
          tabState.activeSince = now;
        }
        tabState.isVisible = true;
      }
      break;
    }
    case "engagement:scroll": {
      const pct = Number(message.scrollDepthPct);
      if (Number.isFinite(pct) && pct > (tabState.scrollDepthPct || 0)) {
        tabState.scrollDepthPct = pct;
      }
      break;
    }
    case "engagement:x-tweets": {
      if (!tabState.viewedTweets) tabState.viewedTweets = [];
      for (const tweet of (message.tweets || [])) {
        if (tabState.viewedTweets.length < 200) {
          tabState.viewedTweets.push(tweet);
        }
      }
      break;
    }
  }

  markSessionDirty();
}

async function handleIdleStateChanged(newState) {
  await ensureHydrated();
  const activeTabId = sessionState.activeTabId;
  if (!Number.isInteger(activeTabId)) return;

  const key = tabKey(activeTabId);
  const tabState = sessionState.tabStates[key];
  if (!tabState) return;

  const now = Date.now();
  const isIdle = newState !== "active";

  if (isIdle && !tabState.isIdle) {
    if (tabState.activeSince) {
      tabState.activeMs = (tabState.activeMs || 0) + (now - tabState.activeSince);
      tabState.activeSince = null;
    }
    tabState.isIdle = true;
  } else if (!isIdle && tabState.isIdle) {
    tabState.isIdle = false;
    if (tabState.isVisible) {
      tabState.activeSince = now;
    }
  }

  markSessionDirty();
}

function buildEntry(tabState, contentState, dwellSeconds, engagement) {
  if (!tabState?.url) return null;

  let parsedUrl;
  try {
    parsedUrl = new URL(tabState.url);
  } catch {
    return null;
  }

  return {
    id: crypto.randomUUID(),
    url: parsedUrl.href,
    title: (contentState?.title || tabState.title || parsedUrl.href).trim(),
    domain: parsedUrl.hostname,
    content: contentState?.content || "",
    visitedAt: new Date(tabState.activatedAt || Date.now()).toISOString(),
    dwellSeconds,
    meta: contentState?.meta || {},
    engagement
  };
}

async function trySendOrQueue(entry, settings) {
  try {
    await sendEntries(settings.serverURL, settings.token, [entry]);
    return "sent";
  } catch (err) {
    console.warn(`[recall] send failed, queued: ${err instanceof Error ? err.message : String(err)}`);
    await enqueue(entry);
    return "queued";
  }
}

async function flushQueue() {
  const settings = await getSettings();
  if (!settings.serverURL || !settings.token) {
    return { attempted: 0, sent: 0, requeued: 0 };
  }

  const pendingEntries = await dequeueAll();
  if (pendingEntries.length === 0) {
    return { attempted: 0, sent: 0, requeued: 0 };
  }

  let sent = 0;
  let requeued = 0;
  for (let index = 0; index < pendingEntries.length; index += 1) {
    try {
      await sendEntries(settings.serverURL, settings.token, [pendingEntries[index]]);
      sent += 1;
      // Update Activity status from "queued" to "sent"
      await recordRecentEntry(pendingEntries[index], "sent");
    } catch {
      for (const entry of pendingEntries.slice(index)) {
        await enqueue(entry);
        requeued += 1;
      }
      break;
    }
  }

  return {
    attempted: pendingEntries.length,
    sent,
    requeued
  };
}

async function finalizeVisit(tabId, reason) {
  await ensureHydrated();
  const key = tabKey(tabId);
  const tabState = sessionState.tabStates[key];
  if (!tabState?.url || !tabState?.activatedAt) {
    return null;
  }

  sessionState.tabStates[key] = {
    ...tabState,
    activatedAt: null,
    lastFinalizedReason: reason,
    lastFinalizedAt: Date.now()
  };
  await flushSessionStateNow();

  const settings = await getSettings();
  flushEngagementTimers(tabState);
  const { dwellSeconds, engagement } = computeEngagement(tabState);
  const contentState = sessionState.contentCache[key];

  // Parse domain from URL for consistent logging
  let logDomain = tabState.domain || "";
  try { logDomain = new URL(tabState.url).hostname; } catch { /* keep fallback */ }

  // Build a minimal entry for logging even if skipped
  const logEntry = {
    id: `${tabId}-${Date.now()}`,
    url: tabState.url,
    title: tabState.title || "Untitled",
    domain: logDomain,
    visitedAt: tabState.activatedAtISO || new Date().toISOString(),
    dwellSeconds,
    contentPreview: contentPreview(contentState?.content),
    contentLength: (contentState?.content || "").length,
    engagement: engagement || null
  };

  if (!settings.enabled) {
    await recordRecentEntry(logEntry, "disabled");
    return null;
  }
  if (!isTrackableUrl(tabState.url)) {
    return null;
  }
  const ruleResult = evaluateRules(tabState.url, settings.rules || [], settings);
  if (ruleResult.blocked) {
    await recordRecentEntry(logEntry, "blocked");
    return null;
  }
  const effectiveDwell = ruleResult.minDwell ?? settings.minDwellSeconds;
  if (dwellSeconds < Math.max(0, effectiveDwell)) {
    await recordRecentEntry(logEntry, "short");
    return null;
  }

  // Article check (opt-in via rule.articleOnly)
  const rule = ruleResult.rule;
  if (rule?.articleOnly && contentState?.contentMetrics) {
    const m = contentState.contentMetrics;
    if (m.linkDensity > 0.4 || (m.paragraphCount < 3 && !m.hasArticleTag)) {
      await recordRecentEntry(logEntry, "not article");
      return null;
    }
  }

  const entry = buildEntry(tabState, contentState, dwellSeconds, engagement);
  if (!entry) {
    return null;
  }

  // Dedup: don't send same URL twice within 6 hours (stored in chrome.storage.local)
  if (await isDuplicate(entry.url)) {
    await recordRecentEntry(entry, "dedup");
    return null;
  }

  const status = await trySendOrQueue(entry, settings);
  await markSent(entry.url);

  // Single write with final status — no intermediate "sending" state
  // that gets stuck if Service Worker dies mid-update
  await recordRecentEntry(entry, status);

  // Notify content script with ticker
  if (status === "sent") {
    try {
      await chrome.tabs.sendMessage(tabId, { type: "show-ticker", message: "Sent to recall" });
    } catch { /* tab may be closed */ }
  }

  return entry;
}

async function updateTabState(tabId, nextState) {
  await ensureHydrated();
  sessionState.tabStates[tabKey(tabId)] = {
    ...(sessionState.tabStates[tabKey(tabId)] || {}),
    ...nextState
  };
  markSessionDirty();
}

async function clearTabArtifacts(tabId, { removeState = false } = {}) {
  await ensureHydrated();
  const key = tabKey(tabId);
  delete sessionState.contentCache[key];
  if (removeState) {
    delete sessionState.tabStates[key];
  }
  if (sessionState.activeTabId === tabId && removeState) {
    sessionState.activeTabId = null;
  }
  await flushSessionStateNow();
}

async function cacheContent(tabId, payload) {
  await ensureHydrated();
  sessionState.contentCache[tabKey(tabId)] = {
    url: payload.url,
    title: payload.title,
    content: payload.content,
    contentMetrics: payload.contentMetrics || null,
    meta: payload.meta || {},
    capturedAt: Date.now()
  };
  markSessionDirty();
}

async function requestContentCapture(tabId, expectedUrl) {
  const key = tabKey(tabId);
  try {
    const payload = await chrome.tabs.sendMessage(tabId, {
      type: "extract-page-content",
      expectedUrl
    });
    if (!payload?.ok) {
      if (sessionState.tabStates[key]) {
        sessionState.tabStates[key].lastCaptureError = payload?.error || "extraction failed";
        sessionState.tabStates[key].lastCaptureErrorAt = Date.now();
        markSessionDirty();
      }
      return;
    }
    if (expectedUrl && payload.url && payload.url !== expectedUrl) {
      return;
    }
    await cacheContent(tabId, payload);
    await updateTabState(tabId, {
      title: payload.title || sessionState.tabStates[key]?.title || "",
      lastCaptureError: null
    });
  } catch (err) {
    // Store error for diagnostics instead of silent swallow
    if (sessionState.tabStates[key]) {
      sessionState.tabStates[key].lastCaptureError = err instanceof Error ? err.message : "content script unreachable";
      markSessionDirty();
    }
  }
}

async function bootstrapActiveTab() {
  const tabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  const [activeTab] = tabs;
  if (!activeTab?.id) return;

  const existingTab = sessionState.tabStates[tabKey(activeTab.id)];
  const activatedAt = existingTab?.activatedAt || Date.now();
  await updateTabState(activeTab.id, {
    url: activeTab.url || existingTab?.url || "",
    title: activeTab.title || existingTab?.title || "",
    activatedAt,
    ...(existingTab?.visibleSince != null ? {} : createEngagementState())
  });
  sessionState.activeTabId = activeTab.id;
  await flushSessionStateNow();

  const settings = await getSettings();
  if (activeTab.status === "complete" && shouldHandleUrl(activeTab.url, settings)) {
    await requestContentCapture(activeTab.id, activeTab.url);
  }
}

async function ensureInitialized() {
  if (!initializePromise) {
    initializePromise = (async () => {
      await ensureHydrated();
      await saveSettings(await getSettings());
      await ensureAlarm();
      await bootstrapActiveTab();
    })();
  }

  await initializePromise;
}

async function handleTabActivated(activeInfo) {
  await ensureInitialized();
  const previousTabId = Number.isInteger(activeInfo.previousTabId) ? activeInfo.previousTabId : sessionState.activeTabId;
  if (Number.isInteger(previousTabId) && previousTabId !== activeInfo.tabId) {
    await finalizeVisit(previousTabId, "tab-switch");
  }

  const tab = await chrome.tabs.get(activeInfo.tabId).catch(() => null);
  sessionState.activeTabId = activeInfo.tabId;
  await updateTabState(activeInfo.tabId, {
    url: tab?.url || sessionState.tabStates[tabKey(activeInfo.tabId)]?.url || "",
    title: tab?.title || sessionState.tabStates[tabKey(activeInfo.tabId)]?.title || "",
    activatedAt: Date.now(),
    ...createEngagementState()
  });
  await flushSessionStateNow();

  const settings = await getSettings();
  if (tab?.status === "complete" && shouldHandleUrl(tab.url, settings)) {
    await requestContentCapture(activeInfo.tabId, tab.url);
  }
}

async function handleTabRemoved(tabId) {
  await ensureInitialized();
  await finalizeVisit(tabId, "tab-close");
  await clearTabArtifacts(tabId, { removeState: true });
}

async function handleTabUpdated(tabId, changeInfo, tab) {
  await ensureInitialized();

  const settings = await getSettings();
  const key = tabKey(tabId);
  const existingState = sessionState.tabStates[key] || { url: "", title: "", activatedAt: tab?.active ? Date.now() : null };

  if (typeof changeInfo.url === "string" && existingState.url && existingState.url !== changeInfo.url) {
    if (existingState.activatedAt) {
      await finalizeVisit(tabId, "navigation");
    }

    await clearTabArtifacts(tabId);
    await updateTabState(tabId, {
      url: changeInfo.url,
      title: tab?.title || changeInfo.title || "",
      activatedAt: tab?.active ? Date.now() : null,
      ...(tab?.active ? createEngagementState() : {})
    });
  } else {
    await updateTabState(tabId, {
      url: tab?.url || existingState.url || "",
      title: changeInfo.title || tab?.title || existingState.title || "",
      activatedAt: existingState.activatedAt || (tab?.active ? Date.now() : null)
    });
  }

  if (tab?.active) {
    sessionState.activeTabId = tabId;
    markSessionDirty();
  }

  const currentUrl = sessionState.tabStates[key]?.url;
  if (changeInfo.status === "complete") {
    if (shouldHandleUrl(currentUrl, settings)) {
      await requestContentCapture(tabId, currentUrl);
    } else {
      await clearTabArtifacts(tabId);
    }
  }
}

async function handlePopupMessage(message) {
  if (!message || typeof message !== "object") {
    return { ok: false, error: "Invalid message" };
  }

  await ensureInitialized();

  switch (message.type) {
    case "popup:get-state": {
      const settings = await getSettings();
      const recentEntries = await getRecentEntries();
      const queueCount = await getQueueCount();
      // Expose active tab capture diagnostics
      let diagnostics = null;
      if (Number.isInteger(sessionState.activeTabId)) {
        const activeState = sessionState.tabStates[tabKey(sessionState.activeTabId)];
        if (activeState?.lastCaptureError) {
          diagnostics = {
            lastCaptureError: activeState.lastCaptureError,
            lastCaptureErrorAt: activeState.lastCaptureErrorAt || null
          };
        }
      }
      return { ok: true, settings, recentEntries, queueCount, diagnostics };
    }
    case "popup:save-settings": {
      const current = await getSettings();
      const settings = await saveSettings({ ...current, ...(message.settings || {}) });
      if (settings.serverURL && settings.token) {
        await flushQueue();
      }
      return { ok: true, settings };
    }
    case "popup:test-connection": {
      const settings = sanitizeSettings({
        ...(await getSettings()),
        serverURL: message.serverURL,
        token: message.token
      });
      const result = await checkHealth(settings.serverURL);
      return { ok: true, result };
    }
    case "popup:queue-count": {
      const queueCount = await getQueueCount();
      return { ok: true, queueCount };
    }
    default:
      return { ok: false, error: `Unknown message type: ${message.type}` };
  }
}

chrome.runtime.onInstalled.addListener(() => {
  void ensureInitialized();
  chrome.contextMenus.create({
    id: "recall-settings",
    title: "recall Settings",
    contexts: ["action"]
  });
});

chrome.contextMenus.onClicked.addListener((info) => {
  if (info.menuItemId === "recall-settings") {
    chrome.runtime.openOptionsPage();
  }
});

chrome.runtime.onStartup.addListener(() => {
  void ensureInitialized();
});

// All tab lifecycle events are serialized through stateChain
chrome.tabs.onActivated.addListener((activeInfo) => {
  void serializeState(() => handleTabActivated(activeInfo));
});

chrome.tabs.onRemoved.addListener((tabId) => {
  void serializeState(() => handleTabRemoved(tabId));
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  void serializeState(() => handleTabUpdated(tabId, changeInfo, tab));
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === ALARM_NAME) {
    void flushQueue().then((result) => {
      if (result.attempted > 0) {
        console.log(`[recall] flushQueue: attempted=${result.attempted} sent=${result.sent} requeued=${result.requeued}`);
      }
    });
  }
});

chrome.idle.setDetectionInterval(IDLE_THRESHOLD_SECONDS);
chrome.idle.onStateChanged.addListener((newState) => {
  void serializeState(() => handleIdleStateChanged(newState));
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (typeof message?.type === "string" && message.type.startsWith("engagement:") && sender.tab?.id) {
    void serializeState(() => handleEngagementMessage(message, sender.tab.id))
      .then(() => sendResponse({ ok: true }))
      .catch(() => sendResponse({ ok: false }));
    return true;
  }

  // Content script asks for site-specific config (e.g. trackTweets)
  if (message?.type === "content:get-site-config" && message.url) {
    void (async () => {
      try {
        const settings = await getSettings();
        const result = evaluateRules(message.url, settings.rules || [], settings);
        sendResponse({ ok: true, trackTweets: !!result.trackTweets, blocked: !!result.blocked });
      } catch {
        sendResponse({ ok: false });
      }
    })();
    return true;
  }

  void handlePopupMessage(message)
    .then((response) => sendResponse(response))
    .catch((error) => sendResponse({ ok: false, error: error instanceof Error ? error.message : String(error) }));
  return true;
});

void ensureInitialized();

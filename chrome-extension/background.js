import { sendEntries, checkHealth } from "./lib/api.js";
import { count as getQueueCount, dequeueAll, enqueue } from "./lib/queue.js";
import { DEFAULT_BLOCKLIST, isBlocked, isTrackableUrl, normalizeBlocklist, shouldTrackVisit } from "./lib/filter.js";

const SETTINGS_KEY = "webHistorySettings";
const RECENT_ENTRIES_KEY = "webHistoryRecentEntries";
const SESSION_KEY = "webHistorySessionState";
const ALARM_NAME = "recall-web-history-sync";
const MAX_RECENT_ENTRIES = 10;
const IDLE_THRESHOLD_SECONDS = 60;
const MAX_ACTIVE_SECONDS = 1800;

const DEFAULT_SETTINGS = {
  enabled: true,
  serverURL: "",
  token: "",
  minDwellSeconds: 15,
  blocklist: DEFAULT_BLOCKLIST
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

function tabKey(tabId) {
  return String(tabId);
}

function sanitizeSettings(raw = {}) {
  const minDwellSeconds = Number(raw.minDwellSeconds);
  return {
    enabled: raw.enabled !== false,
    serverURL: typeof raw.serverURL === "string" ? raw.serverURL.trim() : "",
    token: typeof raw.token === "string" ? raw.token.trim() : "",
    minDwellSeconds: Number.isFinite(minDwellSeconds) ? Math.min(600, Math.max(5, Math.round(minDwellSeconds))) : DEFAULT_SETTINGS.minDwellSeconds,
    blocklist: normalizeBlocklist(Array.isArray(raw.blocklist) ? raw.blocklist : DEFAULT_BLOCKLIST)
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

async function persistSessionState() {
  await chrome.storage.session.set({ [SESSION_KEY]: sessionState });
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

async function recordRecentEntry(entry, status) {
  const recentEntries = await getRecentEntries();
  const nextEntries = [
    {
      id: entry.id,
      title: entry.title,
      domain: entry.domain,
      visitedAt: entry.visitedAt,
      dwellSeconds: entry.dwellSeconds,
      status
    },
    ...recentEntries.filter((item) => item?.id !== entry.id)
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
  return settings.enabled && isTrackableUrl(url) && !isBlocked(url, settings.blocklist);
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

  const now = Date.now();

  switch (message.type) {
    case "engagement:visibility": {
      if (message.hidden) {
        // Page became hidden — pause timers
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
        // Page became visible — resume timers
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

  await persistSessionState();
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
    // Became idle — pause active timer
    if (tabState.activeSince) {
      tabState.activeMs = (tabState.activeMs || 0) + (now - tabState.activeSince);
      tabState.activeSince = null;
    }
    tabState.isIdle = true;
  } else if (!isIdle && tabState.isIdle) {
    // Became active — resume active timer (only if visible)
    tabState.isIdle = false;
    if (tabState.isVisible) {
      tabState.activeSince = now;
    }
  }

  await persistSessionState();
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
  } catch {
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
  await persistSessionState();

  const settings = await getSettings();
  if (!settings.enabled || !shouldHandleUrl(tabState.url, settings)) {
    return null;
  }

  flushEngagementTimers(tabState);
  const { dwellSeconds, engagement } = computeEngagement(tabState);
  if (!shouldTrackVisit(dwellSeconds, settings.minDwellSeconds)) {
    return null;
  }

  const contentState = sessionState.contentCache[key];
  const entry = buildEntry(tabState, contentState, dwellSeconds, engagement);
  if (!entry) {
    return null;
  }

  const status = await trySendOrQueue(entry, settings);
  await recordRecentEntry(entry, status);
  return entry;
}

async function updateTabState(tabId, nextState) {
  await ensureHydrated();
  sessionState.tabStates[tabKey(tabId)] = {
    ...(sessionState.tabStates[tabKey(tabId)] || {}),
    ...nextState
  };
  await persistSessionState();
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
  await persistSessionState();
}

async function cacheContent(tabId, payload) {
  await ensureHydrated();
  sessionState.contentCache[tabKey(tabId)] = {
    url: payload.url,
    title: payload.title,
    content: payload.content,
    meta: payload.meta || {},
    capturedAt: Date.now()
  };
  await persistSessionState();
}

async function requestContentCapture(tabId, expectedUrl) {
  try {
    const payload = await chrome.tabs.sendMessage(tabId, {
      type: "extract-page-content",
      expectedUrl
    });
    if (!payload?.ok) {
      return;
    }
    if (expectedUrl && payload.url && payload.url !== expectedUrl) {
      return;
    }
    await cacheContent(tabId, payload);
    await updateTabState(tabId, {
      title: payload.title || sessionState.tabStates[tabKey(tabId)]?.title || ""
    });
  } catch {
    // Ignore restricted pages or tabs without content script injection.
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
  await persistSessionState();

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
  await persistSessionState();

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
    await persistSessionState();
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
      return { ok: true, settings, recentEntries, queueCount };
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

chrome.tabs.onActivated.addListener((activeInfo) => {
  void handleTabActivated(activeInfo);
});

chrome.tabs.onRemoved.addListener((tabId) => {
  void handleTabRemoved(tabId);
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  void handleTabUpdated(tabId, changeInfo, tab);
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === ALARM_NAME) {
    void flushQueue();
  }
});

chrome.idle.setDetectionInterval(IDLE_THRESHOLD_SECONDS);
chrome.idle.onStateChanged.addListener((newState) => {
  void handleIdleStateChanged(newState);
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (typeof message?.type === "string" && message.type.startsWith("engagement:") && sender.tab?.id) {
    void handleEngagementMessage(message, sender.tab.id)
      .then(() => sendResponse({ ok: true }))
      .catch(() => sendResponse({ ok: false }));
    return true;
  }

  void handlePopupMessage(message)
    .then((response) => sendResponse(response))
    .catch((error) => sendResponse({ ok: false, error: error instanceof Error ? error.message : String(error) }));
  return true;
});

void ensureInitialized();

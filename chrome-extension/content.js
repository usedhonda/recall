// --- Context validity guard ---
// When the extension context is invalidated (update, SW restart),
// content scripts become orphaned. Detect and clean up all timers/observers.
let contextAlive = true;
const cleanupCallbacks = [];

function isContextValid() {
  if (!contextAlive) return false;
  try {
    void chrome.runtime.id;
    return true;
  } catch {
    contextAlive = false;
    for (const cb of cleanupCallbacks) {
      try { cb(); } catch { /* ignore */ }
    }
    cleanupCallbacks.length = 0;
    return false;
  }
}

const MAX_CONTENT_LENGTH = 5000;
const ROOT_SELECTORS = ["article", "main", '[role="main"]'];
const REMOVE_SELECTORS = [
  "script",
  "style",
  "noscript",
  "nav",
  "header",
  "footer",
  "aside",
  "form",
  "dialog",
  "svg",
  "canvas",
  "video",
  "audio",
  "iframe"
].join(",");

function normalizeText(text) {
  return (text || "").replace(/\s+/g, " ").trim();
}

function pickRootNode() {
  for (const selector of ROOT_SELECTORS) {
    const candidate = document.querySelector(selector);
    if (candidate && normalizeText(candidate.innerText).length > 0) {
      return candidate;
    }
  }
  return document.body || document.documentElement;
}

function extractMeta(name, attribute = "name") {
  const selector = `meta[${attribute}="${name}"]`;
  const element = document.querySelector(selector);
  return element?.content?.trim() || "";
}

function extractPagePayload() {
  const root = pickRootNode();
  const clone = root.cloneNode(true);
  clone.querySelectorAll(REMOVE_SELECTORS).forEach((node) => node.remove());

  const content = normalizeText(clone.innerText || root.innerText || document.body?.innerText || "").slice(0, MAX_CONTENT_LENGTH);
  return {
    ok: true,
    url: window.location.href,
    title: normalizeText(document.title),
    content,
    meta: {
      description: extractMeta("description"),
      ogTitle: extractMeta("og:title", "property"),
      ogImage: extractMeta("og:image", "property")
    }
  };
}

try {
  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (!isContextValid()) return false;
    if (message?.type === "extract-page-content") {
      // Reset scroll tracking on new content extraction (SPA navigation)
      maxScrollPct = 0;
      try {
        sendResponse(extractPagePayload());
      } catch (error) {
        sendResponse({
          ok: false,
          error: error instanceof Error ? error.message : String(error),
          url: window.location.href,
          title: normalizeText(document.title),
          content: "",
          meta: {}
        });
      }
      return false;
    }

    return undefined;
  });
} catch {
  // extension context invalidated — content script orphaned
}

// --- Engagement tracking ---

function sendEngagement(payload) {
  if (!isContextValid()) return;
  try {
    chrome.runtime.sendMessage({
      ...payload,
      pageUrl: window.location.href,
      sentAt: Date.now()
    }).catch(() => {});
  } catch {
    contextAlive = false;
  }
}

// Visibility tracking
function onVisibilityChange() {
  if (!isContextValid()) return;
  sendEngagement({ type: "engagement:visibility", hidden: document.hidden });
}
document.addEventListener("visibilitychange", onVisibilityChange);
cleanupCallbacks.push(() => document.removeEventListener("visibilitychange", onVisibilityChange));

// Scroll depth tracking (throttled, passive)
let maxScrollPct = 0;
let scrollTimer = null;

function computeScrollPct() {
  const scrollTop = window.scrollY || document.documentElement.scrollTop;
  const docHeight = Math.max(
    document.documentElement.scrollHeight,
    document.body?.scrollHeight || 0
  );
  const viewportHeight = window.innerHeight;
  if (docHeight <= viewportHeight) return 100;
  return Math.min(100, Math.round(((scrollTop + viewportHeight) / docHeight) * 100));
}

function onScroll() {
  if (!isContextValid()) return;
  if (scrollTimer) return;
  scrollTimer = setTimeout(() => {
    scrollTimer = null;
    if (!isContextValid()) return;
    const pct = computeScrollPct();
    if (pct > maxScrollPct) {
      maxScrollPct = pct;
      sendEngagement({ type: "engagement:scroll", scrollDepthPct: maxScrollPct });
    }
  }, 2000);
}
window.addEventListener("scroll", onScroll, { passive: true });
cleanupCallbacks.push(() => {
  window.removeEventListener("scroll", onScroll);
  if (scrollTimer) { clearTimeout(scrollTimer); scrollTimer = null; }
});

// --- X (twitter.com / x.com) individual tweet tracking ---

const X_DOMAINS = ["x.com", "twitter.com"];
const isXDomain = X_DOMAINS.includes(location.hostname);

if (isXDomain) {
  const TWEET_SELECTOR = 'article[data-testid="tweet"]';
  const TWEET_DWELL_MS = 2000;

  const viewStartMap = new WeakMap();
  const reportedTweetIds = new Set();
  const pendingReports = [];

  function extractTweetData(article) {
    const textEl = article.querySelector('[data-testid="tweetText"]');
    const text = textEl?.innerText || "";

    const userNameEl = article.querySelector('[data-testid="User-Name"]');
    let author = "";
    let handle = "";
    if (userNameEl) {
      author = userNameEl.querySelector("span")?.textContent?.trim() || "";
      for (const span of userNameEl.querySelectorAll("span")) {
        const t = span.textContent?.trim() || "";
        if (t.startsWith("@")) { handle = t; break; }
      }
    }

    const timeEl = article.querySelector("time");
    const linkEl = timeEl?.closest("a");
    const permalink = linkEl?.getAttribute("href") || "";
    const tweetIdMatch = permalink.match(/\/status\/(\d+)/);
    const tweetId = tweetIdMatch?.[1] || "";

    return { tweetId, author, handle, text, permalink };
  }

  const intersectionObserver = new IntersectionObserver((entries) => {
    const now = Date.now();
    for (const entry of entries) {
      if (entry.isIntersecting) {
        viewStartMap.set(entry.target, now);
      } else {
        const start = viewStartMap.get(entry.target);
        viewStartMap.delete(entry.target);
        if (start && (now - start) >= TWEET_DWELL_MS) {
          const data = extractTweetData(entry.target);
          if (data.tweetId && !reportedTweetIds.has(data.tweetId)) {
            reportedTweetIds.add(data.tweetId);
            pendingReports.push({
              ...data,
              viewSeconds: Math.round((now - start) / 1000)
            });
          }
        }
      }
    }
  }, { threshold: 0.5 });

  function observeTweet(node) {
    if (node.dataset.recallTracked) return;
    node.dataset.recallTracked = "1";
    intersectionObserver.observe(node);
  }

  document.querySelectorAll(TWEET_SELECTOR).forEach(observeTweet);

  const mutationObserver = new MutationObserver((mutations) => {
    if (!isContextValid()) { mutationObserver.disconnect(); return; }
    for (const mutation of mutations) {
      for (const node of mutation.addedNodes) {
        if (node.nodeType !== Node.ELEMENT_NODE) continue;
        if (node.matches?.(TWEET_SELECTOR)) {
          observeTweet(node);
        } else {
          const tweets = node.querySelectorAll?.(TWEET_SELECTOR);
          if (tweets) tweets.forEach(observeTweet);
        }
      }
    }
  });
  mutationObserver.observe(document.body, { childList: true, subtree: true });

  const tweetInterval = setInterval(() => {
    if (!isContextValid()) { clearInterval(tweetInterval); return; }
    if (pendingReports.length === 0) return;
    const batch = pendingReports.splice(0);
    sendEngagement({ type: "engagement:x-tweets", tweets: batch });
  }, 5000);

  cleanupCallbacks.push(() => {
    intersectionObserver.disconnect();
    mutationObserver.disconnect();
    clearInterval(tweetInterval);
  });
}

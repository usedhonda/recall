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

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
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

// --- Engagement tracking ---

function sendEngagement(payload) {
  chrome.runtime.sendMessage(payload).catch(() => {});
}

// Visibility tracking
document.addEventListener("visibilitychange", () => {
  sendEngagement({ type: "engagement:visibility", hidden: document.hidden });
});

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

window.addEventListener("scroll", () => {
  if (scrollTimer) return;
  scrollTimer = setTimeout(() => {
    scrollTimer = null;
    const pct = computeScrollPct();
    if (pct > maxScrollPct) {
      maxScrollPct = pct;
      sendEngagement({ type: "engagement:scroll", scrollDepthPct: maxScrollPct });
    }
  }, 2000);
}, { passive: true });

// --- X (twitter.com / x.com) feed tracking ---

const X_DOMAINS = ["x.com", "twitter.com"];
const isXDomain = X_DOMAINS.includes(location.hostname);

if (isXDomain) {
  const TWEET_SELECTOR = 'article[data-testid="tweet"]';
  let tweetsViewed = 0;
  let totalViewMs = 0;
  const viewStartMap = new WeakMap();
  const visibleTweets = new Set();

  const intersectionObserver = new IntersectionObserver((entries) => {
    const now = Date.now();
    for (const entry of entries) {
      if (entry.isIntersecting) {
        if (!viewStartMap.has(entry.target)) {
          tweetsViewed++;
        }
        viewStartMap.set(entry.target, now);
        visibleTweets.add(entry.target);
      } else {
        const start = viewStartMap.get(entry.target);
        if (start) {
          totalViewMs += (now - start);
          viewStartMap.delete(entry.target);
        }
        visibleTweets.delete(entry.target);
      }
    }
  }, { threshold: 0.5 });

  function observeTweet(node) {
    if (node.dataset.recallTracked) return;
    node.dataset.recallTracked = "1";
    intersectionObserver.observe(node);
  }

  // Observe tweets already in the DOM
  document.querySelectorAll(TWEET_SELECTOR).forEach(observeTweet);

  // Watch for new tweets added via infinite scroll
  const mutationObserver = new MutationObserver((mutations) => {
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

  // Report X feed engagement periodically
  setInterval(() => {
    if (tweetsViewed === 0) return;
    const now = Date.now();
    let inFlightMs = 0;
    for (const tweet of visibleTweets) {
      const start = viewStartMap.get(tweet);
      if (start) inFlightMs += (now - start);
    }
    sendEngagement({
      type: "engagement:x-feed",
      tweetsViewed,
      totalViewMs: totalViewMs + inFlightMs
    });
  }, 5000);
}

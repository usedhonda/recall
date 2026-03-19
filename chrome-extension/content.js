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
  if (message?.type !== "extract-page-content") {
    return undefined;
  }

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
});

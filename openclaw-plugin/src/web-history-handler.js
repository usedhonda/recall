import { promises as fs } from "fs";
import { homedir } from "os";
import { join } from "path";
import { getReactionSettings } from "./recall-settings.js";
import { flushSeenIds, getRecentEntries, getStats, storeEntry } from "./web-history-store.js";

const NEXT_MIN_INTERVAL_SEC = 60;
const PREVIEW_LIMIT = 200;
const MEMORY_ROOT = join(homedir(), ".openclaw", "workspace", "memory");
const WEB_HISTORY_STATE_PATH = join(MEMORY_ROOT, "web-history-state.json");
const DEDUP_TTL_MS = 60 * 1000;

// Module-level dedup: prevents duplicate subagent.run from multiple plugin loads
const _sentIds = new Map();
function isDuplicate(key) {
  const now = Date.now();
  if (_sentIds.has(key) && now - _sentIds.get(key) < DEDUP_TTL_MS) return true;
  _sentIds.set(key, now);
  for (const [k, t] of _sentIds) {
    if (now - t > DEDUP_TTL_MS) _sentIds.delete(k);
  }
  return false;
}

function formatJstTime(ts) {
  return ts.toLocaleTimeString("ja-JP", {
    timeZone: "Asia/Tokyo",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

function formatJstDate(ts) {
  return ts.toLocaleDateString("en-CA", { timeZone: "Asia/Tokyo" });
}

function normalizeWhitespace(value) {
  if (typeof value !== "string") return "";
  return value.replace(/\s+/g, " ").trim();
}

function toPreview(content) {
  const normalized = normalizeWhitespace(content);
  if (!normalized) return "";
  if (normalized.length <= PREVIEW_LIMIT) return normalized;
  return `${normalized.slice(0, PREVIEW_LIMIT)}...`;
}

function resolveDomain(urlString, domain) {
  const normalizedDomain = normalizeWhitespace(domain);
  if (normalizedDomain) return normalizedDomain;

  try {
    return new URL(urlString).hostname;
  } catch {
    return "unknown";
  }
}

function normalizeEntry(entry) {
  if (!entry || typeof entry !== "object") return null;

  const id = normalizeWhitespace(entry.id);
  const url = normalizeWhitespace(entry.url);
  if (!id || !url) return null;

  let parsedUrl;
  try {
    parsedUrl = new URL(url);
  } catch {
    return null;
  }

  const visitedAtDate = entry.visitedAt ? new Date(entry.visitedAt) : new Date();
  const visitedAt = Number.isNaN(visitedAtDate.getTime()) ? new Date() : visitedAtDate;
  const dwellSeconds = Number.isFinite(entry.dwellSeconds) ? Math.max(0, Math.round(entry.dwellSeconds)) : 0;
  const title = normalizeWhitespace(entry.title) || parsedUrl.href;
  const domain = resolveDomain(parsedUrl.href, entry.domain);
  const content = typeof entry.content === "string" ? entry.content : "";
  const meta = entry.meta && typeof entry.meta === "object" && !Array.isArray(entry.meta) ? entry.meta : {};

  const engagement = entry.engagement && typeof entry.engagement === "object" && !Array.isArray(entry.engagement)
    ? entry.engagement : null;

  return {
    id,
    url: parsedUrl.href,
    title,
    domain,
    content,
    visitedAt: visitedAt.toISOString(),
    dwellSeconds,
    meta,
    ...(engagement ? { engagement } : {}),
  };
}

async function appendDiaryEntry(entry, log) {
  const visitedAt = new Date(entry.visitedAt);
  const dateStr = formatJstDate(visitedAt);
  const timeStr = formatJstTime(visitedAt);
  const preview = toPreview(entry.content);
  const eng = entry.engagement;
  const viewedTweets = eng?.viewedTweets;
  let engagementTag = "";
  if (Array.isArray(viewedTweets) && viewedTweets.length > 0) {
    engagementTag = ` \u{1F426}${viewedTweets.length} posts read`;
  } else if (eng?.scrollDepthPct > 0 && eng?.engaged) {
    engagementTag = ` \u{1F4D6}${eng.scrollDepthPct}%`;
  }
  const header = `\u{1F310} ${timeStr} - ${entry.title} (${entry.domain}) [${entry.dwellSeconds}s${engagementTag}]\n`;
  let body = "";
  if (Array.isArray(viewedTweets) && viewedTweets.length > 0) {
    body = viewedTweets
      .map((t) => `   ${t.handle || t.author || "?"}: ${normalizeWhitespace(t.text)} (${t.viewSeconds || 0}s)\n`)
      .join("");
  } else if (preview) {
    body = `   ${preview}\n`;
  }
  const diaryPath = join(MEMORY_ROOT, `${dateStr}.md`);

  try {
    await fs.mkdir(MEMORY_ROOT, { recursive: true });
    await fs.appendFile(diaryPath, `${header}${body}`, "utf-8");
  } catch (err) {
    log?.warn?.(`recall-web-history: failed to append diary entry: ${err.message}`);
  }
}

function toRecentEntry(entry) {
  return {
    id: entry.id,
    url: entry.url,
    title: entry.title,
    domain: entry.domain,
    contentPreview: toPreview(entry.content),
    visitedAt: entry.visitedAt,
    dwellSeconds: entry.dwellSeconds,
    engagement: entry.engagement || null,
  };
}

async function persistLatestState(entry, log) {
  const recent = getRecentEntries(10);
  const state = {
    ...entry,
    contentPreview: toPreview(entry.content),
    recentEntries: recent.map(toRecentEntry),
    updatedAt: new Date().toISOString(),
    source: "recall-web-history",
  };

  try {
    await fs.mkdir(MEMORY_ROOT, { recursive: true });
    await fs.writeFile(WEB_HISTORY_STATE_PATH, JSON.stringify(state, null, 2), "utf-8");
  } catch (err) {
    log?.warn?.(`recall-web-history: failed to persist web-history-state.json: ${err.message}`);
  }
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf-8")));
    req.on("error", reject);
  });
}

function sendError(res, status, code, message) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: { code, message } }));
}

function sendJson(res, data) {
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify(data));
}

export function createWebHistoryHandler(api) {
  const log = api.logger;
  const runtime = api.runtime;

  if (runtime?.subagent?.run) {
    log?.info?.("recall-web-history: runtime.subagent.run available");
  } else {
    log?.warn?.("recall-web-history: runtime.subagent.run NOT available — chat delivery will fail");
  }

  function buildDeliveryDirective(settings) {
    const channels = [];
    if (settings.lineDeliveryEnabled) channels.push("LINE");
    if (settings.vibetermDeliveryEnabled) channels.push("Vibeterm");
    if (channels.length === 0) return "\n\u3010\u914D\u4FE1\u5148\u3011\u306A\u3057\uFF08\u914D\u4FE1\u30B9\u30AD\u30C3\u30D7\uFF09";
    return `\n\u3010\u914D\u4FE1\u5148\u3011${channels.join(", ")}`;
  }

  function buildEventText(entry, settings) {
    const lines = [
      "\u{1F310} \u3054\u4E3B\u4EBA\u69D8\u304C\u30A6\u30A7\u30D6\u8A18\u4E8B\u3092\u3057\u3063\u304B\u308A\u8AAD\u3093\u3067\u3044\u305F\u3002web-react \u30B9\u30AD\u30EB\u3067\u53CD\u5FDC\u3057\u3066\u3002",
      "\u3010\u8FD4\u4FE1\u30EB\u30FC\u30EB\u3011\u8FD4\u4FE1\u306E\u5148\u982D\u884C\u306B\u300C\ud83c\udf10 \u30BF\u30A4\u30C8\u30EB (domain)\u300D\u3092\u5FC5\u305A\u542B\u3081\u308B\u3053\u3068\u3002",
      `\u30BF\u30A4\u30C8\u30EB: ${entry.title}`,
      `\u30C9\u30E1\u30A4\u30F3: ${entry.domain}`,
      `URL: ${entry.url}`,
    ];
    if (entry.contentPreview) {
      lines.push(`\u5185\u5BB9: ${entry.contentPreview}`);
    }
    const tweets = entry.engagement?.viewedTweets;
    if (Array.isArray(tweets) && tweets.length > 0) {
      const summary = tweets.map((t) => `@${t.handle || t.author}: ${normalizeWhitespace(t.text)}`).join(" / ");
      lines.push(`\u95B2\u89A7\u30C4\u30A4\u30FC\u30C8: ${summary}`);
    }
    const eng = entry.engagement;
    lines.push(`\u6EDE\u5728: ${entry.dwellSeconds}\u79D2 / \u30A2\u30AF\u30C6\u30A3\u30D6: ${eng?.activeSeconds ?? "?"}\u79D2 / \u30B9\u30AF\u30ED\u30FC\u30EB: ${eng?.scrollDepthPct ?? "?"}%`);
    lines.push(buildDeliveryDirective(settings));
    return lines.join("\n");
  }

  async function trySendChat(entry) {
    if (!entry.engagement?.engaged) return;
    if (!runtime?.subagent?.run) return;

    if (isDuplicate(`web-${entry.id}`)) {
      log?.info?.(`recall-web-history: dedup skip (${entry.id})`);
      return;
    }

    const settings = await getReactionSettings();
    if (!settings.webReactionsEnabled) return;

    // Skip non-X pages with thin content
    const X_DOMAINS = ["x.com", "twitter.com"];
    let isX = false;
    try { isX = X_DOMAINS.includes(new URL(entry.url).hostname); } catch {}
    if (!isX) {
      const minChars = settings.webMinContentChars || 200;
      if (minChars > 0) {
        const contentLen = (entry.content || "").length;
        if (contentLen < minChars) {
          log?.info?.(`recall-web-history: content too short (${contentLen}/${minChars}), skipping reaction`);
          return;
        }
      }
    }

    const wantsLine = settings.lineDeliveryEnabled;
    const wantsVibeterm = settings.vibetermDeliveryEnabled;
    if (!wantsLine && !wantsVibeterm) return;

    const eventText = buildEventText(entry, settings);

    // Single subagent.run: deliver=true sends to LINE, WS broadcast always sends to Vibeterm
    try {
      await runtime.subagent.run({
        sessionKey: "main",
        message: eventText,
        deliver: wantsLine,
        idempotencyKey: `web-${entry.id}-${Date.now()}`,
      });
      log?.info?.(`recall-web-history: subagent.run sent (LINE=${wantsLine}, Vibeterm=${wantsVibeterm})`);
    } catch (err) {
      log?.warn?.(`recall-web-history: subagent.run failed: ${err.message}`);
    }
  }

  return async (req, res) => {
    if (req.method !== "POST") {
      sendError(res, 405, "METHOD_NOT_ALLOWED", "Only POST is accepted");
      return;
    }

    let body;
    try {
      const raw = await readBody(req);
      body = JSON.parse(raw);
    } catch {
      sendError(res, 400, "BAD_REQUEST", "Invalid JSON body");
      return;
    }

    if (!Array.isArray(body.entries)) {
      sendError(res, 400, "BAD_REQUEST", '"entries" array is required');
      return;
    }

    let received = 0;
    for (const rawEntry of body.entries) {
      const entry = normalizeEntry(rawEntry);
      if (!entry) {
        log?.debug?.(`recall-web-history: skipping invalid entry: ${JSON.stringify(rawEntry).slice(0, 160)}`);
        continue;
      }

      if (!storeEntry(entry)) {
        continue;
      }

      received++;
      await appendDiaryEntry(entry, log);
      await persistLatestState(entry, log);
      await trySendChat(entry);
    }

    if (received > 0) {
      await flushSeenIds();
    }

    const stats = getStats();
    log?.info?.(
      `recall-web-history: processed ${body.entries.length} entries, ${received} new` +
      ` dedupSize=${stats.dedupSize} historySize=${stats.historySize} lastEntryAt=${stats.lastEntryAt ?? "-"}`
    );

    sendJson(res, {
      received,
      nextMinIntervalSec: NEXT_MIN_INTERVAL_SEC,
    });
  };
}

import { promises as fs } from "fs";
import { homedir } from "os";
import { join } from "path";
import { verifyAuth } from "./auth.js";
import { flushSeenIds, getStats, storeEntry } from "./web-history-store.js";

const NEXT_MIN_INTERVAL_SEC = 60;
const PREVIEW_LIMIT = 200;
const MEMORY_ROOT = join(homedir(), ".openclaw", "workspace", "memory");
const WEB_HISTORY_STATE_PATH = join(MEMORY_ROOT, "web-history-state.json");

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

  return {
    id,
    url: parsedUrl.href,
    title,
    domain,
    content,
    visitedAt: visitedAt.toISOString(),
    dwellSeconds,
    meta,
  };
}

async function appendDiaryEntry(entry, log) {
  const visitedAt = new Date(entry.visitedAt);
  const dateStr = formatJstDate(visitedAt);
  const timeStr = formatJstTime(visitedAt);
  const preview = toPreview(entry.content);
  const header = `\u{1F310} ${timeStr} - ${entry.title} (${entry.domain}) [${entry.dwellSeconds}s]\n`;
  const body = preview ? `   ${preview}\n` : "";
  const diaryPath = join(MEMORY_ROOT, `${dateStr}.md`);

  try {
    await fs.mkdir(MEMORY_ROOT, { recursive: true });
    await fs.appendFile(diaryPath, `${header}${body}`, "utf-8");
  } catch (err) {
    log?.warn?.(`recall-web-history: failed to append diary entry: ${err.message}`);
  }
}

async function persistLatestState(entry, log) {
  const state = {
    ...entry,
    contentPreview: toPreview(entry.content),
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
  const gatewayToken = api.config?.gateway?.auth?.token;
  const log = api.logger;

  if (!gatewayToken) {
    log?.warn?.("recall-web-history: no gateway auth token found in config");
  }

  return async (req, res) => {
    if (req.method !== "POST") {
      sendError(res, 405, "METHOD_NOT_ALLOWED", "Only POST is accepted");
      return;
    }

    if (gatewayToken) {
      const auth = verifyAuth(req, gatewayToken);
      if (!auth.valid) {
        log?.debug?.(`recall-web-history: auth failed: ${auth.error}`);
        sendError(res, 401, "UNAUTHORIZED", auth.error);
        return;
      }
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

/**
 * Voice transcript handler — POST /api/voice-transcript
 *
 * Receives transcription results from VoiceLog, writes diary entries,
 * and optionally triggers Chi reaction via system-event + cron.wake.
 */

import { promises as fs } from "fs";
import { homedir } from "os";
import { join } from "path";
import { verifyAuth } from "./auth.js";
import { getReactionSettings } from "./recall-settings.js";

const MEMORY_ROOT = join(homedir(), ".openclaw", "workspace", "memory");
const STATE_PATH = join(MEMORY_ROOT, "voice-transcript-state.json");
const MAX_SEGMENTS = 20;

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

async function appendDiaryEntry(data, log) {
  const startedAt = data.started_at ? new Date(data.started_at) : new Date();
  const dateStr = formatJstDate(startedAt);
  const timeStr = formatJstTime(startedAt);
  const durationSec = Math.round(data.duration_sec || 0);
  const lang = data.language || "?";
  const speakerCount = data.speaker_count || 0;

  const header = `\u{1F399} ${timeStr} - [${speakerCount} speaker${speakerCount !== 1 ? "s" : ""}, ${durationSec}s] ${lang}\n`;

  let body = "";
  const segments = data.segments || [];
  for (const seg of segments.slice(0, MAX_SEGMENTS)) {
    const speaker = seg.speaker || "?";
    const text = (seg.text || "").replace(/\s+/g, " ").trim();
    if (text) {
      body += `   ${speaker}: ${text}\n`;
    }
  }
  if (segments.length > MAX_SEGMENTS) {
    body += `   ... (${segments.length - MAX_SEGMENTS} more segments)\n`;
  }

  const diaryPath = join(MEMORY_ROOT, `${dateStr}.md`);
  try {
    await fs.mkdir(MEMORY_ROOT, { recursive: true });
    await fs.appendFile(diaryPath, `${header}${body}`, "utf-8");
  } catch (err) {
    log?.warn?.(`voice-transcript: failed to append diary: ${err.message}`);
  }
}

async function persistState(data, log) {
  const state = {
    recording_id: data.recording_id,
    duration_sec: data.duration_sec,
    speaker_count: data.speaker_count,
    language: data.language,
    started_at: data.started_at,
    updatedAt: new Date().toISOString(),
    source: "voice-transcript",
  };
  try {
    await fs.mkdir(MEMORY_ROOT, { recursive: true });
    await fs.writeFile(STATE_PATH, JSON.stringify(state, null, 2), "utf-8");
  } catch (err) {
    log?.warn?.(`voice-transcript: failed to persist state: ${err.message}`);
  }
}

function buildEventText(data) {
  const segments = data.segments || [];
  const durationSec = Math.round(data.duration_sec || 0);
  const lang = data.language || "?";
  const speakerCount = data.speaker_count || 0;

  const lines = [
    "\u{1F399} \u3054\u4E3B\u4EBA\u69D8\u306E\u4F1A\u8A71\u304C\u6587\u5B57\u8D77\u3053\u3057\u3055\u308C\u305F\u3002voice-react \u30B9\u30AD\u30EB\u3067\u53CD\u5FDC\u3057\u3066\u3002",
    `\u8A71\u8005\u6570: ${speakerCount} / \u8A00\u8A9E: ${lang} / \u6642\u9593: ${durationSec}\u79D2`,
    "\u5185\u5BB9:",
  ];

  for (const seg of segments.slice(0, MAX_SEGMENTS)) {
    const speaker = seg.speaker || "?";
    const text = (seg.text || "").replace(/\s+/g, " ").trim();
    if (text) {
      lines.push(`${speaker}: ${text}`);
    }
  }

  return lines.join("\n");
}

export function createVoiceTranscriptHandler(api) {
  const gatewayToken = api.config?.gateway?.auth?.token;
  const log = api.logger;

  function rpc(method, params) {
    return fetch("http://127.0.0.1:18789/rpc", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${gatewayToken}`,
      },
      body: JSON.stringify({ method, params }),
    });
  }

  async function tryWakeCron(data) {
    if (!gatewayToken) return;

    const settings = await getReactionSettings();
    if (!settings.voiceReactionsEnabled) return;

    const eventText = buildEventText(data);
    rpc("system-event", { text: eventText })
      .then(() => log?.info?.("voice-transcript: system-event sent"))
      .catch(() => {});

    rpc("cron.wake", { mode: "now", text: "voice transcript received" })
      .then(() => log?.info?.("voice-transcript: cron.wake sent"))
      .catch(() => {});
  }

  return async (req, res) => {
    if (req.method !== "POST") {
      sendError(res, 405, "METHOD_NOT_ALLOWED", "Only POST is accepted");
      return;
    }

    if (gatewayToken) {
      const auth = verifyAuth(req, gatewayToken);
      if (!auth.valid) {
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

    if (!body.event || body.event !== "recording_stored") {
      sendError(res, 400, "BAD_REQUEST", 'Expected event: "recording_stored"');
      return;
    }

    log?.info?.(
      `voice-transcript: received recording=${body.recording_id} ` +
        `duration=${body.duration_sec}s speakers=${body.speaker_count} lang=${body.language}`
    );

    await appendDiaryEntry(body, log);
    await persistState(body, log);
    await tryWakeCron(body);

    sendJson(res, { received: true });
  };
}

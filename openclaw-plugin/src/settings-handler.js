/**
 * Settings handler — GET/POST /api/recall-settings
 *
 * Allows recall iOS to read and update Chi reaction toggles.
 */

import { verifyAuth } from "./auth.js";
import { getReactionSettings, saveReactionSettings } from "./recall-settings.js";

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

export function createSettingsHandler(api) {
  const gatewayToken = api.config?.gateway?.auth?.token;
  const log = api.logger;

  return async (req, res) => {
    if (gatewayToken) {
      const auth = verifyAuth(req, gatewayToken);
      if (!auth.valid) {
        sendError(res, 401, "UNAUTHORIZED", auth.error);
        return;
      }
    }

    if (req.method === "GET") {
      const settings = await getReactionSettings();
      sendJson(res, settings);
      return;
    }

    if (req.method === "POST") {
      let body;
      try {
        const raw = await readBody(req);
        body = JSON.parse(raw);
      } catch {
        sendError(res, 400, "BAD_REQUEST", "Invalid JSON body");
        return;
      }

      const saved = await saveReactionSettings(body);
      log?.info?.(`recall-settings: updated ${JSON.stringify(saved)}`);
      sendJson(res, saved);
      return;
    }

    sendError(res, 405, "METHOD_NOT_ALLOWED", "Only GET and POST are accepted");
  };
}

import { readJsonObject, sendBodyError } from "./json-body.js";
/**
 * Settings handler — GET/POST /api/recall-settings
 *
 * Allows recall iOS to read and update reaction toggles.
 */

import { verifyAuth } from "./auth.js";
import { getReactionSettings, saveReactionSettings } from "./recall-settings.js";


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
        body = await readJsonObject(req);
      } catch (err) {
        sendBodyError(res, err);
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

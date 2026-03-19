/**
 * Recall Telemetry plugin for OpenClaw.
 *
 * Registers POST /api/telemetry - receives location and health telemetry
 * and POST /api/web-history - receives browsing history from recall clients.
 */

import { createTelemetryHandler } from "./src/handler.js";
import { createSettingsHandler } from "./src/settings-handler.js";
import { createVoiceTranscriptHandler } from "./src/voice-transcript-handler.js";
import { createWebHistoryHandler } from "./src/web-history-handler.js";

const plugin = {
  id: "recall-telemetry",
  name: "Recall Telemetry",
  description: "REST endpoints for recall telemetry and web history ingestion",

  configSchema: {
    type: "object",
    additionalProperties: false,
    properties: {},
  },

  register(api) {
    const telemetryHandler = createTelemetryHandler(api);
    const webHistoryHandler = createWebHistoryHandler(api);
    const settingsHandler = createSettingsHandler(api);
    const voiceTranscriptHandler = createVoiceTranscriptHandler(api);
    api.registerHttpRoute({
      path: "/api/telemetry",
      handler: telemetryHandler,
      auth: "gateway",
    });
    api.logger?.info?.("recall-telemetry: registered POST /api/telemetry");
    api.registerHttpRoute({
      path: "/api/web-history",
      handler: webHistoryHandler,
      auth: "gateway",
    });
    api.logger?.info?.("recall-web-history: registered POST /api/web-history");
    api.registerHttpRoute({
      path: "/api/recall-settings",
      handler: settingsHandler,
      auth: "gateway",
    });
    api.logger?.info?.("recall-settings: registered GET/POST /api/recall-settings");
    api.registerHttpRoute({
      path: "/api/voice-transcript",
      handler: voiceTranscriptHandler,
      auth: "gateway",
    });
    api.logger?.info?.("voice-transcript: registered POST /api/voice-transcript");
  },
};

export default plugin;

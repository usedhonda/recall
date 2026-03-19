/**
 * Recall Telemetry plugin for OpenClaw.
 *
 * Registers POST /api/telemetry - receives location and health telemetry
 * and POST /api/web-history - receives browsing history from recall clients.
 */

import { createTelemetryHandler } from "./src/handler.js";
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
  },
};

export default plugin;

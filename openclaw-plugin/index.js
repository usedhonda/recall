/**
 * Recall Telemetry plugin for OpenClaw.
 *
 * Registers POST /api/telemetry - receives location and health telemetry
 * from the recall iOS app.
 */

import { createTelemetryHandler } from "./src/handler.js";

const plugin = {
  id: "recall-telemetry",
  name: "Recall Telemetry",
  description: "REST endpoint for recall iOS location and health telemetry",

  configSchema: {
    type: "object",
    additionalProperties: false,
    properties: {},
  },

  register(api) {
    const handler = createTelemetryHandler(api);
    api.registerHttpRoute({
      path: "/api/telemetry",
      handler,
      auth: "gateway",
    });
    api.logger?.info?.("recall-telemetry: registered POST /api/telemetry");
  },
};

export default plugin;

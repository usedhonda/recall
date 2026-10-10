import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { createTelemetryHandler } from "../src/handler.js";

function request(body) {
  const req = new PassThrough();
  req.method = "POST";
  req.headers = {};
  req.end(JSON.stringify(body));
  return req;
}

function response() {
  return {
    statusCode: 0,
    body: "",
    writeHead(status) { this.statusCode = status; },
    end(value) { this.body = value; },
  };
}

const api = { config: {}, logger: { warn() {}, debug() {}, info() {} } };
const health2 = {
  collectedAt: "2026-01-01T00:00:00Z",
  records: [{
    metricId: "HKQuantityTypeIdentifierStepCount",
    value: 12,
    valueText: null,
    unit: "count",
    aggregation: "cumulativeSum",
    measuredAt: "2026-01-01T00:00:00Z",
    intervalStart: null,
    intervalEnd: "2026-01-01T00:00:00Z",
    sampleCount: 1,
    source: "Health",
    sourceBundleId: "com.apple.Health",
    deviceModel: "iPhone",
  }],
  sleep: null,
  workouts: [],
};

test("health2 is preserved and acknowledged only after isolated persistence", async () => {
  const root = await mkdtemp(join(tmpdir(), "recall-telemetry-test-"));
  const handler = createTelemetryHandler(api, { storageRoot: root, disableDiary: true });
  const res = response();
  await handler(request({ samples: [], health2 }), res);
  assert.equal(res.statusCode, 200);
  assert.equal(JSON.parse(res.body).healthReceived, true);
  const persisted = JSON.parse(await readFile(join(root, "health2-state.json"), "utf8"));
  assert.equal(persisted.records[0].metricId, health2.records[0].metricId);
  assert.equal(persisted.records[0].sourceBundleId, "com.apple.Health");
});

test("persistence failure refuses Health but keeps valid GPS independent", async () => {
  const root = await mkdtemp(join(tmpdir(), "recall-telemetry-test-"));
  await mkdir(join(root, "health2-state.json"));
  const handler = createTelemetryHandler(api, { storageRoot: root, disableDiary: true });
  const res = response();
  await handler(request({
    samples: [{ id: "gps-1", lat: 35.6, lon: 139.6, accuracy: 5, timestamp: "2026-01-01T00:00:00Z" }],
    health2,
  }), res);
  const result = JSON.parse(res.body);
  assert.equal(result.received, 1);
  assert.equal(result.healthReceived, false);
});

test("legacy flat health remains accepted independently", async () => {
  const root = await mkdtemp(join(tmpdir(), "recall-telemetry-test-"));
  const handler = createTelemetryHandler(api, { storageRoot: root, disableDiary: true });
  const res = response();
  await handler(request({ health: { steps: 3 } }), res);
  assert.equal(JSON.parse(res.body).healthReceived, true);
});

test("null health2 records are refused without affecting GPS", async () => {
  const root = await mkdtemp(join(tmpdir(), "recall-telemetry-test-"));
  const handler = createTelemetryHandler(api, { storageRoot: root, disableDiary: true });
  const res = response();
  await handler(request({
    samples: [{ id: "gps-2", lat: 35.6, lon: 139.6, accuracy: 5, timestamp: "2026-01-01T00:00:00Z" }],
    health2: { ...health2, records: [null] },
  }), res);
  const result = JSON.parse(res.body);
  assert.equal(result.received, 1);
  assert.equal(result.healthReceived, false);
});

test("GPS retry reports acknowledged ID while received counts only new storage", async () => {
  const root = await mkdtemp(join(tmpdir(), "recall-telemetry-test-"));
  const handler = createTelemetryHandler(api, { storageRoot: root, disableDiary: true });
  const body = { samples: [{ id: "gps-retry", lat: 35.6, lon: 139.6, accuracy: 5, timestamp: "2026-01-01T00:00:00Z" }] };
  const first = response();
  await handler(request(body), first);
  const second = response();
  await handler(request(body), second);
  assert.deepEqual(JSON.parse(first.body).acknowledgedIDs, ["gps-retry"]);
  assert.deepEqual(JSON.parse(second.body).acknowledgedIDs, ["gps-retry"]);
  assert.equal(JSON.parse(second.body).received, 0);
});

import test from "node:test";
import assert from "node:assert/strict";
import { PassThrough } from "node:stream";
import { readJsonObject } from "../src/json-body.js";
import { createTelemetryHandler } from "../src/handler.js";
import { createSettingsHandler } from "../src/settings-handler.js";
import { createWebHistoryHandler } from "../src/web-history-handler.js";
import { createVoiceTranscriptHandler } from "../src/voice-transcript-handler.js";

function request(raw, headers = {}) {
  const req = new PassThrough();
  req.method = "POST";
  req.headers = headers;
  if (raw !== undefined) req.end(raw);
  return req;
}

test("body byte limit includes multibyte and chunked input, including declared excess", async () => {
  const raw = Buffer.from('{"text":"é"}');
  assert.deepEqual(await readJsonObject(request(raw), { maxBytes: raw.length }), { text: "é" });
  const req = request();
  const rejected = assert.rejects(readJsonObject(req, { maxBytes: raw.length - 1 }), { status: 413 });
  req.write(raw.subarray(0, 5));
  req.end(raw.subarray(5));
  await rejected;
  const declared = request(undefined, { "content-length": String(raw.length + 1) });
  await assert.rejects(readJsonObject(declared, { maxBytes: raw.length }), { status: 413 });
  assert.equal(declared.listenerCount("data"), 0, "rejection stops retaining input");
  declared.end();
});

test("aborted, closed and failed body reads settle and release their data listeners", async () => {
  for (const event of ["aborted", "close", "error"]) {
    const req = request();
    const rejected = assert.rejects(readJsonObject(req), { status: 400 });
    req.write('{"partial":');
    req.emit(event, new Error("synthetic transport detail"));
    await rejected;
    assert.equal(req.listenerCount("data"), 0, event);
    // IncomingMessage can emit error after aborted/close; this must not throw.
    req.emit("error", new Error("synthetic late transport detail"));
    req.end();
  }
});

test("the complete read has a deadline even when a body never ends", { timeout: 1000 }, async () => {
  const req = request();
  req.write('{"partial":');
  await assert.rejects(readJsonObject(req, { timeoutMs: 20 }), { status: 408 });
  assert.equal(req.listenerCount("data"), 0);
  req.end();
});

test("all POST routes reject malformed roots and oversized requests before side effects", async () => {
  const api = { config: {}, logger: { warn() {}, debug() {}, info() {} } };
  const factories = [createTelemetryHandler, createSettingsHandler, createWebHistoryHandler, createVoiceTranscriptHandler];
  for (const createHandler of factories) {
    const handler = createHandler(api);
    for (const raw of ["null", "[]", "true", '"text"', "{"]) {
      const res = { writeHead(status) { this.status = status; }, end(body) { this.body = JSON.parse(body); } };
      await handler(request(raw), res);
      assert.equal(res.status, 400, `${createHandler.name}: ${raw}`);
      assert.equal(res.body.error.code, "BAD_REQUEST");
    }
    const req = request(undefined, { "content-length": String(2 * 1024 * 1024 + 1) });
    const res = { writeHead(status) { this.status = status; }, end(body) { this.body = JSON.parse(body); } };
    await handler(req, res);
    assert.equal(res.status, 413, createHandler.name);
    assert.equal(req.listenerCount("data"), 0);
    req.end();
  }
});

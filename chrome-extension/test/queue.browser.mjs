// Run with Node and Playwright installed. Only a loopback fixture server is used.
// RECALL_TEST_CHROMIUM can select an existing Chromium executable.
import test, { before, after } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
const { chromium } = createRequire(import.meta.url)("playwright");

let browser, server, origin;
before(async () => {
  server = createServer(async (req, res) => {
    const files = new Set(["/lib/queue.js", "/lib/upload-queue.js", "/lib/api.js"]);
    if (files.has(req.url)) {
      res.setHeader("Content-Type", "text/javascript");
      res.end(await readFile(new URL(`..${req.url}`, import.meta.url)));
    } else {
      res.setHeader("Content-Type", "text/html");
      res.end("<!doctype html><title>Recall queue regression fixture</title>");
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  origin = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({
    headless: true,
    ...(process.env.RECALL_TEST_CHROMIUM ? { executablePath: process.env.RECALL_TEST_CHROMIUM } : {}),
  });
});
after(async () => {
  await browser?.close();
  if (server) await new Promise((resolve) => server.close(resolve));
});

test("an interrupted first send and interrupted drain both retain durable rows", async () => {
  const context = await browser.newContext();
  try {
    let page = await context.newPage();
    await page.goto(origin);
    await page.evaluate(async () => {
      const { enqueueAndSend } = await import("/lib/upload-queue.js");
      window.started = false;
      void enqueueAndSend({ id: "pending-first-send", visitedAt: new Date().toISOString() }, async () => {
        window.started = true;
        await new Promise(() => {});
      });
    });
    await page.waitForFunction(() => window.started);
    await page.close();
    page = await context.newPage();
    await page.goto(origin);
    assert.deepEqual(await page.evaluate(async () => (await (await import("/lib/queue.js")).readAll()).map((row) => row.entry.id)), ["pending-first-send"]);
    await page.evaluate(async () => {
      const { flushPending } = await import("/lib/upload-queue.js");
      window.started = false;
      void flushPending(async () => { window.started = true; await new Promise(() => {}); });
    });
    await page.waitForFunction(() => window.started);
    await page.close();
    page = await context.newPage();
    await page.goto(origin);
    const result = await page.evaluate(async () => {
      const queue = await import("/lib/queue.js");
      const { flushPending } = await import("/lib/upload-queue.js");
      const before = await queue.count();
      const sent = [];
      await flushPending(async (entry) => { sent.push(entry.id); });
      return { before, after: await queue.count(), sent };
    });
    assert.deepEqual(result, { before: 1, after: 0, sent: ["pending-first-send"] });
  } finally { await context.close(); }
});

test("failure retains keys/order, acknowledgment preserves concurrent rows, and retention still applies", async () => {
  const context = await browser.newContext();
  try {
    const page = await context.newPage();
    await page.goto(origin);
    const result = await page.evaluate(async () => {
      const queue = await import("/lib/queue.js");
      const { flushPending } = await import("/lib/upload-queue.js");
      const fresh = new Date().toISOString();
      await queue.enqueue({ id: "expired", visitedAt: "2000-01-01T00:00:00Z" });
      await queue.enqueue({ id: "accepted", visitedAt: fresh });
      const failedKey = await queue.enqueue({ id: "failed", visitedAt: fresh });
      const laterKey = await queue.enqueue({ id: "later", visitedAt: fresh });
      const summary = await flushPending(async (entry) => {
        if (entry.id === "failed") throw new Error("controlled delivery failure");
        await queue.enqueue({ id: "concurrent", visitedAt: fresh });
      }, { onSent: async () => { throw new Error("controlled activity-display failure"); } });
      const retained = await queue.readAll();
      return { summary, retained: retained.map((row) => row.entry.id), keys: retained.slice(0, 2).map((row) => row.key), expectedKeys: [failedKey, laterKey] };
    });
    assert.deepEqual(result.summary, { attempted: 3, sent: 1, requeued: 2 });
    assert.deepEqual(result.retained, ["failed", "later", "concurrent"]);
    assert.deepEqual(result.keys, result.expectedKeys);
  } finally { await context.close(); }
});

test("the existing queue capacity retains the newest 1000 entries", async () => {
  const context = await browser.newContext();
  try {
    const page = await context.newPage();
    await page.goto(origin);
    const result = await page.evaluate(async () => {
      const queue = await import("/lib/queue.js");
      for (let id = 0; id < 1001; id++) await queue.enqueue({ id });
      const rows = await queue.readAll();
      return { count: rows.length, first: rows[0].entry.id, last: rows.at(-1).entry.id };
    });
    assert.deepEqual(result, { count: 1000, first: 1, last: 1000 });
  } finally { await context.close(); }
});

test("a timeout during a successful response body preserves the pending upload", async () => {
  const context = await browser.newContext();
  try {
    const page = await context.newPage();
    await page.goto(origin);
    const result = await page.evaluate(async () => {
      const { sendEntries } = await import("/lib/api.js");
      const { enqueueAndSend } = await import("/lib/upload-queue.js");
      const queue = await import("/lib/queue.js");
      const originalFetch = window.fetch, originalTimeout = window.setTimeout;
      try {
        window.setTimeout = (callback, delay) => originalTimeout(callback, delay === 20_000 ? 5 : delay);
        window.fetch = async (_url, { signal }) => ({
          ok: true, status: 200, headers: new Headers({ "Content-Type": "application/json" }),
          json: () => new Promise((_resolve, reject) => signal.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")), { once: true })),
        });
        const status = await enqueueAndSend({ id: "timed-out", visitedAt: new Date().toISOString() }, (entry) => sendEntries(location.origin, "fixture-token", [entry]));
        return { status, ids: (await queue.readAll()).map((row) => row.entry.id) };
      } finally { window.fetch = originalFetch; window.setTimeout = originalTimeout; }
    });
    assert.deepEqual(result, { status: "queued", ids: ["timed-out"] });
  } finally { await context.close(); }
});

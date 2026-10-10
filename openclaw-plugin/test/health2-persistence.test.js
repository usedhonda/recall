import test from "node:test";
import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { persistHealth2Json } from "../src/health2-persistence.js";

function gate() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

test("same-path concurrent long and short Health publications serialize", async () => {
  const root = await fs.mkdtemp(join(tmpdir(), "recall-health-atomic-"));
  const path = join(root, "health2-state.json");
  const entered = gate();
  const release = gate();
  let opens = 0;
  const io = {
    ...fs,
    async open(...args) {
      opens += 1;
      const handle = await fs.open(...args);
      if (opens !== 1) return handle;
      return {
        async writeFile(...values) {
          entered.resolve();
          await release.promise;
          return handle.writeFile(...values);
        },
        sync: () => handle.sync(),
        close: () => handle.close(),
      };
    },
  };
  const long = { records: [{ valueText: "x".repeat(10000) }] };
  const short = { records: [] };
  const first = persistHealth2Json(path, long, io);
  await entered.promise;
  const second = persistHealth2Json(path, short, io);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(opens, 1, "second writer cannot open before first publication");
  release.resolve();
  await first;
  await second;
  assert.equal(opens, 2);
  assert.deepEqual(JSON.parse(await fs.readFile(path, "utf8")), short);
  assert.deepEqual(await fs.readdir(root), ["health2-state.json"]);
});

test("partial failed write preserves previous acknowledged JSON and permits retry", async () => {
  const root = await fs.mkdtemp(join(tmpdir(), "recall-health-atomic-"));
  const path = join(root, "health2-state.json");
  const original = { records: [{ value: 12 }] };
  await persistHealth2Json(path, original);
  const io = {
    ...fs,
    async open(...args) {
      const handle = await fs.open(...args);
      return {
        async writeFile() {
          await handle.writeFile("{partial", "utf8");
          throw new Error("controlled write failure");
        },
        sync: () => handle.sync(),
        close: () => handle.close(),
      };
    },
  };
  await assert.rejects(persistHealth2Json(path, { records: [] }, io), /controlled write failure/);
  assert.deepEqual(JSON.parse(await fs.readFile(path, "utf8")), original);
  assert.deepEqual(await fs.readdir(root), ["health2-state.json"]);
  await persistHealth2Json(path, { records: [] });
  assert.deepEqual(JSON.parse(await fs.readFile(path, "utf8")), { records: [] });
});

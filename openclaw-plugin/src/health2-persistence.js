import { promises as fs } from "node:fs";
import { randomUUID } from "node:crypto";
import { dirname } from "node:path";

// Shared across handler instances: one final path has one publication owner.
const pendingWrites = new Map();

export async function persistHealth2Json(path, state, io = fs) {
  const previous = pendingWrites.get(path) ?? Promise.resolve();
  const operation = previous.then(async () => {
    const temporary = `${path}.${randomUUID()}.tmp`;
    let handle;
    try {
      await io.mkdir(dirname(path), { recursive: true });
      handle = await io.open(temporary, "wx", 0o600);
      await handle.writeFile(JSON.stringify(state, null, 2), "utf8");
      await handle.sync();
      await handle.close();
      handle = undefined;
      await io.rename(temporary, path);
    } finally {
      await handle?.close().catch(() => {});
      await io.unlink(temporary).catch(() => {});
    }
  });
  // A failed write must not poison subsequent writes to this destination.
  const settled = operation.catch(() => {});
  pendingWrites.set(path, settled);
  try {
    await operation;
  } finally {
    if (pendingWrites.get(path) === settled) pendingWrites.delete(path);
  }
}

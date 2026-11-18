import { enqueue, readAll, acknowledge } from "./queue.js";

export async function enqueueAndSend(entry, send) {
  // Persist before the first network await. A stopped worker must leave a retry.
  const key = await enqueue(entry);
  try {
    await send(entry);
    await acknowledge([key]);
    return "sent";
  } catch (err) {
    console.warn(`[recall] send failed, retained in queue: ${err instanceof Error ? err.message : String(err)}`);
    return "queued";
  }
}

export async function flushPending(send, { onSent = async () => {}, maxAgeMs = 2 * 60 * 60 * 1000, now = Date.now() } = {}) {
  const rows = await readAll();
  if (rows.length === 0) {
    return { attempted: 0, sent: 0, requeued: 0 };
  }

  // Keep the existing two-hour retention policy, retiring only expired keys.
  const expiredKeys = [];
  const pendingRows = rows.filter(({ key, entry }) => {
    const ts = entry.visitedAt ? new Date(entry.visitedAt).getTime() : 0;
    if (now - ts > maxAgeMs) {
      expiredKeys.push(key);
      return false;
    }
    return true;
  });
  await acknowledge(expiredKeys);
  if (pendingRows.length === 0) {
    return { attempted: rows.length, sent: 0, requeued: 0 };
  }

  let sent = 0;
  let requeued = 0;
  for (let index = 0; index < pendingRows.length; index += 1) {
    const { key, entry } = pendingRows[index];
    try {
      await send(entry);
      await acknowledge([key]);
    } catch {
      // No delete/reinsert cycle: preserve IDs, insertion order and retry state.
      requeued = pendingRows.length - index;
      break;
    }
    sent += 1;
    try {
      await onSent(entry);
    } catch {
      // Activity display failure cannot change an accepted delivery back to pending.
      console.warn("[recall] failed to update recent activity after delivery");
    }
  }

  return { attempted: pendingRows.length, sent, requeued };
}

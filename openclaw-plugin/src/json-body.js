const MAX_BODY_BYTES = 2 * 1024 * 1024;
const BODY_TIMEOUT_MS = 15_000;

class BodyError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function invalidBody() {
  return new BodyError(400, "BAD_REQUEST", "A complete JSON object body is required");
}

// Bound retained bytes and the complete read, including requests that stop
// producing data without ending. The surrounding Gateway still owns admission.
export async function readJsonObject(req, { maxBytes = MAX_BODY_BYTES, timeoutMs = BODY_TIMEOUT_MS } = {}) {
  const raw = await new Promise((resolve, reject) => {
    let chunks = [];
    let bytes = 0;
    let settled = false;
    let timer;

    const cleanup = () => {
      clearTimeout(timer);
      req.removeListener("data", onData);
      req.removeListener("end", onEnd);
      req.removeListener("aborted", onAborted);
      req.removeListener("close", onAborted);
    };
    const fail = (error) => {
      if (settled) return;
      settled = true;
      cleanup();
      chunks = [];
      // Leave onError installed: an aborted IncomingMessage can emit error
      // after aborted/close. Remaining bytes are discarded, never accumulated.
      req.resume();
      reject(error);
    };
    const onError = () => fail(invalidBody());
    const onAborted = () => fail(invalidBody());
    const onData = (value) => {
      const chunk = Buffer.isBuffer(value) ? value : Buffer.from(value);
      bytes += chunk.length;
      if (bytes > maxBytes) {
        fail(new BodyError(413, "PAYLOAD_TOO_LARGE", "Request body exceeds the byte limit"));
        return;
      }
      chunks.push(chunk);
    };
    const onEnd = () => {
      if (settled) return;
      settled = true;
      cleanup();
      req.removeListener("error", onError);
      resolve(Buffer.concat(chunks, bytes).toString("utf8"));
      chunks = [];
    };

    req.on("error", onError);
    req.on("aborted", onAborted);
    req.on("close", onAborted);
    req.on("end", onEnd);
    req.on("data", onData);
    const declaredLength = req.headers?.["content-length"];
    if (typeof declaredLength === "string" && /^\d+$/.test(declaredLength) && Number(declaredLength) > maxBytes) {
      fail(new BodyError(413, "PAYLOAD_TOO_LARGE", "Request body exceeds the byte limit"));
    } else if (req.destroyed || req.aborted) {
      fail(invalidBody());
    } else {
      timer = setTimeout(() => fail(new BodyError(408, "REQUEST_TIMEOUT", "Request body was not completed in time")), timeoutMs);
    }
  });

  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    throw invalidBody();
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) throw invalidBody();
  return body;
}

export function sendBodyError(res, error) {
  const failure = error instanceof BodyError ? error : invalidBody();
  res.writeHead(failure.status, {
    "Content-Type": "application/json",
    "Connection": "close",
    "Cache-Control": "no-store",
  });
  res.end(JSON.stringify({ error: { code: failure.code, message: failure.message } }));
}

function normalizeBaseUrl(serverURL) {
  if (typeof serverURL !== "string" || !serverURL.trim()) {
    throw new Error("Server URL is required");
  }

  const parsed = new URL(serverURL.trim());
  if (!["http:", "https:"].includes(parsed.protocol)) {
    throw new Error("Server URL must use http or https");
  }

  return parsed;
}

async function parseResponseBody(response) {
  const contentType = response.headers.get("content-type") || "";
  if (contentType.includes("application/json")) {
    try {
      return await response.json();
    } catch {
      return null;
    }
  }

  try {
    return await response.text();
  } catch {
    return null;
  }
}

export async function sendEntries(serverURL, token, entries) {
  if (!Array.isArray(entries) || entries.length === 0) {
    return { received: 0 };
  }
  if (typeof token !== "string" || !token.trim()) {
    throw new Error("Authentication token is required");
  }

  const base = normalizeBaseUrl(serverURL);
  const endpoint = new URL("/api/web-history", base);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20_000);
  try {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token.trim()}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({ entries }),
      signal: controller.signal
    });

    const body = await parseResponseBody(response);
    // parseResponseBody tolerates an absent/malformed body, but cancellation
    // during body consumption is not an acknowledgment of this upload.
    if (controller.signal.aborted) throw new Error("Upload timed out");
    if (!response.ok) {
      const detail = typeof body === "string" ? body : JSON.stringify(body);
      throw new Error(`Upload failed (${response.status}): ${detail}`);
    }

    return body || { received: entries.length };
  } finally {
    clearTimeout(timer);
  }
}

export async function checkHealth(serverURL) {
  try {
    const base = normalizeBaseUrl(serverURL);
    const endpoint = new URL("/health", base);
    const response = await fetch(endpoint, { method: "GET" });
    const body = await parseResponseBody(response);
    return {
      ok: response.ok,
      status: response.status,
      body
    };
  } catch (error) {
    return {
      ok: false,
      status: 0,
      error: error instanceof Error ? error.message : String(error)
    };
  }
}

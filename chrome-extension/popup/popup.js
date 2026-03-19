const FORM_IDS = {
  enabled: "enabledToggle",
  serverURL: "serverUrlInput",
  token: "tokenInput",
  minDwellSeconds: "dwellSlider",
  blocklist: "blocklistInput"
};

const elements = {
  enabledToggle: document.getElementById(FORM_IDS.enabled),
  serverUrlInput: document.getElementById(FORM_IDS.serverURL),
  tokenInput: document.getElementById(FORM_IDS.token),
  dwellSlider: document.getElementById(FORM_IDS.minDwellSeconds),
  dwellValue: document.getElementById("dwellValue"),
  blocklistInput: document.getElementById(FORM_IDS.blocklist),
  saveButton: document.getElementById("saveButton"),
  testButton: document.getElementById("testButton"),
  scanQrButton: document.getElementById("scanQrButton"),
  queueCount: document.getElementById("queueCount"),
  healthStatus: document.getElementById("healthStatus"),
  statusMessage: document.getElementById("statusMessage"),
  saveRulesButton: document.getElementById("saveRulesButton"),
  recentEntries: document.getElementById("recentEntries"),
  qrOverlay: document.getElementById("qrOverlay"),
  closeQrButton: document.getElementById("closeQrButton"),
  qrVideo: document.getElementById("qrVideo"),
  qrMessage: document.getElementById("qrMessage")
};

let qrStream = null;
let qrAnimationFrame = null;
let barcodeDetector = null;

function setStatus(message, tone = "neutral") {
  elements.statusMessage.textContent = message;
  elements.statusMessage.dataset.tone = tone;
}

function formatBlocklist(blocklist = []) {
  return blocklist.join("\n");
}

function parseBlocklist(raw) {
  return raw
    .split(/\n+/)
    .map((entry) => entry.trim())
    .filter(Boolean);
}

function readForm() {
  return {
    enabled: elements.enabledToggle.checked,
    serverURL: elements.serverUrlInput.value.trim(),
    token: elements.tokenInput.value.trim(),
    minDwellSeconds: Number(elements.dwellSlider.value),
    blocklist: parseBlocklist(elements.blocklistInput.value)
  };
}

function applySettings(settings) {
  elements.enabledToggle.checked = settings.enabled !== false;
  elements.serverUrlInput.value = settings.serverURL || "";
  elements.tokenInput.value = settings.token || "";
  elements.dwellSlider.value = String(settings.minDwellSeconds || 15);
  elements.dwellValue.textContent = `${elements.dwellSlider.value}s`;
  elements.blocklistInput.value = formatBlocklist(settings.blocklist || []);
}

function formatVisitedAt(value) {
  if (!value) return "unknown";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString();
}

function renderRecentEntries(entries = []) {
  if (entries.length === 0) {
    elements.recentEntries.innerHTML = '<li>No captures yet.</li>';
    return;
  }

  elements.recentEntries.innerHTML = entries
    .map((entry) => `
      <li>
        <div class="recent-top">
          <div>
            <strong>${escapeHtml(entry.title || "Untitled")}</strong>
            <div class="recent-domain">${escapeHtml(entry.domain || "unknown")}</div>
          </div>
          <span class="recent-status ${escapeHtml(entry.status || "queued")}">${escapeHtml(entry.status || "queued")}</span>
        </div>
        <div class="recent-meta">${escapeHtml(formatVisitedAt(entry.visitedAt))} · ${escapeHtml(String(entry.dwellSeconds || 0))}s</div>
      </li>
    `)
    .join("");
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

async function sendMessage(message) {
  return chrome.runtime.sendMessage(message);
}

async function refreshState() {
  const response = await sendMessage({ type: "popup:get-state" });
  if (!response?.ok) {
    setStatus(response?.error || "Failed to load popup state.", "error");
    return;
  }

  applySettings(response.settings);
  elements.queueCount.textContent = String(response.queueCount || 0);
  renderRecentEntries(response.recentEntries || []);
}

async function saveSettings() {
  const settings = readForm();
  const response = await sendMessage({ type: "popup:save-settings", settings });
  if (!response?.ok) {
    setStatus(response?.error || "Failed to save settings.", "error");
    return;
  }

  applySettings(response.settings);
  await refreshState();
  setStatus("Settings saved.", "success");
}

async function testConnection() {
  const response = await sendMessage({
    type: "popup:test-connection",
    serverURL: elements.serverUrlInput.value.trim(),
    token: elements.tokenInput.value.trim()
  });

  if (!response?.ok) {
    elements.healthStatus.textContent = "Error";
    setStatus(response?.error || "Connection test failed.", "error");
    return;
  }

  const result = response.result;
  elements.healthStatus.textContent = result.ok ? `HTTP ${result.status}` : (result.status ? `HTTP ${result.status}` : "Offline");
  if (result.ok) {
    setStatus("Health check passed.", "success");
  } else {
    const detail = result.error || JSON.stringify(result.body || {});
    setStatus(`Health check failed: ${detail}`, "warning");
  }
}

function parseConnectionQr(rawValue) {
  try {
    const parsed = new URL(rawValue);
    if (parsed.protocol !== "openclaw:") {
      return null;
    }
    const serverURL = parsed.searchParams.get("url")?.trim() || "";
    const token = parsed.searchParams.get("token")?.trim() || "";
    if (!serverURL) return null;
    return { serverURL, token };
  } catch {
    return null;
  }
}

function stopQrScan() {
  if (qrAnimationFrame) {
    cancelAnimationFrame(qrAnimationFrame);
    qrAnimationFrame = null;
  }
  if (qrStream) {
    qrStream.getTracks().forEach((track) => track.stop());
    qrStream = null;
  }
  elements.qrOverlay.classList.add("hidden");
  elements.qrOverlay.setAttribute("aria-hidden", "true");
  elements.qrVideo.srcObject = null;
}

async function scanFrame() {
  if (!barcodeDetector || !elements.qrVideo.srcObject) return;

  try {
    const barcodes = await barcodeDetector.detect(elements.qrVideo);
    const match = barcodes.find((barcode) => typeof barcode.rawValue === "string");
    if (match) {
      const parsed = parseConnectionQr(match.rawValue);
      if (parsed) {
        elements.serverUrlInput.value = parsed.serverURL;
        elements.tokenInput.value = parsed.token;
        elements.qrMessage.textContent = "QR scan complete. Review the fields and save.";
        stopQrScan();
        return;
      }
      elements.qrMessage.textContent = "QR detected, but it was not an openclaw://connect payload.";
    }
  } catch {
    elements.qrMessage.textContent = "QR scan failed. Try again with a clearer frame.";
  }

  qrAnimationFrame = requestAnimationFrame(scanFrame);
}

async function startQrScan() {
  if (!("BarcodeDetector" in window)) {
    setStatus("BarcodeDetector is not available in this Chrome build.", "warning");
    return;
  }
  if (!navigator.mediaDevices?.getUserMedia) {
    setStatus("Camera access is not available in this popup context.", "warning");
    return;
  }

  barcodeDetector = new BarcodeDetector({ formats: ["qr_code"] });
  qrStream = await navigator.mediaDevices.getUserMedia({
    video: { facingMode: { ideal: "environment" } },
    audio: false
  });

  elements.qrOverlay.classList.remove("hidden");
  elements.qrOverlay.setAttribute("aria-hidden", "false");
  elements.qrVideo.srcObject = qrStream;
  elements.qrMessage.textContent = "Point the camera at an openclaw://connect QR code.";
  await elements.qrVideo.play();
  qrAnimationFrame = requestAnimationFrame(scanFrame);
}

function bindEvents() {
  elements.dwellSlider.addEventListener("input", () => {
    elements.dwellValue.textContent = `${elements.dwellSlider.value}s`;
  });
  elements.dwellSlider.addEventListener("change", () => {
    void saveSettings();
  });
  elements.saveButton.addEventListener("click", () => {
    void saveSettings();
  });
  elements.testButton.addEventListener("click", () => {
    void testConnection();
  });
  elements.enabledToggle.addEventListener("change", () => {
    void saveSettings();
  });
  elements.saveRulesButton.addEventListener("click", () => {
    void saveSettings();
  });
  elements.scanQrButton.addEventListener("click", () => {
    void startQrScan().catch((error) => {
      setStatus(error instanceof Error ? error.message : String(error), "error");
      stopQrScan();
    });
  });
  elements.closeQrButton.addEventListener("click", stopQrScan);
  window.addEventListener("unload", stopQrScan);
}

bindEvents();
void refreshState();

const elements = {
  enabledToggle: document.getElementById("enabledToggle"),
  serverUrlInput: document.getElementById("serverUrlInput"),
  tokenInput: document.getElementById("tokenInput"),
  dwellSlider: document.getElementById("dwellSlider"),
  dwellValue: document.getElementById("dwellValue"),
  minContentSlider: document.getElementById("minContentSlider"),
  minContentValue: document.getElementById("minContentValue"),
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
  qrMessage: document.getElementById("qrMessage"),
  // Rules tab
  rulesList: document.getElementById("rulesList"),
  rulePatternInput: document.getElementById("rulePatternInput"),
  ruleActionSelect: document.getElementById("ruleActionSelect"),
  ruleCustomFields: document.getElementById("ruleCustomFields"),
  ruleDwellInput: document.getElementById("ruleDwellInput"),
  ruleContentInput: document.getElementById("ruleContentInput"),
  addRuleButton: document.getElementById("addRuleButton")
};

let currentRules = [];

let qrStream = null;
let qrAnimationFrame = null;
let barcodeDetector = null;

// Tab switching
for (const tab of document.querySelectorAll(".tab")) {
  tab.addEventListener("click", () => {
    for (const t of document.querySelectorAll(".tab")) t.classList.remove("active");
    for (const c of document.querySelectorAll(".tab-content")) c.classList.add("hidden");
    tab.classList.add("active");
    const target = document.getElementById(`tab-${tab.dataset.tab}`);
    if (target) target.classList.remove("hidden");
  });
}

function setStatus(message, tone = "neutral") {
  elements.statusMessage.textContent = message;
  elements.statusMessage.dataset.tone = tone;
}

function readForm() {
  return {
    enabled: elements.enabledToggle.checked,
    serverURL: elements.serverUrlInput.value.trim(),
    token: elements.tokenInput.value.trim(),
    minDwellSeconds: Number(elements.dwellSlider.value),
    minContentChars: Number(elements.minContentSlider.value),
    rules: currentRules
  };
}

function applySettings(settings) {
  elements.enabledToggle.checked = settings.enabled !== false;
  elements.serverUrlInput.value = settings.serverURL || "";
  elements.tokenInput.value = settings.token || "";
  elements.dwellSlider.value = String(settings.minDwellSeconds || 15);
  elements.dwellValue.textContent = `${elements.dwellSlider.value}s`;
  elements.minContentSlider.value = String(settings.minContentChars ?? 200);
  elements.minContentValue.textContent = String(elements.minContentSlider.value);
  currentRules = settings.rules || [];
  renderRules();
}

// --- Rules tab ---

function renderRules() {
  if (!elements.rulesList) return;
  if (currentRules.length === 0) {
    elements.rulesList.innerHTML = '<p class="log-empty">No rules yet.</p>';
    return;
  }
  elements.rulesList.innerHTML = currentRules.map((rule, i) => {
    const isBlock = rule.action === "block";
    const actionClass = isBlock ? "rule-action-block" : "rule-action-allow";
    const actionLabel = isBlock ? "block" : "allow";
    const meta = [];
    if (!isBlock) {
      if (rule.minDwell != null) meta.push(`${rule.minDwell}s`);
      if (rule.minContent != null) meta.push(`${rule.minContent}ch`);
    }
    const metaStr = meta.length > 0 ? meta.join(" · ") : "";
    const dwellVal = rule.minDwell != null ? rule.minDwell : "";
    const contentVal = rule.minContent != null ? rule.minContent : "";
    return `<div class="rule-row" data-index="${i}">
      <div class="rule-summary">
        <button class="rule-btn rule-btn-up" data-dir="up" title="Move up" ${i === 0 ? "disabled" : ""}>▲</button>
        <button class="rule-btn rule-btn-down" data-dir="down" title="Move down" ${i === currentRules.length - 1 ? "disabled" : ""}>▼</button>
        <span class="rule-pattern" title="${escapeHtml(rule.pattern)}">${escapeHtml(rule.pattern)}</span>
        <span class="rule-action ${actionClass}">${actionLabel}</span>
        ${metaStr ? `<span class="rule-meta">${escapeHtml(metaStr)}</span>` : ""}
        <button class="rule-btn rule-btn-delete" title="Delete">✕</button>
      </div>
      <div class="rule-edit hidden">
        <input class="rule-edit-pattern" type="text" value="${escapeHtml(rule.pattern)}" spellcheck="false">
        <div class="rule-edit-options">
          <select class="rule-edit-action">
            <option value="block" ${isBlock ? "selected" : ""}>Block</option>
            <option value="allow" ${!isBlock ? "selected" : ""}>Allow</option>
          </select>
          <div class="rule-edit-custom ${isBlock ? "hidden" : ""}">
            <label class="rule-inline-field">Dwell <input class="rule-edit-dwell" type="number" min="0" max="600" value="${dwellVal}" placeholder="—"></label>
            <label class="rule-inline-field">Chars <input class="rule-edit-content" type="number" min="0" max="5000" value="${contentVal}" placeholder="—"></label>
          </div>
          <button class="rule-edit-save" type="button">Save</button>
        </div>
      </div>
    </div>`;
  }).join("");

  // Bind events
  for (const btn of elements.rulesList.querySelectorAll(".rule-btn-up, .rule-btn-down")) {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const row = e.currentTarget.closest(".rule-row");
      const idx = Number(row.dataset.index);
      const dir = e.currentTarget.dataset.dir;
      const swap = dir === "up" ? idx - 1 : idx + 1;
      if (swap < 0 || swap >= currentRules.length) return;
      [currentRules[idx], currentRules[swap]] = [currentRules[swap], currentRules[idx]];
      renderRules();
      void saveSettings();
    });
  }
  for (const btn of elements.rulesList.querySelectorAll(".rule-btn-delete")) {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const row = e.currentTarget.closest(".rule-row");
      const idx = Number(row.dataset.index);
      currentRules.splice(idx, 1);
      renderRules();
      void saveSettings();
    });
  }
  // Click summary to toggle edit panel
  for (const summary of elements.rulesList.querySelectorAll(".rule-summary")) {
    summary.addEventListener("click", (e) => {
      if (e.target.closest(".rule-btn")) return; // don't toggle on button clicks
      const row = e.currentTarget.closest(".rule-row");
      const editPanel = row.querySelector(".rule-edit");
      editPanel.classList.toggle("hidden");
    });
  }
  // Action select toggles custom fields
  for (const sel of elements.rulesList.querySelectorAll(".rule-edit-action")) {
    sel.addEventListener("change", (e) => {
      const custom = e.currentTarget.closest(".rule-edit-options").querySelector(".rule-edit-custom");
      custom.classList.toggle("hidden", e.currentTarget.value === "block");
    });
  }
  // Save edit
  for (const btn of elements.rulesList.querySelectorAll(".rule-edit-save")) {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const row = e.currentTarget.closest(".rule-row");
      const idx = Number(row.dataset.index);
      const pattern = row.querySelector(".rule-edit-pattern").value.trim();
      const action = row.querySelector(".rule-edit-action").value;
      const dwell = row.querySelector(".rule-edit-dwell").value;
      const content = row.querySelector(".rule-edit-content").value;
      if (!pattern) return;
      const updated = { pattern, action };
      if (action === "allow") {
        if (dwell !== "") updated.minDwell = Number(dwell);
        if (content !== "") updated.minContent = Number(content);
      }
      currentRules[idx] = updated;
      renderRules();
      void saveSettings();
    });
  }
}

function addRule(pattern, action, minDwell, minContent) {
  const rule = { pattern: pattern.trim(), action };
  if (action === "allow") {
    if (minDwell != null && minDwell !== "") rule.minDwell = Number(minDwell);
    if (minContent != null && minContent !== "") rule.minContent = Number(minContent);
  }
  currentRules.push(rule);
  renderRules();
  void saveSettings();
}

function formatVisitedAt(value) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString();
}

function formatShortTime(value) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

const X_DOMAINS = ["x.com", "twitter.com"];

function filterStatus(entry, minContentChars) {
  const domain = entry.domain || "";
  if (X_DOMAINS.includes(domain)) return { pass: true, reason: "X (always)" };
  const len = entry.contentLength ?? 0;
  const threshold = minContentChars ?? 200;
  if (threshold === 0) return { pass: true, reason: "filter off" };
  if (len >= threshold) return { pass: true, reason: `${len}/${threshold} chars` };
  return { pass: false, reason: `${len}/${threshold} chars` };
}

function renderRecentEntries(entries = [], settings = {}) {
  if (entries.length === 0) {
    elements.recentEntries.innerHTML = '<tr><td colspan="5" class="log-empty">No captures yet.</td></tr>';
    return;
  }

  const minContentChars = settings.minContentChars ?? 200;

  elements.recentEntries.innerHTML = entries
    .map((entry) => {
      const status = escapeHtml(entry.status || "queued");
      const title = escapeHtml(entry.title || "Untitled");
      const domain = escapeHtml(entry.domain || "unknown");
      const dwell = escapeHtml(String(entry.dwellSeconds || 0));
      const time = escapeHtml(formatShortTime(entry.visitedAt));
      const filter = filterStatus(entry, minContentChars);
      const filterClass = filter.pass ? "filter-pass" : "filter-skip";
      const filterLabel = filter.pass ? "ok" : "skip";
      const isSkipped = ["short", "blocked", "disabled", "dedup"].includes(entry.status);
      const rowClass = isSkipped ? "log-row log-row-skipped" : "log-row";
      const skipReason = isSkipped ? ` (${status})` : "";

      // Detail row (expandable)
      let detailRow = "";
      const detailParts = [];
      if (entry.contentPreview) {
        detailParts.push(escapeHtml(entry.contentPreview));
      }
      const eng = entry.engagement;
      if (eng) {
        const parts = [];
        if (eng.activeSeconds != null) parts.push(`${eng.activeSeconds}s active`);
        if (eng.scrollDepthPct != null) parts.push(`${eng.scrollDepthPct}% scroll`);
        if (parts.length > 0) detailParts.push(parts.join(", "));
      }
      if (detailParts.length > 0 || domain) {
        detailRow = `<tr class="log-detail hidden" data-detail-for="${escapeHtml(entry.id || "")}">
          <td colspan="5">
            <div class="log-detail-content">
              ${detailParts.length > 0 ? `<div class="recent-preview">${detailParts.join(" · ")}</div>` : ""}
              <button class="block-domain-btn" data-domain="${domain}" type="button">Block ${domain}</button>
            </div>
          </td>
        </tr>`;
      }

      return `
        <tr class="${rowClass}" data-entry-id="${escapeHtml(entry.id || "")}">
          <td class="col-time">${time}</td>
          <td class="col-title" title="${title}">${title}${skipReason}</td>
          <td class="col-domain">${domain}</td>
          <td class="col-dwell">${dwell}s</td>
          <td class="col-status"><span class="recent-status ${status}">${status}</span> <span class="filter-tag ${filterClass}">${filterLabel}</span></td>
        </tr>
        ${detailRow}
      `;
    })
    .join("");

  // Click row to expand detail
  for (const row of elements.recentEntries.querySelectorAll(".log-row")) {
    row.addEventListener("click", () => {
      const id = row.dataset.entryId;
      const detail = elements.recentEntries.querySelector(`.log-detail[data-detail-for="${id}"]`);
      if (detail) detail.classList.toggle("hidden");
    });
  }

  for (const btn of elements.recentEntries.querySelectorAll(".block-domain-btn")) {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const domain = e.currentTarget.dataset.domain;
      if (!domain) return;
      if (!currentRules.some((r) => r.pattern === domain)) {
        addRule(domain, "block");
      }
      e.currentTarget.textContent = "Blocked!";
      e.currentTarget.disabled = true;
    });
  }
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
  try {
    return await chrome.runtime.sendMessage(message);
  } catch (err) {
    return { ok: false, error: err instanceof Error ? err.message : "Extension disconnected" };
  }
}

async function refreshState() {
  const response = await sendMessage({ type: "popup:get-state" });
  if (!response?.ok) {
    setStatus(response?.error || "Failed to load popup state.", "error");
    return;
  }

  applySettings(response.settings);
  elements.queueCount.textContent = String(response.queueCount || 0);
  renderRecentEntries(response.recentEntries || [], response.settings || {});

  // Show capture diagnostics if present
  if (response.diagnostics?.lastCaptureError) {
    setStatus(`Capture: ${response.diagnostics.lastCaptureError}`, "warning");
  }
}

function flashSaved(button) {
  const original = button.textContent;
  button.textContent = "Saved!";
  button.classList.add("saved");
  setTimeout(() => {
    button.textContent = original;
    button.classList.remove("saved");
  }, 1200);
}

async function saveSettings(triggerButton) {
  const settings = readForm();
  const response = await sendMessage({ type: "popup:save-settings", settings });
  if (!response?.ok) {
    setStatus(response?.error || "Failed to save settings.", "error");
    return;
  }

  applySettings(response.settings);
  await refreshState();
  if (triggerButton) {
    flashSaved(triggerButton);
  } else {
    setStatus("Settings saved.", "success");
  }
}

async function testConnection() {
  const response = await sendMessage({
    type: "popup:test-connection",
    serverURL: elements.serverUrlInput.value.trim(),
    token: elements.tokenInput.value.trim()
  });

  if (!response?.ok) {
    elements.healthStatus.innerHTML = '<span class="conn-dot conn-error"></span> Error';
    setStatus(response?.error || "Connection test failed.", "error");
    return;
  }

  const result = response.result;
  if (result.ok) {
    elements.healthStatus.innerHTML = `<span class="conn-dot conn-ok"></span> Connected`;
    setStatus("Health check passed.", "success");
  } else {
    elements.healthStatus.innerHTML = `<span class="conn-dot conn-error"></span> ${result.status ? `HTTP ${result.status}` : "Offline"}`;
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
  elements.minContentSlider.addEventListener("input", () => {
    elements.minContentValue.textContent = String(elements.minContentSlider.value);
  });
  elements.minContentSlider.addEventListener("change", () => {
    void saveSettings();
  });
  elements.saveButton.addEventListener("click", () => {
    void saveSettings(elements.saveButton);
  });
  elements.testButton.addEventListener("click", () => {
    void testConnection();
  });
  elements.enabledToggle.addEventListener("change", () => {
    void saveSettings();
  });
  elements.saveRulesButton.addEventListener("click", () => {
    void saveSettings(elements.saveRulesButton);
  });
  // Rules tab
  elements.ruleActionSelect.addEventListener("change", () => {
    elements.ruleCustomFields.classList.toggle("hidden", elements.ruleActionSelect.value === "block");
  });
  elements.addRuleButton.addEventListener("click", () => {
    const pattern = elements.rulePatternInput.value.trim();
    if (!pattern) return;
    const action = elements.ruleActionSelect.value;
    const dwell = elements.ruleDwellInput.value;
    const content = elements.ruleContentInput.value;
    addRule(pattern, action, dwell || null, content || null);
    elements.rulePatternInput.value = "";
    elements.ruleDwellInput.value = "";
    elements.ruleContentInput.value = "";
    elements.ruleActionSelect.value = "block";
    elements.ruleCustomFields.classList.add("hidden");
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

// Load state then auto-check connection
void (async () => {
  await refreshState();
  const url = elements.serverUrlInput.value.trim();
  if (!url) {
    elements.healthStatus.innerHTML = '<span class="conn-dot conn-error"></span> Not configured';
    return;
  }
  try {
    await testConnection();
  } catch {
    elements.healthStatus.innerHTML = '<span class="conn-dot conn-error"></span> Offline';
  }
})();

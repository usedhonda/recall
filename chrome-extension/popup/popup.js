// --- Elements ---

const el = {
  enabledToggle: document.getElementById("enabledToggle"),
  gearButton: document.getElementById("gearButton"),
  healthDot: document.getElementById("healthDot"),
  queueCount: document.getElementById("queueCount"),
  statusMessage: document.getElementById("statusMessage"),
  recentEntries: document.getElementById("recentEntries"),
  rulesList: document.getElementById("rulesList"),
  rulePatternInput: document.getElementById("rulePatternInput"),
  addRuleButton: document.getElementById("addRuleButton"),
  // Drawer
  settingsDrawer: document.getElementById("settingsDrawer"),
  closeDrawerButton: document.getElementById("closeDrawerButton"),
  serverUrlInput: document.getElementById("serverUrlInput"),
  tokenInput: document.getElementById("tokenInput"),
  saveButton: document.getElementById("saveButton"),
  testButton: document.getElementById("testButton"),
  scanQrButton: document.getElementById("scanQrButton"),
  dwellSlider: document.getElementById("dwellSlider"),
  dwellValue: document.getElementById("dwellValue"),
  minContentSlider: document.getElementById("minContentSlider"),
  minContentValue: document.getElementById("minContentValue"),
  // QR
  qrOverlay: document.getElementById("qrOverlay"),
  closeQrButton: document.getElementById("closeQrButton"),
  qrVideo: document.getElementById("qrVideo"),
  qrMessage: document.getElementById("qrMessage")
};

let currentRules = [];
let qrStream = null;
let qrAnimationFrame = null;
let barcodeDetector = null;

// --- Tab switching ---

for (const tab of document.querySelectorAll(".tab")) {
  tab.addEventListener("click", () => {
    for (const t of document.querySelectorAll(".tab")) t.classList.remove("active");
    for (const c of document.querySelectorAll(".tab-content")) c.classList.add("hidden");
    tab.classList.add("active");
    const target = document.getElementById(`tab-${tab.dataset.tab}`);
    if (target) target.classList.remove("hidden");
  });
}

// --- Helpers ---

function escapeHtml(value) {
  return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

function formatShortTime(value) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

async function sendMessage(message) {
  try {
    return await chrome.runtime.sendMessage(message);
  } catch (err) {
    return { ok: false, error: err instanceof Error ? err.message : "Extension disconnected" };
  }
}

function setStatus(message) {
  el.statusMessage.textContent = message;
}

// --- Settings ---

function readForm() {
  return {
    enabled: el.enabledToggle.checked,
    serverURL: el.serverUrlInput.value.trim(),
    token: el.tokenInput.value.trim(),
    minDwellSeconds: Number(el.dwellSlider.value),
    minContentChars: Number(el.minContentSlider.value),
    rules: currentRules
  };
}

function applySettings(settings) {
  el.enabledToggle.checked = settings.enabled !== false;
  el.serverUrlInput.value = settings.serverURL || "";
  el.tokenInput.value = settings.token || "";
  el.dwellSlider.value = String(settings.minDwellSeconds || 15);
  el.dwellValue.textContent = `${el.dwellSlider.value}s`;
  el.minContentSlider.value = String(settings.minContentChars ?? 200);
  el.minContentValue.textContent = String(el.minContentSlider.value);
  currentRules = settings.rules || [];
  renderRules();
}

async function saveSettings(triggerButton) {
  const settings = readForm();
  const response = await sendMessage({ type: "popup:save-settings", settings });
  if (!response?.ok) {
    setStatus(response?.error || "Save failed");
    return;
  }
  applySettings(response.settings);
  await refreshState();
  if (triggerButton) {
    const orig = triggerButton.textContent;
    triggerButton.textContent = "Saved!";
    triggerButton.classList.add("saved");
    setTimeout(() => { triggerButton.textContent = orig; triggerButton.classList.remove("saved"); }, 1200);
  }
}

async function refreshState() {
  const response = await sendMessage({ type: "popup:get-state" });
  if (!response?.ok) {
    setStatus(response?.error || "Failed to load state");
    return;
  }
  applySettings(response.settings);
  el.queueCount.textContent = `${response.queueCount || 0} queued`;
  renderActivity(response.recentEntries || []);
  if (response.diagnostics?.lastCaptureError) {
    setStatus(`Capture: ${response.diagnostics.lastCaptureError}`);
  }
}

// --- Activity log ---

function renderActivity(entries) {
  if (entries.length === 0) {
    el.recentEntries.innerHTML = '<tr><td colspan="4" class="log-empty">No captures yet.</td></tr>';
    return;
  }

  el.recentEntries.innerHTML = entries.map((entry) => {
    const rawStatus = entry.status || "queued";
    const title = escapeHtml(entry.title || "Untitled");
    const domain = escapeHtml(entry.domain || "");
    const dwell = entry.dwellSeconds || 0;
    const time = escapeHtml(formatShortTime(entry.visitedAt));
    const isSent = rawStatus === "sent";
    const isSkipped = ["short", "blocked", "disabled", "dedup", "not article"].includes(rawStatus);
    const rowClass = isSkipped ? "log-row log-row-skipped" : "log-row";

    let outcome;
    if (isSent) {
      outcome = '<span class="outcome-sent">SENT</span>';
    } else if (isSkipped) {
      outcome = `<span class="outcome-reason">${escapeHtml(rawStatus)}</span>`;
    } else {
      outcome = `<span class="outcome-reason">${escapeHtml(rawStatus)}</span>`;
    }

    let detailRow = "";
    const detailParts = [];
    if (entry.contentPreview) detailParts.push(escapeHtml(entry.contentPreview));
    const eng = entry.engagement;
    if (eng) {
      const parts = [];
      if (eng.activeSeconds != null) parts.push(`${eng.activeSeconds}s active`);
      if (eng.scrollDepthPct != null) parts.push(`${eng.scrollDepthPct}% scroll`);
      if (parts.length > 0) detailParts.push(parts.join(", "));
    }
    if (detailParts.length > 0 || domain) {
      detailRow = `<tr class="log-detail hidden" data-detail-for="${escapeHtml(entry.id || "")}">
        <td colspan="4">
          <div class="log-detail-content">
            ${detailParts.length > 0 ? `<div class="recent-preview">${detailParts.join(" · ")}</div>` : ""}
            ${domain ? `<button class="block-domain-btn" data-domain="${domain}" type="button">Block ${domain}</button>` : ""}
          </div>
        </td>
      </tr>`;
    }

    return `
      <tr class="${rowClass}" data-entry-id="${escapeHtml(entry.id || "")}">
        <td>${time}</td>
        <td><div class="log-page-title">${title}</div><div class="log-page-domain">${domain}</div></td>
        <td class="col-dwell">${dwell}s</td>
        <td class="col-outcome">${outcome}</td>
      </tr>
      ${detailRow}
    `;
  }).join("");

  for (const row of el.recentEntries.querySelectorAll(".log-row")) {
    row.addEventListener("click", () => {
      const id = row.dataset.entryId;
      const detail = el.recentEntries.querySelector(`.log-detail[data-detail-for="${id}"]`);
      if (detail) detail.classList.toggle("hidden");
    });
  }

  for (const btn of el.recentEntries.querySelectorAll(".block-domain-btn")) {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const domain = e.currentTarget.dataset.domain;
      if (!domain) return;
      if (!currentRules.some((r) => r.pattern === domain)) {
        currentRules.push({ pattern: domain, action: "block" });
        renderRules();
        void saveSettings();
      }
      e.currentTarget.textContent = "Blocked!";
      e.currentTarget.disabled = true;
    });
  }
}

// --- Rules ---

function renderRules() {
  if (!el.rulesList) return;
  if (currentRules.length === 0) {
    el.rulesList.innerHTML = '<p class="log-empty">No rules. Add a pattern below.</p>';
    return;
  }

  el.rulesList.innerHTML = currentRules.map((rule, i) => {
    const isBlock = rule.action === "block";
    const chipClass = isBlock ? "block" : "allow";
    const chipLabel = isBlock ? "BLOCK" : "ALLOW";
    const dwellVal = rule.minDwell != null ? rule.minDwell : "";
    const contentVal = rule.minContent != null ? rule.minContent : "";
    const articleOnly = rule.articleOnly ? "checked" : "";

    return `<div class="rule-card" data-index="${i}">
      <div class="rule-card-row1">
        <span class="rule-handle">☰</span>
        <input class="rule-pattern-input" type="text" value="${escapeHtml(rule.pattern)}" spellcheck="false">
        <button class="rule-action-chip ${chipClass}" type="button">${chipLabel}</button>
        <button class="rule-move-btn" data-dir="up" title="Up" ${i === 0 ? "disabled" : ""}>▲</button>
        <button class="rule-move-btn" data-dir="down" title="Down" ${i === currentRules.length - 1 ? "disabled" : ""}>▼</button>
        <button class="rule-delete-btn" title="Delete">✕</button>
      </div>
      <div class="rule-card-row2 ${isBlock ? "hidden" : ""}">
        <span class="rule-option-field">dwell <input type="number" class="rule-dwell" min="0" max="600" value="${dwellVal}" placeholder="—">s</span>
        <span class="rule-option-field">chars <input type="number" class="rule-content" min="0" max="5000" value="${contentVal}" placeholder="—"></span>
        <label class="rule-option-field"><input type="checkbox" class="rule-article" ${articleOnly}> article only</label>
      </div>
    </div>`;
  }).join("");

  bindRuleEvents();
}

function bindRuleEvents() {
  // Action chip toggle
  for (const chip of el.rulesList.querySelectorAll(".rule-action-chip")) {
    chip.addEventListener("click", () => {
      const card = chip.closest(".rule-card");
      const idx = Number(card.dataset.index);
      const rule = currentRules[idx];
      rule.action = rule.action === "block" ? "allow" : "block";
      if (rule.action === "block") {
        delete rule.minDwell;
        delete rule.minContent;
        delete rule.articleOnly;
      }
      renderRules();
      void saveSettings();
    });
  }

  // Move
  for (const btn of el.rulesList.querySelectorAll(".rule-move-btn")) {
    btn.addEventListener("click", () => {
      const card = btn.closest(".rule-card");
      const idx = Number(card.dataset.index);
      const dir = btn.dataset.dir;
      const swap = dir === "up" ? idx - 1 : idx + 1;
      if (swap < 0 || swap >= currentRules.length) return;
      [currentRules[idx], currentRules[swap]] = [currentRules[swap], currentRules[idx]];
      renderRules();
      void saveSettings();
    });
  }

  // Delete
  for (const btn of el.rulesList.querySelectorAll(".rule-delete-btn")) {
    btn.addEventListener("click", () => {
      const card = btn.closest(".rule-card");
      const idx = Number(card.dataset.index);
      currentRules.splice(idx, 1);
      renderRules();
      void saveSettings();
    });
  }

  // Auto-save on pattern/dwell/content/article change
  for (const input of el.rulesList.querySelectorAll(".rule-pattern-input, .rule-dwell, .rule-content")) {
    input.addEventListener("change", () => {
      const card = input.closest(".rule-card");
      const idx = Number(card.dataset.index);
      syncRuleFromCard(card, idx);
    });
  }

  for (const cb of el.rulesList.querySelectorAll(".rule-article")) {
    cb.addEventListener("change", () => {
      const card = cb.closest(".rule-card");
      const idx = Number(card.dataset.index);
      syncRuleFromCard(card, idx);
    });
  }
}

function syncRuleFromCard(card, idx) {
  const pattern = card.querySelector(".rule-pattern-input").value.trim();
  if (!pattern) return;
  const rule = currentRules[idx];
  rule.pattern = pattern;
  if (rule.action === "allow") {
    const dwell = card.querySelector(".rule-dwell").value;
    const content = card.querySelector(".rule-content").value;
    const articleOnly = card.querySelector(".rule-article").checked;
    rule.minDwell = dwell !== "" ? Number(dwell) : undefined;
    rule.minContent = content !== "" ? Number(content) : undefined;
    rule.articleOnly = articleOnly || undefined;
    // Clean undefined
    if (rule.minDwell == null) delete rule.minDwell;
    if (rule.minContent == null) delete rule.minContent;
    if (!rule.articleOnly) delete rule.articleOnly;
  }
  void saveSettings();
}

// --- Drawer ---

el.gearButton.addEventListener("click", () => el.settingsDrawer.classList.remove("hidden"));
el.closeDrawerButton.addEventListener("click", () => el.settingsDrawer.classList.add("hidden"));
document.querySelector(".drawer-backdrop")?.addEventListener("click", () => el.settingsDrawer.classList.add("hidden"));

// --- Connection test ---

async function testConnection() {
  const response = await sendMessage({
    type: "popup:test-connection",
    serverURL: el.serverUrlInput.value.trim(),
    token: el.tokenInput.value.trim()
  });
  if (!response?.ok) {
    el.healthDot.className = "conn-dot conn-error";
    setStatus(response?.error || "Connection failed");
    return;
  }
  if (response.result.ok) {
    el.healthDot.className = "conn-dot conn-ok";
    setStatus("Connected");
  } else {
    el.healthDot.className = "conn-dot conn-error";
    setStatus(`HTTP ${response.result.status || "Offline"}`);
  }
}

// --- QR ---

function parseConnectionQr(rawValue) {
  try {
    const parsed = new URL(rawValue);
    if (parsed.protocol !== "openclaw:") return null;
    const serverURL = parsed.searchParams.get("url")?.trim() || "";
    const token = parsed.searchParams.get("token")?.trim() || "";
    if (!serverURL) return null;
    return { serverURL, token };
  } catch { return null; }
}

function stopQrScan() {
  if (qrAnimationFrame) { cancelAnimationFrame(qrAnimationFrame); qrAnimationFrame = null; }
  if (qrStream) { qrStream.getTracks().forEach((t) => t.stop()); qrStream = null; }
  el.qrOverlay.classList.add("hidden");
  el.qrVideo.srcObject = null;
}

async function scanFrame() {
  if (!barcodeDetector || !el.qrVideo.srcObject) return;
  try {
    const barcodes = await barcodeDetector.detect(el.qrVideo);
    const match = barcodes.find((b) => typeof b.rawValue === "string");
    if (match) {
      const parsed = parseConnectionQr(match.rawValue);
      if (parsed) {
        el.serverUrlInput.value = parsed.serverURL;
        el.tokenInput.value = parsed.token;
        stopQrScan();
        return;
      }
    }
  } catch { /* retry */ }
  qrAnimationFrame = requestAnimationFrame(scanFrame);
}

async function startQrScan() {
  if (!("BarcodeDetector" in window) || !navigator.mediaDevices?.getUserMedia) {
    setStatus("QR scan not available");
    return;
  }
  barcodeDetector = new BarcodeDetector({ formats: ["qr_code"] });
  qrStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: "environment" } }, audio: false });
  el.qrOverlay.classList.remove("hidden");
  el.qrVideo.srcObject = qrStream;
  await el.qrVideo.play();
  qrAnimationFrame = requestAnimationFrame(scanFrame);
}

// --- Bind events ---

el.enabledToggle.addEventListener("change", () => void saveSettings());
el.dwellSlider.addEventListener("input", () => { el.dwellValue.textContent = `${el.dwellSlider.value}s`; });
el.dwellSlider.addEventListener("change", () => void saveSettings());
el.minContentSlider.addEventListener("input", () => { el.minContentValue.textContent = String(el.minContentSlider.value); });
el.minContentSlider.addEventListener("change", () => void saveSettings());
el.saveButton.addEventListener("click", () => void saveSettings(el.saveButton));
el.testButton.addEventListener("click", () => void testConnection());
el.scanQrButton.addEventListener("click", () => void startQrScan().catch(() => stopQrScan()));
el.closeQrButton.addEventListener("click", stopQrScan);
el.addRuleButton.addEventListener("click", () => {
  const pattern = el.rulePatternInput.value.trim();
  if (!pattern) return;
  currentRules.push({ pattern, action: "block" });
  el.rulePatternInput.value = "";
  renderRules();
  void saveSettings();
});
window.addEventListener("unload", stopQrScan);

// --- Init ---

void (async () => {
  await refreshState();
  const url = el.serverUrlInput.value.trim();
  if (!url) {
    el.healthDot.className = "conn-dot conn-error";
    return;
  }
  try { await testConnection(); } catch { el.healthDot.className = "conn-dot conn-error"; }
})();

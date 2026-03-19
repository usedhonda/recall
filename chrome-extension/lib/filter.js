const ALLOWED_PROTOCOLS = new Set(["http:", "https:"]);

export const DEFAULT_BLOCKLIST = [
  "mail.google.com",
  "outlook.live.com",
  "*.outlook.office.com",
  "accounts.google.com",
  "login.microsoftonline.com",
  "*.okta.com",
  "*.auth0.com",
  "*.1password.com",
  "*.lastpass.com",
  "*.paypal.com",
  "*.stripe.com",
  "*.chase.com",
  "*.bankofamerica.com",
  "*.wellsfargo.com",
  "*.capitalone.com",
  "*.citi.com",
  "*.mychart.com"
];

function escapeRegExp(value) {
  return value.replace(/[|\\{}()[\]^$+?.]/g, "\\$&");
}

function wildcardToRegExp(pattern) {
  return new RegExp(`^${escapeRegExp(pattern).replace(/\*/g, ".*")}$`, "i");
}

export function normalizeBlocklist(blocklist = []) {
  const normalized = blocklist
    .map((entry) => (typeof entry === "string" ? entry.trim().toLowerCase() : ""))
    .filter(Boolean);
  return [...new Set(normalized)];
}

export function isTrackableUrl(url) {
  try {
    const parsed = new URL(url);
    return ALLOWED_PROTOCOLS.has(parsed.protocol);
  } catch {
    return false;
  }
}

export function isBlocked(url, blocklist = DEFAULT_BLOCKLIST) {
  if (!isTrackableUrl(url)) return true;

  const parsed = new URL(url);
  const patterns = normalizeBlocklist(blocklist);

  return patterns.some((pattern) => {
    const target = pattern.includes("://") || pattern.includes("/") ? parsed.href.toLowerCase() : parsed.hostname.toLowerCase();
    if (pattern.includes("*")) {
      return wildcardToRegExp(pattern).test(target);
    }
    return target === pattern;
  });
}

export function shouldTrackVisit(dwellSeconds, minDwellSeconds = 15) {
  const dwell = Number(dwellSeconds);
  const threshold = Number(minDwellSeconds);
  if (!Number.isFinite(dwell)) return false;
  if (!Number.isFinite(threshold)) return dwell > 0;
  return dwell >= Math.max(0, threshold);
}

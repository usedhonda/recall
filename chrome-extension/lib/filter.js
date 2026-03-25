const ALLOWED_PROTOCOLS = new Set(["http:", "https:"]);

export const DEFAULT_RULES = [
  { pattern: "x.com/notifications", action: "block" },
  { pattern: "x.com/home", action: "block" },
  { pattern: "x.com/search", action: "block" },
  { pattern: "x.com/i/*", action: "block" },
  { pattern: "x.com", action: "allow", trackTweets: true },
  { pattern: "twitter.com", action: "allow", trackTweets: true },
  { pattern: "www.youtube.com/shorts/*", action: "block" },
  { pattern: "mail.google.com", action: "block" },
  { pattern: "outlook.live.com", action: "block" },
  { pattern: "*.outlook.office.com", action: "block" },
  { pattern: "accounts.google.com", action: "block" },
  { pattern: "login.microsoftonline.com", action: "block" },
  { pattern: "*.okta.com", action: "block" },
  { pattern: "*.auth0.com", action: "block" },
  { pattern: "*.1password.com", action: "block" },
  { pattern: "*.lastpass.com", action: "block" },
  { pattern: "*.paypal.com", action: "block" },
  { pattern: "*.stripe.com", action: "block" },
  { pattern: "*.chase.com", action: "block" },
  { pattern: "*.bankofamerica.com", action: "block" },
  { pattern: "*.wellsfargo.com", action: "block" },
  { pattern: "*.capitalone.com", action: "block" },
  { pattern: "*.citi.com", action: "block" },
  { pattern: "*.mychart.com", action: "block" }
];

function escapeRegExp(value) {
  return value.replace(/[|\\{}()[\]^$+?.]/g, "\\$&");
}

function wildcardToRegExp(pattern) {
  return new RegExp(`^${escapeRegExp(pattern).replace(/\*/g, ".*")}$`, "i");
}

function matchPattern(pattern, target) {
  const p = pattern.trim().toLowerCase().replace(/\/+$/, "");
  const t = target.toLowerCase().replace(/\/+$/, "");
  if (p.includes("*")) {
    return wildcardToRegExp(p).test(t);
  }
  return t === p || t.startsWith(p + "/");
}

export function isTrackableUrl(url) {
  try {
    const parsed = new URL(url);
    return ALLOWED_PROTOCOLS.has(parsed.protocol);
  } catch {
    return false;
  }
}

/**
 * Evaluate URL against ordered rules. First match wins.
 * Returns { blocked, minDwell, minContent, rule }.
 */
export function evaluateRules(url, rules, globalSettings) {
  if (!isTrackableUrl(url)) return { blocked: true, rule: null };

  const parsed = new URL(url);
  for (const rule of rules) {
    const hasPath = rule.pattern.includes("/");
    const target = hasPath
      ? parsed.hostname + parsed.pathname
      : parsed.hostname;
    if (matchPattern(rule.pattern, target)) {
      if (rule.action === "block") return { blocked: true, rule };
      return {
        blocked: false,
        minDwell: rule.minDwell ?? globalSettings.minDwellSeconds,
        minContent: rule.minContent ?? globalSettings.minContentChars,
        trackTweets: !!rule.trackTweets,
        rule
      };
    }
  }
  return {
    blocked: false,
    minDwell: globalSettings.minDwellSeconds,
    minContent: globalSettings.minContentChars,
    rule: null
  };
}

/**
 * Migrate legacy blocklist array to rules format.
 */
export function migrateBlocklistToRules(blocklist) {
  if (!Array.isArray(blocklist)) return null;
  return blocklist
    .map((entry) => (typeof entry === "string" ? entry.trim() : ""))
    .filter(Boolean)
    .map((pattern) => ({ pattern, action: "block" }));
}

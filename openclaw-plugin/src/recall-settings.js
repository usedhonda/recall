/**
 * Recall reaction settings — read/write utility.
 *
 * Persists to ~/.openclaw/workspace/memory/recall-settings.json
 */

import { promises as fs } from "fs";
import { homedir } from "os";
import { join } from "path";

const SETTINGS_PATH = join(
  homedir(),
  ".openclaw",
  "workspace",
  "memory",
  "recall-settings.json"
);

const DEFAULTS = {
  webReactionsEnabled: true,
  voiceReactionsEnabled: true,
  lineDeliveryEnabled: true,
  vibetermDeliveryEnabled: true,
  webMinContentChars: 200,
};

export async function getReactionSettings() {
  try {
    const raw = await fs.readFile(SETTINGS_PATH, "utf-8");
    const data = JSON.parse(raw);
    return {
      webReactionsEnabled: data.webReactionsEnabled ?? DEFAULTS.webReactionsEnabled,
      voiceReactionsEnabled: data.voiceReactionsEnabled ?? DEFAULTS.voiceReactionsEnabled,
      lineDeliveryEnabled: data.lineDeliveryEnabled ?? DEFAULTS.lineDeliveryEnabled,
      vibetermDeliveryEnabled: data.vibetermDeliveryEnabled ?? DEFAULTS.vibetermDeliveryEnabled,
      webMinContentChars: data.webMinContentChars ?? DEFAULTS.webMinContentChars,
      updatedAt: data.updatedAt ?? null,
    };
  } catch {
    return { ...DEFAULTS, updatedAt: null };
  }
}

export async function saveReactionSettings(settings) {
  const current = await getReactionSettings();
  const merged = {
    webReactionsEnabled: settings.webReactionsEnabled ?? current.webReactionsEnabled,
    voiceReactionsEnabled: settings.voiceReactionsEnabled ?? current.voiceReactionsEnabled,
    lineDeliveryEnabled: settings.lineDeliveryEnabled ?? current.lineDeliveryEnabled,
    vibetermDeliveryEnabled: settings.vibetermDeliveryEnabled ?? current.vibetermDeliveryEnabled,
    webMinContentChars: settings.webMinContentChars ?? current.webMinContentChars,
    updatedAt: new Date().toISOString(),
  };
  const dir = join(homedir(), ".openclaw", "workspace", "memory");
  await fs.mkdir(dir, { recursive: true });
  await fs.writeFile(SETTINGS_PATH, JSON.stringify(merged, null, 2), "utf-8");
  return merged;
}

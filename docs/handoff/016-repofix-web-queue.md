# RepoFix: retain browser history until delivery acknowledgment

Base: `cb4d590396b9eb685302f3a46afa01c3c2fa1023` (2026-11-09).

The old queue read deleted every IndexedDB row before network delivery. The
first-send path also tried the network before persisting a retry. A worker that
stopped during either fetch could leave no durable retry. The new flow commits
before sending, reads without deletion, and acknowledges stable row keys only
after HTTP success. Failed rows keep their original ordering. The drain still
sends one entry per POST and preserves the two-hour/1,000-entry retention rules.

- Chrome manifest: 0.3.0 -> 0.3.1.
- Passed: production upload helper in Node VM with controlled queue/transport
  doubles (persist before suspended initial send; remove after success; retain
  failed IDs/order and concurrent additions; UI failure cannot requeue success).
- Passed: actual API function with controlled fetch verifies timeout during a
  200 response body rejects rather than acknowledging; production timeout is 20 s.
- Passed: JavaScript syntax and the repository contract check.
- Not run: four committed Chromium/IndexedDB regression scenarios. Playwright is
  installed, but Chromium cannot start in this container (`socket()` EPERM).
  A real browser or CI must run them before treating IndexedDB lifecycle coverage
  as verified. The Node doubles do not establish transaction durability.
- Browser tests added 4 / removed 0 / consolidated 0 (no previous browser suite).
  Existing plugin tests are unchanged. No extension installation, live capture,
  server delivery or iOS build/deployment was performed.

Reference checked 2026-11-09:
https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle
Documents extension-worker termination and why state must live in persistent
storage. This patch preserves at-least-once delivery, not exactly-once effects.

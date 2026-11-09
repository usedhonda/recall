# RepoFix: bounded plugin request bodies

Base: `cb4d590396b9eb685302f3a46afa01c3c2fa1023` (2026-11-09).

The four plugin POST routes duplicated an unbounded body accumulator. The base
telemetry handler accepted a body larger than 2 MiB, and a JSON `null` root threw
outside its parse guard. A request that closed before `end` could leave its read
pending. The shared reader now bounds bytes and total read duration, settles on
abort/error/early close, and requires an object before per-route processing.

- Plugin version: 2026.3.11 in both metadata files.
- Node regression suite: 7 -> 11 cases; 11 passed. Added 4 / removed 0 /
  consolidated 0 test cases. Existing 7 cases protect distinct receipt and
  persistence boundaries and remain intact. Four production readers consolidated.
- Baseline control: `null` throws TypeError; >2 MiB valid telemetry returns 200.
- Checks cover exact byte boundary, multibyte/chunked/declared excess, abort/close/
  error, a shortened synthetic deadline, and all four actual route factories.
- No iOS changes, simulator build, live Gateway request or deployment.

The 2 MiB/15 s limits are compatibility limits for callers with unusually large or
slow uploads. Authentication and per-stream acceptance remain host/route-owned;
this change does not claim exhaustive validation of every nested payload field.

Reference checked 2026-11-09: https://nodejs.org/api/http.html (IncomingMessage
completion/close and the distinction between timeout notification and abort).

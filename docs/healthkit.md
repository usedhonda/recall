# How HealthKit holds data, and how recall reads it

Written after a ring's sleep and heart rate went missing from Hub while the Health app showed
them. Marked **Apple** (official docs), **Community** (forum reports, not official) or
**Observed** (this device's logs and screens). Unmarked lines are design decisions.

## What the store is

- **Apple:** every object is immutable and has a UUID, a source revision and a device. A sample
  has a start and end date. Nothing can be edited in place; a change is a delete plus a new save.
- **Apple:** HealthKit records the source and version when saving. A deleted sample leaves an
  `HKDeletedObject` for a time, visible to `HKAnchoredObjectQuery`.
- A sample's dates say when it was **measured**, not when it was **written**. The public fields
  expose no write time. So a date-window query cannot find "what is new".
- **Apple:** iPhone has its own store and syncs with Apple Watch. Recall reads the phone's store.

## Who writes, and when

- Observed: the ring's samples reach the Health store through its companion app, not directly.
  The source name is that app; whether a value came from the ring hardware cannot be told from it.
- Observed: the app writes in **batches**. Observer wake counts sat near 10-20 an hour, then jumped
  to thousands for sleep and tens of thousands for heart rate in one hour. Large batches were
  seen 2026-10-24 and 2026-10-31, with none between. What triggers a batch (for example opening
  the app) is **not established**.
- Observed: batches this large repeat over hours, which fits rewriting existing samples.
  Not proven: recall counts wakes, not sample identities.
- Observed: the companion app's own screen can hold data it has not yet written to Health (a week
  of nights in the app while the Health store's newest night was older). The Health app is the
  truth for what recall can read; the companion app is not.
- Observed: the same app also writes weight and body fat, with no scale in use. Do not read those
  as fresh measurements. Their origin is an open question.
- Observed: HRV is in the companion app. Its presence in Health is unchecked.

## How to read it

| Need | Query | Note |
|---|---|---|
| Totals (steps, kcal) | `HKStatisticsQuery` | **Community:** merges overlapping sources like the Health app |
| Discrete range (heart rate) | `HKStatistics(Collection)Query` | min, max, average |
| Latest value (weight, SpO2) | `HKSampleQuery` limit 1, newest first | check the date: it may be weeks old |
| Sleep | `HKSampleQuery` | **Community:** returns every overlapping sample; nothing merges them. How the Health app builds its timeline is not documented |
| "Something changed" | `HKObserverQuery` | **Apple:** fires on saves and deletes, carries no samples |
| "What was written since" | `HKAnchoredObjectQuery` | **Apple:** returns new saves and deletions after an anchor; nil anchor returns everything |

- Locked phone: queries fail with "Protected health data is inaccessible". Recall skips, then
  catches up on unlock.
- Read permission: **Apple's** privacy design does not reveal a denied read; expect it to look
  like "no data". An empty result therefore means no data **or** no permission.

## What recall does

- Sleep and heart rate were read from a window of the last 24 hours by sample date. A night written
  more than a day after it ended was never seen: the original failure.
- Each snapshot now also carries `sleepSessions` and `heartRateDays`, rebuilt from the last
  `HealthKitManager.historyDays` days (14). See docs/hub-producer.md for the fields.
- Why a rebuilt window and not an anchor: an anchor delivers each change once, so recall would have
  to store it, tie it to Hub acknowledgement, handle deletes and rewrites, and rebuild after a
  reinstall. A rebuild has no state and gets the same answer after any of these.
  Its limit: a night written more than 14 days late is missed, and so is anything older than that
  at first run.
- Sessions: grouped per source, split by a 3 hour gap, overlaps counted once, `inBed` excluded.
  These totals can differ from the Health app, which attributes sleep to days by its own rules.
- A snapshot goes out only when its fingerprint changes (or at the keepalive), so history alone
  does not cause extra sends.

## Checking by hand

Compare in this order: the Health app (category, then Show More Sleep Data), then
`[HEALTH] HK sleepSessions:` / `heartRateDays:` in the device log, then the
`metadata-health` receipt line, then the Hub reader. Each step can fail alone.

## Sources

- https://developer.apple.com/documentation/healthkit/about-the-healthkit-framework
- https://developer.apple.com/documentation/healthkit/hkanchoredobjectquery
- https://developer.apple.com/documentation/healthkit/hkobserverquery
- https://developer.apple.com/forums/thread/109473
- https://developer.apple.com/forums/thread/842919
- https://sahha.ai/blog/deduplicating-health-data-across-wearables/

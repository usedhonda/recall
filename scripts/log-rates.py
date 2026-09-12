#!/usr/bin/env python3
"""Count what recall did per hour, from the on-device activity log.

The log is the only honest record of how hard the app worked: a build that passes
says nothing about how often it woke up. Point this at one or more
`activity_<date>.log` files (UTC timestamps, JST-named files) and it prints, per
category, the total and the per-hour rate over the window, plus the location sends
hour by hour so a stationary stretch can be read off directly.

    scripts/log-rates.py logs/activity_2026-09-10.log
    scripts/log-rates.py --from 2026-09-12T00:00Z --to 2026-09-12T12:00Z logs/*.log
"""
import argparse
import re
from collections import Counter
from datetime import datetime, timezone

LINE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z \[([A-Z]+)\] (.*)$")

# What each counter means, in the order worth reading.
COUNTERS = [
    ("health query cycles", lambda c, m: c == "HEALTH" and m.startswith("Queried ")),
    ("health POST (bg)", lambda c, m: m.startswith("Telemetry POST (bg): health2")),
    ("health POST skipped (unchanged)", lambda c, m: "Unchanged since last POST" in m),
    ("location sent", lambda c, m: c == "LOC" and (
        m.startswith("Sent:") or m.startswith("BG direct sent") or m.startswith("BG heartbeat"))),
    ("location filtered", lambda c, m: c == "LOC" and m.startswith("Filtered:")),
    ("fresh-fix kick", lambda c, m: "fresh-fix kick" in m),
    ("upload queue health", lambda c, m: m.startswith("Queue health")),
    ("audio chunks finalized", lambda c, m: m.startswith("Finalized:")),
    ("battery", lambda c, m: m.startswith("Battery:")),
]

IS_LOCATION_SEND = COUNTERS[3][1]


def parse(paths, start, end):
    rows = []
    for path in paths:
        with open(path, errors="replace") as handle:
            for line in handle:
                match = LINE.match(line.rstrip("\n"))
                if not match:
                    continue
                stamp = datetime.strptime(match.group(1), "%Y-%m-%dT%H:%M:%S").replace(
                    tzinfo=timezone.utc)
                if (start and stamp < start) or (end and stamp >= end):
                    continue
                rows.append((stamp, match.group(2), match.group(3)))
    return rows


def when(text):
    if not text:
        return None
    return datetime.strptime(text.rstrip("Z"), "%Y-%m-%dT%H:%M").replace(tzinfo=timezone.utc)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("logs", nargs="+")
    ap.add_argument("--from", dest="start", help="UTC, e.g. 2026-09-12T00:00Z")
    ap.add_argument("--to", dest="end", help="UTC, exclusive")
    args = ap.parse_args()

    rows = parse(args.logs, when(args.start), when(args.end))
    if not rows:
        raise SystemExit("no log lines in that window")

    first, last = rows[0][0], rows[-1][0]
    hours = max((last - first).total_seconds() / 3600, 1 / 60)
    print(f"window {first:%Y-%m-%dT%H:%MZ} -> {last:%Y-%m-%dT%H:%MZ}  ({hours:.1f} h)")
    print(f"{'total lines':<34}{len(rows):>8}{len(rows) / hours:>10.1f}/h")
    for label, matches in COUNTERS:
        n = sum(1 for _, category, message in rows if matches(category, message))
        print(f"{label:<34}{n:>8}{n / hours:>10.1f}/h")

    per_hour = Counter(stamp.strftime("%m-%d %HZ") for stamp, category, message in rows
                       if IS_LOCATION_SEND(category, message))
    if per_hour:
        print("\nlocation sends by hour (UTC)")
        for hour in sorted(per_hour):
            print(f"  {hour}  {per_hour[hour]:>4}  {'#' * min(per_hour[hour], 60)}")


if __name__ == "__main__":
    main()

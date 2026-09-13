#!/usr/bin/env python3
"""Ask whether the speech detector can tell real speech from silence.

The transcriber answers silence with a stock phrase it learned from subtitles, so a
recording labelled "nothing but boilerplate" is one the device should never have sent.
oc-general labels those (`scripts/voice-labels` in their repo, one row per recording:
uuid, segments, boilerplate, low_confidence); this joins the labels to what recall
measured about the same audio and reports whether any threshold separates the two.

A detector that works shows the groups apart. On 2026-09-13, before the streaming fix,
they were on top of each other — median speech probability 0.41 for recordings with no
speech in them and 0.40 for real ones — and every candidate rule threw away real speech
at the same rate it caught silence.

    scripts/voice-separation.py labels.tsv activity_2026-09-13.log [more logs...]

Report the matched count, not only the rates: a rule looks perfect on an empty
denominator.
"""
import re
import sys

UPLOAD = re.compile(r"Uploaded (\S+\.caf) -> ([0-9a-f-]{36})")
FINAL = re.compile(
    r"Finalized: (\S+\.caf) ([\d.]+)s (\d+)KB rms=([\d.]+) vad=([\d.]+) mcv=(\d+)ms vfr=([\d.]+)"
)

# Each rule drops a chunk before upload. Good ones catch silence without taking speech.
RULES = [
    ("vad < 0.30", lambda c: c["vad"] < 0.30),
    ("vad < 0.35", lambda c: c["vad"] < 0.35),
    ("vad < 0.45", lambda c: c["vad"] < 0.45),
    ("vad < 0.60", lambda c: c["vad"] < 0.60),
    ("longest run < 1.5 s", lambda c: c["mcv"] < 1500),
    ("voice frames < 50%", lambda c: c["vfr"] < 0.50),
    ("shorter than 5 s", lambda c: c["dur"] < 5),
    ("shorter than 5 s and vad < 0.40", lambda c: c["dur"] < 5 and c["vad"] < 0.40),
    ("longest run < 1.5 s and vad < 0.40", lambda c: c["mcv"] < 1500 and c["vad"] < 0.40),
]


def load_labels(path):
    labels = {}
    with open(path) as handle:
        for line in handle:
            parts = line.split()
            if len(parts) >= 3:
                labels[parts[0]] = (int(parts[1]), int(parts[2]))
    return labels


def load_chunks(paths):
    uploaded, measured = {}, {}
    for path in paths:
        with open(path, errors="replace") as handle:
            for line in handle:
                if (m := UPLOAD.search(line)):
                    uploaded[m.group(1)] = m.group(2)
                if (m := FINAL.search(line)):
                    measured[m.group(1)] = {
                        "dur": float(m.group(2)), "rms": float(m.group(4)),
                        "vad": float(m.group(5)), "mcv": int(m.group(6)),
                        "vfr": float(m.group(7)),
                    }
    return uploaded, measured


def quantiles(rows, key):
    values = sorted(row[key] for row in rows)
    if not values:
        return "-"
    pick = lambda p: values[int(p * (len(values) - 1))]
    return f"p10 {pick(.1):8.2f}   median {pick(.5):8.2f}   p90 {pick(.9):8.2f}"


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    labels = load_labels(sys.argv[1])
    uploaded, measured = load_chunks(sys.argv[2:])

    silent, speech = [], []
    for filename, uuid in uploaded.items():
        if uuid not in labels or filename not in measured:
            continue
        segments, boilerplate = labels[uuid]
        if segments and boilerplate == segments:
            silent.append(measured[filename])
        elif boilerplate == 0:
            speech.append(measured[filename])

    print(f"labels {len(labels)}   uploads seen {len(uploaded)}   chunks measured {len(measured)}")
    print(f"matched: {len(silent)} with no speech, {len(speech)} with speech\n")
    if not silent or not speech:
        raise SystemExit("nothing to compare — check that the logs cover the labelled days")

    for key, label in [("vad", "speech probability"), ("mcv", "longest run (ms)"),
                       ("vfr", "voice frames"), ("dur", "duration (s)"), ("rms", "level")]:
        print(f"{label}")
        print(f"  no speech   {quantiles(silent, key)}")
        print(f"  speech      {quantiles(speech, key)}")
    print()

    print("if the chunk were dropped before upload:")
    for name, rule in RULES:
        caught = sum(1 for c in silent if rule(c))
        lost = sum(1 for c in speech if rule(c))
        print(f"  {name:36s} catches {100*caught//len(silent):3d}% of the silence, "
              f"loses {100*lost//len(speech):3d}% of the speech")


if __name__ == "__main__":
    main()

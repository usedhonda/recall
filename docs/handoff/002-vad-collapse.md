# Handoff: vad-collapse

- Goal / why: the speech detector decides what recall records and sends. When it is wrong
  the transcriber answers silence with a stock phrase it learned from subtitles, and that
  fiction reaches Chi as if the owner had said it.
- Scope: `Core/Audio/VADService.swift`, the detector call in `AudioRecordingEngine`,
  `RingBuffer`, `scripts/voice-separation.py`.
- Explicitly out: chunking rules (1.5 s silence / 30 s max), the audio format, upload.
- Status: repaired and deployed to kana 2026-09-13; **not yet verified against labels**.

## Two wrong shapes, and how each broke it

Silero is recurrent: it judges the current 256 ms partly from what came before, carried in
a state it returns with every result.

1. **Padded windows into a state that was never reset** (before `b51b646`): 100 ms of audio
   padded to 256 ms, fed into an accumulating state. Detection collapsed to silence within
   1-3 hours of a fresh start.
2. **Fresh state per overlapping window** (`b51b646`, 09-11): the newest 256 ms re-scored
   from scratch every 100 ms. Detection never collapsed, and never meant anything either.

## The measurement that settled it (2026-09-13)

oc-general labelled 903 recordings by whether every transcript segment was boilerplate.
Joined to what recall measured about the same audio (883 matched: 510 with no speech, 373
with speech), the two groups sat on top of each other:

| | no speech | speech |
|---|---|---|
| speech probability (median) | 0.41 | 0.40 |
| longest run (median) | 24.3 s | 24.2 s |
| voice frames (median) | 0.89 | 0.87 |

Every candidate rule threw away real speech at the rate it caught silence — `vad < 0.45`
catches 73% of the silence and loses 66% of the speech. **No on-device filter is possible
on these numbers**, which is the point: the absence of a difference is the evidence that
the detector carried no information.

## What this was NOT (corrected 2026-09-13, oc-general)

The rate of boilerplate transcripts rose from 1.6% on 09-11 to 41% on 09-12, and within
09-12 it climbed through the evening. Neither is evidence that `b51b646` made anything
worse, and this document should not be read that way:

- The evening climb is the owner asleep. Counting real (non-boilerplate) speech by hour
  UTC: 07h 89%, 08h 82%, 09h 82%, 15h 82%, then **16h 7%, 17h 9%, 18h 5%, 19h 11%**, back
  to 85% at 23h. 16-19h UTC is 01-04h JST.
- The day-over-day jump is recording hours. 09-11 recorded only 07-11h UTC (daytime, no
  night); 09-12 ran all 24 h, so a night of silence was added to the denominator.

The case for the repair rests on something else entirely: **the detector's numbers carried
no information about whether anyone had spoken** (0.41 vs 0.40, below). Never compare daily
totals — compare the same hours.

## Baseline before the swap (oc-general, 2026-09-13)

| | all segments | real speech | characters of real speech | recordings |
|---|---|---|---|---|
| 09-11 | 311 | 296 | 5,250 | 153 |
| 09-12 | 1,270 | 543 | 7,192 | 891 |

Daytime (07-15h UTC) real-speech share ran 44-89% on the old build. **That is the number
that falls if the new gate starts missing quiet or distant speech** — and it is invisible
in the boilerplate labels, because audio that was never recorded is never labelled.

## The repair (`dbbf499`)

Contiguous, non-overlapping windows, state carried forward, and the library's own state
machine (`makeStreamState` / `processStreamingChunk`) raising speech start and end. Quiet
audio is fed too — that is how the model hears a sentence end; the power gate only decides
whether a frame may open a chunk. `RingBuffer.read(after:)` hands over exactly what has
arrived since last time (tested: `RingBufferStreamTests`).

## How to verify — do not skip this

A changed detector always changes the distribution. That is not evidence it separates.

1. Let the new build run through a normal day.
2. Regenerate labels: `scripts/voice-labels` in oc-general's repo (`--start-date` /
   `--end-date`), which imports the live filter's own predicate so the yardstick cannot
   drift from production.
3. `scripts/voice-separation.py labels.tsv <device logs>` and read the matched count first
   — a rule looks perfect on an empty denominator.
4. Regenerate the by-hour real-speech table too, and compare **daytime hours against the
   baseline above**. Do not skip this: "fewer hallucinations" is also what you get by
   recording less, and the owner losing a real utterance costs more than a fiction kept.
5. Only then pick a drop rule, and only if it catches silence at a rate the speech loss
   does not match.

## First signals from the new build (2026-09-13 00:40Z, directional only)

Quiet frames on the device now report 0.00 where they used to drift between 0.16 and 0.43,
and a silent simulator reads 0.061 where it read 0.15-0.55. Four chunks opened in the first
80 minutes of a quiet room. **None of this is evidence of separation** — that needs the
labels. Note also that the macmini UDP mirror showed 170 chunks over the same window: it
carries lines from a second sender and cannot be counted. Use the on-device log.

## Also watch

- **Missed quiet speech.** The new gate leans on Silero's own start threshold. The owner
  cares about distant speech (3-5 m); if real utterances stop being recorded, that is the
  cost side of this change and it will not show up in the labels above.
- oc-general suppresses known boilerplate before Chi reads it (their `2bd62a2`): 733 of 914
  recordings excluded, no real recording lost. Audio and rows are untouched, so everything
  can be re-judged once the detector is trusted. It is symptom relief — noise-derived text
  that is not a known phrase still passes.

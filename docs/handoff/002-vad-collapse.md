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
4. Only then pick a drop rule, and only if it catches silence at a rate the speech loss
   does not match.

## Also watch

- **Missed quiet speech.** The new gate leans on Silero's own start threshold. The owner
  cares about distant speech (3-5 m); if real utterances stop being recorded, that is the
  cost side of this change and it will not show up in the labels above.
- oc-general suppresses known boilerplate before Chi reads it (their `2bd62a2`): 733 of 914
  recordings excluded, no real recording lost. Audio and rows are untouched, so everything
  can be re-judged once the detector is trusted. It is symptom relief — noise-derived text
  that is not a known phrase still passes.

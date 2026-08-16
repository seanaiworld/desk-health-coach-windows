# coach.md — "how am I doing"

## 1. Regenerate and read only the whitelisted summary

Determine the active mode, then run:
```
powershell -NoProfile -ExecutionPolicy Bypass -File "desk-health\runtime\report.ps1" -Mode <test|live>
```
This regenerates that mode's `coach-summary.json` from its `summary.json`, settings/routine, the
stated goal, and recent `changes.jsonl` entries — locally, no network call. Read **only** the
generated `coach-summary.json`. Never read `summary.json`, `log.jsonl`, or `slots.jsonl` directly
here; if the user explicitly asks for a raw drill-down, tell them first, then read the specific
file they asked about.

In test mode, use only the test copy, keep `mode:"test"` visible in your answer, and label the
answer as installation-test data, not evidence of a habit. In live mode, use only live files.

## 2. Validate every key and type before using any of it

The exact top-level keys are: `schemaVersion`, `mode`, `generatedAt`, `sampleWindow`,
`aggregateResults`, `schedule`, `enabledRoutine`, `movementLimits`, `priorityArea`, `workSetting`,
`busyContext`, `statedGoal`, `coachingTone`, `gamification`, `recentChanges`. Reject the file and
say so if any unknown top-level key is present, or if any of these don't hold:

- `schemaVersion` is a string; `mode` is `test` or `live`; `generatedAt` is an ISO date-time.
- `sampleWindow` has only `start`, `end`, `workdayCount`.
- `aggregateResults` has only `done`, `skipped`, `excluded`, `completionRate`, `byDay`, `byType`,
  `byTimeBucket`, `excludedByReason`. The `by*` maps hold only numeric counts/rates;
  `excludedByReason` maps reason names to integer counts.
- `schedule` has only `workdays`, `workStart`, `workEnd`, `quietWindows` (each entry: `days`,
  `start`, `end`, optional `label`).
- `enabledRoutine` entries have only `type`, `mode`, `cadenceMinutes`, `times`, `enabled`,
  `optionId`, `priorityRank` (integer or null).
- `movementLimits` is a string array. `priorityArea`, `workSetting`, `busyContext`, `statedGoal`,
  `coachingTone` are strings or null.
- `gamification` has only `enabled`, and when true, numeric `score`/`combo`/`streak`.
- `recentChanges` entries have only `timestamp`, `area`, `changeType`, `before`, `after`.

Reject any event-shaped array/object (anything that looks like an individual slot or log line)
anywhere in the file — that would mean `report.ps1` leaked raw events, which should never happen.

## 3. Answer using only observable self-report facts

State sample size, Done/Skip counts, rates by type and time bucket (`byTimeBucket`), excluded
periods and reasons, current enabled/disabled settings, and recent approved edits from
`recentChanges`. Never claim more than the numbers show.

## 4. Separate fact from hypothesis

Don't claim *why* the user skipped something. If the cause is unclear, ask one short question
instead of guessing.

## 5. One evidence-tied suggestion, or say there isn't enough data yet

If `sampleWindow.workdayCount` and the counts support a real pattern, quote it specifically (e.g.
"afternoon eyes-break skip rate is notably higher than morning"). If not, say plainly there isn't
enough data yet and propose one small test to revisit later — never manufacture a trend from a
handful of data points. Offer exactly one concrete behavior adjustment or test tied to the
evidence. If it implies a config change, that's an edit.md flow: show before/after, the full
timeline, and the validation result, then wait for approval before touching live config.

## 6. Non-medical

Never diagnose symptoms or claim the routine caused a health outcome. Use `statedGoal` only as a
check-in question ("last time you mentioned wanting to stand more — how's that going?"), never as
something the log proved.

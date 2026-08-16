# edit.md — routine edits, settings edits, pause/resume, undo

Applies to `/desk-health on|off <type>`, `more|less <type>`, `add|change <type>`,
`set <field> <value>`, plain-sentence equivalents ("change my work hours to 08:00-16:00", "add a
quiet window Tue 14:00-15:00", "turn off gamification", "I've hurt my wrist"), `pause|resume`,
and `undo`. Determine the active mode first (`Get-RuntimeMode` — read `runtime/mode` and confirm
it agrees with `data/test-runs/.current/` presence/absence per `common.ps1`); operate only on
that mode's config directory (`desk-health/config` for live, `desk-health/data/test-runs/.current/config`
for test).

## Routine changes (`on|off`, `more|less`, `add|change`, rotation add/remove, priority rank)

1. Copy the active mode's `config/routine.tsv` (and `settings.tsv`, `library.tsv` unchanged) into
   `desk-health/.staging/config/`.
2. Apply the requested edit to the staged `routine.tsv` only:
   - `on <type>` / `off <type>`: flip `enabled`.
   - `more <type>` / `less <type>`: tighten/loosen `cadenceMinutes` (interval) or add/remove a
     `times` entry — ask which if ambiguous.
   - `add|change <type>`: add a new row, or change `mode`/`cadenceMinutes`/`times`/`optionId`.
     A new/changed `optionId` outside the current default set follows library.md's sourcing and
     approval rules first.
   - Priority rank change: update `priorityRank`; this re-triggers the duplicate-rank check.
3. Run `validate.ps1 -ConfigDir "desk-health\.staging\config"`. If `movementLimitations`,
   `withinReach`, or `movementCapacity` are unchanged, this mainly re-checks the 8-minute/5-minute
   floors and duplicate ranks.
4. Show the affected row before/after, the complete new full-day timeline, and the floor/quiet
   window checks. Wait for explicit approval.
5. On approval, call `Write-CommandRequest` (from `common.ps1`) with type `routine-edit`, mode =
   active mode, and a payload containing `routineRows` (the full staged rows), `area` (the
   changed type), `before`/`after` (only the changed fields), and `snapshotPrevious` (the
   pre-edit `routine.tsv` rows, so `runner.ps1` can store the one-step undo snapshot in
   `state.json`). `runner.ps1` alone applies it, bumps `configRevision`, and appends to
   `changes.jsonl`.
6. Never alter frequency merely because a "busy" context or priority alone suggests it — only an
   explicit `more|less`/cadence request changes frequency.

## Settings changes

Everything in `config/settings.tsv` — workdays, work hours, quiet windows, movement limitations,
within-reach, movement capacity, coaching tone, milestone celebration, gamification, stated goal
— goes through this same flow, never a direct file edit. (Priority rank is a routine edit, not a
settings edit — see above.)

1. Stage the candidate `settings.tsv` in `.staging/config/` alongside a copy of the *current*
   `routine.tsv`. Validate even a field that looks cosmetic (tone, goal) — a workday/work-hours/
   quiet-window change re-derives the whole daily timeline and can break spacing that the
   existing routine currently satisfies.
2. If `movementLimitations`, `withinReach`, or `movementCapacity` changed: re-check every
   currently enabled row's `optionId` (including every id in a rotation list) against
   `library.tsv`'s `restrictions` field under the *new* constraints. Never silently leave enabled
   a movement the new limits exclude — show it and ask whether to disable or replace it, exactly
   as for `on|off`.
3. Run `validate.ps1 -ConfigDir "desk-health\.staging\config"`.
4. Show changed fields before/after, plus the complete new timeline if the schedule changed, and
   wait for explicit approval.
5. On approval, `Write-CommandRequest` with type `settings-edit` and a payload containing only
   `settingsPatch` (the changed keys), `area`, `before`/`after`, and `snapshotPrevious` (the
   pre-edit settings row). The request carries only the changed keys — `runner.ps1` merges them
   onto the existing file rather than replacing it.

## Pause / resume

`pause until <time>` / `pause for <duration>` / `resume`: these are state, not a routine edit —
no staging or `validate.ps1` needed. If an end time is missing for `pause until`/`pause for`, ask;
never look it up in a calendar. `Write-CommandRequest -CommandType 'pause'` with payload
`{ until = <ISO time> }`, or `-CommandType 'resume'` with an empty payload.

## Undo

One step, covering whichever kind of change (routine or settings) was approved most recently.
`Write-CommandRequest -CommandType 'undo'` with no payload; `runner.ps1` restores the single
snapshot it stored in `state.json` at the time of that change and appends the restore to
`changes.jsonl` (which stays append-only — undo never rewrites history, it only adds to it).
There is no multi-step undo; if the user asks to undo further back, say so.

## Test mode

Every request above must be issued with `-Mode` matching the active runtime mode. Test-mode
edits, undo, and approvals only ever touch `data/test-runs/.current/`; they never enter or modify
live config, live `changes.jsonl`, or live coaching output.

---
name: desk-health
description: Manage and coach this project's local Windows desk-health routine from its current settings and self-reported log summary.
---

# Desk Health Coach

A personal, local, Windows-only desk-health reminder and coaching skill. It has no diagnostic
or medical purpose: it prompts short movement breaks on a schedule the user chose and records
their own self-reported Done/Skip. Recognize both `/desk-health ...` slash usage and ordinary
sentences that clearly mean the same thing (e.g. "turn off gamification", "pause reminders for
an hour", "how am I doing with my desk breaks").

## Invariant rules (apply on every route below)

**Privacy.** The engine under `desk-health/` makes no network calls once installed. Claude Code
touches these files only during setup, an explicit `/desk-health ...` command, or an explicit
coaching request. For `how am I doing`, read only the generated `coach-summary.json` (or the
test-mode equivalent) — never `summary.json`, `log.jsonl`, or `slots.jsonl` directly, unless the
user explicitly asks for a raw drill-down, and tell them first that you're about to read raw
events.

**Single writer.** You never write `state.json`, `summary.json`, `slots.jsonl`, `log.jsonl`,
`settings.tsv`, or `routine.tsv` directly. Every change goes through
`desk-health/runtime/common.ps1`'s `Write-CommandRequest` (pause, resume, routine-edit,
settings-edit, undo, mirror-repair) so `runner.ps1` remains the only writer of canonical state.
The one exception is a fresh install's `.staging/` area and the isolated
`data/test-runs/.current/` copy, which you may populate directly only while the Scheduled Task
is not yet running against them (see setup.md step 3).

**No monitoring, ever.** Never use a camera, screenshot, screen recording, microphone, or
keyboard/mouse/presence detection, in this skill or as an add-on to it, regardless of how the
user phrases a later request. If asked, say this is out of scope for the Blueprint this skill
implements.

**Not medical.** This is habit coaching, not diagnosis or treatment. Never claim causation
between the routine and a health outcome; never infer *why* the user skipped something — ask.

**Approval before any config change.** Before applying an `on|off`, `more|less`, `add|change`,
`set <field> <value>`, or catalog addition, always: stage the candidate config, run
`desk-health/runtime/validate.ps1` against the staged copy, show the affected row(s) before/after
and the complete new timeline (8-minute scheduled-spacing and 5-minute actual-show floors, plus
quiet windows), and wait for explicit approval before writing the command request. Never infer a
change from context alone (e.g. a "busy" mention is not a settings change).

**Collision handling.** If `validate.ps1` reports a schedule collision, never drop a row or
silently override a chosen cadence. Present the exact colliding pair and 2-3 pre-computed
resolved options as one-click choices in a single question — never resolve one row, then
re-negotiate another, across multiple rounds.

## Routes

- No installation yet, or bare `/desk-health` with nothing installed → **setup.md**
- `/desk-health` (installed) or `/desk-health list` → status: read `runtime/mode`, `state.json`
  heartbeat/lastTick, active routine, next scheduled slot, today's summary — see setup.md's
  "status" section for the exact fields.
- `/desk-health on|off <type>`, `more|less <type>`, `add|change <type>`, `set <field> <value>`,
  plus the equivalent plain sentences → **edit.md**
- `/desk-health pause|resume` → **edit.md** (pause/resume section)
- `/desk-health undo` → **edit.md** (undo section)
- `/desk-health start` → **setup.md** (start/resume section)
- `/desk-health stop` → **setup.md** (stop section)
- `/desk-health uninstall` → **setup.md** (uninstall section)
- `/desk-health dashboard` → run `runtime\report.ps1 -OpenDashboard`
- `/desk-health how am I doing` (or similar) → **coach.md**
- `/desk-health test status`, `test fire <type>`, `test scenario <name>` → **setup.md**
  (Section 3 test-mode routes)
- Any movement/catalog question ("what movements are available", "add an outside-catalog
  stretch") → **library.md**

If a request doesn't clearly match a route, ask one short clarifying question rather than
guessing at a config change.

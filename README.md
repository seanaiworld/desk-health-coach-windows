# Desk Health Coach (Windows)

A personal, local desk-health reminder and coaching engine for Windows 10/11, driven by a
Claude Code skill. It prompts short movement breaks on a schedule you choose and tracks your own
self-reported Done/Skip — it does not diagnose, treat, or measure anything, and it does not use a
camera, microphone, or activity monitoring.

No installation is included in this repo. This is the reusable engine and setup skill; running
`/desk-health` in Claude Code interviews you for your own schedule, movement limitations, and
preferences, then builds and validates your personal routine from that.

## How it works

- **No extra runtime.** Windows-provided Task Scheduler, PowerShell (5.1 or 7), and the built-in
  `System.Windows.Forms` assembly only — no Node, Python, Docker, browser extension, or
  third-party module.
- **Local only.** Once installed, the reminder engine makes no network calls. Config, schedule,
  and logs are local files under a private `desk-health/` folder that setup creates in your
  project (see [.gitignore](.gitignore) — that folder's config/state/data are never committed).
- **One Scheduled Task.** A single per-user Scheduled Task (`\DeskHealthCoach\runner`) runs the
  reminder loop at login. No admin rights required, no Windows Service, no Startup-folder hack.
- **Approve every change.** Every routine or settings change is staged, validated, shown to you
  with the full before/after timeline, and applied only after you approve it.

## Getting started

1. Open this project in Claude Code.
2. Run `/desk-health` (or just say what you want, e.g. "set up my desk health reminders").
3. Answer the short interview: workdays, work hours, quiet windows, any movement limitations,
   which reminder types you want and how often, coaching tone, and whether to turn on
   gamification.
4. Claude Code stages and validates the proposed schedule (checking for scheduling collisions),
   shows you the full timeline, and waits for your approval before installing anything.
5. The install runs in an isolated test mode first — you verify reminders actually fire and the
   dashboard updates — before it ever switches to live tracking.

## Repository layout

```
.claude/skills/desk-health/   the Claude Code skill (routes /desk-health commands)
  SKILL.md                    routing + the invariant privacy/approval/safety rules
  setup.md                    interview -> stage/validate/approve/install -> test mode -> live
  edit.md                     routine/settings edits, pause/resume, undo
  coach.md                    the "how am I doing" coaching flow
  library.md                  the movement catalog and sourcing rules for new movements

desk-health/runtime/          the engine itself (generic, not tied to any one user)
  common.ps1                  locking, atomic writes, TSV/JSON helpers
  schedule.ps1                timeline expansion and the collision/placement algorithm
  scoring.ps1                 gamification points, streaks, milestone lines
  validate.ps1                schema + schedule validation, run before every install/change
  runner.ps1                  the long-running Scheduled Task process (only writer of state)
  dialog.ps1                  the reminder popup (Skip/Done)
  report.ps1                  generates the local dashboard and coaching summary
  test-harness.ps1            deterministic scenario injectors for `/desk-health test scenario`
  catalog-defaults.tsv        the default movement library (eyes, neck, wrists, back, etc.)
```

Everything a real install creates — `desk-health/config/`, `state/`, `data/`, `dashboard.html`,
`coach-summary.json`, `installed-files.txt` — is private to your machine and gitignored, since it
holds your schedule, any stated limitations, and your goal.

## Commands

Once installed, talk to the skill via `/desk-health` or plain sentences:

| Command | Does |
|---|---|
| `/desk-health` / `list` | Status: alive/dead, current routine, next prompt, today's counts |
| `/desk-health on\|off <type>` | Enable/disable a reminder type |
| `/desk-health more\|less <type>` | Tighten/loosen a cadence |
| `/desk-health set <field> <value>` | Change work hours, quiet windows, tone, goal, etc. |
| `/desk-health pause\|resume` | Pause reminders until a time or duration |
| `/desk-health dashboard` | Open the local dashboard |
| `/desk-health how am I doing` | Coaching based on your self-reported log |
| `/desk-health undo` | Revert the most recent approved change |
| `/desk-health stop` / `start` | Disable/re-enable the Scheduled Task, keeping all history |
| `/desk-health uninstall` | Remove the install; preserves your data by default |

## Non-goals

Not a medical device, not a fitness tracker, and not a monitoring tool. It never uses a camera,
screenshot, screen recording, microphone, or keyboard/mouse/presence detection, and it never
infers meetings from a calendar. Done and Skip are your own self-reports.

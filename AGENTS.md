# AGENTS.md

This repo contains the Desk Health Coach engine and its operating instructions. Read this file
first if you are Codex, or any other agent that reads `AGENTS.md`, before touching
`desk-health/` or acting on a desk-health-related request.

## What this repo is

`desk-health/runtime/` is a generic, local Windows reminder/coaching engine (PowerShell + Task
Scheduler + WinForms, no extra runtime, no network calls once installed). It is driven by an
instruction set written for Claude Code's skill format, but nothing about following those
instructions requires Claude Code specifically — read the markdown files with your normal file
tools and act on them with your normal shell/PowerShell tool the same way you would follow any
other instructions file in this repo.

## Where the actual instructions live

`.claude/skills/desk-health/` — read `SKILL.md` first. It contains the routing table and the
invariant rules (privacy, single-writer state, no monitoring, non-medical, approval-before-change,
collision handling) that apply no matter which route you're on. It then points to:

- `setup.md` — first-time install: interview the user, stage config, validate, get approval,
  install, run the isolated test-mode checklist, then switch to live.
- `edit.md` — routine/settings changes, pause/resume, undo.
- `coach.md` — the "how am I doing" coaching flow and its strict output-schema checks.
- `library.md` — the default movement catalog and the approval flow for adding movements.

Follow those files exactly as written; they were authored to be tool-agnostic already (every
action they describe is a plain PowerShell invocation of a script under `desk-health/runtime/`,
never a Claude-specific tool call). The only Claude-specific things in this repo are the
slash-command surface (`/desk-health ...`) and the YAML frontmatter at the top of `SKILL.md` —
treat a request phrased as `/desk-health ...` or in equivalent plain English the same way that
document does, and treat the frontmatter as a name/description only, not something you need to
execute.

## Ground rules that apply regardless of which agent is driving

- Never write `desk-health/state/`, `data/`, `config/settings.tsv`, or `config/routine.tsv`
  directly — every change is staged, validated with `desk-health/runtime/validate.ps1`, shown to
  the user for approval, then submitted as a command request per `common.ps1`'s
  `Write-CommandRequest`, so `runner.ps1` remains the only writer of canonical state.
- Never add camera, screenshot, screen-recording, microphone, or keyboard/mouse/presence
  monitoring, in this skill or as an add-on to it.
- Never claim the routine diagnosed, treated, or caused a change in a health outcome.
- Windows only, PowerShell only (5.1 or 7), no admin elevation, no extra installed runtime.

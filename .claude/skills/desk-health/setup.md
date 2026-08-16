# setup.md — install, status, start/stop, uninstall, Section 3 test routes

This is Windows v1 for fixed repeating workdays and work hours on Windows 10/11 only. Never offer
a macOS build, variable-shift support, calendar access, or inferred meeting detection. Use 24-hour
time; accept only a same-day work range where start is earlier than end. Do not require or
request Administrator elevation anywhere in this flow.

## 0. Before anything else

Check whether `desk-health/config/settings.tsv` and `desk-health/runtime/mode` already exist.

- If they exist → this is not a fresh install. Stop this flow and offer an update/migration
  conversation instead; never reset existing live state, summaries, config, or history to zero.
- If the currently opened project folder resolves to the user's home folder itself, stop and ask
  them to open a real project folder first — building `desk-health/` there would make the skill
  folder resolve to the user's global home `.claude/skills/`, which uninstall could then delete.

## 1. Interview (replaces the Blueprint's Section 1 PDF)

Ask for, in one pass, everything needed to populate `config/settings.tsv` and
`config/routine.tsv`. Don't turn this into a multi-round interview — batch it:

1. **Workdays** — subset of Mon..Sun.
2. **Work hours** — 24h `HH:mm` start and end, same day, start earlier than end.
3. **Quiet windows** (optional) — any number of `day(s) + start + end (+ label)` entries. No
   calendar access; ask the user directly, never infer from any application.
4. **Movement limitations** — "none" or a list (e.g. wrist, back, hip). Reject "none" combined
   with a specific limitation.
5. **What's within reach at the desk** and **movement capacity** (can they stand/walk freely,
   are they seated-only, etc.) — free text, used later for coaching context and for filtering
   the catalog in library.md.
6. **Which movement categories to enable** and, per category, **interval (every N minutes) or
   exact times**, plus an optional **priority rank** (1 = highest; blank = unranked; ranks must
   be unique). Categories map to the default catalog in library.md — filter out any the user's
   limitations rule out, and ask about outside-catalog or extra rotation movements per
   library.md's sourcing rules (batch all sourcing/approval into this same interview, never a
   separate round per movement).
7. **Coaching tone** (e.g. encouraging, direct, minimal, playful).
8. **Gamification on/off**, and if on, **milestone celebration on/off**.
9. **Stated goal** (optional, free text) — a check-in question for coach.md, never proof of
   anything.

Read back the interpreted answers as a short list. Ask again only for a missing required answer
or a genuine ambiguity that would change the build (e.g. a cadence collision touching several
rows) — pre-compute the concrete resolved options for that and ask once, all options together.

## 2. Stage and validate

1. Create `desk-health/.staging/` restricted to the current user
   (`icacls <path> /inheritance:r /grant:r "$env:USERNAME:(OI)(CI)F"`) before writing anything
   into it.
2. Write the interviewed answers into `desk-health/.staging/config/settings.tsv` and
   `routine.tsv` (single-row settings.tsv; routine.tsv one row per category — see the header
   columns documented at the top of `runtime/validate.ps1`). Seed
   `desk-health/.staging/config/library.tsv` from the tracked, generic
   `desk-health/runtime/catalog-defaults.tsv` (the six defaults — this file ships in the repo and
   is never per-user), then append any newly-approved catalog additions from library.md. From
   this point on, `config/library.tsv` is this install's private working copy; edits to it go
   through the normal staged/validate/approve flow like any other config file, never by editing
   `catalog-defaults.tsv`.
3. Run:
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File "desk-health\runtime\validate.ps1" -ConfigDir "desk-health\.staging\config"
   ```
4. If it reports `INVALID`, this is a schedule collision or a schema problem — never drop a row
   or silently change a cadence. Show the exact error, pre-compute 2-3 concrete resolved pairings
   (e.g. "Eyes 20 / Neck hourly" vs "Eyes 30 / Neck 30" vs "Eyes 20 / Neck off"), and ask once.
   Re-stage and re-validate after the user picks.
5. If it reports `VALID` with warnings (e.g. a movement conflicts with a stated limitation), show
   the warning and ask whether to disable or replace that row before continuing.
6. Print the full interpreted answers, the complete proposed timeline from `validate.ps1`'s
   output, all quiet windows, and confirmation that the 8-minute scheduled-spacing and 5-minute
   actual-show floors are satisfied.

## 3. Explain and approve

Explain plainly: approval promotes this already-validated staging build and registers one
per-user Scheduled Task (`\DeskHealthCoach\runner`, trigger "At log on" for the current user,
restart-on-failure with a bounded restart count). No Administrator rights, no extra runtime, no
network calls once running. Wait for explicit approval. If declined, leave any existing live
install untouched (there shouldn't be one at this point per step 0) and offer to remove staging.

Before using the task path `\DeskHealthCoach\runner`, check with
`Get-ScheduledTask -TaskPath '\DeskHealthCoach\' -TaskName 'runner'` (ignore the not-found error)
— if it already exists, stop and ask before touching it.

## 4. Promote, isolate into test mode, and start

After approval:

1. Atomically promote `.staging/config/*` into `desk-health/config/*`, then re-run
   `validate.ps1 -ConfigDir "desk-health\config"` against the promoted copy. If that fails,
   restore from `.staging` (nothing was registered yet) and stop.
2. Create `desk-health/data/test-runs/.current/` and copy the promoted `config/` into it, plus an
   empty `changes.jsonl`. Confirm `desk-health/state/`, `desk-health/data/*.jsonl`, and
   `desk-health/data/summary.json` are all absent/empty at the live root.
3. Write `desk-health/runtime/mode` containing exactly `test`.
4. Register the Scheduled Task:
   ```
   $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File "<absolute path to>\desk-health\runtime\runner.ps1"'
   $trigger = New-ScheduledTaskTrigger -AtLogOn
   $settings = New-ScheduledTaskSettingsSet -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 5
   Register-ScheduledTask -TaskName 'runner' -TaskPath '\DeskHealthCoach\' -Action $action -Trigger $trigger -Settings $settings
   Start-ScheduledTask -TaskName '\DeskHealthCoach\runner'
   ```
   Use absolute, quoted paths throughout. Never elevate.
5. Confirm the runner is alive: check `desk-health/runtime/tick.log` for a heartbeat newer than a
   few seconds ago, and `state.json`'s `lastTick` in `data/test-runs/.current/state/`.
6. Write `desk-health/installed-files.txt` with the canonical absolute paths this build created
   (config, runtime scripts, the Scheduled Task path, the skill folder) — this becomes the
   manifest `stop`/`uninstall` validate against.

The runner must never execute in live mode before Section 3 below is complete.

## Section 3 — test-mode verification (must complete before going live)

Stay entirely in test mode for all of this. Nothing here touches live files.

1. `/desk-health test status` → confirm `runtime/mode` is `test`, `data/test-runs/.current/`
   exists, and report the next required check from the list below.
2. `/desk-health test fire <type>` → trigger a reminder immediately for that type (bypass the
   schedule check for this one call only, still write through the normal dialog/runner path).
   Click Done before `minSeconds` elapses, confirm the "Not so fast" re-prompt, then click Done
   truthfully. Confirm the event in `data/test-runs/.current/data/slots.jsonl` shows
   `"mode":"test"` and the test dashboard's count reflects it
   (`runtime\report.ps1 -Mode test -OpenDashboard`).
3. Run each scenario and confirm the described outcome:
   `powershell -NoProfile -ExecutionPolicy Bypass -File "desk-health\runtime\test-harness.ps1" -Scenario <name>`
   for `pause`, `quiet`, `dialog-busy`, `unshown`, `wake-gap`, `collision`, `streak` — each prints
   what it injected and what to confirm. These call into the same `runner.ps1`/`schedule.ps1`
   code paths as live mode; they never fabricate expected output directly and never touch the
   real PC clock.
4. Propose one small approved change (routine or settings) through edit.md while still in test
   mode, then run `/desk-health undo` and confirm the test copy matches its initial routine and
   settings — and that the *live* `desk-health/config/*` remains byte-for-byte unchanged
   throughout (it's never touched while in test mode).
5. After a logout/login, instruct the user to reopen this project folder and run
   `/desk-health test status` again before continuing, to prove the Scheduled Task resumed in
   test mode.

## Switch to live

Once every applicable Section 3 check passes:

1. Stop the runner (`Stop-ScheduledTask -TaskName '\DeskHealthCoach\runner'`), confirm no dialog
   worker process remains, and confirm the test command inbox, dialog inbox, and dialog lock are
   all empty.
2. Atomically rename `data/test-runs/.current/` to `data/test-runs/<timestamp>/`.
3. Initialize fresh, empty live `state/`, `data/slots.jsonl`, `data/log.jsonl`,
   `data/summary.json`, and `data/changes.jsonl` (an empty live install may include one optional
   non-behavioral setup-baseline record and nothing else).
4. Write `runtime/mode` as `live`.
5. Run `runtime\report.ps1 -Mode live` to regenerate the live dashboard/coach-summary from those
   empty files and confirm every count starts at zero.
6. Restart the Scheduled Task. The next actual workday is Day 1.

Print the one-line privacy summary, `/desk-health` status command, `/desk-health pause|resume`,
`/desk-health how am I doing`, and `/desk-health uninstall`. Then stop.

## Status (`/desk-health` or `/desk-health list`)

Read `runtime/mode`; read that mode's `state.json` for `lastTick` (alive if within the last
~2 minutes) and `pauseUntil`; read the active `config/routine.tsv` for the enabled routine; run
`schedule.ps1`'s `Build-Timeline` (via `validate.ps1 -ConfigDir <active config dir>`) to report the
next scheduled slot; read that mode's `data/summary.json` for today's Done/Skip/excluded counts.
Report all of this plainly — never claim more than what's in these files.

## `/desk-health start`

Only after `/desk-health stop`. Refuse if the recorded Scheduled Task name/path in
`installed-files.txt` doesn't match `\DeskHealthCoach\runner` exactly (identity-safe reload).
Otherwise `Enable-ScheduledTask` + `Start-ScheduledTask` on that exact path.

## `/desk-health stop`

Show a dry-run: which Scheduled Task will be disabled. On confirmation,
`Disable-ScheduledTask -TaskName '\DeskHealthCoach\runner'`, confirm the runner process and any
dialog worker have stopped, but preserve every config/state/data file untouched.

## `/desk-health uninstall`

1. Dry-run: list every path from `installed-files.txt`. Reject and refuse to proceed if any
   entry is relative, contains `..`, is a symlink/junction, resolves outside the exact
   `desk-health/` folder or this project's `.claude/skills/desk-health/`, or isn't the exact
   expected Scheduled Task path.
2. Confirm with the user.
3. Disable/unregister the Scheduled Task, verify the runner and any dialog worker actually
   stopped (`Get-Process` check by recorded PID/name), then unregister the task.
4. Copy validated `settings.tsv`, `routine.tsv`, `library.tsv`, and `changes.jsonl` into a
   timestamped `desk-health/data/uninstall-snapshot/` before removing anything.
5. Remove only the exact manifest-listed runtime/config/dashboard/skill files. Preserve
   `data/`/history by default; only delete history if the user separately asks for and approves
   an exact history-deletion list. Never touch unrelated project files, and never remove the
   `.gitignore` entries while any preserved snapshot or history remains. Never use
   `Remove-Item -Recurse -Force` on the project root, user profile, `.claude`, or Windows system
   directories — remove only the exact listed files/folders.

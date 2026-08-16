# library.md — movement catalog

## Default catalog (do not invent alternatives to these)

`desk-health/runtime/catalog-defaults.tsv` is the tracked, generic source for these six vetted
defaults (it ships with the engine, is never per-user, and is never edited in place). setup.md
seeds each install's private `config/library.tsv` from it. Filter which defaults apply against
the user's stated movement limitations during setup/edit; never invent an exercise or silently
substitute a different one for an excluded category.

| optionId | type | dose | minSeconds | notes |
|---|---|---|---|---|
| distance-gaze-20s | eyes | 20 sec | 20 | look ~20 feet away |
| shoulder-rolls | neck-shoulders | 6 rolls | 15 | 3 forward, 3 back |
| hands-open-close | wrists-hands | 3 reps | 10 | fist open/close |
| seated-slouch-tall | lower-back | 3 reps | 15 | restrictions: omit for back pain/limits or uncertainty |
| stand-walk | standing | 60 sec | 60 | restrictions: standing/walking must be allowed |
| posture-self-check | posture | one check | 15 | shows one compact self-check list, still counts as one action per reminder |

Each row's `sourceURL` is preserved in `library.tsv` — show it if asked. `minSeconds` is a
workflow honesty gate (the dialog re-prompts if Done is clicked too fast), never a medical dose.

If a selected category has no compatible catalog item under the user's limitations, say so
directly rather than substituting something else.

## Adding more than one rotation movement per category, or an outside-catalog movement

If Section 1 (the setup interview) or a later `add|change` request wants more than one rotating
movement for a category, or a movement outside this catalog entirely:

1. Find a reputable public-health, occupational-health, or clinical source (comparable in kind
   to the sources already in `library.tsv` — official health-agency, hospital, or standards-body
   guidance, not a general fitness blog).
2. Write out the exact action, dose, restrictions, source URL, and a `minSeconds` gate, in the
   same shape as the existing rows.
3. If the requested count for one category is unusually high (more than about 4), say so and
   confirm before spending sourcing/approval effort on it.
4. Source every extra movement across every requested category **first**, then present all of
   them together in the same single batched approval message as the interview readback — never a
   separate approval round per movement or per category.
5. On approval, append the row(s) to `library.tsv` via the same staged/validate flow as any other
   config change (this is a `routine.tsv`/`library.tsv` pairing, so route it through edit.md's
   routine-change flow — the new `optionId`(s) get referenced from the relevant `routine.tsv` row
   after the library row exists and passes `validate.ps1`'s library schema checks).

Never invent an exercise, imply treatment, or add a movement without showing its source and
getting explicit approval first.

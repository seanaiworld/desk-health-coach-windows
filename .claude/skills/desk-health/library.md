# library.md — movement catalog

## Default catalog (do not invent alternatives to these)

`desk-health/runtime/catalog-defaults.tsv` is the tracked, generic source for these vetted
defaults (it ships with the engine, is never per-user, and is never edited in place). setup.md
seeds each install's private `config/library.tsv` from it. Filter which defaults apply against
the user's stated movement limitations during setup/edit; never invent an exercise or silently
substitute a different one for an excluded category.

Each category ships with 3 defaults, so a rotation is available out of the box without any
per-install sourcing. Every row's `sourceURL` is a real, verified page — not paraphrased or
invented — and is preserved in `library.tsv`; show it if asked. `minSeconds` is a workflow
honesty gate (the dialog re-prompts if Done is clicked too fast), never a medical dose.

| optionId | type | dose | minSeconds | notes |
|---|---|---|---|---|
| distance-gaze-20s | eyes | 20 sec | 20 | look ~20 feet away |
| eye-palming | eyes | 30 sec | 30 | cup warmed palms over closed eyes |
| eye-near-far-focus | eyes | 3 reps | 20 | restrictions: not a substitute for care if a diagnosed vision condition |
| shoulder-rolls | neck-shoulders | 6 rolls | 15 | 3 forward, 3 back |
| neck-chin-tuck | neck-shoulders | 10 reps | 20 | draw head straight back |
| neck-side-stretch | neck-shoulders | 10 reps/side | 40 | restrictions: ease off if it worsens symptoms |
| hands-open-close | wrists-hands | 3 reps | 10 | fist open/close |
| wrist-side-bend | wrists-hands | 5-10 reps/dir | 45 | restrictions: stop if sharp pain |
| hook-full-fist | wrists-hands | 10 reps | 30 | restrictions: stop if sharp pain |
| seated-slouch-tall | lower-back | 3 reps | 15 | restrictions: omit for back pain/limits or uncertainty |
| standing-back-extension | lower-back | 3-5 reps | 30 | restrictions: stop if pain; standing must be allowed |
| cat-stretch | lower-back | 5 reps | 25 | restrictions: needs floor/kneeling space |
| stand-walk | standing | 60 sec | 60 | restrictions: standing/walking must be allowed |
| standing-wall-press | standing | 3x10 | 45 | restrictions: standing must be allowed |
| standing-thigh-stretch | standing | 20 sec x3/leg | 40 | restrictions: use desk/chair for balance; standing must be allowed |
| posture-self-check | posture | one check | 15 | shows one compact self-check list, still counts as one action per reminder |
| posture-chin-tuck | posture | 3x5s | 15 | seated, pull chin straight back |
| wall-posture-check | posture | one check | 15 | stand back against a wall to notice postural drift |

If a selected category has no compatible catalog item under the user's limitations, say so
directly rather than substituting something else.

## Adding a 4th+ rotation movement per category, or an outside-catalog movement

If Section 1 (the setup interview) or a later `add|change` request wants more than the 3 shipped
defaults for a category, or a movement outside this catalog entirely:

1. Find a reputable public-health, occupational-health, or clinical source (comparable in kind
   to the sources already in `library.tsv` — official health-agency, hospital, or standards-body
   guidance, not a general fitness blog).
2. Write out the exact action, dose, restrictions, source URL, and a `minSeconds` gate, in the
   same shape as the existing rows.
3. If the requested total for one category is unusually high (more than about 6, i.e. more than
   3 beyond the shipped defaults), say so and confirm before spending sourcing/approval effort on it.
4. Source every extra movement across every requested category **first**, then present all of
   them together in the same single batched approval message as the interview readback — never a
   separate approval round per movement or per category.
5. On approval, append the row(s) to `library.tsv` via the same staged/validate flow as any other
   config change (this is a `routine.tsv`/`library.tsv` pairing, so route it through edit.md's
   routine-change flow — the new `optionId`(s) get referenced from the relevant `routine.tsv` row
   after the library row exists and passes `validate.ps1`'s library schema checks).

Never invent an exercise, imply treatment, or add a movement without showing its source and
getting explicit approval first.

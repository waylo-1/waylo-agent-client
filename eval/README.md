# Waylo grounding eval set

## Why this exists

`PIPELINE_STATE.md` (repo root) shows that L0 (accessibility tree) and L1
(OCR) are the only screen-understanding layers with any on-device
confirmation of working — L2 (YOLO) and L3 (Gemini Vision) have never been
observed firing successfully in any log captured so far. Before trusting or
tuning any of these layers further (especially before wiring in a real
Gemini-grounding API key — see `GEMINI_GROUNDING_PLAN.md`), we need a fixed,
labeled set of (screenshot, target description, correct answer) cases we can
replay against any layer or model and get an objective pass/fail — instead
of relying on ad hoc on-device runs and reading logcat after the fact.

This eval set is **not** a replacement for on-device testing (real
device behavior — animations, transient overlays, IME timing — won't show
up in a static screenshot). It's for answering a narrower, cheaper
question: **given a screenshot and a `findDescription`, does a given
detector/model point at the right element?** That question is exactly what
L0/L1/L2/L3 (and any future Gemini-grounding call) all try to answer, so one
eval set can be replayed against all of them.

## What a "case" is

Each case is one screenshot plus one `findDescription` (the same field the
backend's `/plan` response sends per-step, see `CLAUDE.md`'s enriched
`/plan` schema) plus a human-verified correct answer for where that
description actually points on that specific screenshot.

## How to build real cases (this template ships with EXAMPLES only)

1. **Capture a screenshot** from a real device mid-guidance-session, at the
   exact moment a step is trying to locate its target (the dev tools sheet's
   manual controls, or a `ScreenCaptureManager` capture saved to disk, both
   work — screenshots are normally never persisted per `CLAUDE.md`'s
   "screenshots are never retained" rule, so capturing one for this eval set
   is a deliberate, one-off exception done manually, not something the app
   does automatically).
2. **Record the exact `findDescription`** (and `visualDescription`/
   `screenRegion`/`alternateLabels` if you want richer cases later) the
   backend actually sent for that step — pull it from the `STEP_START`
   `WAYLO_VERIFY` log line, or from the raw `/plan` response if you have it.
3. **Label the correct answer by hand**: open the screenshot, find the
   element a reasonable person would tap for that instruction, and record
   its visible label/text (`expected_label`) and a plain-English position
   hint (`expected_position_hint`, e.g. "top-right corner, circular avatar
   icon next to the search bar"). Do NOT reverse-engineer this from what
   `ElementFinder`/OCR/YOLO *returned* — the whole point is an independent
   ground truth to check them against. If you're not confident what the
   "correct" tap target is, don't add the case (or mark it in `notes` as
   ambiguous and exclude it from pass-rate scoring until resolved).
4. **Classify `category`** as one of exactly four values: `text` (a
   text-labeled button/list item, e.g. "History"), `icon` (an app icon or
   icon-only button with no visible text, e.g. a hamburger menu or a home-
   screen app icon), `nav` (a bottom nav bar / tab bar item), or `profile`
   (a profile picture / avatar — usually image-only, no text or
   contentDescription, historically the hardest category for L0/L1 per
   `looksLikeImageOnlyTarget`'s existence in `GuidanceEngine.kt`).
5. **Add a row** to `cases.csv` following `schema.json`'s field definitions.
   Keep `case_id` unique and stable (don't renumber existing cases when
   adding new ones — downstream eval-run history keys off `case_id`).
6. **Store the actual screenshot file** alongside this README under
   `eval/screenshots/<case_id>.png` (directory not created yet — create it
   when the first real screenshot is added; do not commit placeholder image
   files). Reference it from `screen_description` in words, since the CSV
   itself doesn't embed images.

## What "pass" means when replaying a case against a detector

A case passes for a given detector/model if the detector's returned
tap-point (or bounding box centroid) falls inside the actual on-screen
bounds of the element identified by `expected_label` — not merely "close in
pixels," since a coordinate can be numerically near the right element but
still be over the wrong (e.g. overlapping) view. When replaying against
`ElementFinder`/OCR (which return a matched node/text block, not just
coordinates), "pass" is simpler: does the matched node's own visible
text/contentDescription equal (or clearly refer to) `expected_label`?

## Current status

**Every row in `cases.csv` right now is a placeholder EXAMPLE**, derived
from the failure categories mentioned across `WAYLO_VERIFY_LOGGING.md`,
`WAYLO_FIX_STEPBUGS.md`, `WAYLO_RESCAN_FIX.md`, and `WAYLO_GUARD_FIX.md`
(profile avatar, app-open icons, the real "History" text case from
`PIPELINE_STATE.md`'s cited log evidence, hamburger/menu icons, bottom-nav
items) — **not** real labeled screenshots. `screen_description` describes
what the screenshot *would* show; there is no actual image file backing any
row yet. Each example row's `notes` field says `EXAMPLE — replace with a
real labeled screenshot` for exactly this reason. Do not use this data to
compute a real pass rate for anything — it exists to pin down the schema
and give a concrete starting shape, not as ground truth.

## Files

- `cases.csv` — the case table itself (schema below).
- `schema.json` — formal JSON Schema for one case row, for anyone building
  tooling around this later (a CSV→JSON loader, a validator, etc.). The CSV
  is the source of truth for now; this schema documents its shape.

## Schema (columns)

| Column | Type | Meaning |
|---|---|---|
| `case_id` | string | Stable, unique identifier (e.g. `yt-001`). Never renumber. |
| `app` | string | The app the screenshot is from (e.g. `YouTube`, `WhatsApp`) — matches `Plan.appName` where applicable. |
| `screen_description` | string | Plain-English description of what screen/state the screenshot shows, for a human skimming the CSV without opening the image. |
| `findDescription` | string | The exact (or realistic) backend-style find description for this step — same field/format as `Step.findDescription` in `PlanParser.kt`. |
| `expected_label` | string | The correct element's own visible text or contentDescription — the human-verified ground truth. |
| `expected_position_hint` | string | Plain-English location description (e.g. "bottom navigation bar, second icon from left") — used when `expected_label` alone is ambiguous (icon-only elements, duplicate text). |
| `category` | enum | One of `text`, `icon`, `nav`, `profile`. |
| `notes` | string | Anything relevant — known ambiguity, why this case was chosen, `EXAMPLE — replace with a real labeled screenshot` for placeholder rows. |

# Session summary — pipeline state + eval scaffolding

Autonomous, unattended session. Analysis and scaffolding only — no source
code was modified, no `gradle` builds were run, no network calls were made,
no git push, nothing EC2/backend/pm2-related was touched. Confirmed via
`git status` at the end of the session: the only new files are the four
deliverables below (plus the `eval/` folder); every `M` (modified) entry in
the working tree predates this session.

## What was produced

1. **`PIPELINE_STATE.md`** — a single table covering all four
   screen-understanding layers (L0 tree/`ElementFinder`, L1 OCR, L2 YOLO, L3
   Gemini Vision): what each does, its current confidence thresholds, and a
   conservative VERIFIED/UNVERIFIED judgment backed by exact log-line
   citations pulled from `fulllog2.txt`/`fulllog5.txt` (the only two log
   files in this repo that contain any `WAYLO_VERIFY`-tagged output).
   Headline findings:
   - **L0 (tree) and L1 (`ScreenAnalysisPipeline`'s own OCR pass) are
     VERIFIED** — real `TREE_SCAN`/`OCR_SCAN` → `DOT_PLACED` sequences
     exist in the logs (e.g. `fulllog5.txt:32452`→`:34290`, the "History"
     score=130 case).
   - **L2 (YOLO) and L3 (Gemini Vision) are UNVERIFIED** — zero `YOLO_CALL`
     or `VISION_CALL` lines anywhere in the repo's logs, in either
     direction (not "known broken," simply never observed firing).
   - **The most recent fix in the repo (`WAYLO_GUARD_FIX.md`'s wrong-app
     priority reorder) is itself unverified on-device** — its own tests
     pass, but every capture in this repo predates the fix, and
     `fulllog5.txt` in fact captures the *unfixed* 8-second block the fix
     was written to solve. This is flagged as the single most important
     thing to re-verify on the next real run.
2. **`eval/` folder** — `README.md` (methodology: how to capture a
   screenshot, record the real `findDescription`, hand-label ground truth
   independent of any detector's output, classify into one of exactly four
   categories, and what "pass" means when replaying a case), `schema.json`
   (formal JSON Schema for one case row), and `cases.csv` (15 example rows
   spanning `text`/`icon`/`nav`/`profile`, derived from the real failure
   categories named in the task and cross-referenced against
   `PIPELINE_STATE.md`'s cited evidence — every row's `notes` field is
   explicitly marked `EXAMPLE - replace with a real labeled screenshot`;
   none of these are backed by an actual saved image yet).
3. **`GEMINI_GROUNDING_PLAN.md`** — code-free plan for A/B testing a
   grounding-capable Gemini call against the current boolean-only Vision
   LOCATE call: what gets sent (reuses `eval/cases.csv`'s schema directly),
   per-category metrics (with `profile` flagged as the category with the
   most upside, since it's structurally the hardest for tree/OCR), a
   three-tier pass bar (worth investigating → worth trusting for placement,
   with real confidence-calibration required for the latter → worth using
   just for better spoken descriptions even without placement trust), and a
   shadow-mode-first rollout that reuses the existing `WAYLO_VERIFY` logging
   pattern rather than inventing a new one.
4. **This file.**

## Open questions

- **Does `fulllog5.txt` (or any capture) exist for a run *after*
  `WAYLO_GUARD_FIX.md`'s fix landed?** Not found in this repo. The fix's
  correctness currently rests entirely on 13 unit tests against a pure
  predicate, not a real device confirmation that `PLACEMENT_OVERRIDES_PACKAGE`
  actually fires and the History-style 8-second block is gone. This should
  be the first thing checked on the next on-device session.
- **Is L2 (YOLO) actually reachable at all right now?** `detect_log.txt`
  only shows "couldn't capture screen" warnings for Layer 2b, never a real
  network attempt/response either way. Worth confirming whether the YOLO
  service at `:8000` is even up/reachable from a real device before
  investing more in that layer, independent of any Gemini-grounding work.
- **Where would real eval screenshots actually get captured from?**
  `eval/README.md` proposes a manual, one-off capture (deliberately
  contradicting the app's normal "never persist screenshots" rule) — worth
  confirming that's an acceptable process before anyone starts labeling
  real cases, since it's a departure from `CLAUDE.md`'s stated privacy
  posture, even if scoped to a dev-only eval artifact never shipped with
  the app.
- **What would the actual backend endpoint for Gemini grounding look
  like?** `GEMINI_GROUNDING_PLAN.md` deliberately doesn't design this (out
  of scope, and the key lives on the backend per `CLAUDE.md`) — someone
  with backend access needs to decide whether it's a new endpoint, a new
  `mode` on the existing `/vision` endpoint, or something else, before the
  A/B plan can actually run.
- **What should the real floor+gap numbers be for a grounding layer, if it
  clears the placement-grade bar?** `GEMINI_GROUNDING_PLAN.md` deliberately
  leaves this open — it should come from calibration data on the real eval
  set, not be guessed here.

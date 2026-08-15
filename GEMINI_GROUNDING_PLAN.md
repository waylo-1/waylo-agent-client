# Plan: A/B test Gemini visual grounding vs the current Vision layer

Code-free. No live API calls made or written as part of this plan — this
describes what we'd build and measure once a Gemini API key/endpoint is
actually available to test against. Per `CLAUDE.md`'s coding rules, the
Gemini key lives only on the backend and the app never holds it, so any new
grounding capability would need a **new or extended backend endpoint**, not
a client-side key — that constraint shapes the plan below.

## Background: what the current Vision layer actually does today

Per `PIPELINE_STATE.md`, `GeminiVisionClient`'s LOCATE call (`POST /vision`,
`mode=locate`) is L3 in the pipeline, and — per a fix made earlier this
session — it **never places the dot directly**, regardless of what it
returns. It only returns a boolean `found` flag plus coordinates; a boolean
has no score or runner-up gap to check against the confidence floor every
other layer (tree/OCR/YOLO) uses, so treating `found=true` as sufficient to
place a dot would be placing it on a guess — exactly what this app has
spent several fix sessions eliminating. Today, `found=true` only triggers a
spoken description; L0/L1/L2 keep re-scanning independently until one of
*them* confirms the target with a real score.

This plan is about testing whether a **grounding-style** Gemini call —
returning an actual bounding box (or point) *with* a usable
confidence/quality signal — could either (a) replace today's boolean LOCATE
call with something that clears the same floor+gap bar every other layer
already meets, or (b) at minimum, produce a better *description* to speak
than today's LOCATE does, even if it never becomes a placement-grade layer.
Both are worth measuring; only (a) would change `GuidanceEngine`'s control
flow, and only after clearing a high bar (see "Pass bar" below).

## What we'd send

Reuse `eval/cases.csv`'s schema directly — it already captures exactly what
a grounding call needs and what current LOCATE calls already send per
`CLAUDE.md`'s `/vision` contract:

- The screenshot (base64 JPEG, matching `GeminiVisionClient`'s existing
  encoding).
- `findDescription` (required).
- `visualDescription`/`screenRegion`/`alternateLabels` when available
  (optional context, same fields the enriched `/plan` response already
  provides per step).
- Task/step context (`task`, `currentStepIndex`, `totalSteps`) — included
  today's LOCATE call already sends these; keep them for parity.

For the A/B specifically, each eval case gets sent to **both**:
1. **Baseline**: the current `/vision` LOCATE endpoint, unchanged.
2. **Candidate**: whatever new grounding-capable endpoint/prompt we're
   evaluating (a backend change, out of scope for this plan to design in
   code — just needs to exist before this A/B can run for real).

## What we'd measure, per category

Using `eval/cases.csv`'s four categories (`text`/`icon`/`nav`/`profile`),
since each stresses the pipeline differently:

| Category | What we specifically want to know |
|---|---|
| `text` | Does grounding at least match L0/L1's already-good performance here? Text is the category tree/OCR already handle well (see `PIPELINE_STATE.md`'s verified History case) — grounding shouldn't need to win here, just not regress if it ever became a fallback for this category too. |
| `icon` | Icons often have no text and inconsistent contentDescriptions across apps — this is where a vision model *might* meaningfully beat tree/OCR, since it can reason about visual shape ("three horizontal lines") the way a person would. |
| `nav` | Bottom nav bars pack multiple small, similar-looking targets close together — tests whether grounding can disambiguate position precisely, not just "somewhere near the bottom." |
| `profile` | The hardest category for every existing layer (`looksLikeImageOnlyTarget` exists in `GuidanceEngine.kt` specifically because tree/OCR structurally can't identify a pure image) — this is the category where grounding has the most room to add real value, and where failing gracefully (saying "not confident" rather than pointing at the wrong avatar) matters most. |

Per-category, per-case metrics:

- **Localization accuracy**: does the returned point/bbox centroid fall
  inside the true element's bounds, per `eval/README.md`'s "what pass
  means"? Binary per case, aggregated to a per-category pass rate.
- **Confidence calibration** (if the candidate returns a numeric
  score/quality signal at all): bucket cases by returned confidence and
  check whether higher-confidence buckets really do have higher pass rates.
  This is the single most important thing to establish before this could
  ever become a real, placement-grade layer — every other layer in this app
  has a calibrated score+gap; a grounding response with no meaningful
  correlation between "confidence" and "correctness" is not usable the same
  way, no matter how good its raw accuracy looks.
- **Agreement with baseline LOCATE**: does the candidate's `found`/not-found
  call agree with the existing boolean LOCATE call? On disagreements, the
  eval set's human-labeled ground truth is the tiebreaker, not whichever
  call "sounds more confident" — this is exactly why `eval/cases.csv`'s
  `expected_label`/`expected_position_hint` were labeled independently of
  any detector's output.
- **Latency**: p50/p90 response time. The existing Vision layer is already
  documented (`FallbackHandler.kt`) as "the slower, paid" tier tried last,
  after OCR and YOLO — a grounding call needs to be evaluated against that
  same "last resort, patience-window-limited" budget, not treated as
  free/instant.
- **Cost per call**: token/request cost, multiplied by expected call volume
  (only fires after L0+L1+L2 all miss *and* the patient window expires —
  see `PIPELINE_STATE.md`'s note that this has never once fired in any
  capture in this repo, meaning in practice L0/L1 resolve almost
  everything seen so far; cost projections should account for that low
  observed frequency rather than assuming every step reaches this layer).

## Pass bar

Proposed thresholds — conservative on purpose, matching this app's existing
"never place a dot on a guess" ethos (every existing layer requires *both*
an absolute floor *and* a gap over the runner-up before it's trusted to
place anything):

- **To be worth investigating further at all**: candidate must beat the
  current boolean LOCATE's effective "found the right thing" rate on the
  `profile` category by a clear margin (this is the category with the most
  headroom and the most user-safety upside — a wrong tap on an elderly
  user's screen from a mis-grounded profile picture is a worse outcome than
  saying "I'm not sure" and falling back to `speakTargetDescription`, which
  is exactly what happens today when nothing is confident).
- **To be worth wiring in as a real, placement-grade layer** (i.e., allowed
  to call `onTargetLocated()` the way L0/L1/L2 already can): candidate must
  (a) demonstrate real confidence calibration (see above — not just good
  raw accuracy), (b) clear a floor+gap bar analogous to the existing
  35/10 (tree) and 30/10 (OCR) — the *exact* numbers should come from
  calibration data on the real eval set, not be guessed in advance, but the
  *shape* of the bar (absolute floor **and** margin over the runner-up
  candidate, if the model can return more than one) should match every
  other layer in this codebase, not be a special case, and (c) not
  meaningfully regress the `text`/`nav` categories where L0/L1 already
  perform well.
- **To be worth using even without placement-grade trust**: candidate at
  minimum produces a *better spoken description* than today's LOCATE
  response when `found=true` — this is a much lower bar (no coordinate
  accuracy required, just "is this description clearer/more accurate than
  what we say today") and could ship independently of the placement
  question.

## Rollout approach (once the eval bar is cleared)

1. **Shadow mode first**: call the new endpoint alongside the existing
   fallback chain, log its result (`stepIndex`, category, agreement with
   what actually got placed/spoken), but never act on it. This reuses the
   same `WAYLO_VERIFY`-tagged logging pattern already established for every
   other layer (`VISION_CALL`, etc.) so shadow-mode data is directly
   comparable to the real pipeline's own logs, the same way this session's
   `PIPELINE_STATE.md` was built from real log evidence rather than
   assumption.
2. Only after shadow-mode data independently confirms the pass bar above
   (not just the offline eval set — real on-device shadow data, since that's
   the same "code-verified vs on-device-verified" distinction
   `PIPELINE_STATE.md` insists on) would this become an actual
   `onTargetLocated()`-capable layer, and only with its own confidence
   floor+gap check, never a bare boolean override.
3. If it only clears the lower "better description" bar, ship *that* much
   (replace/augment the description text used when `Described` fires) without
   touching placement logic at all — a strictly smaller, lower-risk change.

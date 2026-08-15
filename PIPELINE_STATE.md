# Screen-understanding pipeline: current state

Consolidated from `WAYLO_VERIFY_LOGGING.md`, `WAYLO_FIX_STEPBUGS.md`,
`WAYLO_SPEECH_CHANGES.md`, `WAYLO_RESCAN_FIX.md`, `WAYLO_GUARD_FIX.md`, plus
direct `grep` evidence from the log files in this repo (`fulllog.txt`,
`fulllog2.txt`, `fulllog4.txt`, `fulllog5.txt`, `detect_log.txt`, and the
older `run_log*`/`pacing_log*`/`dot_log.txt`/`crash_log.txt`/`waylo_log.txt`).
Verification methodology: a layer is **VERIFIED** only if a real log line
from an actual on-device run demonstrates it producing a result (cited
below, file:line, verbatim). Passing unit tests, compiling cleanly, or a
prior session's doc claim are **not** sufficient for VERIFIED — those get
**UNVERIFIED** unless independently confirmed by a log line here. Only 2 of
the 9+ log files in this repo (`fulllog2.txt`, `fulllog5.txt`) contain any
`WAYLO_VERIFY`-tagged lines at all — everything else predates that
instrumentation (added mid-day 2026-07-10) or never triggered it.

## Layer table

| Layer | What it does | Confidence gate | Status | Evidence |
|---|---|---|---|---|
| **L0 — ElementFinder (accessibility tree)** | Scores every node in the live a11y tree against `findDescription`/`alternateLabels`/`visualDescription` tokens (`ElementFinder.kt`). | `MIN_SCORE=30` (loose, gates the raw functions' own null-return); the *real* placement gate is `MatchResult.isConfident()`: `MIN_CONFIDENT_SCORE=35` **and** `MIN_CONFIDENCE_GAP=10` over the runner-up. | **VERIFIED** | `fulllog5.txt:32452` — `TREE_SCAN \| stepIndex=2 \| candidateCount=132 \| topScore=130 \| topText=History \| ... \| runnerUpScore=95 \| gap=35 \| confident=true \| failReason=passed` — followed by `fulllog5.txt:34290` — `DOT_PLACED \| stepIndex=2 \| x=135 \| y=624 \| sourceLayer=TREE \| score=130.0`. A second, independent instance: `fulllog5.txt:26056` (`TREE_SCAN stepIndex=0 topScore=185 gap=60 confident=true`) → `fulllog5.txt:26088` (`DOT_PLACED stepIndex=0 sourceLayer=TREE score=185.0`). |
| **L1 — OCR (ML Kit, `OcrAnalyzer.kt`)** | Runs on-device text recognition over a screenshot, scores detected text blocks against the same token set. Two separate call sites: `ScreenAnalysisPipeline`'s own L1 pass (tried when L0 misses), and a second, independent OCR pass inside `FallbackHandler`'s Layer 2 (tried again after the *whole* L0+L1 pipeline times out). | `MIN_MATCH_SCORE=30`, `MIN_MATCH_GAP=10` (added this session — previously no gap check existed). | **VERIFIED for `ScreenAnalysisPipeline`'s own L1 pass.** `FallbackHandler`'s separate Layer-2 OCR retry: **UNVERIFIED** (no evidence either way). | `fulllog5.txt:22270` — `OCR_SCAN \| stepIndex=0 \| blockCount=9 \| topScore=30 \| topMatchedText=youtube history \| runnerUpScore=0 \| gap=30 \| confident=true \| failReason=passed` → `fulllog5.txt:22294` — `DOT_PLACED \| stepIndex=0 \| x=332 \| y=1921 \| sourceLayer=OCR \| score=0.91741073`. **Caveat**: `DOT_PLACED`'s `score` field for an OCR-sourced result is `OcrElement.confidence` (ML Kit's own text-recognition confidence, a 0–1 float) — a *different number on a different scale* than the `OCR_SCAN` match score (30, on the ~0–100+ scale shared with L0). This is a pre-existing labeling quirk, not something this session introduced or fixed — flagging it here since it could mislead anyone reading `DOT_PLACED` logs as if `score` always meant "match score." |
| **L2 — YOLO object detector (`YoloDetectionClient.kt`, EC2 `:8000`)** | POSTs a screenshot to a YOLO detection service, takes the highest-confidence returned box. | `MIN_CONFIDENCE=0.5` (0–1 scale), `MIN_CONFIDENCE_GAP=0.1` (added this session — previously no gap check). | **UNVERIFIED — likely never actually contributing.** | Zero `YOLO_CALL` lines in any log file in this repo (`grep -rn "YOLO_CALL" *.txt fulllog*.txt` → no matches). `detect_log.txt:7983` and `:9902` show `W/WAYLO_DOT: Layer 2b: couldn't capture screen` — a screen-capture failure *upstream* of the network call, not evidence the YOLO service itself was ever successfully reached. `UNATTENDED_REPORT.md` (an earlier session) explicitly flagged the `/detect` request/response shape as an **"unverified... plausible guess"** for a generic FastAPI service, and a later session's code comment in `YoloDetectionClient.kt` claims the contract was "re-verified live against `GET /openapi.json`" — but that's a self-reported claim from a prior session's summary, not something re-confirmed in this pass, and even a correct wire *shape* says nothing about whether real detections are ever returned/used on-device (no `DOT_PLACED sourceLayer=YOLO_OR_OCR_RETRY` line exists anywhere either — see L3 row). |
| **L3 — Gemini Vision (`GeminiVisionClient.kt`, via backend `POST /vision`)** | LOCATE: "I expect X, where is it?" → per this session's earlier fix, **never places the dot directly** (a boolean `found` flag has no score/gap to check against the confidence floor) — only supplies a description to speak while L0/L1/L2 keep re-scanning. TROUBLESHOOT: "X is missing, what should the user do?" → recovery steps spliced into the plan. | No numeric confidence — boolean `found` (LOCATE) / `recoverable` (TROUBLESHOOT). Not applicable to the floor/gap system by design. | **UNVERIFIED.** | Zero `VISION_CALL` lines in any log file in this repo. `FallbackHandler`'s Layer 3a/3b are only reached after L1 OCR *and* L2 YOLO both miss *and* the full patient window (6s image-only / 30s normal) expires — in every capture in this repo where a target was eventually found, L0 or L1 succeeded well before that deadline (see L0/L1 evidence above), so Layer 3 was structurally never exercised. No confirmed successful *or* failed real `/vision` call observed anywhere. |

## Orchestration-layer fixes: verification status (not a "screen-understanding layer" but directly relevant to trusting the table above)

These aren't detection layers, but they gate whether L0–L3's results ever
reach the user, so their own verification status matters for anyone
designing an eval around this pipeline:

| Fix | Status | Evidence |
|---|---|---|
| `PERIODIC_RESCAN` (tighter 900ms poll, `WAYLO_RESCAN_FIX.md` BUG A) | **VERIFIED firing and detecting.** | `fulllog5.txt:32457` — `PERIODIC_RESCAN \| stepIndex=2 \| found=true \| topScore=130.0`, timestamped `17:50:36.012`, essentially simultaneous with the `TREE_SCAN` at `17:50:36.009` it triggered. |
| `WRONG_LOCATION_SUPPRESSED` / silent wrong-app handling (`WAYLO_SPEECH_CHANGES.md` Change 1) | **VERIFIED** — the guard fires silently as designed (no speech). | `fulllog5.txt:19340`–`:20993` and `:23222`+ — repeated `WRONG_LOCATION_SUPPRESSED \| stepIndex=0 \| confirmedScans=N` lines, no matching spoken-nudge log nearby. |
| `WRONG_LOCATION_SPOKEN` (debounced spoken nudge, `WAYLO_FIX_STEPBUGS.md` BUG 1 — since deleted entirely by the later Change 1) | **VERIFIED it fired (on an older build, before deletion).** | `fulllog2.txt:14900` — `WRONG_LOCATION_SPOKEN \| stepIndex=0 \| trigger=isInExpectedApp_confirmed_miss \| currentPackage=com.android.systemui \| expectedPackage=com.google.android.youtube \| confirmedScans=2`, timestamped `16:40:43.965` — this is itself confirmation of the exact bug `WAYLO_GUARD_FIX.md` later fixed (SystemUI misread as foreground). This log **predates** Change 1's deletion (`WAYLO_SPEECH_CHANGES.md` was written `16:54`, this capture is `16:40`), so it does not contradict the deletion — it's evidence for *why* the deletion and the later guard fix were both necessary. |
| **The wrong-app-guard *priority* fix itself** (`WAYLO_GUARD_FIX.md` — element confidence should override a package mismatch; `PLACEMENT_OVERRIDES_PACKAGE` / `TRANSIENT_PACKAGE_IGNORED` logging) | **UNVERIFIED ON-DEVICE.** Code compiles, unit tests pass (74/74 per the doc), but **no log file in this repo postdates the fix** (`WAYLO_GUARD_FIX.md` was written `18:17`; the newest capture, `fulllog5.txt`, is `17:50` — before the fix existed). `grep -rn "PLACEMENT_OVERRIDES_PACKAGE\|TRANSIENT_PACKAGE_IGNORED" *.txt fulllog*.txt` → **no matches anywhere.** | `fulllog5.txt` in fact captures the **unfixed** behavior: `TREE_SCAN` finds History confidently at `17:50:36.009` (score=130, gap=35) while `WRONG_LOCATION_SUPPRESSED`/`WRONG_LOCATION` fire repeatedly for `com.oplus.screenrecorder`/`com.android.systemui` from `17:50:35.017` through at least `17:50:43.185` (18+ consecutive suppressed scans visible), and the dot isn't placed until `17:50:44.396` (`DOT_PLACED stepIndex=2 ... score=130.0`) — an 8-second block, exactly as `WAYLO_GUARD_FIX.md` describes as the *problem*, not the *fix*. **This is the single most important gap for the next on-device run to close**: re-run the same History flow and confirm `PLACEMENT_OVERRIDES_PACKAGE` now fires near `17:50:36` instead of the dot waiting until `:44`. |
| Nudge throttle (`WAYLO_RESCAN_FIX.md` BUG B — `SPOKE_DESCRIPTION_SUPPRESSED`) | **UNVERIFIED ON-DEVICE.** | `grep -rn "SPOKE_DESCRIPTION_SUPPRESSED" *.txt fulllog*.txt` → no matches. No image-only target's repeated-nudge scenario was captured after this fix landed. |
| Step-numbering log fix (`WAYLO_FIX_STEPBUGS.md` BUG 2) | Not independently checkable from logs (it's a log-text-only change with no new tag) — code-verified via the 4 new unit tests only. | N/A — by design, nothing to grep for; the fix is that the *existing* `advanceFrom` log line reads unambiguously now. |

## Summary judgment

- **L0 (tree) and L1 (`ScreenAnalysisPipeline`'s own OCR pass) are the only
  layers with direct on-device confirmation of actually placing the dot.**
  Every `DOT_PLACED` line found in any log in this repo has
  `sourceLayer=TREE` or `sourceLayer=OCR` — never `YOLO_OR_OCR_RETRY`.
- **L2 (YOLO) and L3 (Gemini Vision) have zero on-device evidence in this
  repo**, in either direction — not "known broken," just never observed
  firing at all in any capture available here. Given L0/L1 evidently
  resolve every case seen in these logs before the patient window expires,
  it's plausible L2/L3 simply haven't been *exercised* yet, not that
  they're faulty — but that's a guess, not a finding, and should not be
  reported as either VERIFIED or KNOWN-BROKEN.
- **The most recent fix (`WAYLO_GUARD_FIX.md`, wrong-app-guard priority) is
  entirely unverified on-device** — it was written and tested *after* the
  last capture in this repo. Its correctness rests on 13 new unit tests
  against a pure predicate function, not a real run.

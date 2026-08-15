# WAYLO_VERIFY diagnostic logging

Logging-only instrumentation added across the screen-understanding pipeline so
step success/failure can be diagnosed from `logcat` alone. No thresholds,
scoring, or control flow were changed — every new `Log.d` call is either a
pure addition after a value was already computed, or a cosmetic
restructuring (e.g. `if/else` expression → named variables) that produces the
exact same return value as before. All lines use `Log.d` (debug level, never
`Log.e`/`Log.w`) under the single tag **`WAYLO_VERIFY`**, pipe-separated
`key=value` format, one line per event.

## How to view the logs

```
adb logcat -s WAYLO_VERIFY:D
```

To watch one event type only, e.g. wrong-location events for bug (a):

```
adb logcat -s WAYLO_VERIFY:D | grep "WRONG_LOCATION"
```

To follow a single step across every layer it touched (replace `2` with the
step index, 0-based):

```
adb logcat -s WAYLO_VERIFY:D | grep "stepIndex=2 "
```

To reconstruct one full step's story in order (start → scans → placement/
description → advance decision):

```
adb logcat -s WAYLO_VERIFY:D | grep -E "STEP_START \| stepIndex=2 |TREE_SCAN \| stepIndex=2 |OCR_SCAN \| stepIndex=2 |YOLO_CALL \| stepIndex=2 |VISION_CALL \| stepIndex=2 |DOT_PLACED \| stepIndex=2 |SPOKE_DESCRIPTION \| stepIndex=2 |ADVANCE_CHECK \| stepIndex=2 |REVALIDATE \| stepIndex=2 "
```

For the two active bugs specifically:

```
# (a) false "wrong location" firing on correct screens
adb logcat -s WAYLO_VERIFY:D | grep "WRONG_LOCATION"

# (b) wrong dot placement on in-app navigation steps
adb logcat -s WAYLO_VERIFY:D | grep -E "DOT_PLACED|STEP_START"
```

## Files touched

| File | What was added |
|---|---|
| `app/src/main/java/com/waylo/guidance/GuidanceEngine.kt` | `STEP_START`, `WRONG_LOCATION` (×2), `DOT_PLACED`, `ADVANCE_CHECK` (×8 call sites), `LOOKAHEAD_SKIP` (×2), `SPOKE_DESCRIPTION`, `REVALIDATE` (×4), `VISION_CALL` (×4). Also threads a `stepIndex` argument into its existing `ElementFinder`/`ScreenAnalysisPipeline`/`ElementFinder.findPartialMatch` calls so those layers can tag their own logs correctly. |
| `app/src/main/java/com/waylo/accessibility/ElementFinder.kt` | `TREE_SCAN` (one shared private `logTreeScan()` helper, called from `findElement`, `findOnHomeScreen`, `scorePartialMatch`). Added an additive `stepIndex: Int = -1` default parameter to `findElement`, `findOnHomeScreen`, `findPartialMatch`, `scorePartialMatch` — existing callers/tests are unaffected. |
| `app/src/main/java/com/waylo/ocr/OcrAnalyzer.kt` | `OCR_SCAN` (empty-elements early-return case, and the main scored-match case). Added an additive `stepIndex: Int = -1` parameter to `findBestMatch`. |
| `app/src/main/java/com/waylo/ocr/ScreenAnalysisPipeline.kt` | No new log lines — purely a pass-through: added `stepIndex: Int = -1` to `analyze`/`find`/`findAndShow` so `GuidanceEngine.locateOnDevice()` can thread its step index down into `ElementFinder.findElement` and `OcrAnalyzer.findBestMatch`. |
| `app/src/main/java/com/waylo/ai/YoloDetectionClient.kt` | `YOLO_CALL` (HTTP-failure case in `requestDetections`, exception case in `detectAndMatch`, and the success/scored case in the new `selectBest()`). Added an additive `stepIndex: Int = -1` parameter to `detectAndMatch`/`requestDetections`, and `stepIndex`/`httpStatus` defaulted parameters on `selectBest` (already `internal` and unit-tested; defaults keep the existing `YoloDetectionClientTest` calls compiling unchanged). |
| `app/src/main/java/com/waylo/guidance/FallbackHandler.kt` | No new log lines — passes the `stepIndex` it already receives in `handle()` into its `OcrAnalyzer.findBestMatch`/`YoloDetectionClient.detectAndMatch` calls so those layers' `OCR_SCAN`/`YOLO_CALL` logs are correctly tagged during the fallback chain too. |
| `app/src/test/java/com/waylo/accessibility/ElementFinderLookaheadTest.kt`, `.../ai/YoloDetectionClientTest.kt`, `.../ocr/OcrAnalyzerTest.kt` | Untouched — verified the new default parameters didn't require any test changes. |

No backend, EC2, or `.md`/config files outside this new summary were touched.
Nothing was pushed to remote.

## Every log point

### 1. `STEP_START` — `GuidanceEngine.kt:372`
Emitted once at the top of `executeStep()`, right after the step object is
resolved (before instruction is spoken).
```
STEP_START | stepIndex=<int> | elementType=<APP_ICON|NAVIGATION|TEXT_INPUT|...|null> | instruction=<first 60 chars> | findDescription=<first 80 chars>
```

### 2. `TREE_SCAN` — `ElementFinder.kt:123` (shared `logTreeScan()` helper)
Called from three places, each right after the candidate list is scored and
sorted, before the function's own (looser) accept/reject decision:
- `ElementFinder.findElement()` (called from `ScreenAnalysisPipeline`,
  `pollTextInput`, `checkTapInAppEvidence` ×2, `onTextChanged` ×2)
- `ElementFinder.findOnHomeScreen()` (step-0 home-screen search)
- `ElementFinder.scorePartialMatch()` (the lowered-search-scope, still
  full-confidence partial-match fallback)

`confident`/`failReason` are computed against the **real** placement gate
(`MIN_CONFIDENT_SCORE=35`, `MIN_CONFIDENCE_GAP=10`), independent of whichever
looser threshold (`MIN_SCORE=30`) the calling function itself uses for its
own null-return decision — so this always reflects why the dot would or
wouldn't actually be placed, not just why that one function returned null.
```
TREE_SCAN | stepIndex=<int> | candidateCount=<int> | topScore=<int> | topText=<80> | topContentDesc=<80> | topViewId=<str> | runnerUpScore=<int> | runnerUpText=<80> | gap=<int> | confident=<bool> | failReason=<no_candidates|below_floor|gap_too_small|passed> | top3=[(score=..,text=..,desc=..) x3]
```

### 3. `OCR_SCAN` — `OcrAnalyzer.kt:128` (empty case) and `:173` (main case)
Emitted from `findBestMatch()`, after scoring, using the real accept gate
(`MIN_MATCH_SCORE=30`, `MIN_MATCH_GAP=10`).
```
OCR_SCAN | stepIndex=<int> | blockCount=<int> | topScore=<int> | topMatchedText=<80> | runnerUpScore=<int> | gap=<int> | confident=<bool> | failReason=<no_candidates|below_floor|gap_too_small|passed>
```

### 4. `YOLO_CALL` — `YoloDetectionClient.kt:117` (exception), `:143` (success path, in `selectBest()`), `:201` (HTTP failure)
```
YOLO_CALL | stepIndex=<int> | httpStatus=<200|non-2xx|-1 for exception> | boxCount=<int> | topConfidence=<float> | runnerUpConfidence=<float> | gap=<float> | confident=<bool> | errorBody=<first 120 chars, empty on success>
```

### 5. `VISION_CALL` — `GuidanceEngine.kt:986,993,1013,1019` (in `tryVisionFallback()`)
One line per outcome of the whole Layer-2/2b/3 fallback chain
(`FallbackHandler.handle()`), using the same `FOUND`/`DESCRIBED`/`MISSED`
vocabulary as the existing `VisionOutcome` enum: `FOUND` = OCR/YOLO retry hit
a real score and placed the dot, or Troubleshoot spliced in recovery steps;
`DESCRIBED` = Gemini Vision LOCATE saw it but (per the earlier fix) never
places the dot from a bare found-flag; `MISSED` = nothing recovered.
```
VISION_CALL | stepIndex=<int> | outcome=<FOUND|DESCRIBED|MISSED> | descriptionReturned=<first 80 chars>
```

### 6. `WRONG_LOCATION` — `GuidanceEngine.kt:1097` (`onWindowStateChanged` AppLaunch mismatch) and `:1408` (`isInExpectedApp()` core check)
**The most important one for bug (a).** `:1408` fires every time the
continuous "are we on the right screen" guard (used by both `locateStep()`'s
search loop and `revalidatePlacement()`) detects a mismatch — this is the
guard that drives the "This isn't the right place" spoken nudge
(`handleWrongApp()`). `:1097` fires separately when a `TYPE_WINDOW_STATE_CHANGED`
event doesn't match what an `AppLaunch`-verified step (including the new
`NAVIGATION` step type) expected, so it doesn't advance — this is bug (b)'s
most likely log source for in-app navigation steps.
```
WRONG_LOCATION | stepIndex=<int> | currentPackage=<pkg> | expectedPackage=<pkg|null(launcher)> | whichCheckFailed=<isLauncherPackage|packageEquality|appLaunchVerification> | compared=(current=<pkg> vs expected=<pkg>[ fromLauncherOnly=<bool>])
```

### 7. `DOT_PLACED` — `GuidanceEngine.kt:809` (in `onTargetLocated()`, the single choke point that calls `OverlayManager.showDotAtResult`)
`sourceLayer` is best-effort-mapped from `PipelineResult.source`: `TREE` for
`"accessibility"/"home-screen"/"partial-match"`, `OCR` for `"ocr"`, and
`YOLO_OR_OCR_RETRY` for `"vision"` — that last tag is a pre-existing quirk in
`GuidanceEngine.tryVisionFallback()`: it labels **any** `FallbackHandler.Found`
result `"vision"` regardless of whether it actually came from the Layer-2 OCR
retry or the Layer-2b YOLO retry inside the fallback chain (Gemini Vision
LOCATE itself never reaches this function — it only ever returns
`Described`, logged separately via `VISION_CALL`). Cross-reference the
preceding `OCR_SCAN`/`YOLO_CALL` line for the same `stepIndex` to tell which
one it really was.
```
DOT_PLACED | stepIndex=<int> | x=<int> | y=<int> | sourceLayer=<TREE|OCR|YOLO_OR_OCR_RETRY> | score=<float>
```

### 8. `ADVANCE_CHECK` — 8 call sites in `GuidanceEngine.kt` (lines 935, 1090, 1152, 1195, 1204, 1215, 1249, 1268)
One per verification-decision branch, covering all three `Verification`
strategies:
- `935` — `pollTextInput()` polling tick (`TextInput`)
- `1090` — `onWindowStateChanged()` (`AppLaunch`, incl. `NAVIGATION` steps)
- `1152` — `checkTapInAppEvidence()` clicked-node match (`TapInApp`)
- `1195` — `checkTapInAppEvidence()` next-target-appeared / target-gone+click (`TapInApp`)
- `1204` — `checkTapInAppEvidence()` ambiguous (`TapInApp`)
- `1215` — `checkTapInAppEvidence()` target still present, no change (`TapInApp`)
- `1249`, `1268` — `onTextChanged()` direct-node and re-resolved paths (`TextInput`)
```
ADVANCE_CHECK | stepIndex=<int> | elementType=<str|null> | verified=<bool> | reason=<free-text>
```

### 9. `LOOKAHEAD_SKIP` — `GuidanceEngine.kt:625` (first sighting, pending) and `:638` (confirmed, commits the skip)
In `checkLookaheadSkip()`. `confirmedScans=1` = seen once, not yet acted on
(debounce); `confirmedScans=2` = seen on two consecutive scans, skip commits.
```
LOOKAHEAD_SKIP | fromStep=<int> | toStep=<int> | matchScore=<int> | confirmedScans=<1|2>
```

### 10. `SPOKE_DESCRIPTION` — `GuidanceEngine.kt:1054` (in `speakTargetDescription()`)
`whichFieldUsed` names the primary content field actually spoken (the real
precedence order is `visionDescription` (Gemini Vision's own phrasing, only
present when called from the `Described` vision outcome) → `visualDescription`
→ `findDescription`); `screenRegionUsed`/`fallbackHintUsed` report the two
additive modifier fields separately since either can be appended regardless
of which primary field won.
```
SPOKE_DESCRIPTION | stepIndex=<int> | whichFieldUsed=<visionDescription|visualDescription|findDescription> | screenRegionUsed=<bool> | fallbackHintUsed=<bool>
```

### (bonus, not separately numbered in the request) `REVALIDATE` — `GuidanceEngine.kt:847,875,895,899`
In `revalidatePlacement()`, the 4-second (`REVALIDATE_INTERVAL_MS`) recheck
loop for an already-placed dot.
```
REVALIDATE | stepIndex=<int> | stillValid=<bool> | newTopScore=<float> | reason=<wrong_app|no_longer_confirmable|moved_dot|no_change>
```

## Verification

`./gradlew testDebugUnitTest` — all 47 existing tests pass (0 failures, 0
errors) after the change, including the three files whose functions gained
new default parameters (`ElementFinderLookaheadTest`, `YoloDetectionClientTest`,
`OcrAnalyzerTest`). `./gradlew compileDebugKotlin compileDebugUnitTestKotlin`
also succeeds.

## Known gaps

- `YoloDetectionClient.detectAndMatch()`'s outer `withTimeoutOrNull(TIMEOUT_MS)`
  means a genuine 3-second timeout cancels the coroutine before any log line
  can run — a timed-out YOLO call produces no `YOLO_CALL` line at all (only
  HTTP failures, exceptions, and successful responses do). Absence of a
  `YOLO_CALL` line for a step where YOLO should have run is itself a signal
  of a timeout.
- `DOT_PLACED`'s `sourceLayer=YOLO_OR_OCR_RETRY` is ambiguous by design (see
  point 7 above) — a pre-existing quirk in how `GuidanceEngine` labels
  `FallbackHandler` hits, not something this change altered.

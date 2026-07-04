# Waylo (Android)

Waylo is an accessibility-overlay app that walks an elderly/non-technical user
through a task on their phone ("how do I make a story on Instagram?") one step
at a time: it speaks an instruction, places a red dot on the screen element to
tap, and advances automatically when it detects the user has acted. The app is
Kotlin, single-module (`app/`), min SDK 26 / target SDK 34.

The user asks for a task in plain English (typed, voice input is currently a
stub — see "Known stubs" below). Waylo sends the task to a backend, which
calls Gemini to produce a step-by-step plan, then Waylo finds each step's
target element on screen and shows the dot.

## Detection pipeline (L0 → L3)

Four layers, tried in order, each one only running if the previous one didn't
find a confident match:

1. **L0 — accessibility tree.** `ElementFinder.kt`
   (`com.waylo.accessibility`) scores every node in the live
   `AccessibilityNodeInfo` tree against the step's `findDescription` (plus
   `alternateLabels`, and a `targetPackage` bonus when the backend resolved
   one). Instant, fully on-device, no screenshot needed.
2. **L1 — ML Kit OCR.** `OcrAnalyzer.kt` (`com.waylo.ocr`) runs on-device text
   recognition over a screenshot and scores detected text blocks the same way
   (exact/partial/per-token, plus `visualDescription` words and
   `alternateLabels` folded into the token pool).
3. **L2 — YOLO object detector on EC2.** `YoloDetectionClient.kt`
   (`com.waylo.ai`) POSTs the screenshot to a YOLO detection service on the
   same EC2 host as the backend (port 8000), gets back labeled bounding
   boxes, and scores them with the same exact/partial/token/alternate-label
   shape. Feature-flagged via `YoloDetectionClient.YOLO_LAYER_ENABLED`; a 3s
   timeout and any failure fall through silently to L3.
   **The `/detect` path and request/response JSON shape are an unverified
   best guess** — confirm against the actual FastAPI service before relying
   on this layer. See `UNATTENDED_REPORT.md` for what was assumed.
4. **L3 — Gemini Vision, via the backend.** `GeminiVisionClient.kt`
   (`com.waylo.ai`) sends the screenshot to the backend's `/vision` endpoint
   for a `locate` call ("I expect X, where is it?"); if that also misses, a
   `troubleshoot` call asks Gemini what to do and can splice recovery steps
   into the remaining plan.

**Note on in-code "Layer N" naming:** the source comments don't use this L0–L3
numbering verbatim. `ScreenAnalysisPipeline.kt` (which runs L0 and L1 for
every step) calls them "Layer 1" and "Layer 2"; its own "Layer 3" comment is
dead — Gemini Vision is never called from that file. The real L2/L3 escalation
happens in `FallbackHandler.kt` (invoked by `GuidanceEngine` only when
`ScreenAnalysisPipeline` returns `"failed"`), which calls OCR again ("Layer
2", redundant with L1), then YOLO ("Layer 2b"), then Gemini Vision LOCATE/
TROUBLESHOOT ("Layer 3a"/"Layer 3b"). If you're tracing a failure, the L0–L3
description above is the conceptual model; the in-code comments are the
literal call graph.

## Backend

Single deployed instance, no staging/prod split:

- **Base URL:** `http://13.127.137.249:3000` (plain HTTP — the app has
  `android:usesCleartextTraffic="true"` for this reason)
- **`POST /plan`** — `{"task": "...", "language": "en"}` → the enriched plan
  (see schema below). Called from `GeminiClient.kt`, retried up to 3x on
  non-2xx/exception with a 2s delay between attempts.
- **`POST /vision`** — `{"mode": "locate"|"troubleshoot", "screenshotBase64":
  "...", "task", "currentStepIndex", "totalSteps", "findDescription",
  "language"}` → coordinates or recovery steps. Called from
  `GeminiVisionClient.kt`.
- **YOLO detector (unverified):** `http://13.127.137.249:8000`, assumed
  `POST /detect` — see the L2 note above.

The Gemini API key lives only on the backend; the app never holds it.

### Enriched `/plan` response schema

```json
{
  "success": true,
  "appPackage": "com.google.android.youtube",
  "appName": "YouTube",
  "language": "en",
  "totalSteps": 4,
  "steps": [
    {
      "stepNumber": 1,
      "instruction": "Open YouTube app",
      "findDescription": "youtube app icon",
      "elementType": "APP_ICON",
      "screenRegion": "center",
      "visualDescription": "red play button icon",
      "alternateLabels": [],
      "fallbackHint": "scroll down and tap",
      "parentContainer": "home screen"
    }
  ]
}
```

Parsed by `PlanParser.parse()` into `Plan` (`appPackage`, `appName`, `steps`,
plus `error`/`errorDetail` when `success: false`) and `Step` (`index`,
`instruction`, `findDescription`, `elementType`, `screenRegion`,
`visualDescription`, `alternateLabels`, `fallbackHint`, `parentContainer`).
Every enriched field is nullable/defaulted so an older cached plan without
them still parses instead of crashing. `GeminiClient.getPlan()` is the only
caller of `PlanParser.parse()` — don't reimplement plan parsing elsewhere.

On backend failure (`success: false`, or a thrown exception with no
response), `GuidanceEngine` classifies the error into a short, elderly-
friendly spoken+Toast message (`friendlyErrorMessage()` in
`GuidanceEngine.kt`) while logging the full technical error/detail to
Logcat — never show the raw backend error text to the user.

## Key files

| File | Role |
|---|---|
| `guidance/GuidanceEngine.kt` | Main orchestrator — walks the step list, owns session state (`steps`, `currentIndex`, `isRunning`, `currentAppPackage`), auto-advances on window-change events. |
| `guidance/FallbackHandler.kt` | L2/L2b/L3 escalation chain, invoked when the primary L0+L1 pipeline misses. |
| `ocr/ScreenAnalysisPipeline.kt` | Runs L0 (`ElementFinder`) then L1 (`OcrAnalyzer`) for a single step. |
| `accessibility/ElementFinder.kt` | L0 scoring over the accessibility tree. |
| `accessibility/WayloAccessibilityService.kt` | The accessibility service; forwards window-change events to `GuidanceEngine`. |
| `ocr/OcrAnalyzer.kt` | L1 on-device OCR + scoring. |
| `ai/YoloDetectionClient.kt` | L2 EC2 YOLO detector client + scoring. |
| `ai/GeminiVisionClient.kt` | L3 Gemini Vision (locate/troubleshoot) client. |
| `ai/GeminiClient.kt` | `/plan` client with retry logic. |
| `ai/PlanParser.kt` | `Step`/`Plan` data models + the one true JSON parser for `/plan` responses. |
| `service/WayloGuidanceService.kt` | Foreground service owning the overlay dot and `Speaker`; guidance survives leaving the app. |
| `overlay/OverlayManager.kt` | Places/moves the red dot overlay window. |
| `voice/Speaker.kt` | TTS wrapper (fully implemented — see stubs below for what isn't). |
| `screenshot/ScreenCaptureManager.kt` | MediaProjection screen capture, used by OCR/YOLO/Gemini Vision. |
| `ui/MainActivity.kt` | Task entry point; checks overlay/accessibility/screen-capture permissions before starting guidance. |
| `ui/DeveloperToolsSheet.kt` | Hidden dev menu (5 taps on the logo) with manual test controls for each layer. |

## Known stubs (not implemented — don't assume otherwise)

- **`voice/MicHandler.kt`** — voice input for task entry / mid-flow Q&A. Both methods are empty `// TODO`.
- **`sharing/GuideRepository.kt`** — `POST /guide` / `GET /guide/:id` for shareable guides. Both methods return `null`/`emptyList()`.
- **`sharing/DeepLinkHandler.kt`** — parsing incoming `https://waylo.app/guide/<id>` links. Returns `null`.
- **`guidance/StepExecutor.kt`** — dead code, superseded by `GuidanceEngine.executeStep()`; not called from anywhere.

`voice/Speaker.kt` (TTS output) is fully implemented, unlike the above.

## Coding rules for this project

- **Coroutines:** network/IO work (backend calls, screen capture, OCR, file
  encode) runs on `Dispatchers.IO`; UI/overlay/TTS updates run on
  `Dispatchers.Main` via `withContext`. `GuidanceEngine` owns a single
  `CoroutineScope(Dispatchers.Main + SupervisorJob())` — don't create ad hoc
  scopes elsewhere in the guidance flow.
- **No API keys in the app.** The Gemini key lives only on the backend. If a
  new vision/AI capability needs a key, add a backend endpoint — don't embed
  a key client-side.
- **Screenshots are never retained.** Every `Bitmap` captured for OCR/YOLO/
  Gemini Vision is recycled (`bitmap.recycle()`) in a `finally` block
  immediately after use, and never written to disk or cached. Follow this
  pattern for any new vision layer.
- **Elderly-friendly UX copy.** User-facing text (TTS + Toast) must be short,
  calm, and free of technical jargon or raw error text — see
  `GuidanceEngine.friendlyErrorMessage()` for the pattern: classify the
  failure, then pick from a small set of plain phrases. Full technical detail
  always goes to Logcat instead, never to the user.
- **Debug-only builds.** There is no `signingConfigs` block and no keystore in
  the repo — only `assembleDebug` is meaningful here; `assembleRelease` would
  produce an unsigned APK.
- **Gradle wrapper is not always present.** It's normal `.gitignore`-tracked
  boilerplate, but was missing from `main` at one point and had to be
  regenerated (`gradle wrapper --gradle-version 8.12 --distribution-type
  all`). `local.properties` (`sdk.dir=...`) is gitignored and must be created
  per machine.
- **Other remote branches** (`week2-integration`,
  `feature/enriched-detection-failure-flagging`) contain more advanced,
  unmerged versions of the detection pipeline (icon classifiers, semantic
  matchers, a macOS companion app). `main` does not include any of that —
  don't assume symbols from those branches exist here without checking.

# CLAUDE.md — Waylo project context

This file gives Claude Code complete context on the Waylo codebase. Read it before making changes.

> Note on accuracy: this file reflects the **actual code** as of this writing. Two in-repo docs are partially stale — `waylo-macos/README.md` still says "Gemini Vision" (the code uses **Amazon Nova** + dual-model **YOLO**), and the files in `backend_initial/sql/*.sql` describe an older **Supabase** schema (the live code targets **AWS RDS/Aurora Postgres + pgvector** with a different column layout). Trust the code, not those two docs. Details under "Known discrepancies".

---

## 1. What Waylo is

Waylo is **AI-powered, on-screen guidance for any app**. A user asks a question in plain language (typed or spoken) — "how do I bold text in Word?", "how do I empty the Trash?", "WhatsApp profile photo kaise badlein?". Waylo:

1. Generates an ordered **step plan** (each step describes a UI element to interact with).
2. For each step, **finds the exact element on the user's real screen**.
3. Draws a **pulsing dot** over it, **speaks** the instruction, and **auto-advances** when the user acts.
4. **Self-heals** when the screen doesn't look as expected.

It works on top of apps Waylo has never seen — no per-app integration. Target users are people who find computers intimidating (elderly, first-time users), so the UX is simple, spoken, and forgiving.

**Core design principle — fastest/cheapest/most-private layer first.** Each client tries instant, free, fully on-device detection before any network call. The paid cloud-vision call is a last resort. Every paid call is captured to make future local detection smarter and cheaper (caches + training data). Screenshots are **in-memory only, never written to disk**.

---

## 2. Three components, one contract

| Component | Tech | Location |
|---|---|---|
| Android app | Kotlin, Gradle, minSdk 26 / target 34 | `app/` |
| macOS app | Swift, AppKit + SwiftUI, Xcode, macOS 13+ | `waylo-macos/` |
| Backend | Node 18+/Express on AWS Bedrock + RDS/Aurora Postgres (pgvector) | `backend_initial/` |
| YOLO microservice | Python, FastAPI, Ultralytics YOLO | `backend_initial/yolo-service/` |

The shared contract is a **step plan**: a list of steps, each carrying an element description plus rich metadata. The backend `/plan` route branches on `platform: "macos"` vs the Android (mobile) shape.

---

## 3. Repository layout

```
waylo/
├── app/                              # Android app (Kotlin)
│   └── src/main/java/com/waylo/
│       ├── accessibility/            # WayloAccessibilityService (reads UI tree), ElementFinder (L0 scoring)
│       ├── ai/                       # GeminiClient (/plan), GeminiVisionClient (/vision), PlanParser
│       ├── guidance/                 # GuidanceEngine (orchestrator), SemanticMatcher, FallbackHandler,
│       │                             #   StepMetadata, DemoTasks, DetectionFailure, FailureLogger
│       ├── ml/                       # YOLOv8Detector (on-device TFLite, optional/no-op if asset missing)
│       ├── ocr/                      # ScreenAnalysisPipeline (L0→L1→L2 orchestration), OcrAnalyzer (ML Kit)
│       ├── overlay/                  # OverlayManager, DotView (pulsing dot)
│       ├── permissions/              # PermissionManager
│       ├── screenshot/               # ScreenCaptureManager (MediaProjection, in-memory)
│       ├── service/                  # WayloGuidanceService (foreground mediaProjection service)
│       ├── sharing/                  # GuideRepository, DeepLinkHandler
│       ├── ui/                       # MainActivity, OnboardingActivity, sheets, adapters, onboarding/
│       └── voice/                    # Speaker (TTS), MicHandler (STT)
│   └── src/main/assets/              # guides.json, ui_labels.txt, README_ui_detector.md (ui_detector.tflite bundled separately)
│
├── waylo-macos/WayloMac/             # macOS app (Swift)
│   ├── WayloMacApp.swift             # @main, menu-bar-only app
│   ├── AppDelegate.swift             # lifecycle, status item, permissions, hotkey registration
│   ├── accessibility/                # AccessibilityReader (AX tree), ElementFinder (scoring), TargetAppTracker
│   ├── ai/                           # WayloAPIClient (all HTTP), AppConfig (backend URL), PlanParser
│   ├── detection/                    # CoordinateResolver (pipeline orchestrator), LocalVisionDetector (OCR),
│   │                                 #   YOLODetector (L2.5), NovaVisionFallback (L3), ScreenCapturer,
│   │                                 #   ScreenRegion(+Helper), CoordinateResolver
│   ├── guidance/                     # GuidanceEngine (orchestrator), TaskHistory
│   ├── conversation/                 # ConversationEngine (mid-guide Q&A), QuestionClassifier
│   ├── voice/                        # Speaker (AVSpeech), MicHandler (SFSpeech), VoiceCommandEngine
│   ├── input/                        # HotkeyManager (CGEventTap global hotkeys)
│   ├── overlay/                      # OverlayWindow(+Controller), DotView, ScreenCoordinates (Cocoa↔AX)
│   ├── ui/                           # OnboardingView(+Controller), HomePanel/ (notch panel)
│   ├── permissions/                  # ScreenRecordingPermission
│   ├── debug/                        # DebugLogger, DebugOverlay*, CoordinateTests
│   └── models/                       # Step, GuidePlan, StepAction, StepTargetType, ScreenRegion
│
└── backend_initial/                  # Node/Express backend
    ├── index.js                      # server + all routes
    ├── bedrock.js                    # AWS Bedrock Converse: plan gen, desktop plan gen, vision, Q&A, recover
    ├── embeddings.js                 # Titan Text Embeddings v2 (1536-dim)
    ├── db.js                         # pg Pool (DATABASE_URL → RDS/Aurora)
    ├── planCache.js                  # in-process exact-task cache (Map, 7-day TTL) — Android
    ├── semanticPlanCache.js          # pgvector semantic plan cache (paraphrase match) — macOS
    ├── stepLabelCache.js             # pgvector step-label cache (skip vision next time)
    ├── demoPlans.js                  # hardcoded deterministic demo plans (macOS)
    ├── langdetect.js                 # Unicode-script language detection (10 Indian langs + en)
    ├── supabase.js                   # legacy (superseded by db.js; see discrepancies)
    ├── routes/                       # vision.js, vision-fallback.js, yolo-detect.js, failure.js
    ├── sql/                          # SCHEMA DOCS — STALE (Supabase era); see discrepancies
    └── yolo-service/                 # Python FastAPI dual-model YOLO microservice (main.py)
```

Build/output dirs to ignore: `app/build/`, `build/`, `.gradle/`, `backend_initial/node_modules/`, `waylo-macos/WayloMac.xcodeproj/` internals.

---

## 4. The shared step contract

**macOS `Step`** (`waylo-macos/WayloMac/models/Step.swift`):
- `index`, `instruction` (spoken/shown), `action` (`click`/`type`/`key`/`info`), `key` (for key actions).
- `targetLabel` — exact visible text to find (`""` for icon-only targets).
- `elementDescription` / `findDescription` — natural-language hints for AX/vision.
- `screenRegion` — `menuBar`/`ribbon`/`dialog`/`sidebar`/`spreadsheet`/`statusBar`/`fullScreen`.
- `targetType` — `text` (AX + OCR) vs `icon` (AX-by-desc + YOLO + Nova). **Routes which detectors run.**
- `controlKind` — `button`/`menuItem`/`checkbox`/`tab`/`link`/`field`/`""`. Lets detection prefer a real control over plain text.
- `anchorText` + `anchorPosition` (`below`/`above`/`left`/`right`/`near`) — disambiguate short/repeated labels.
- `labelCacheKey` — stable key (`elementDescription + targetLabel + action`) for the step-label cache; built identically on lookup and store paths so embeddings line up.
- `GuidePlan.demo == true` → plan is **locked**: mid-run corrections may relabel/re-point a step but never replan.

**Android `StepMetadata`** (`app/.../guidance/StepMetadata.kt`): enriched 8-field format — `instruction`, `findDescription`, `elementType` (enum: BUTTON, ICON_BUTTON, FAB, TEXT_INPUT, NAV_ITEM, TOGGLE, APP_ICON, LIST_ITEM, IMAGE, TAB, OVERFLOW_MENU, BACK_BUTTON, OTHER), `screenRegion` (top/top_center/bottom/bottom_right/center/left/right/full), `visualDescription`, `alternateLabels[]`, `fallbackHint`, `parentContainer`. Plus server-enriched `appPackage` and per-step `targetPackage`/`doneWhen`.

---

## 5. macOS app (the primary focus)

Menu-bar-only (`NSApp.setActivationPolicy(.accessory)`, no Dock icon). A notch panel is the UI. **App Sandbox is DISABLED on purpose** — a sandboxed app can't call `AXUIElementCreateApplication` on other processes or install a global event tap (same reason Alfred/Raycast aren't sandboxed). Hardened Runtime is on for future notarization.

Permissions: **Accessibility** (mandatory, read other apps' AX tree + event tap), **Screen Recording** (vision/OCR, requested up front), **Microphone + Speech** (voice, requested up front).

### 5.1 The element-finding pipeline — `detection/CoordinateResolver.swift`
This is the heart of the macOS app. It returns a point in **AX-global coordinates** (top-left origin from the primary display) that the overlay uses. It branches on `targetType` and `controlKind`:

- **Plain text target (not a real control):** OCR **first** (visual ground truth), then AX.
- **Real control (button/menuItem/…):** AX **first** (role/anchor pick the actual control over header text), OCR as fallback.
- **Icon target:** skip OCR; AX-by-description → YOLO (L2.5) → Nova (L3).

Layer order and where each lives:

| Layer | Technique | File | Cost | Notes |
|---|---|---|---|---|
| L1 (OCR) | **Apple Vision** `VNRecognizeTextRequest` (.accurate, no autocorrect) | `LocalVisionDetector.swift` | ~80ms, free, private | Recall-biased fuzzy word-set score; **threshold 0.8**. Can crop to `screenRegion`. Returns AX-global point. |
| L0 (AX) | **Accessibility tree** scoring | `AccessibilityReader.swift` + `ElementFinder.swift` | free, pixel-exact | Walks AX tree of the **target** app (not Waylo). Scores by title/desc/role/anchor. Min score 40; **40–55 = low confidence → returns nil** so OCR can win. |
| Label cache | prior working label → try AX only | `WayloAPIClient.lookupLabel` → `/label/lookup` | 1 DB call | A hit lets us skip the paid vision call. |
| L2.5 (YOLO) | **Dual-model** OmniParser + Screen2AX | `YOLODetector.swift` → `/detect-elements` → Python service | ~paid/compute | **Icon targets only.** Returns 0–1 normalized boxes; Swift scores by AX-class match + confidence + region. |
| L3 (Nova) | **Amazon Nova 2 Lite** object detection | `NovaVisionFallback.swift` → `/nova-vision` | paid, last resort | Returns bbox on **0–1000 normalized** scale (resolution-independent). On success: **caches the working label** (so next run resolves via AX) **and logs a YOLO training example** to a local JSONL. |

`ScreenCapturer.swift` uses **ScreenCaptureKit**, captures the display under the cursor, **excludes Waylo's own windows**, downscales to base64 JPEG (max 1280px, quality 0.6) for uploads.

### 5.2 Accessibility tree details — `AccessibilityReader.swift`
- The macOS equivalent of Android's AccessibilityService. Recursively walks `AXUIElement` tree (max depth 14) of the **target app** (tracked by `TargetAppTracker`, not Waylo itself).
- Interactive roles surfaced include `AXButton`, `AXMenuItem`, `AXTextField`, `AXCheckBox`, `AXTab`, `AXLink`, `AXMenuBarItem`, and **short** `AXStaticText`/`AXRow` (AX-hostile apps like System Settings expose sidebar items as static text in rows). Skips window chrome (close/min/zoom traffic lights).
- Can also read **system UI** processes (`com.apple.dock`, `controlcenter`, `systemuiserver`) for Dock icons / menu-bar extras, which never appear in the frontmost app's tree.
- Helpers: `targetHasScrollArea()` (gates scroll-assist), `targetFocusedWindowFrame()` (validate dialog-region hits).

`ElementFinder.swift` scoring: strips stop words → keywords; exact title/desc match +120; whole-word title hit +35 (beats substring so "file" ≠ "profile"); full-coverage bonus +40; role boosts; `controlKind` preference (matching role +45, penalize static text/rows −30 when a real control is wanted); small-control size bonus; **anchor** bonus (prefer elements in the requested direction near a known label, fading with distance). Rejects off-screen/zero-size.

### 5.3 Orchestration — `guidance/GuidanceEngine.swift` (`@MainActor` singleton)
- Walks steps. Speaks each instruction. `click` steps → locate + show dot; `type`/`key`/`info` → banner + advance on commit.
- Detects keyboard-shortcut steps mis-emitted as clicks ("Press Command+Space") and reroutes to a `.key`/`.info` step; advances on the exact combo (incl. system combos like ⌘Space via an observe-only key tap).
- On dot shown, installs a **global click monitor**: a real `leftMouseDown` within ~60pt of the dot = completion → next step.
- **Retry once after 800ms** if all layers miss (apps mid-animation have stale AX/screenshots). `locateToken` guards stale async work.
- **Self-healing** when all layers miss: (1) **scroll assist** — if the app has a scroll area, show a bouncing arrow and poll AX+OCR (local-only, ~18s, flips direction halfway); (2) **recovery** via `/recover` — relabel (retry resolver + cache), replan (splice new steps from current index), or scroll-direction hint; (3) **manual** — ask user to do it and advance on any click.
- On complete, records to `TaskHistory` (user can ✓ to cache the plan as correct via `/plan/learn`, ✗ to forget via `/plan/forget`).

### 5.4 Audio / voice — `voice/` + `conversation/`
- `Speaker.swift` — `AVSpeechSynthesizer` TTS, en-US, rate 0.45 (slower for clarity). Every step is spoken.
- `MicHandler.swift` — `SFSpeechRecognizer` STT. Needs **both** Speech auth and Microphone (TCC). Reports partial results; 6s capture window then finalizes.
- `VoiceCommandEngine.swift` (⌃⌥⌘V) — no guide running → spoken phrase becomes a **new task**; guide running → phrase is a **correction/follow-up** sent to `/recover` with a fresh screenshot. Local fast-path for "next"/"go back"/"repeat".
- `ConversationEngine.swift` (⌃⌥⌘A) — mid-guide voice Q&A. `QuestionClassifier` (pure local, no API) sorts into: **navigation** (control the guide), **concept** ("what is a VLOOKUP?" → `/qa` spoken text), or **location** ("where is X?" → run resolver + drop dot).
- Screen Q&A (⌃⌥⌘Q) — free-form question answered from a screenshot via `/ask-screen`; speaks/shows answer, no dot.

### 5.5 Global hotkeys — `input/HotkeyManager.swift`
Uses a **CGEventTap** (session level), not `NSEvent` global monitors, so combos fire in any app (incl. Waylo) and are **consumed** (no clashes). All use **⌃⌥⌘**. Registered in `AppDelegate.registerHotkeys()`:

| Combo | Key | Action |
|---|---|---|
| ⌃⌥⌘V | 9 | voice command (new task / correction) |
| ⌃⌥⌘N | 45 | re-detect current step (fresh screenshot → Nova recovery) |
| ⌃⌥⌘A | 0 | ask a question by voice |
| ⌃⌥⌘Q | 12 | ask about what's on screen (vision Q&A) |
| ⌃⌥⌘W | 13 | toggle notch panel |
| ⌃⌥⌘D | 2 | toggle debug overlay |
| ⌃⌥⌘T | 17 | coordinate self-test |

`addKeyObserver` is an **observe-only** matcher (does NOT consume) so e.g. ⌘Space still opens Spotlight while advancing a guide step.

### 5.6 Coordinates — `overlay/ScreenCoordinates.swift`
Cocoa is bottom-left origin; AX is top-left origin from the primary display. All conversions are centralized here. The overlay is a transparent, always-on-top, click-through window (`OverlayWindow`); `DotView` is the SwiftUI pulsing red dot. Multi-monitor handled via the captured screen's frame.

### 5.7 Backend URL — `ai/AppConfig.swift`
Never hardcoded. Resolved: `WAYLO_BACKEND_URL` env → `WayloBackendURL` in Info.plist → `http://localhost:3000`.

---

## 6. Android app

Kotlin, minSdk 26 / target 34, ViewBinding. Onboarding is the launcher activity (enables AccessibilityService + overlay permission). Guidance runs at **process scope** (singleton `GuidanceEngine`), so it survives the user leaving the Waylo app.

Permissions (`AndroidManifest.xml`): `SYSTEM_ALERT_WINDOW` (overlay dot), `BIND_ACCESSIBILITY_SERVICE` (read UI tree), `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PROJECTION` (screen capture), `RECORD_AUDIO` (voice), `INTERNET`, `POST_NOTIFICATIONS`.

### Pipeline — `ocr/ScreenAnalysisPipeline.kt` (per-step, wrapped in a 4s timeout in `GuidanceEngine`)
- **L0 — accessibility tree** (`accessibility/ElementFinder.kt` + `guidance/SemanticMatcher.kt`): scores every node on the live tree. `SemanticMatcher.scoreNode` → 0..100 (text 0–40, element type 0–30, screen region 0–20, parent container 0–10); acceptance threshold **70**. Big **target-package bonus (+60/+50)** so the real app's node (e.g. `com.google.android.youtube`) outscores look-alikes (Play Store listing). Step 1 uses `findOnHomeScreen` (launcher packages only).
- **L1 — ML Kit OCR** (`ocr/OcrAnalyzer.kt`): on-device text recognition (Latin + Devanagari) on a downscaled in-memory screenshot; scored via `SemanticMatcher.scoreText` (threshold 60).
- **L2 — on-device YOLOv8-nano** (`ml/YOLOv8Detector.kt`, TFLite): icon-only/custom elements. **No-ops gracefully if `assets/ui_detector.tflite` is absent.**
- **L3 — cloud vision fallback** (`guidance/FallbackHandler.kt` → `GeminiVisionClient` → `/vision`): two modes — `locate` (return x,y of a missing element) and `troubleshoot` (analyze a wrong-looking screen → recovery steps spliced into the live plan from the current index). If everything misses, a fallback dot is still placed so the user always has feedback.

### Other Android pieces
- `accessibility/WayloAccessibilityService.kt` — reads the UI tree of any app; on `TYPE_WINDOW_STATE_CHANGED` calls `GuidanceEngine.onWindowChanged()`.
- **Auto-advance:** after a step shows, an `ADVANCE_GUARD_MS = 1200ms` dwell prevents premature advance; a foreground window change after that = the user acted → advance after a 500ms settle.
- `overlay/OverlayManager.kt` + `DotView.kt` — always-on-top pulsing dot that glides between targets.
- `screenshot/ScreenCaptureManager.kt` — MediaProjection, in-memory only; bitmaps recycled immediately after OCR/vision.
- `service/WayloGuidanceService.kt` — `mediaProjection` foreground service hosting capture; owns `Speaker`.
- `ai/GeminiClient.kt` (`/plan`), `ai/GeminiVisionClient.kt` (`/vision`), `ai/PlanParser.kt` (tolerant JSON → `StepMetadata`).
- `data/` — Room DB for on-device plan cache; `PlanRepository.getPlan()` resolves **prebuilt guides → Room cache → backend**.
- `voice/` — `Speaker` (TTS), `MicHandler` (STT).
- `sharing/` — save/retrieve shareable guides; deep links.

> Naming note: the Android classes are named `GeminiClient`/`GeminiVisionClient` for historical reasons, but they call the shared Waylo backend (Bedrock/Claude/Nova), not Google Gemini.

---

## 7. Backend — `backend_initial/`

Node/Express. `npm run dev` (watch) or `npm start`. CORS on; `express.json({ limit: '12mb' })` for base64 screenshots; rate limit on `/plan` (20/min/IP).

### 7.1 Models (AWS Bedrock, Converse API) — `bedrock.js`
- **Plan generation:** Android enriched plans use **Nova Micro** (`BEDROCK_PLAN_MODEL_ID`, default `us.amazon.nova-micro-v1:0`, ~23× cheaper than Nova Pro). macOS desktop plans use the main `BEDROCK_MODEL_ID` (Claude) via `generateDesktopSteps` with a detailed prompt (finish the whole task, prefer Dock/menu bar/Spotlight/shortcuts, current macOS names, exact complete labels, mark icon targets).
- **Vision grounding:** `/nova-vision` → `detectObject` uses **Amazon Nova 2 Lite** object detection (0–1000 bbox).
- **Android vision:** `/vision` → Claude vision, `locate` | `troubleshoot` modes (`routes/vision.js`).
- **macOS legacy vision:** `/vision-fallback` → Claude vision returns corrected element + pixel point (`routes/vision-fallback.js`).
- **Q&A:** `/qa` → `answerConcept` (text, no vision); `/ask-screen` → `answerWithScreen` (vision answer from screenshot).
- **Recovery:** `/recover` → `recoverDesktopStep` (relabel / replan / scroll hint).
- **Embeddings:** `embeddings.js` → **Amazon Titan Text Embeddings v2** (1536-dim) for the semantic caches.
- App-package enrichment: `KNOWN_PACKAGES` map resolves app names → Android package names deterministically server-side.
- Language: `langdetect.js` detects 10 Indian languages + English by Unicode script (Marathi vs Hindi by wordlist). Instructions are localized; `findDescription` stays English.

### 7.2 Caching — three layers (huge cost/latency win)
1. **In-process exact-task cache** (`planCache.js`): dependency-free `Map`, SHA-256 task key, **7-day TTL**, 5000-entry cap. Android exact repeats cost $0. Swappable for Redis.
2. **Semantic plan cache** (`semanticPlanCache.js`, macOS): Postgres + pgvector + Titan embeddings. Paraphrases ("freeze the top row" ≈ "lock the first row") hit the same plan via `match_plan_cache` RPC at **cosine threshold 0.92**. `PLAN_PROMPT_VERSION` (currently `v8`) is folded into the `platform` filter so bumping the prompt invalidates all old rows. `learnPlan` (remember a corrected plan, delete near-dupes) / `forgetPlan` (delete a wrong plan).
3. **Step-label cache** (`stepLabelCache.js`): when Nova/recovery finds the real visible label, store it (embedded, keyed by step description). Future runs look it up (`match_step_label_cache`, threshold **0.93**) and resolve via the local AX tree — skipping vision entirely.
4. **Guides table**: `/guide` saves a shareable guide (8-char id) + returns a link; `/guide/:id` retrieves it (open counter).
5. **Demo plans** (`demoPlans.js`): hardcoded, deterministic, planner-free — used for demo videos so a known task always produces the exact same vetted steps.

### 7.3 Database — `db.js`
Single `pg.Pool` from `DATABASE_URL` (AWS RDS/Aurora Postgres, `ssl: { rejectUnauthorized: false }`), created once and reused across warm instances. Tables: `plan_cache`, `step_label_cache`, `guides`, `detection_failures`. pgvector for the two semantic caches.

**Runtime schema expected by the JS (source of truth):**
- `plan_cache(id, task TEXT, platform TEXT, steps_json TEXT, embedding vector(1536))` — RPC `match_plan_cache(query_embedding vector, threshold float, count int, platform_filter text)` filtering platform by exact equality.
- `step_label_cache(id BIGSERIAL, step_description TEXT, label TEXT, embedding vector(1536), created_at)` — RPC `match_step_label_cache(query_embedding vector, threshold float, count int)` (no app_name column).
- `guides(id, task, steps_json, opens)`.

### 7.4 Dual-model YOLO microservice — `yolo-service/main.py` (FastAPI)
- Loads **two** models once at startup, runs them **in parallel** per request (latency = max, not sum):
  - **OmniParser** (`microsoft/OmniParser-v2.0` `icon_detect/model.pt`) — general icon/element detection.
  - **Screen2AX** (`macpaw-research/yolov11l-ui-elements-detection`) — UI elements **with AX class names** (AXButton, AXLink, AXTextArea…).
- Merges boxes with **IoU dedup**: Screen2AX has priority (carries AX classes); OmniParser boxes added only if not overlapping a Screen2AX box by >40%. Returns 0–1 normalized boxes.
- Reached via Node proxy `routes/yolo-detect.js` (`POST /detect-elements` → `${YOLO_SERVICE_URL}/detect`, 5s timeout). Deployed as a **separate** Railway service.

### 7.5 Endpoints
| Method | Route | Purpose |
|---|---|---|
| GET | `/health` | health check |
| POST | `/plan` | generate steps (branches on `platform: "macos"`; demo → semantic cache → generate) |
| POST | `/vision` | Android vision: `locate` \| `troubleshoot` |
| POST | `/vision-fallback` | macOS legacy Claude vision (corrected element + pixel point) |
| POST | `/nova-vision` | macOS L3 grounding (Nova 2 Lite, 0–1000 bbox) |
| POST | `/detect-elements` | proxy → Python dual-YOLO microservice |
| POST | `/recover` | self-healing: relabel / replan / scroll |
| POST | `/qa` | concept Q&A (text) |
| POST | `/ask-screen` | vision Q&A from a screenshot |
| POST | `/label/lookup`, `/label/store` | step-label cache |
| POST | `/plan/learn`, `/plan/forget` | remember / forget a corrected plan |
| POST | `/failure` | log detection misses for future training |
| POST | `/guide`, GET `/guide/:id` | save / retrieve shareable guide |

### 7.6 Environment variables
`DATABASE_URL`; `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_REGION`; `BEDROCK_MODEL_ID`, `BEDROCK_PLAN_MODEL_ID`, `BEDROCK_VISION_MODEL_ID`, `BEDROCK_EMBED_MODEL_ID`; `YOLO_SERVICE_URL`; `PORT`; `WAYLO_DEBUG=1` (log full vision prompts/responses).

---

## 8. The self-improving loop (important mental model)

Cheap/local/private first → paid Nova last, and **every paid call funds future free detection**:
- Nova success → **step-label cache** (next run resolves via AX, no vision) + **semantic plan cache** (paraphrases reuse the plan).
- Nova success → appends a labelled **YOLO training example** (local JSONL on macOS; `/failure` + `detection_failures` table on Android) for future fine-tuning of the on-device/L2.5 models.
- User feedback → `/plan/learn` (remember corrected plan) and `/plan/forget` (drop wrong plan), so the system improves with no prompt edit or redeploy.

It always degrades gracefully (scroll assist → recovery replanning → "do it yourself and press Next"), so the user is never stuck.

---

## 9. Build & run

**Backend:**
```bash
cd backend_initial
npm install
cp .env.example .env   # fill in AWS Bedrock + DATABASE_URL + YOLO_SERVICE_URL
npm run dev            # watch mode (or npm start)
```

**YOLO microservice:** see `yolo-service/` (`requirements.txt`, `download_weights.sh`, `Procfile`, `nixpacks.toml`); deploy separately, set `YOLO_SERVICE_URL` on the Node service.

**Android:**
```bash
./gradlew :app:assembleDebug        # from repo root
```
Or open in Android Studio. Point at the backend, complete onboarding (enable AccessibilityService + overlay).

**macOS:**
```bash
cd waylo-macos
open WayloMac.xcodeproj
# or: xcodebuild -project WayloMac.xcodeproj -scheme WayloMac -configuration Debug build
```
Grant Accessibility in System Settings. Uses an Xcode "synchronized" file group — files added under `WayloMac/` are auto-included.

> Long-running commands (`npm run dev`, dev servers, watchers) must be run manually in a terminal, not via a blocking one-shot command.

---

## 10. Conventions & gotchas

- **Privacy:** never write screenshots to disk; recycle/clear after analysis; never log screenshot bytes (`/vision-fallback` explicitly avoids it).
- **Coordinates:** macOS pipeline returns **AX-global** points; Nova/YOLO/OCR all convert to AX-global via the captured screen's frame for multi-monitor correctness. Don't introduce crop-relative bugs (always add the crop origin back — see `LocalVisionDetector`).
- **Layer ordering matters and is `targetType`/`controlKind`-dependent** — don't reorder casually. Text→OCR-first, control→AX-first, icon→YOLO/Nova.
- **Thresholds:** macOS OCR 0.8; macOS AX min 40 / confident 55; Android AX(semantic) 70 / Android OCR 60 / target-package bonus 60; semantic plan cache 0.92; step-label cache 0.93. These are tuned — change deliberately.
- **`labelCacheKey` must stay identical on lookup and store** or the embedding match breaks.
- **`PLAN_PROMPT_VERSION`** — bump it (in `semanticPlanCache.js`) whenever the planner prompt changes meaningfully, to invalidate stale cached plans.
- **Demo plans are locked** (`GuidePlan.demo`) — corrections relabel only, never replan.
- macOS hotkeys go through `HotkeyManager` (CGEventTap), not `NSEvent` monitors.

---

## 11. Known discrepancies (stale docs — trust the code)

1. **`waylo-macos/README.md`** says "Gemini Vision" and describes a simple 3-layer (AX → vision → manual) model. The shipped code uses **Amazon Nova 2 Lite** for grounding (`NovaVisionFallback`/`/nova-vision`) plus a **dual-model YOLO** L2.5 layer, with OCR-first/AX-first branching. (`/vision-fallback` still exists and is Claude-based, but the live macOS pipeline uses `/nova-vision` + `/detect-elements`.)
2. **`backend_initial/sql/*.sql`** describe an older **Supabase** schema (columns `app_name`, `task_text`, `task_embedding`, `step_plan jsonb`; 4-arg RPCs with `app_name_filter`). The **live JS** (`db.js`, `semanticPlanCache.js`, `stepLabelCache.js`) targets **AWS RDS/Aurora Postgres** with a different schema (`task`/`platform`/`steps_json`/`embedding`; `step_description`/`label`; RPCs filter by `platform` or take no app filter). `supabase.js` and the `@supabase/supabase-js` dependency are leftovers from that migration. **The JS is the runtime source of truth.**
3. Android `ai/Gemini*` class names are historical — they call the shared Bedrock-backed Waylo backend, not Google Gemini.
4. The macOS `CoordinateResolver` header comment lists layers in a slightly different fixed order than the code executes; the real flow branches on `targetType`/`controlKind` (described in §5.1).
5. macOS training-data dir/log uses the legacy name "Sahayak" (`Application Support/Sahayak/yolo_training_log.jsonl`) — the project's prior name.

---

## 12. One-paragraph summary

Waylo points a talking dot at the exact next thing to tap, in any app, on Android and macOS, driven by a shared Bedrock-backed backend. The hard part — "where is this described element on the real screen right now?" — is solved by a layered, self-healing pipeline that goes cheapest/most-private first (accessibility tree + Apple Vision OCR on macOS; AX tree + ML Kit OCR on Android), then dual-model YOLO for icons, then Amazon Nova as a paid last resort — and every paid call is harvested into caches (semantic plan cache + step-label cache on Aurora/pgvector) and YOLO training data so future detection is free. It's fully voice-driven both directions (TTS out; STT for new tasks, corrections, and mid-session concept/location/screen Q&A), localized into 10 Indian languages + English, and never dead-ends the user.

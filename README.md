<div align="center">

# Waylo

**AI-powered, on-screen guidance for any app — point, speak, and walk through any task one tap at a time.**

Waylo overlays a pulsing dot on the exact element you need to tap next, speaks each step aloud, and adapts in real time when the screen doesn't look the way it expected. It exists to make smartphones and computers usable for people who find them intimidating — elderly users, first-time users, and anyone who just wants to be shown, not told.

[Android App](#-android-app) · [macOS App](#-macos-app) · [Backend](#-backend) · [Architecture](#-system-architecture) · [Getting Started](#-getting-started)

</div>

---

## Table of Contents

- [What Waylo Does](#what-waylo-does)
- [System Architecture](#-system-architecture)
- [The Element-Finding Pipeline](#-the-element-finding-pipeline-the-core-idea)
- [Android App](#-android-app)
- [macOS App](#-macos-app)
- [Backend](#-backend)
- [Repository Layout](#-repository-layout)
- [Getting Started](#-getting-started)
- [Configuration](#-configuration)
- [Privacy & Security](#-privacy--security)
- [Roadmap](#-roadmap)

---

## What Waylo Does

You ask a question in plain language — typed or spoken — like *"How do I change my WhatsApp profile photo?"* or *"How do I bold text in Word?"*. Waylo then:

1. **Generates a plan.** An LLM on the backend turns your question into an ordered list of concrete steps, each with a precise description of the UI element you need to interact with.
2. **Finds the element on your real screen.** Using accessibility APIs (and a vision fallback when needed), Waylo locates the actual button, icon, or field on whatever app is in front of you.
3. **Shows you where to tap.** A pulsing dot is drawn directly over the target element, with a short label, and the step is spoken aloud.
4. **Advances automatically.** When you act and the screen changes, Waylo detects it and glides to the next step. If it can't find something, it asks you to tap it and keeps going.

The result is a guided, click-by-click walkthrough that works **on top of apps Waylo has never seen before** — no per-app integration required.

---

## 🏗 System Architecture

Waylo is three cooperating components that share one contract: a **step plan** and an **element description** per step.

```
┌──────────────────────┐         ┌──────────────────────┐
│   Android App         │         │     macOS App         │
│   (Kotlin)            │         │     (Swift / AppKit)  │
│                       │         │                       │
│  AccessibilityService │         │  AXUIElement reader   │
│  Overlay dot + TTS    │         │  Overlay dot + TTS    │
│  On-device finding    │         │  On-device finding    │
└───────────┬───────────┘         └───────────┬───────────┘
            │                                  │
            │      POST /plan, /vision,        │
            │      /vision-fallback, /guide     │
            └───────────────┬──────────────────┘
                            ▼
                ┌───────────────────────────┐
                │     Backend (Node/Express)  │
                │                             │
                │  LLM step generation        │
                │   (AWS Bedrock / Claude)    │
                │  Vision locate + troubleshoot│
                │  Language detection (10 IN) │
                │  Guide persistence (Supabase)│
                └───────────────────────────┘
```

**Design principle: fastest layer first.** Each client tries cheap, instant, fully on-device methods before reaching for the network or a vision model. The expensive cloud vision call is a last resort, not the default path. This keeps guidance responsive and private, and keeps cloud costs low.

---

## 🔍 The Element-Finding Pipeline (the core idea)

The hardest problem Waylo solves is: *given the description "the red YouTube icon with a white play button", where exactly is it on this user's screen right now?* Both clients answer this with a layered fallback chain, fastest and most private first.

### Android pipeline

| Layer | Technique | Where | Budget |
|------:|-----------|-------|--------|
| **L0** | Accessibility tree scoring via `SemanticMatcher` (threshold 70, `appPackage` bonus +60) | `ElementFinder.kt`, `SemanticMatcher.kt` | ~300ms |
| **L1** | ML Kit on-device text recognition (Latin + Devanagari) on a downscaled screenshot | `OcrAnalyzer.kt` | ~800ms |
| **L2a** | Vision `locate` via backend `/vision` | `GeminiVisionClient.kt` | ~15s |
| **L2b** | Vision `troubleshoot` → recovery steps spliced into the live plan | `GeminiVisionClient.kt` | ~20s |

> The whole pipeline is wrapped in a 4s timeout per step (`GuidanceEngine.kt`); if every on-device layer misses, the vision fallback runs, and if that also fails the dot is still placed at a sensible position so the user always has feedback.

### macOS pipeline

| Layer | Technique | Where |
|------:|-----------|-------|
| **L1** | `AXUIElement` tree search with scoring | `AccessibilityReader.swift` + `ElementFinder.swift` |
| **L2** | In-memory screenshot → backend `/vision-fallback` (vision model returns a pixel point) | `FallbackHandler.swift` |
| **L3** | Manual — user clicks the element and guidance continues | `GuidanceEngine.swift` |

### How scoring works

The element description from the backend is often a full sentence. The finder strips punctuation and filler/stop words (`the`, `button`, `icon`, `screen`, …) down to meaningful tokens, then scores **every node on screen** across multiple signals:

- Exact / partial match on `contentDescription`, visible `text`, and resource id
- Affordance bonuses (`clickable`, `visible`)
- **Target-package bonus** — a node belonging to the app the plan targets gets a large boost, so the real YouTube icon outscores a look-alike in the Play Store
- Launcher-class hints for home-screen app icons
- Cumulative per-word presence across all fields

The highest-scoring node that clears the confidence threshold wins; otherwise the pipeline falls through to the next layer.

### Self-healing guidance

When even vision can't locate the target, the backend's **troubleshoot** mode inspects the screenshot, decides whether the situation is recoverable, and returns a fresh set of recovery steps. The client keeps the already-completed steps, splices the recovery steps into the plan from the current index, and re-runs — so a wrong turn doesn't dead-end the user.

---

## 📱 Android App

A Kotlin app (minSdk 26, targetSdk 34) that guides users through any Android app using an `AccessibilityService` and a system overlay.

### Key components

| Area | File(s) | Responsibility |
|------|---------|----------------|
| **Orchestration** | `guidance/GuidanceEngine.kt` | Process-level singleton that walks the plan step by step, speaks each instruction, places the dot, and auto-advances on window changes. Survives the user leaving the Waylo app. |
| **Element finding** | `accessibility/ElementFinder.kt`, `guidance/SemanticMatcher.kt` | Scoring-based search over the live accessibility tree. |
| **Screen pipeline** | `ocr/ScreenAnalysisPipeline.kt`, `ocr/OcrAnalyzer.kt` | Layers L0→L1→L2 orchestration; ML Kit OCR on downscaled screenshots. |
| **Accessibility** | `accessibility/WayloAccessibilityService.kt` | Reads the UI tree of the frontmost app; notifies the engine on window changes. |
| **Overlay** | `overlay/OverlayManager.kt`, `overlay/DotView.kt` | Always-on-top pulsing dot with a short label; glides between targets. |
| **Screen capture** | `screenshot/ScreenCaptureManager.kt` | MediaProjection capture, used only in memory for OCR/vision; bitmaps recycled immediately. |
| **AI** | `ai/GeminiClient.kt`, `ai/GeminiVisionClient.kt`, `ai/PlanParser.kt` | Backend `/plan` and `/vision` calls; tolerant JSON parsing into enriched step metadata. |
| **Voice** | `voice/Speaker.kt`, `voice/MicHandler.kt` | Text-to-speech for each step; speech-to-text for spoken tasks. |
| **Foreground service** | `service/WayloGuidanceService.kt` | Hosts screen capture during guidance (`mediaProjection` foreground service). |
| **Sharing** | `sharing/GuideRepository.kt`, `sharing/DeepLinkHandler.kt` | Save/retrieve shareable guides via the backend; deep-link into a saved guide. |
| **UI / onboarding** | `ui/…`, `ui/onboarding/…` | Permission onboarding, main task entry, recent tasks, developer tools. |

### Permissions required

- `SYSTEM_ALERT_WINDOW` — draw the dot over other apps
- `BIND_ACCESSIBILITY_SERVICE` — read the on-screen UI tree
- `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PROJECTION` — screen capture during guidance
- `RECORD_AUDIO` — voice input
- `INTERNET` — backend calls
- `POST_NOTIFICATIONS` — foreground-service notification

Onboarding is the launcher activity and walks the user through enabling the accessibility service and overlay permission before any guidance can start.

### Auto-advance logic

After a step is shown, a guard window (`ADVANCE_GUARD_MS = 1200ms`) prevents premature advancement. Once the user acts and the foreground window changes, `onWindowChanged()` treats it as completion and moves to the next step after a short settle delay, so the same dot view glides smoothly to the next target.

---

## 💻 macOS App

The desktop companion (`waylo-macos/`) — Swift + AppKit/SwiftUI — brings the same experience to any Mac app via the Accessibility API.

- **Menu-bar only** (no Dock icon). Toggle the floating task panel from the menu-bar icon or **⌘⇧W**.
- Reads the `AXUIElement` tree of the frontmost app, draws a pulsing red dot over the target element, and speaks each step.
- Uses the **shared backend** (`platform: "macos"` branch of `/plan`) with a vision fallback via `/vision-fallback`.

### Key components

| Area | File(s) |
|------|---------|
| App lifecycle / menu bar / hotkey | `WayloMacApp.swift`, `AppDelegate.swift` |
| AX tree reading | `accessibility/AccessibilityReader.swift` |
| Element scoring | `accessibility/ElementFinder.swift` |
| Overlay window (transparent, always-on-top, click-through) | `overlay/OverlayWindow.swift`, `overlay/OverlayWindowController.swift`, `overlay/DotView.swift` |
| Cocoa↔AX coordinate conversion | `overlay/ScreenCoordinates.swift` |
| Orchestration | `guidance/GuidanceEngine.swift` |
| Vision fallback | `guidance/FallbackHandler.swift` |
| Backend client + config + parsing | `ai/WayloAPIClient.swift`, `ai/AppConfig.swift`, `ai/PlanParser.swift` |
| Voice | `voice/Speaker.swift` (`AVSpeechSynthesizer`), `voice/MicHandler.swift` (`SFSpeechRecognizer`) |
| Permissions / onboarding | `permissions/ScreenRecordingPermission.swift`, `ui/OnboardingView.swift` |

### Click detection

macOS guidance waits for a real click. A global event monitor checks whether a `leftMouseDown` lands within an 80pt tolerance of the target frame; a matching click hides the dot and advances after a short delay. If the element couldn't be located automatically, Waylo asks the user to click it and advances on any click.

### Requirements & sandboxing

- macOS 13.0+, Xcode 16+
- **App Sandbox is disabled** — a sandboxed app cannot call `AXUIElementCreateApplication` on other processes or install global event monitors (the same reason Alfred and Raycast aren't sandboxed). Hardened Runtime is enabled for future notarization.
- **Accessibility** permission is required; **Screen Recording** (vision fallback) and **Microphone** (voice) are requested on demand.

---

## 🌐 Backend

A Node.js / Express server (`backend_initial/`) shared by both clients.

### Responsibilities

- **Step generation** — turns a natural-language task into an ordered, enriched step plan using **AWS Bedrock (Claude)**. Each step is enriched with the target app's package name so the on-device finder can prefer the real app.
- **Vision** — `POST /vision` (Android) and `POST /vision-fallback` (macOS): a vision model `locate`s a missing element on a screenshot or `troubleshoot`s a wrong-looking screen into recovery steps.
- **Multilingual** — detects and responds in 10 Indian languages plus English (Hindi, Tamil, Telugu, Bengali, Marathi, Gujarati, Kannada, Malayalam, Punjabi, English).
- **Persistence** — `/guide` saves shareable guides to **Supabase** with a 30-day expiry; `/guide/:id` retrieves them.
- **Hardening** — CORS enabled, rate limiting on `/plan` (20 req/min/IP), 12mb body limit for Base64 screenshots.

### Endpoints

| Method | Route | Purpose |
|--------|-------|---------|
| `GET` | `/health` | Health check |
| `POST` | `/plan` | Generate steps (branches on `platform: "macos"`) |
| `POST` | `/vision` | Android vision: `locate` \| `troubleshoot` |
| `POST` | `/vision-fallback` | macOS desktop screenshot analysis |
| `POST` | `/failure` | Log detection misses (for future model training) |
| `POST` | `/guide` | Save a guide, return a shareable link |
| `GET` | `/guide/:id` | Retrieve a saved guide (`404` not found, `410` expired) |

#### `POST /plan` response (Android)

```json
{
  "success": true,
  "appPackage": "com.whatsapp",
  "appName": "WhatsApp",
  "language": "hi",
  "steps": [
    {
      "stepNumber": 1,
      "instruction": "व्हाट्सएप खोलें",
      "findDescription": "WhatsApp icon",
      "appName": "WhatsApp",
      "expectedScreenTitle": "WhatsApp",
      "appPackage": "com.whatsapp"
    }
  ],
  "totalSteps": 5
}
```

See [`backend_initial/README.md`](backend_initial/README.md) for the full API reference and request/response schemas.

---

## 📂 Repository Layout

```
waylo/
├── app/                      # Android app (Kotlin, Gradle)
│   └── src/main/java/com/waylo/
│       ├── accessibility/    # AccessibilityService + element finder
│       ├── ai/               # backend + vision clients, plan parser
│       ├── guidance/         # GuidanceEngine, matcher, fallback, step models
│       ├── ocr/              # screen analysis pipeline + ML Kit OCR
│       ├── overlay/          # pulsing dot overlay
│       ├── permissions/      # permission manager
│       ├── screenshot/       # MediaProjection capture
│       ├── service/          # foreground guidance service
│       ├── sharing/          # shareable guides + deep links
│       ├── ui/               # activities, onboarding, dev tools
│       └── voice/            # TTS + speech recognition
│
├── waylo-macos/              # macOS companion (Swift, Xcode)
│   └── WayloMac/
│       ├── accessibility/    # AXUIElement reader + finder
│       ├── ai/               # API client, config, parser
│       ├── guidance/         # GuidanceEngine, fallback
│       ├── overlay/          # transparent overlay window + dot
│       ├── permissions/      # screen recording permission
│       ├── voice/            # AVSpeech + SFSpeech
│       └── ui/               # onboarding, home panel
│
├── backend_initial/          # Node/Express backend
│   ├── index.js              # server + routes
│   ├── bedrock.js            # AWS Bedrock (Claude) integration
│   ├── routes/               # vision, vision-fallback, failure
│   ├── langdetect.js         # language detection
│   └── supabase.js           # guide persistence
│
├── build.gradle.kts          # Android root build
└── settings.gradle.kts
```

---

## 🚀 Getting Started

### 1. Backend

```bash
cd backend_initial
npm install
cp .env.example .env        # fill in AWS Bedrock + Supabase credentials
npm run dev                  # auto-reload, or `npm start` for production
```

Create the Supabase `guides` table (SQL in [`backend_initial/README.md`](backend_initial/README.md)), then deploy to Railway / Render / any Node host.

### 2. Android app

```bash
# from the repo root
./gradlew :app:assembleDebug
# or open the project in Android Studio and run on a device
```

Point the app at your backend (see [Configuration](#-configuration)), install, then complete onboarding to enable the accessibility service and overlay permission.

### 3. macOS app

```bash
cd waylo-macos
open WayloMac.xcodeproj
# or:
xcodebuild -project WayloMac.xcodeproj -scheme WayloMac -configuration Debug build
```

On first launch, grant Accessibility access in **System Settings → Privacy & Security → Accessibility**. The project uses an Xcode synchronized file group, so files added under `WayloMac/` are included automatically.

---

## ⚙ Configuration

### Backend environment variables

| Variable | Purpose |
|----------|---------|
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | AWS credentials for Bedrock |
| `AWS_REGION` | Bedrock region (e.g. `us-east-1`) |
| `BEDROCK_MODEL_ID` | Claude model / inference profile |
| `SUPABASE_URL` / `SUPABASE_ANON_KEY` | Guide persistence |
| `PORT` | Server port (default `3000`, auto-set by most hosts) |
| `WAYLO_DEBUG` | Set to `1` to log full vision prompts and raw responses |

### macOS backend URL resolution (never hardcoded)

1. `WAYLO_BACKEND_URL` environment variable (scheme → Run → Arguments → Environment Variables)
2. `WayloBackendURL` key in `WayloMac/Info.plist`
3. Fallback: `http://localhost:3000`

---

## 🔐 Privacy & Security

- **Screenshots are never written to disk.** Both clients capture the screen in memory only for OCR / vision and recycle the bitmap as soon as analysis completes.
- **On-device first.** The accessibility-tree layers run entirely on the device; the network is only used when local layers can't find the target.
- **Scoped capabilities.** Android uses a `mediaProjection` foreground service with a visible notification; macOS requests Screen Recording and Microphone only on demand.
- **Rate limiting & CORS** protect the backend; guides expire after 30 days.

> ⚠️ The accessibility services in both clients can read the content of other apps' UI to locate elements. This is the core capability that makes Waylo work, and it's also powerful — treat the build, signing, and distribution of these apps with appropriate care.

---

## 🗺 Roadmap

- Add an on-device icon-recognition layer (colour signature → labeling → trained TFLite classifier), fed by `/failure` miss logs.
- Expand the macOS pipeline with on-device OCR (Vision framework) before the cloud fallback.
- Broaden language coverage and offline TTS quality.

---

<div align="center">

Built to make technology approachable — one tap at a time.

</div>

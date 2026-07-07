# CLAUDE.md — Waylo macOS (WayloMac) context

> **2026-07 update — read this first; sections below may lag the code.**
> - **No hover UI**: the notch panel is click-driven (menu-bar icon / ⌃⌥⌘W /
>   clicking the running pill), content-sized, dismisses on click-outside
>   (clicky-style). `NotchExpansion` has only `expanded`.
> - **Region highlights**: every layer returns the target's bounding rect;
>   the overlay draws a dashed box (`HighlightBoxView`) and a click anywhere
>   inside it advances. Bare dot is the fallback.
> - **Assist mode is the default** (`GuideMode.assist`): safe clicks are
>   performed via AXPress/synthetic click; destructive steps (empty/delete/
>   send/pay…) always fall back to point-and-confirm.
> - **Ambiguity**: near-tied confident AX matches show numbered badges
>   (`CandidateBadgeView`); the user's click picks.
> - **Grounded planning**: `/plan` is sent a live AX snapshot
>   (`ScreenContextBuilder`) — plans start from the current screen state.
>   Hardcoded demo plans are REMOVED from the backend.
> - **Clicks come from the CGEventTap** (`HotkeyManager.addClickObserver`),
>   not NSEvent monitors (those miss menu/Dock tracking clicks).
> - **New-window & modal awareness**: window-list diffs after each action
>   prefer the just-opened window; sheets/dialogs (AXSheets attr) hard-focus
>   detection inside them. Verification: a screen fingerprint detects
>   "the last action did nothing" and informs /recover.
> - **Electron apps**: `AXManualAccessibility` is set on every target app.
> - **Intents**: URL / named-engine search / "open <installed app>" bypass
>   the planner (`IntentShortcuts`).
> - **Language**: en/hi/pa preference drives STT + TTS + `L10n` UI strings.
> - **YOLO service** returns CLIP `match_score` per box (semantic matching);
>   opt-in training-screenshot capture + `finetune/` pipeline exist.
> - CI builds Debug+Release on pushes touching `waylo-macos/`.

Complete context for the **macOS** app. Read this before making changes in `waylo-macos/`.
It is the macOS-focused companion to the repo-root `../CLAUDE.md`; where they overlap this
file is the authority for the macOS target.

> **Trust the code, not the README.** `waylo-macos/README.md` is **stale**: it says vision
> uses "Gemini Vision" and describes a simple 3-layer (AX → vision → manual) pipeline, and
> lists macOS 13.0+. The shipped code uses **Amazon Nova 2 Lite** for grounding
> (`NovaVisionFallback` / `/nova-vision`) plus a **dual-model YOLO** L2.5 layer, with
> OCR-first / AX-first branching, and `Info.plist` sets `LSMinimumSystemVersion` **14.0**.
> Details in §11.

---

## 1. What this app is

Waylo macOS is **AI-powered, on-screen guidance for any Mac app**. The user asks a question
in plain language (typed or spoken) — "how do I bold text in Word?", "how do I empty the
Trash?". Waylo:

1. Generates an ordered **step plan** (each step describes a UI element to interact with).
2. For each step, **finds the exact element on the user's real screen** (AX tree + Apple
   Vision OCR + YOLO + Nova).
3. Draws a **pulsing red dot** over it, **speaks** the instruction, and **auto-advances**
   when the user clicks the right place.
4. **Self-heals** when the screen doesn't look as expected (scroll assist → recovery
   replanning → "do it yourself and continue").

It works on top of apps Waylo has never seen — no per-app integration. Target users are
people who find computers intimidating, so the UX is simple, spoken, and forgiving.

**Core design principle — fastest / cheapest / most-private layer first.** Each step tries
instant, free, on-device detection (Apple Vision OCR + the Accessibility tree) before any
network call. The paid cloud-vision call (Nova) is a last resort, and every paid call is
harvested into caches + YOLO training data so future detection is free. **Screenshots are
in-memory only, never written to disk.**

---

## 2. Platform, project shape, build

- **Language/UI:** Swift, AppKit + SwiftUI. Xcode project (`WayloMac.xcodeproj`).
- **Deployment target:** macOS **14.0** (`Info.plist` `LSMinimumSystemVersion`). Built
  against recent Xcode.
- **Menu-bar-only app:** `NSApp.setActivationPolicy(.accessory)` — no Dock icon
  (`LSUIElement = true`). The UI lives in a notch panel.
- **Synchronized file group:** the Xcode target uses a synchronized group, so **any file
  added under `WayloMac/` is auto-included** in the build — no manual `.pbxproj` edits.

Build:
```bash
open WayloMac.xcodeproj
# or
xcodebuild -project WayloMac.xcodeproj -scheme WayloMac -configuration Debug build
# release packaging
./build-release.sh          # produces dist/Waylo.app, .dmg, .zip (signing in .signing/)
```

> Long-running commands (dev servers, watchers) must be run manually in a terminal, not via
> a one-shot blocking command.

### 2.1 Sandbox & entitlements — `WayloMac.entitlements`
- **App Sandbox is DISABLED on purpose.** A sandboxed app can't call
  `AXUIElementCreateApplication` on other processes or install a global event tap (same
  reason Alfred/Raycast aren't sandboxed). Do **not** re-enable it.
- Hardened Runtime is on (for future notarization). `device.audio-input` (mic) and
  `automation.apple-events` are granted.

### 2.2 Permissions (all requested up front in `AppDelegate`)
- **Accessibility** (mandatory) — read other apps' AX tree + install the CGEventTap.
  Checked via `AXIsProcessTrustedWithOptions`; if untrusted, onboarding is shown.
- **Screen Recording** (`ScreenRecordingPermission`) — required for OCR / vision / YOLO / Nova.
- **Microphone + Speech** (`MicHandler.requestPermission`) — voice input.

---

## 3. Backend contract & configuration

The macOS app is a thin client over the **shared Waylo backend** (`../backend_initial`,
Node/Express on AWS Bedrock + RDS/Aurora Postgres + pgvector) and a **Python dual-YOLO
microservice**. The `/plan` route branches on `platform: "macos"`.

### 3.1 Backend URL — `ai/AppConfig.swift` (never hardcoded in Swift)
Resolved in priority order:
1. `WAYLO_BACKEND_URL` env var (scheme → Run → Arguments → Environment Variables).
2. `WayloBackendURL` key in `Info.plist` — currently `http://13.127.137.249:3000` (EC2).
3. Fallback `http://localhost:3000`.

The EC2 backend is plain **HTTP**, so `Info.plist` has a scoped ATS exception
(`NSExceptionDomains` → `13.127.137.249` → `NSExceptionAllowsInsecureHTTPLoads`). If you
change the backend host, update both the URL and the ATS exception (or serve HTTPS).

### 3.2 Endpoints the macOS client calls — `ai/WayloAPIClient.swift`
| Method | Route | Used for | Response type |
|---|---|---|---|
| POST | `/plan` (`platform:"macos"`) | generate step plan | `GuidePlan` via `PlanParser` |
| POST | `/nova-vision` | L3 grounding (Nova 2 Lite, **0–1000** bbox) | `NovaVisionResponse` |
| POST | `/detect-elements` | L2.5 proxy → Python dual-YOLO | `YOLODetectResponse` |
| POST | `/vision-fallback` | legacy Claude vision (pixel point) | `VisionFallbackResponse` |
| POST | `/label/lookup`, `/label/store` | step-label cache (skip vision next time) | JSON |
| POST | `/recover` | self-healing: relabel / replan / scroll hint | `RecoverResult` |
| POST | `/qa` | concept Q&A (spoken text answer) | `{answer}` |
| POST | `/ask-screen` | vision Q&A from a screenshot | `{answer}` |
| POST | `/plan/learn`, `/plan/forget` | remember / forget a corrected plan | fire-and-forget |
| POST | `/guide` | save shareable guide (expects `taskName`,`language`,`steps`) | `SavedGuide` |

`PlanParser` is tolerant of both the macOS shape (`index`, `findDescription`, …) and the
Android/mobile shape (`stepNumber`, `appName`) so it decodes either contract.

---

## 4. The shared step contract — `models/Step.swift`

A `GuidePlan` = `{ task, app, steps: [Step], demo }`.

**`Step`** fields (all drive detection/advancement):
- `index`, `instruction` (spoken/shown), `findDescription`.
- `action` (`StepAction`): `click` (show dot, advance on click) / `type` (banner, advance on
  Return) / `key` (banner, advance on that key) / `info` (instruction/wait).
- `key` — for `.key` actions (e.g. "return", "tab").
- `targetLabel` — **exact visible text** to find via OCR (`""` for icon-only targets).
- `elementDescription` — natural-language hint for AX / vision (e.g. "Bold button in the
  toolbar").
- `screenRegion` (`ScreenRegion`): `menuBar` / `ribbon` / `dialog` / `sidebar` /
  `spreadsheet` / `statusBar` / `fullScreen`. Used **softly** (filter AX candidates, crop
  OCR) — never a hard reject of a resolved point.
- `targetType` (`StepTargetType`): `.text` (AX + OCR) vs `.icon` (AX-by-desc + YOLO + Nova).
  **Routes which detectors run.**
- `controlKind`: `button` / `menuItem` / `checkbox` / `tab` / `link` / `field` / `""`. Lets
  detection prefer a real control over matching plain header/label text.
- `anchorText` + `anchorPosition` (`below`/`above`/`left`/`right`/`near`) — disambiguate
  short/repeated labels by locating a nearby known label first.
- `autoAdvanceSeconds` — auto-advance N seconds after showing (for "do this then I continue"
  info steps).
- `silent` — show instruction without speaking (pure-wait steps).
- `advanceOnAnyClick` — info steps that advance on ANY click when Waylo can't point precisely.
- `labelCacheKey` (computed) — `"<elementDescription> <targetLabel> <action>"`, trimmed.
  **Built identically on lookup and store paths** so the step-label-cache embedding lines up.
- `GuidePlan.demo == true` → plan is **LOCKED**: mid-run corrections may relabel/re-point a
  step but never replan.

---

## 5. The element-finding pipeline — `detection/CoordinateResolver.swift`

This is the heart of the app. `resolve(...)` returns a point in **AX-global coordinates**
(top-left origin from the primary display) that the overlay uses. It **branches on
`targetType` and `controlKind`** — the header comment in the file listing a fixed "layer
order 1–4" is stale; the real flow is:

1. Resolve an **anchor** point first (if `anchorText` set) via AX, else OCR (≥0.8), so AX can
   prefer the target in the requested direction.
2. **Plain text target, not a real control** → **OCR first** (visual ground truth).
3. **Layer 0 — AX tree** (`axSearch` → `AccessibilityReader` + `ElementFinder`): search the
   target app's tree by `targetLabel` (role/anchor aware), then by description **only** when
   there's no precise `targetLabel` or it's an icon target (a verbose desc pollutes labelled
   matches). System-UI (Dock / menu-bar extras) allowed only for a precise label with a
   **strong** (all-words) title match.
4. **Control text target** → **OCR fallback** after AX (a button's label sits on it).
5. If `localOnly` (scroll-assist polling) → return nil here (no network).
6. **Label cache** (`/label/lookup`): a prior working label → try **AX only**; a hit skips
   the paid L3 call.
7. **Layer 2.5 — dual-model YOLO** (`YOLODetector` → `/detect-elements`): **icon targets
   only** (text targets skip straight to Nova).
8. **Layer 3 — Nova 2 Lite** (`NovaVisionFallback` → `/nova-vision`): paid last resort,
   requires Screen Recording. Returns **0–1000 normalized** bbox → AX-global point. On
   success it (a) **caches the working label** via `/label/store` so next run resolves via
   AX, and (b) **logs a YOLO training example** (local JSONL). May instead return a refined
   description, which is re-tried via AX then OCR.

Detector files & thresholds:
| Layer | Technique | File | Notes |
|---|---|---|---|
| L1 OCR | Apple Vision `VNRecognizeTextRequest` (.accurate) | `LocalVisionDetector.swift` | ~80ms, free, private. Fuzzy word-set score; **threshold 0.8**. Crops to `screenRegion`. Adds crop origin back → AX-global. |
| L0 AX | Accessibility tree scoring | `AccessibilityReader.swift` + `ElementFinder.swift` | free, pixel-exact. Min score 40; **40–55 = low confidence → nil** so OCR can win. |
| L2.5 YOLO | OmniParser + Screen2AX (dual) | `YOLODetector.swift` → `/detect-elements` | icon targets only; 0–1 normalized boxes scored by AX-class + confidence + region. |
| L3 Nova | Amazon Nova 2 Lite | `NovaVisionFallback.swift` → `/nova-vision` | paid; 0–1000 bbox; caches label + logs training example on hit. |

`ScreenCapturer.swift` — **ScreenCaptureKit**, captures the display under the cursor,
**excludes Waylo's own windows**, downscales to base64 JPEG (max 1280px, quality 0.6).

---

## 6. Accessibility layer — `accessibility/`

- **`AccessibilityReader.swift`** — recursively walks the `AXUIElement` tree (max depth 14)
  of the **target app** (from `TargetAppTracker`, not Waylo). Surfaces interactive roles:
  `AXButton`, `AXMenuItem`, `AXTextField`, `AXCheckBox`, `AXTab`, `AXLink`, `AXMenuBarItem`,
  and **short** `AXStaticText`/`AXRow` (AX-hostile apps like System Settings expose sidebar
  items as static text in rows). Skips window chrome (traffic lights). Can also read **system
  UI** processes (`com.apple.dock`, `controlcenter`, `systemuiserver`) for Dock icons /
  menu-bar extras. Helpers: `getTargetAppElements()`, `getSystemUIElements()`,
  `targetHasScrollArea()`, `targetFocusedWindowFrame()`.
- **`ElementFinder.swift`** — scoring: strip stop words → keywords; exact title/desc match
  +120; whole-word title hit +35 (beats substring so "file" ≠ "profile"); full-coverage
  bonus +40; role boosts; `controlKind` preference (matching role +45, penalize static
  text/rows −30 when a real control is wanted); small-control size bonus; **anchor** bonus
  (prefer elements in the requested direction near a known label, fading with distance).
  Rejects off-screen / zero-size. `isControlKind(_:)` classifies whether a `controlKind` is a
  real control.
- **`TargetAppTracker.swift`** — tracks the frontmost **non-Waylo** app so all AX reads and
  the app-name cache key target the app the user is actually working in.

---

## 7. Orchestration — `guidance/GuidanceEngine.swift` (`@MainActor` singleton)

- Walks steps, speaks each instruction. `click` → locate + show dot; `type`/`key`/`info` →
  banner + advance on commit.
- Detects keyboard-shortcut steps mis-emitted as clicks ("Press Command+Space") and reroutes
  to a `.key`/`.info` step; advances on the exact combo (incl. system combos like ⌘Space via
  an observe-only key tap).
- On dot shown, installs a **global click monitor**: a real `leftMouseDown` within ~60pt of
  the dot = completion → next step.
- **Retry once after 800ms** if all layers miss (apps mid-animation have stale AX /
  screenshots). `locateToken` guards stale async work.
- **Self-healing** when all layers miss: (1) **scroll assist** — if the target app has a
  scroll area, show a bouncing arrow and poll AX+OCR locally (~18s, flips direction halfway);
  (2) **recovery** via `/recover` — relabel (retry resolver + cache), replan (splice new
  steps from the current index), or scroll-direction hint; (3) **manual** — ask the user and
  advance on any click.
- On complete → records to `TaskHistory` (user can ✓ to cache the plan via `/plan/learn`, ✗
  to forget via `/plan/forget`). `debugRelocate()` (⌃⌥⌘N) re-detects the current step.

---

## 8. Voice & conversation — `voice/` + `conversation/`

- **`Speaker.swift`** — `AVSpeechSynthesizer` TTS, en-US, rate 0.45 (slower for clarity).
- **`MicHandler.swift`** — `SFSpeechRecognizer` STT; needs **both** Speech auth and
  Microphone (TCC). Partial results; ~6s capture window then finalizes.
- **`VoiceCommandEngine.swift`** (⌃⌥⌘V) — no guide running → spoken phrase becomes a **new
  task**; guide running → phrase is a **correction/follow-up** sent to `/recover` with a
  fresh screenshot. Local fast-path for "next"/"go back"/"repeat".
- **`ConversationEngine.swift`** (⌃⌥⌘A / ⌃⌥⌘Q) — mid-guide voice Q&A. `QuestionClassifier`
  (pure local, no API) sorts into **navigation** (control the guide), **concept**
  (→ `/qa`, spoken), or **location** ("where is X?" → run resolver + drop dot). `askAboutScreen()`
  answers a free-form question from a screenshot via `/ask-screen`.

---

## 9. Global hotkeys — `input/HotkeyManager.swift`

Uses a **CGEventTap** (session level), not `NSEvent` global monitors, so combos fire in any
app (incl. Waylo) and are **consumed** (no clashes). All use **⌃⌥⌘**. Registered in
`AppDelegate.registerHotkeys()`:

| Combo | keyCode | Action |
|---|---|---|
| ⌃⌥⌘V | 9 | voice command (new task / correction) |
| ⌃⌥⌘N | 45 | re-detect current step (fresh screenshot → Nova recovery) |
| ⌃⌥⌘A | 0 | ask a question by voice |
| ⌃⌥⌘Q | 12 | ask about what's on screen (vision Q&A) |
| ⌃⌥⌘W | 13 | toggle notch panel |
| ⌃⌥⌘D | 2 | toggle debug overlay (logging always stays on) |
| ⌃⌥⌘T | 17 | coordinate self-test |

`HotkeyManager.addKeyObserver` is an **observe-only** matcher (does NOT consume) so e.g.
⌘Space still opens Spotlight while advancing a guide step.

---

## 10. Overlay & coordinates — `overlay/`

- **`OverlayWindow.swift` / `OverlayWindowController.swift`** — transparent, always-on-top,
  click-through window (singleton controller); `showDot(atAXPoint:)` is the entry point.
- **`DotView.swift`** — SwiftUI pulsing red dot; glides between targets.
- **`ScreenCoordinates.swift`** — Cocoa is bottom-left origin; AX is top-left origin from the
  primary display. **All conversions are centralized here.** The pipeline returns AX-global
  points; Nova/YOLO/OCR all convert to AX-global via the captured screen's frame for
  multi-monitor correctness. Don't introduce crop-relative bugs (always add the crop origin
  back — see `LocalVisionDetector`).

Other dirs: **`ui/`** — `OnboardingView`/`OnboardingWindowController` (accessibility
permission flow) and `HomePanel/` (the notch panel, task input, dev tools).
**`permissions/ScreenRecordingPermission.swift`**. **`debug/`** — `DebugLogger` (always on),
`DebugOverlayController`/`DebugOverlayView` (⌃⌥⌘D), `CoordinateTests` (⌃⌥⌘T).

---

## 11. Known discrepancies (stale docs — trust the code)

1. **`waylo-macos/README.md`** says vision uses **"Gemini Vision"** and a simple 3-layer
   (AX → vision → manual) pipeline, macOS **13.0+**. Reality: **Nova 2 Lite** grounding
   (`NovaVisionFallback` / `/nova-vision`) + **dual-model YOLO** L2.5 (`/detect-elements`),
   OCR-first/AX-first branching, and `LSMinimumSystemVersion` **14.0**. `/vision-fallback`
   still exists (Claude-based) but the live pipeline uses `/nova-vision` + `/detect-elements`.
2. **`CoordinateResolver.swift` header comment** lists a fixed layer order (1 OCR → 2 CoreML
   YOLO → 3 AX → 4 Nova Pro) and calls YOLO a "stub". The real flow branches on
   `targetType`/`controlKind` (see §5) and YOLO is a live dual-model call for icon targets.
3. macOS training-data dir/log uses the **legacy name "Sahayak"**
   (`~/Library/Application Support/Sahayak/yolo_training_log.jsonl`) — the project's prior name.
4. The backend URL in `Info.plist` is a plain-HTTP EC2 IP with a scoped ATS exception; the
   repo-root docs describe it generically as "Railway". The client works against any host
   given via `WAYLO_BACKEND_URL` / `WayloBackendURL`.

---

## 12. Conventions & gotchas

- **Privacy:** never write screenshots to disk; recycle after analysis; never log screenshot
  bytes.
- **Coordinates are AX-global** end-to-end; always convert via the captured screen's frame
  and add crop origins back.
- **Layer ordering is `targetType`/`controlKind`-dependent — don't reorder casually.**
  Text→OCR-first, control→AX-first, icon→YOLO/Nova.
- **Thresholds are tuned — change deliberately:** OCR **0.8**; AX min **40** / confident
  **55**. (Backend-side: semantic plan cache 0.92, step-label cache 0.93.)
- **`labelCacheKey` must stay identical** on lookup and store or the embedding match breaks.
- **Demo plans are LOCKED** (`GuidePlan.demo`) — corrections relabel only, never replan.
- **Hotkeys go through `HotkeyManager` (CGEventTap)**, not `NSEvent` monitors.
- **Never re-enable App Sandbox** — it breaks cross-process AX and the event tap.
- New Swift files under `WayloMac/` are auto-included (synchronized group) — no `.pbxproj`
  edits needed.

---

## 13. One-paragraph summary

Waylo macOS points a talking red dot at the exact next thing to click in any Mac app. It's a
menu-bar-only, non-sandboxed AppKit/SwiftUI app that reads the target app's Accessibility tree
and drives a layered, self-healing element-finding pipeline (`CoordinateResolver`): cheapest
and most private first — Apple Vision OCR + AX tree — then dual-model YOLO for icons, then
Amazon Nova 2 Lite as a paid last resort, all returning AX-global coordinates for the overlay.
Plans come from the shared Bedrock-backed backend (`platform:"macos"`), every paid Nova hit is
harvested into a step-label cache (skip vision next time) and YOLO training data, it's fully
voice-driven both directions with global ⌃⌥⌘ hotkeys, and it never dead-ends the user (scroll
assist → recovery replanning → "do it yourself and continue").

<!-- ═══════════════════════════════════════════════════════════════════════ -->
<!--  ALL THINGS AGENTIC HACKATHON — Track: The Collaborative Partner          -->
<!-- ═══════════════════════════════════════════════════════════════════════ -->

# 🔴 Waylo Agent — Client (macOS + Android)

**Submission for the All Things Agentic Hackathon · Track: The Collaborative Partner.**

This repo is the **client**: it reads the screen, draws the talking red dot, and drives the agent loop. The **agent brain** — Gemini 3.5 + Genkit on Cloud Run + Firestore — lives in a separate repo:

- **Agent backend (the brain):** https://github.com/waylo-1/waylo_agent
- **Live backend (Google Cloud Run):** https://waylo-agent-506434766076.asia-south1.run.app
- **How it works:** you type or speak a task → the client sends the task + a live screen snapshot + session memory to Cloud Run → **Genkit + Gemini 3.5** return a step-by-step plan (or a clarifying question) → the client points the red dot at each step, on-device. It never dead-ends: after a task it asks for a follow-up and remembers what you just did.

## What was built for this hackathon (disclosure)

Per the **New Projects Only** rule, the boundary is explicit:

- **Built during the Submission Period (Aug 3–31, 2026):** the entire **agent backend** (Genkit + Gemini 3.5 planner, clarifying-question flow, per-turn agent) in the `waylo_agent` repo; and, in **this** repo, the client's **agent wiring** — Follow-up mode, the clarify UI, and Right-⌘ voice / typed feedback capture (all commits in this window, on the branch merged here).
- **Pre-existing, carried in (before Aug 3, 2026), named as such:** the macOS / Android **client shell** (window, notch panel, red-dot overlay) and the **on-device detection pipeline** (L0 Accessibility, L1 OCR, L2 / L2.5 YOLO) that turns a planned step into pixel coordinates.
- **Standard frameworks:** Genkit, Google GenAI SDK, SwiftUI / AppKit, Kotlin.

## Reproducible testing instructions

**Easiest — try the prebuilt macOS app (no build needed):**
1. Download `Waylo-AgentDemo.app` from the hosted download page (Devpost "Try it" link).
2. Open it. On first launch, grant the three macOS permissions it requests: **Accessibility**, **Screen Recording**, and **Microphone + Speech Recognition** (System Settings → Privacy & Security). These let it read the screen and draw the dot.
3. In the notch panel, pick **Follow-up** in the mode picker.
4. Type or say a task, e.g. **"make the text bold in Pages"**. Waylo opens the app and guides you with the red dot.
5. When it finishes, the panel opens for a **follow-up** — type/say **"now make it bigger"** (it remembers you were in Pages). Try a vague one like **"share this"** to see it **ask a clarifying question**. Correct a dot by holding **Right ⌘** and speaking, or press **⌃⌥⌘N** to confirm-and-learn.
6. The plans come live from the Genkit backend on Cloud Run — no local backend needed.

**Build from source (macOS):**
```bash
# Requires Xcode 15+ on macOS 13+
open waylo-macos/WayloMac.xcodeproj
# In Xcode: select the "WayloMac" scheme → Product ▸ Run (⌘R)
# — or build a Release app from the command line:
xcodebuild -project waylo-macos/WayloMac.xcodeproj -scheme WayloMac \
  -configuration Release -derivedDataPath build build
open build/Build/Products/Release/WayloMac.app
```
The client calls the **Genkit `/plan`** endpoint on Cloud Run (`AppConfig.genkitBaseURL`); no keys or local services are required to test. Grant the three permissions above on first run.

**Android:** the Android app (`app/`, Gradle) shares the same agent backend; `./gradlew assembleDebug` builds it (Android Studio recommended).

---

<div align="center">

# 🔴 Waylo — Apps (macOS + Android)

**AI on-screen guidance — a glowing red dot points at exactly what to tap next, in any app.**

[![Website](https://img.shields.io/badge/website-waylo--web.vercel.app-6C4CF1)](https://waylo-web-virid.vercel.app)
[![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](https://waylo-web-virid.vercel.app/Waylo-macOS.dmg)
[![Android](https://img.shields.io/badge/Android-8%2B-3DDC84?logo=android&logoColor=white)](https://waylo-web-virid.vercel.app/waylo.apk)
[![Powered by Gemini](https://img.shields.io/badge/AI-Google%20Gemini-4285F4?logo=googlegemini&logoColor=white)](https://ai.google.dev)

**🌐 [Website](https://waylo-web-virid.vercel.app)  ·  ⬇️ [Download for Mac](https://waylo-web-virid.vercel.app/Waylo-macOS.dmg)  ·  ⬇️ [Download for Android](https://waylo-web-virid.vercel.app/waylo.apk)**

</div>

This repository holds **both client apps**. The [`backend_initial`](https://github.com/waylo-1/backend_initial) service (Gemini planning + vision, YOLO, plan cache) is the shared brain both apps talk to.

```
.
├── waylo-macos/     → macOS app (Swift / AppKit, menu-bar app)
├── app/  + gradle/  → Android app (Kotlin, Accessibility Service)
├── backend_initial/ → the backend (its own repo, nested here)
└── eval/            → detection evaluation harness
```

---

## What it does

You say what you want; a **talking red dot** points at exactly what to tap next, on your real screen. It *teaches* rather than takes over — it points, **you** click, you learn. It remembers what you just did across apps, and gets more accurate every time anyone uses it.

**Three modes of autonomy (one engine):** *Teach me* (point & you learn) · *Do it with me* (safe steps automated, risky ones confirm) · *Do it for me* (full agent).

---

## How a step is resolved — the 10-layer cascade

For every step, the app must find *where on your screen* the target is. It runs a cascade **cheapest-and-most-certain first, stopping at the first confident hit** (our **cost-first, correct-first** principle):

**Tier 1 — on-device, instant, free:** ① accessible-name deep-AX · ② OCR · ③ AX tree scoring · ④ control OCR + profile synonyms · ⑤ label cache · ⑥ colour match · ⑦ icon memory (perceptual hash, fleet-synced)

**Tier 2 — cloud vision, only if Tier 1 misses:** ⑧ YOLO object detection · ⑨ **Gemini vision** (reasons about pixels; Set-of-Mark disambiguation)

**Tier 3 — safety net:** ⑩ region + describe (never confidently wrong; a one-tap ⌃⌥⌘N correction teaches the exact spot)

> **Gemini generates the detailed plan *and* is the main vision fallback.** The powerful model is spent only when the free local layers can't resolve the target. Every verified click + labelled icon syncs to the fleet and fine-tunes the YOLO model — so it works more on-device over time.

---

## 🖥 macOS app (`waylo-macos/`)

Native Swift / AppKit menu-bar app, built on the macOS **Accessibility API** for cross-app awareness and control. macOS 14+.

**Build both distributables:**
```bash
cd waylo-macos
./build-release.sh both
#   dist/Waylo-macOS.dmg           → public build (freemium: 5 free / 25 paid)
#   dist/Waylo-Reviewer-macOS.dmg  → reviewer build (unlimited tasks, no sign-in)
```
Both ship the clean production surface (Judge/max-accuracy on, no developer tools). The reviewer build is compiled with the `JUDGE_BUILD` flag.

**Key hotkeys:** hold **Right ⌘** to talk · **⌃⌥⌘N** confirm/re-detect · **Esc** stop.

---

## 📱 Android app (`app/`)

Native Kotlin app using the Android **Accessibility Service** to read the screen and place the guidance overlay, with voice input via `SpeechRecognizer`. Android 8+.

**Build:**
```bash
./gradlew assembleRelease
# app/build/outputs/apk/release/app-release.apk
```

---

## ⬇️ Download & install (end users)

**macOS** — [download the .dmg](https://waylo-web-virid.vercel.app/Waylo-macOS.dmg) → drag to Applications → first launch: right-click → **Open** → **Open** (or **System Settings → Privacy & Security → Open Anyway**) → grant **Accessibility**, **Screen Recording**, **Microphone** → sign in.

**Android** — [download the APK](https://waylo-web-virid.vercel.app/waylo.apk) → allow install from unknown sources → enable Waylo's **Accessibility Service** → go.

---

## Configuration

The backend base URL is read from `WayloBackendURL` in `Info.plist` (macOS). Behaviour (Judge Mode, detection confidence, voice engine, broadcast messages, update prompts) is **remote-configured** from the backend's `/config` — no re-download needed. See [`backend_initial`](https://github.com/waylo-1/backend_initial).

---

<div align="center">

**Part of [Waylo](https://github.com/waylo-1)** · Digital confidence, and the power to learn anything on a screen.

</div>

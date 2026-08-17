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

# Speech changes: wrong-place/dot phrases removed, target descriptions added

Android-only, nothing pushed, backend/EC2 untouched.

## Pre-change inventory (what was found before coding)

**CHANGE 1 candidates** (searched `app/src/**/*.kt`, `app/src/main/res/values/strings.xml`;
no `values-hi` directory exists in this project — checked, does not exist):
- `app/src/main/java/com/waylo/guidance/GuidanceEngine.kt` — the ONLY hardcoded
  spoken string in the whole codebase matching these patterns, inside what was
  then called `handleWrongApp()` (already renamed `speakWrongAppNudge()` in a
  prior session): `"This isn't the right place — please press the back button to go back."`
- No `strings.xml` entry existed for this text (confirmed by search — it was a
  Kotlin string literal, not an Android resource).

**CHANGE 2 candidates** (same search, for "red dot"/"follow the dot"/"click the dot"):
- **None found as an active spoken string.** A prior session had already
  removed the only such narration (`"When you see the red dot, tap it."`) and
  the `"Follow the dot"` default-instruction fallback in `PlanParser.kt` (now
  `"Look for $findDescription."`). Remaining "red dot"/"follow the dot"
  mentions are all non-spoken: `DotView.kt`'s class doc (describes the visual
  drawable), `WayloApplication.kt`'s doc (describes the dot-overlay
  *architecture*, not narration), `PlanParser.kt`'s comment (explains why the
  default was changed). None of these are `speak()`/`speakQueued()` calls or
  string resources — left untouched, they're accurate developer documentation.

**CHANGE 3/4 target**: `GuidanceEngine.speakTargetDescription()` — existed,
but was only called from below-confidence-floor "not found" paths, never from
the normal "dot placed" path (`onTargetLocated()`), per that function's own
"Speech policy" doc comment, which explicitly said the step's instruction was
"the ONLY announcement for finding the target."

## What was deleted

| File | Deleted |
|---|---|
| `app/src/main/java/com/waylo/guidance/GuidanceEngine.kt` | The `speak("This isn't the right place — please press the back button to go back.")` call, and the entire `speakWrongAppNudge()` function it lived in. Also removed the now-dead `hasAnnouncedWrongApp` state and `WRONG_APP_CONFIRM_SCANS` constant (their only purpose was gating that one spoken line). |

No `strings.xml` entries existed for either banned phrase, so none needed removal there.

## What the app says now, in each situation

| Situation | Before | Now |
|---|---|---|
| Screen/app confirmed wrong (`isInExpectedApp` fails) | Spoke the "wrong place / go back" line once per excursion | **Says nothing.** Dot/arrow hide immediately and silently; a debug-only log (`WRONG_LOCATION_SUPPRESSED`) records it, nothing is spoken. |
| Dot successfully placed (any layer: tree/OCR/YOLO/partial-match) | Only the step's original instruction (spoken once, at step start) | Same instruction, **plus** a queued (non-interrupting) description: `"Tap <target>[ in the <region>]."` — e.g. `"Tap the History button."` or `"Tap the round profile picture in the top right corner."` |
| Target not found after the full patient window (normal case, app is correct) | `"Look for <target>[ in the <region>]. [<fallbackHint>]"` | Unchanged — this was already correct per Change 3's field priority, now also used for the AppLaunch-with-no-known-appName case (see below). |
| Target not found after the full patient window, AND the step is about opening/finding an app (step 0, `elementType=APP_ICON`/`NAVIGATION`, or a legacy "Open/Launch/Start..." instruction), AND the plan's `appName` is known | Same generic "Look for..." line | **New:** `"Please open <app name>."` — e.g. `"Please open YouTube."` |
| Screen/app confirmed wrong for an ENTIRE patient window (regression fix, see below) | Nothing — the app never reached the escalation logic while wrong-app persisted; if `WRONG_APP_CONFIRM_SCANS` was hit it spoke the deleted "wrong place" line instead | **New:** the same "Please open X" / "Look for X" logic as above, once per patient window — never silence-forever, never the deleted phrase |
| Gemini Vision saw the target but has no on-device score (`Described` outcome) | `"Look for <vision's own phrasing>[ in the <region>]. [<fallbackHint>]"` | Unchanged |

**Language note:** `com.waylo.voice.Speaker` hardcodes `Locale.ENGLISH` — there
is no existing Hindi (or any other language) TTS support anywhere in this app,
and no `values-hi` resource directory. "Match existing Speaker language
behavior" therefore means: everything above is spoken in English, identical to
every other string already in the app. No language-switching logic was added —
that would be new functionality with no existing hook to attach to, out of
scope for a speech-wording change.

## Field priority for target descriptions (Change 3)

`speakTargetDescription()` now resolves the *primary* target name in this
order (as specified): `visionDescription` (screen-specific, only present when
called from the vision-`Described` path — kept as the top tier since it's
strictly more specific than the plan's static fields) → `Step.findDescription`
→ `Step.visualDescription` → `elementLabel` (the actually-matched node's own
`text`/`contentDescription`, threaded in from
`ScreenAnalysisPipeline.PipelineResult.label` — this is the same value
`visibleLabelFor()` already computes elsewhere in this file). `screenRegion`
and `fallbackHint` remain **appended modifiers** ("...in the top right
corner", "...if not visible, tap the menu"), not primary-name candidates —
treating them as alternate names ("Tap the top right corner") wouldn't read as
a natural sentence. `fallbackHint` is only appended in the "Look for" (not
found) context, never in the "Tap" (found) context, since a hint on what to do
if you can't find something doesn't belong on a "go tap it" announcement.

## Root-cause check: did the `wrongAppStreak` debounce regress normal behavior?

**Traced and confirmed: no regression to the found-and-placed path.** The
debounce only executes inside the `if (!isInExpectedApp(index))` branch of
`locateStep()`'s loop — on a correct screen, that branch is never entered, so
dot placement and the original instruction speech were never affected.

**But it did surface a real, pre-existing gap, made worse by removing the
spoken nudge:** `locateStep()`'s wrong-app branch has always `continue`d back
to the top of the loop unconditionally, *skipping* the shared
deadline-escalation block below it (the one that runs `tryPartialMatchAcceptance`
/ vision fallback / speaks a description) on every iteration, for as long as
`isInExpectedApp()` kept failing. Since `lastKnownForegroundPackage` is
updated with no settling delay and can get stuck on a stale/wrong reading
(e.g. if a transient system window's dismissal doesn't fire a
`TYPE_WINDOW_STATE_CHANGED` back to the real app — see the false-positive
root cause from the previous session), a step could get stuck in this branch
**forever**: dot hidden, nothing found, nothing ever escalated. Before this
change, that silence was partially masked by the (buggy) "wrong place / go
back" nudge firing repeatedly — annoying, but at least audible. After
deleting that phrase (Change 1), a stuck step would have gone **completely
silent forever**, which is a worse regression than before and exactly the
failure mode Change 4 is meant to prevent.

**Minimal fix applied:** the wrong-app branch now also checks the same shared
`deadline` used by the normal path. Once the patient window expires while
still confirmed wrong-app, it calls `speakCantReachTarget()` — **not** the
live-screen search functions (`tryPartialMatchAcceptance`/`tryVisionFallback`),
since those inspect the *current* screen, which is exactly the wrong one to
search; `speakCantReachTarget` only reads static step/plan data, so it's safe
to call even while genuinely off-screen. This guarantees the user hears
*something actionable* ("Please open X" / "Look for X") at least once per
patient window, never silence forever, and never the deleted phrase.

## Files changed

| File | Change |
|---|---|
| `app/src/main/java/com/waylo/guidance/GuidanceEngine.kt` | Change 1: deleted `speakWrongAppNudge()`, its spoken line, `hasAnnouncedWrongApp`, `WRONG_APP_CONFIRM_SCANS`; wrong-app branch now silent + logs `WRONG_LOCATION_SUPPRESSED` instead. Change 3: `speakTargetDescription()` extended (`elementLabel`, `verb`, `queued` params; new findDescription-first field order); new call in `onTargetLocated()` (queued, `verb="Tap"`) — the normal placement path now speaks a description. Change 4: new `speakCantReachTarget()` (routes to "Please open `<appName>`" for AppLaunch steps, else the normal description); wired into both the normal not-found escalation and the wrong-app-stuck-past-deadline regression fix. Threaded `currentAppName`/`appName` param through `start()` from `Plan.appName`. |

No other files needed changes — no test asserted any of the deleted strings
(confirmed by search before editing), and `Plan.appName`/`PlanParser` already
existed and needed no changes, just threading through.

## Verification

`./gradlew compileDebugKotlin compileDebugUnitTestKotlin testDebugUnitTest` —
BUILD SUCCESSFUL, all 51 existing tests pass (0 failures, 0 errors). No test
needed updating (grep confirmed beforehand that no test asserted the deleted
strings or the renamed/removed symbols).

## Proof the two banned phrase families appear nowhere anymore

```
# Wrong-place / go-back family — expect zero matches outside comments explaining the removal
grep -rniE "isn.t the right place|please press the back|please go back|wrong place" app/src --include=*.kt --include=*.xml

# Red-dot / follow-the-dot family — expect zero matches that are actual spoken strings
grep -rniE "click on the red dot|tap the red dot|follow the dot|press the dot" app/src --include=*.kt --include=*.xml
```

Both return only non-spoken comments (this file's own explanatory comments
about the removal, `DotView.kt`'s drawable doc, `WayloApplication.kt`'s
architecture doc, `PlanParser.kt`'s historical note) — zero `speak()`/
`speakQueued()` calls or `strings.xml` entries match either pattern.

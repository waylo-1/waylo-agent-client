# Fixes: wrong-location false positive (unlogged) + confusing step-advance log

Both bugs were reported from one real on-device YouTube-history run. Android-only
changes, nothing pushed, nothing backend/EC2-related touched.

---

## BUG 1 — "wrong place, please go back" spoken but not logged

### Search results: every place this string can be spoken

Searched the whole codebase (`app/src/main/**/*.kt`, `app/src/main/res/**/*.xml`,
including for a `values-hi` locale — none exists, there is only one `strings.xml`)
for variants of "right place", "press the back", "go back", "wrong place/screen".

**Exactly one hardcoded spoken string exists in the entire app:**

```
app/src/main/java/com/waylo/guidance/GuidanceEngine.kt:1459 (before this fix)
WayloGuidanceService.instance?.speaker?.speak("This isn't the right place — please press the back button to go back.")
```

It lived in a function then called `handleWrongApp()`, which had **exactly one
call site** in the whole codebase: `locateStep()`'s per-scan loop, gated by
`if (!isInExpectedApp(index))`. `strings.xml` has no matching string (checked
`ob_overlay_body`, dev-tool button labels, etc. — none of them are this text).
No other file, dev-tool, or backend-driven (`troubleshoot`/`fallbackHint`)
string matches this wording.

### Why the WRONG_LOCATION log (added last session) didn't show it firing

Tracing the call chain: `locateStep()` calls the private `isInExpectedApp(index)`
wrapper, which calls the pure, already-instrumented
`isInExpectedApp(index, foregroundPackage, expectedAppPackage)` — the exact
function that logs `WRONG_LOCATION` on every mismatch. `handleWrongApp()` (the
only thing that speaks the string) is *only* reachable through that same
`if (!isInExpectedApp(index))` check. So structurally, every time the string
was spoken, `WRONG_LOCATION` must have logged immediately before it in the same
call — **there is no second, uninstrumented code path** (this rules out the
task's own working hypothesis of "a different code path"). The two most likely
explanations for the log appearing to go missing on that capture are (1) the
tested APK predated the `WRONG_LOCATION` instrumentation being installed, or
(2) logcat buffer loss under the very high volume the `getAllNodes()` tree-dump
logging produces every scan (a known issue already called out in this file's
own comments for `STEP_SKIP`). Regardless of which, the fix below adds a
**second, independent log line right at the `speak()` call itself** — so even a
dropped/missed `WRONG_LOCATION` line from `isInExpectedApp()` can't hide this
again.

### Root cause of the false positive itself (why it fires on a CORRECT screen)

`GuidanceEngine.lastKnownForegroundPackage` — the only signal `isInExpectedApp()`
checks against — is updated **unconditionally, with no settling delay**, on
every single `TYPE_WINDOW_STATE_CHANGED` accessibility event, from *any*
package (`WayloAccessibilityService.onAccessibilityEvent` forwards every event
type "across ALL packages" per its own service-connected config). Meanwhile,
`locateStep()`'s poll loop calls `isInExpectedApp(index)` on **every single
iteration** (every rescan trigger, or at minimum every `RESCAN_POLL_MS` =
1500ms) with **zero debounce** — a single bad reading fires the nudge
immediately (only gated by `hasAnnouncedWrongApp`, a one-shot-per-excursion
flag, not a confirmation count).

A single transient `TYPE_WINDOW_STATE_CHANGED` event from a different package —
a system permission/consent dialog, a keyboard IME popup, an ad interstitial,
or any brief overlay window that legitimately passes through *while the user's
underlying screen is still the correct one* — is enough to overwrite
`lastKnownForegroundPackage` for the few hundred milliseconds until the next
real event corrects it. If `locateStep()`'s loop happens to check
`isInExpectedApp()` during that exact window, it sees a mismatch and speaks the
warning instantly, even though the user never actually left the correct screen.

This is structurally the *identical* problem the codebase already solved once
for `checkLookaheadSkip()`: its own comments document that "a single
transient/flickery match... could otherwise hijack a step instantly" and fixed
it with a two-consecutive-scans debounce (`pendingSkipTargetIndex`). No
equivalent debounce existed for the wrong-app guard.

### Fix (minimal, behavior-preserving except for this one gate)

`app/src/main/java/com/waylo/guidance/GuidanceEngine.kt`:

1. New per-step counter `wrongAppStreak` (reset to 0 in `executeStep()`,
   alongside the existing `hasAnnouncedWrongApp` reset).
2. New constant `WRONG_APP_CONFIRM_SCANS = 2` — same value, same reasoning, as
   `checkLookaheadSkip`'s existing two-scan debounce.
3. In `locateStep()`'s wrong-app branch: `OverlayManager.hideDot()`/
   `hideArrow()` still run **immediately and unconditionally** on every single
   miss (unchanged safety property — a stray match must never stay visible,
   and hiding an already-hidden overlay is a no-op either way). `wrongAppStreak`
   increments on every miss and resets to 0 the moment a check passes. The
   **spoken nudge** only fires once `wrongAppStreak >= WRONG_APP_CONFIRM_SCANS`
   (i.e. two consecutive misses, roughly 1.5–3s apart under normal polling,
   confirmed via the accessibility events too if they arrive faster).
4. `handleWrongApp()` renamed to `speakWrongAppNudge(stepIndex: Int)` — now
   purely the speak-once-per-excursion part (the hide calls moved to the call
   site, see point 3). This is where the new log line lives:

```kotlin
private fun speakWrongAppNudge(stepIndex: Int) {
    if (!hasAnnouncedWrongApp) {
        hasAnnouncedWrongApp = true
        Log.e(TAG, "speakWrongAppNudge: foreground=$lastKnownForegroundPackage, expected=$currentAppPackage — nudging back.")
        Log.d(
            "WAYLO_VERIFY",
            "WRONG_LOCATION_SPOKEN | stepIndex=$stepIndex | trigger=isInExpectedApp_confirmed_miss | " +
                "currentPackage=$lastKnownForegroundPackage | expectedPackage=${currentAppPackage ?: "null"} | " +
                "confirmedScans=$wrongAppStreak"
        )
        WayloGuidanceService.instance?.speaker?.speak("This isn't the right place — please press the back button to go back.")
    }
}
```

Nothing about *placement safety* changed — a dot is still never shown/kept
while `isInExpectedApp()` fails, on the very first miss. Only the **spoken
interruption to the user** is now debounced, since that was the actual
reported symptom (repeated false warnings on a correct screen).

### Grep to watch next run

```
adb logcat -s WAYLO_VERIFY:D | grep "WRONG_LOCATION_SPOKEN"
```

To correlate with the underlying per-scan misses that led up to it (now always
2+ per spoken nudge):

```
adb logcat -s WAYLO_VERIFY:D | grep -E "WRONG_LOCATION|WRONG_LOCATION_SPOKEN"
```

---

## BUG 2 — "advanceFrom(2): verified, advancing to step 4" — step 3 skipped?

### Root-cause analysis (before any code change)

Traced every path that can advance `currentIndex`:

- `advanceFrom(index)` — the **only** function that starts the next step from
  a verification signal (`onWindowStateChanged`, `checkTapInAppEvidence`,
  `pollTextInput`, `onTextChanged`, `onUserTappedTarget` all call *only* this).
  Its body unconditionally calls `executeStep(index + 1)` — always exactly one
  array position forward. There is no branch, no computed offset, nothing that
  could skip an array position from this function.
- `checkLookaheadSkip()` — the *only* mechanism in the file that can jump more
  than one array position (`executeStep(targetIndex)` directly). It has its
  own, completely distinct log line format: `"STEP_SKIP: step ${index + 1}...
  jumping to step ${targetIndex + 1}..."`. The reported log line
  (`"advanceFrom(2): verified, advancing to step 4"`) does not match that
  format — it can only have come from `advanceFrom()`, meaning
  `checkLookaheadSkip` was **not** involved in this specific event. **Rules
  out (a).**
- `tryVisionFallback`'s `NewSteps` case replaces the remaining plan and
  re-runs the *same* index — not relevant to a forward skip.

So mechanically: `executeStep(3)` is called (0-based array index 3), one
position after `executeStep(2)` (0-based array index 2, the step that was
just verified). **The array walk is sequential; no step was skipped in
execution.**

The actual bug is in the **log line's own wording**, and it is exactly what
misled the report. The old line:

```kotlin
Log.e(TAG, "advanceFrom($index): verified, advancing to step ${index + 2}.")
```

prints a **raw 0-based array index** (`$index`, e.g. `2`) immediately next to
a **1-based step number** (`${index + 2}`, e.g. `4`) with no label
distinguishing the two conventions — and `index + 2` is a genuinely unusual
computation nowhere else in this file (every other step-related log line uses
`${index + 1}` to mean "this index's own 1-based number", e.g. `STEP_SKIP`,
`STEP_START`). Reading "`advanceFrom(2)`... advancing to step 4" naturally
reads as "step 2 finished, now going to step 4" — which looks like step 3 was
skipped. The correct reading is: array index 2 **is** 1-based step 3 (the step
that was just verified/completed), and it's advancing to array index 3 = step
4 — i.e., **step 3 is the step this very log line reports as just having
finished**, not a step that got skipped.

**Conclusion: (b) — but a display/logging inconsistency, not a real
index-vs-array-position bug in the advancement logic itself.** No plan-gap
issue either (ruling out (c) for this specific event) — `steps[index+1]` is
always the literal next array element, independent of whatever the backend's
own `stepNumber` field says for each step.

### Fix (minimal, log-clarity only — zero behavior change)

`app/src/main/java/com/waylo/guidance/GuidanceEngine.kt`:

1. New pure, unit-tested helper:
   ```kotlin
   internal fun stepDisplayNumber(arrayIndex: Int): Int = arrayIndex + 1
   ```
2. `advanceFrom()`'s log line rewritten to spell out both the array index and
   the 1-based display number for *both* steps involved, explicitly labeled:
   ```kotlin
   Log.e(
       TAG,
       "advanceFrom: step ${stepDisplayNumber(index)} (array index $index) verified, " +
           "advancing to step ${stepDisplayNumber(index + 1)} (array index ${index + 1})."
   )
   ```
   For the reported event this now reads: `"advanceFrom: step 3 (array index 2)
   verified, advancing to step 4 (array index 3)."` — unambiguous, and
   impossible to misread as a skip.

`executeStep(index + 1)` itself was **not changed** — the advancement logic
was already correct; only the log text changed.

### Test added

`app/src/test/java/com/waylo/guidance/GuidanceEngineStepNumberingTest.kt` (new
file, 4 tests) locks in the numbering contract:
- array index 0 → step 1
- array index 2 → step 3 (the exact value from the real capture)
- the array-index-2 → array-index-3 pair maps to step 3 → step 4 with a gap of
  exactly 1
- for every array index 0..20, advancing by one array position always
  advances the display number by exactly one (the general regression guard —
  if this ever fails, something really did break the sequential walk).

`GuidanceEngine`'s core advancement functions (`advanceFrom`, `executeStep`)
remain untestable in a plain JVM test without Robolectric (they're entangled
with `WayloGuidanceService`/`OverlayManager`/live coroutine scopes, same as
every other orchestration function in this file) — consistent with the
existing test strategy in this codebase, only the pure numbering contract is
unit-tested directly.

---

## Files changed

| File | Change |
|---|---|
| `app/src/main/java/com/waylo/guidance/GuidanceEngine.kt` | Bug 1: `wrongAppStreak` debounce state + `WRONG_APP_CONFIRM_SCANS` constant, `locateStep()`'s wrong-app branch restructured (immediate hide, debounced speak), `handleWrongApp()` → `speakWrongAppNudge()` with new `WRONG_LOCATION_SPOKEN` log. Bug 2: new `stepDisplayNumber()` helper, `advanceFrom()`'s log line rewritten. |
| `app/src/test/java/com/waylo/guidance/GuidanceEngineStepNumberingTest.kt` | New — 4 tests for `stepDisplayNumber()`. |

No other files touched. No backend/EC2 code touched. Nothing pushed.

## Verification

`./gradlew compileDebugKotlin compileDebugUnitTestKotlin testDebugUnitTest` —
BUILD SUCCESSFUL, all 51 tests pass (0 failures, 0 errors), including the 4
new `GuidanceEngineStepNumberingTest` tests and all pre-existing suites
(`GuidanceEngineWrongAppGuardTest` unaffected — it only exercises the pure
`isInExpectedApp()` core, whose logic was not changed this session).

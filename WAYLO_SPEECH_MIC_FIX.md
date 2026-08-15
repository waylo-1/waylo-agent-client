# Speech field, action-step repetition, and mic overlay fixes

Android-only, nothing pushed, backend untouched.

## BUG 1 — App speaks the wrong field (root cause, before code)

`speakTargetDescription()` built its spoken sentence from a field-priority
chain: `visionDescription` → `Step.findDescription` → `Step.visualDescription`
→ the matched element's own label — with `Step.instruction` **never
consulted at all**. Since `visionDescription`/`elementLabel` are usually
absent (only populated from specific fallback paths) and `Step.findDescription`
is *always* present and non-blank on a real backend plan, the `when` chain's
second branch (`step.findDescription.isNotBlank() -> ...`) won this on
essentially every call — hence `SPOKE_DESCRIPTION | whichFieldUsed=findDescription`
on every single step in the capture. `findDescription` is written for
`ElementFinder`/OCR scoring (hedged, multi-candidate search text — "or",
"maybe", alternate wording so the matcher has more to score against), never
for a human ear; `Step.instruction` is the short, plan-authored, user-facing
sentence. The function simply never looked at the right field.

### Fix

`speakTargetDescription()` no longer has a field-priority chain at all — it
calls a new, tiny, pure function:

```kotlin
internal fun targetDescriptionMessage(step: Step): String = step.instruction
```

and speaks exactly that, unconditionally. The `visionDescription`/
`elementLabel`/`verb`/`queued` parameters are gone from its signature —
there is no longer any field to choose between. The two remaining call
sites (`tryVisionFallback`'s `Described` branch, `speakCantReachTarget`'s
fallback branch) were updated to the new signature — neither passes
Gemini Vision's own description text anymore, since that's exactly the kind
of "not the instruction field" text this fix eliminates.

A **third** call site — inside `onTargetLocated()`, speaking with `verb="Tap"`
right after the dot was placed — was **removed entirely**, not just
updated. Once every code path is forced to speak `instruction` and nothing
else, that call would always be a byte-for-byte repeat of the instruction
`executeStep()` already spoke a moment earlier (queued right behind it) —
it could never again add information, so keeping it as a guaranteed-redundant
call made no sense. This also directly helps BUG 2.

The `WAYLO_VERIFY` log is unchanged in shape, only in content:
`SPOKE_DESCRIPTION | stepIndex=<int> | whichFieldUsed=instruction | screenRegionUsed=false | fallbackHintUsed=false`
— `whichFieldUsed` is now a constant `instruction` string rather than a
computed value, since there's only one field left to report.

## BUG 2 — Spoken instruction repeats / talks over the user during action steps (root cause, before code)

Two separate repetition sources, both now closed:

1. **The (now-removed) `onTargetLocated()` "Tap X" call** — as above, this
   fired once per step regardless of step type, immediately re-speaking
   what had just been said. Removing it (BUG 1's fix) already eliminates
   this for every step type, not just TEXT_INPUT/app-open/swipe.
2. **`speakTargetDescription()`'s not-found nudge** — throttled to at most
   once per 15s (`PATIENCE_MS`, from a previous session's fix) but with no
   step-type awareness at all — it would keep firing every ~15–30s
   indefinitely on ANY step still searching, including a TEXT_INPUT step
   where the user is actively typing, or a NAVIGATION/app-open step where
   they're actively swiping through their home screen or typing an app name
   into the launcher's search box.

### Fix

New predicate, `isActionStepNoRepeat`, suppresses this nudge entirely (not
just throttles it further) whenever the step is `TEXT_INPUT`, any
`AppLaunch`-verified step (step 0, `APP_ICON`, `NAVIGATION` — i.e. "the
swipe/open steps"), or the instruction implies a scroll/swipe gesture
(`impliedScrollDirection(step) != null`):

```kotlin
internal fun isActionStepNoRepeat(isTextInput: Boolean, isAppLaunch: Boolean, impliesScroll: Boolean): Boolean =
    isTextInput || isAppLaunch || impliesScroll
```

(Takes plain booleans rather than the `Verification` sealed class directly —
`Verification` is `private`, and an `internal` function can't expose a
private type in its signature; same pattern already used for
`shouldContinuePeriodicRescan` avoiding `StepPhase` for the same reason.)

Wired into `speakTargetDescription()` as the first check, ahead of the
15s throttle — so for these step types, the nudge is silent from the very
first patient-window escalation, not just after the 15s floor. The
one-shot `schedulePatienceCheck()` repeat (re-speaking the instruction once,
15s after the dot is placed, only if the user hasn't acted at all) is
**unchanged** — it already had a correct once-per-step guard
(`hasRepeatedThisStep`) from before this session and isn't part of the
reported repetition.

`speakCantReachTarget()`'s "Please open `<appName>`" branch is **deliberately
not** gated by `isActionStepNoRepeat` (it would always evaluate true for
that branch, since it only ever fires on `AppLaunch` steps, defeating its
own purpose) — it keeps its own 15s throttle, and is additionally suppressed
while `imeLikelyVisible` (see BUG 3) so it doesn't interrupt someone typing
an app name into a launcher search box.

## BUG 3 — Mic overlay positioned over the keyboard, never dismisses (root cause, before code)

Traced `OverlayManager`/`CorrectionFlow`/`WayloGuidanceService`:

- The mic button (`OverlayManager.showMicButton`) is shown once, in
  `WayloGuidanceService.onCreate()`, and — by original design — "stays up
  for the service's whole lifetime, not just during an active guidance
  run." It sits at a fixed `Gravity.BOTTOM or Gravity.END` position with a
  24dp margin, and unlike the dot/arrow, it is **touchable** (no
  `FLAG_NOT_TOUCHABLE`) — deliberately, since it needs to receive taps.
  Bottom-right is exactly where an on-screen keyboard renders, so it can sit
  directly on top of (or immediately adjacent to) real keyboard keys.
- `CorrectionFlow.start()` has **no internal auto-repeat** — it's a no-op if
  already in progress, and nothing times out and re-triggers it. So
  "repeatedly prompts" cannot originate from `CorrectionFlow` itself; it can
  only mean `start()` is being **called repeatedly** — via the touchable mic
  button being repeatedly (likely accidentally) tapped while the user is
  trying to type nearby/underneath it, or via repeated volume-down double-
  presses. Either way, every successful call speaks "What went wrong?" from
  scratch, since there was no guard against running the flow while the user
  is mid-typing.
- `hideMicButton()` existed but its only caller anywhere in the codebase was
  `OverlayManager.destroy()`, itself only called from
  `WayloGuidanceService.onDestroy()` (full service shutdown). **Neither
  `GuidanceEngine.taskComplete()` nor `GuidanceEngine.stop()` ever hid it** —
  confirmed by reading both bodies before making any change. So the mic
  button had no teardown tied to a guidance session ending at all, matching
  the reported "does not disappear on task completion."
- No accessibility-window-type check (`AccessibilityWindowInfo`/
  `TYPE_INPUT_METHOD`) exists anywhere in this app — "is an IME visible" has
  no direct signal to read. The closest existing thing is
  `isTransientForegroundPackage()` (from a previous session), which
  deliberately **discards** IME-package events rather than recording them,
  precisely so they don't corrupt `lastKnownForegroundPackage` — meaning
  that field can never be used to detect "IME is up" either, by design.

### Fix

**Teardown on task completion** — `taskComplete()` now calls
`OverlayManager.hideMicButton()` in the same block that hides the dot/arrow
and speaks "All done! Task complete.". This is a full, permanent teardown
for that guidance run (mirrors the dot/arrow, which also aren't
automatically re-shown after completion) — the mic becomes guidance-run-
scoped by this fix rather than service-lifetime-scoped. Re-showing it
automatically for a subsequent task is a follow-up product decision, not
requested here, and not done.

**IME-visibility signal** — new `imeLikelyVisible` state, updated in
`onWindowStateChanged`/`onContentChanged` right where those functions
already inspect the event's package: set `true` when the (otherwise-ignored)
package matches a new, narrower `isImePackage()` check (a subset of the
existing transient-package list — Gboard/SwiftKey/Samsung-keyboard plus an
`"inputmethod"` substring pattern for other OEMs); set `false` the moment
any trusted, non-transient app package event fires. Best-effort only (no
real window-type API exists to check) — acceptable here since it only gates
speech/mic suppression, never a placement-safety decision.

**Suppress the mic overlay itself while typing** — `OverlayManager` gained
`setMicButtonSuppressed(Boolean)`, which hides the button (reusing
`hideMicButton()`) or re-shows it using the **same tap handler** it was
first shown with (remembered in a new `micButtonOnTap` field, so the caller
doesn't need to reconstruct the `{ CorrectionFlow.start() }` lambda every
time). `GuidanceEngine.updateMicButtonVisibility()` calls this whenever the
step type changes (`executeStep()`) or the IME signal changes
(`onWindowStateChanged`/`onContentChanged`), suppressing whenever
`imeLikelyVisible` or the current step is `TEXT_INPUT`. Guarded by
`isRunning` internally so it can never fight with `taskComplete()`'s
permanent teardown — `onWindowStateChanged`/`onContentChanged` fire
constantly, for every app on the device, not just Waylo's, so without this
guard the very next unrelated window event after task completion would
immediately re-show the button `setMicButtonSuppressed(false)` would have
called.

**Suppress the correction flow itself, not just the button** — new
`GuidanceEngine.shouldSuppressCorrectionPrompt()` (`imeLikelyVisible` OR an
active `TEXT_INPUT` step), checked at the top of `CorrectionFlow.start()`.
This is the fix for "repeatedly prompts 'what went wrong'": even if a tap
still somehow lands on the mic button (or the volume-down double-press
fires, which works independent of the button's visibility), the flow now
refuses to start and never speaks the prompt while the user is typing.

## Files changed

| File | Change |
|---|---|
| `app/src/main/java/com/waylo/guidance/GuidanceEngine.kt` | BUG 1: `speakTargetDescription()` rewritten around new `targetDescriptionMessage()`; removed the on-placement re-announcement from `onTargetLocated()`; updated `tryVisionFallback()`'s call site. BUG 2: new `isActionStepNoRepeat()` wired into `speakTargetDescription()`. BUG 3: new `imeLikelyVisible` state + `isImePackage()`/`IME_PACKAGES`/`IME_PACKAGE_PATTERN`, `updateMicButtonVisibility()`, `shouldSuppressCorrectionPrompt()`; wired into `executeStep()`, `onWindowStateChanged()`, `onContentChanged()`, `taskComplete()`. |
| `app/src/main/java/com/waylo/overlay/OverlayManager.kt` | New `micButtonOnTap` field (remembered from `showMicButton()`) and `setMicButtonSuppressed(Boolean)`. |
| `app/src/main/java/com/waylo/correction/CorrectionFlow.kt` | `start()` now checks `GuidanceEngine.shouldSuppressCorrectionPrompt()` before doing anything. |
| `app/src/test/java/com/waylo/guidance/GuidanceEngineSpeechMicTest.kt` | New — 11 tests: `targetDescriptionMessage()` always returns `instruction`, never `findDescription` (the specific test required by this task, including a case with `findDescription` full of "or"/"maybe"/"sideways" wording, matching the reported symptom exactly); `isActionStepNoRepeat()` combinations; `isImePackage()` positive/negative/OEM-pattern cases. |

## Confirmation the app now speaks instruction only

`targetDescriptionMessage(step) = step.instruction` — there is no branch,
no fallback, no other field reachable from this function at all anymore.
Grepped every remaining `speakTargetDescription`/`speak(`/`speakQueued(`
call site in `GuidanceEngine.kt` after the change (see command below) —
the only two calls to `speakTargetDescription` both use the new
`(step, stepIndex = index)` signature; no call site anywhere passes a
`visionDescription`/`elementLabel` argument (the parameters no longer
exist to pass). The one still-dynamic, non-instruction spoken string in
the file — `speakCantReachTarget()`'s `"Please open $appName."` — is not a
per-step field selection at all (it's a plan-level app name, used only when
`Step.instruction`-based description would be less helpful than naming the
app directly) and was out of this bug's stated scope (`findDescription`/
`visualDescription`/`fallbackHint`, not `appName`).

```
grep -n "speakTargetDescription\|whichFieldUsed" app/src/main/java/com/waylo/guidance/GuidanceEngine.kt
```

## Verification

`./gradlew compileDebugKotlin compileDebugUnitTestKotlin testDebugUnitTest` —
BUILD SUCCESSFUL, all 85 tests pass (0 failures, 0 errors), including the
11 new tests above. No existing test needed updating (verified no test
referenced the removed `speakTargetDescription` parameters before editing).

## What to watch on the next on-device run

```
# BUG 1 — should now show whichFieldUsed=instruction on every line, never findDescription
adb logcat -s WAYLO_VERIFY:D | grep "SPOKE_DESCRIPTION"

# BUG 2 — confirm suppression is firing for TEXT_INPUT/app-open/swipe steps
adb logcat -s WAYLO_VERIFY:D | grep "SPOKE_DESCRIPTION_SUPPRESSED"

# BUG 3 — confirm the mic button teardown fires alongside "Task complete"
adb logcat -s WAYLO_DOT:E | grep -E "hideMicButton|Task complete"
```

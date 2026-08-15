# Periodic rescan + nudge throttle fix

Android-only, nothing pushed, backend/EC2 untouched.

## Root causes (before any code)

### BUG A — target not found until a manual screen-change event

`GuidanceEngine.locateStep()`'s LOCATING-phase loop was **not** purely
event-driven — it already had a fallback: `waitForRescanTrigger()` returns
either when an accessibility event flips `locateRescanRequested`, or
unconditionally after `RESCAN_POLL_MS` (1500ms), whichever comes first. So a
rescan should already have happened within ~1.5s even with zero events.

The real problem is that **1.5s is on the slow side for something the user
is actively watching**, and it's the *only* mechanism — there's no dedicated,
independently-cadenced polling loop; it's a shared fallback baked into the
same wait function every other part of the loop (deadline checks, wrong-app
handling, escalation) also passes through. A real capture showed the target
sitting confidently findable (score 130, an easy win — well above the 35/10
floor) but the dot didn't appear until the user's manual scroll fired a
`TYPE_WINDOW_CONTENT_CHANGED` event and woke the loop early. Whether that
capture's actual gap before the scroll was longer than 1.5s (a genuinely
slow poll) or the user's perception made ~1.5s feel like "the app is stuck,"
the fix requested — an explicit, tighter, independently-observable periodic
rescan — directly addresses both: it's faster (900ms) and it's now a named,
loggable mechanism in its own right instead of an implicit side effect of a
generic wait helper.

### BUG B — nudge speech repeats too often

Traced every place that speaks a "target not found" description/hint
(`speakTargetDescription()`'s `"Look for..."` path, and the "Please open X"
path in `speakCantReachTarget()`, both introduced in the previous session).
Both are called from `locateStep()`'s deadline-escalation block, which runs
— and re-speaks — every time `deadline` is reached, and `deadline` resets to
`now + timeoutMs` after every escalation. `timeoutMs` is
`LOCATE_TIMEOUT_MS` = 30s normally, but only `IMAGE_ONLY_LOCATE_TIMEOUT_MS` =
**6s** for image-only targets (round profile pictures, avatar icons, etc. —
see `looksLikeImageOnlyTarget`). For those steps, the nudge could speak again
every 6 seconds indefinitely while the user was still mid-action — exactly
the reported "repeats over and over" symptom. Nothing previously
distinguished "keep escalating the *search* (partial-match, vision retry)"
from "keep re-*speaking* the same hint" — they were coupled to the same
timer.

## Fixes

### BUG A: `periodicRescan()` — `app/src/main/java/com/waylo/guidance/GuidanceEngine.kt`

A new coroutine, launched from `executeStep()` on the same `stepScope`
(tied to `stepJob`) as `locateStep()` itself — so it starts the moment a
step begins waiting for its target, and `executeStep()`'s existing
`stepJob?.cancel()` (already run before every new step's coroutines are
launched, unmodified) stops it automatically the instant a step
starts/advances. **Never stacks**: there is exactly one `stepJob` at a time,
and both `locateStep()` and `periodicRescan()` live on it — cancelling the
job cancels both.

Every `PERIODIC_RESCAN_MS` (see interval choice below), it calls
`locateOnDevice(index, step, pkg)` — **the exact same function**
`locateStep()` itself calls, so no scoring/matching logic is duplicated —
and logs the result:

```
PERIODIC_RESCAN | stepIndex=<int> | found=<true/false> | topScore=<float>
```

**It does not call `onTargetLocated()` itself.** `locateStep()`'s own loop
remains the single path that ever places the dot. If `periodicRescan()`
finds a confident result, it only sets `locateRescanRequested = true` — the
exact same flag `waitForRescanTrigger()` already polls every 150ms — and
then stops itself. `locateStep()`'s loop wakes within ~150ms, re-runs its
own `locateOnDevice()` call, and places the dot through its own existing,
unmodified code path. This means the two coroutines can never race into a
double placement (double dot-show, double `schedulePatienceCheck`, double
`revalidatePlacement` launch): only one function anywhere in the file ever
calls `onTargetLocated()`, and it's always called from the same place.

**Stops as soon as the element is found and the dot is placed**: its loop
condition is `shouldContinuePeriodicRescan(isRunning, currentIndex == index,
currentStepPhase == StepPhase.LOCATING)` — a pure, unit-tested predicate
(see Tests below) — so it exits on its own the moment the phase leaves
LOCATING (found), the step changes (advance/lookahead-skip), or guidance
stops, without waiting for cancellation to catch up.

Only launched for steps that actually search for an element — `isNavigationStep`
steps (which skip `locateStep()` entirely, per an earlier session's fix)
correctly get no `periodicRescan()` either, since both are launched from the
same post-navigation-check code path in `executeStep()`.

### Interval chosen: 900ms

Requested band was 800ms–1s. Picked the midpoint:
- Fast enough that a user watching the screen after their own action (e.g. a
  list finishing a scroll/load) sees the dot appear within under a second,
  not a perceptible stall.
- Meaningfully tighter than the pre-existing 1500ms fallback
  (`RESCAN_POLL_MS`, left unchanged — it remains a harmless outer backstop;
  in practice `locateRescanRequested` now gets set by `periodicRescan()`
  well before its 1500ms timeout would ever fire on its own).
  Not tighter than ~800ms: each tick is a full accessibility-tree walk
  (`ElementFinder.findElement`, potentially over every node in a busy
  screen like a YouTube history list) — going much faster buys negligible
  extra responsiveness (a user can't perceive the difference between "found
  within 500ms" and "found within 900ms") while proportionally increasing
  CPU/battery cost of scanning a screen that may not have changed.

### BUG B: nudge throttle — same file

New per-step state `lastNotFoundNudgeAt: Long` (0L = "not yet spoken this
step", reset in `executeStep()`), gating BOTH `speakTargetDescription()`'s
`"Look for..."` path and `speakCantReachTarget()`'s "Please open X" path
(the `"Tap..."` on-placement announcement from `onTargetLocated()` is
**never** throttled by this — it's already a strict one-shot, only ever
called once per step). Gate is `notFoundNudgeAllowed()`:

```kotlin
private fun notFoundNudgeAllowed(): Boolean {
    val now = SystemClock.elapsedRealtime()
    if (!shouldAllowNotFoundNudge(now, lastNotFoundNudgeAt, PATIENCE_MS)) return false
    lastNotFoundNudgeAt = now
    return true
}
```

`shouldAllowNotFoundNudge(now, lastNudgeAt, minInterval) = now - lastNudgeAt
>= minInterval` is the pure, unit-tested core. **Reuses `PATIENCE_MS`
(15,000ms)** — the existing "gentle repeat" nudge timer already used for
re-speaking the instruction while a placed dot sits unclicked — rather than
introducing a near-duplicate constant, per the task's "use/raise the
existing nudge timer." The *search* itself (`tryPartialMatchAcceptance`,
`tryVisionFallback`) is untouched and keeps escalating on its own existing
cadence (still every `timeoutMs` = 6s/30s) — only the **speech** is
separately throttled to at most once per 15s, so escalation keeps trying
harder to find the target without the user hearing a new "look for X" every
single cycle.

Net effect for the reported image-only case (6s escalation cycle, 15s
speech floor): 1st escalation (t=6s) speaks; 2nd (t=12s, only 6s since last
nudge) suppressed; 3rd (t=18s, 12s since) suppressed; 4th (t=24s, 18s since)
speaks again. Roughly one nudge every 18–24s in the worst case — never more
often than the requested ~15s floor. Normal (non-image) targets already
escalate every 30s, comfortably past the 15s floor on their own, so they're
unaffected.

A suppressed nudge still logs (debug-only, not spoken):
```
SPOKE_DESCRIPTION_SUPPRESSED | stepIndex=<int> | sinceLastNudgeMs=<long>
```

### Confirmed: periodic rescan does NOT cause repeated speech

`periodicRescan()` never calls any speech function — it only sets
`locateRescanRequested` and returns. All "Tap X" / "Look for X" / "Please
open X" speech happens exclusively inside `onTargetLocated()` (called only
by `locateStep()`'s own loop, once) and `locateStep()`'s deadline-escalation
block (now throttled as above). BUG A's fix and BUG B's fix are independent
and don't interact — the rescan can fire every 900ms indefinitely without
producing any additional speech.

## Files changed

| File | Change |
|---|---|
| `app/src/main/java/com/waylo/guidance/GuidanceEngine.kt` | BUG A: new `periodicRescan()` + pure `shouldContinuePeriodicRescan()`, launched from `executeStep()` alongside `locateStep()` on the same `stepScope`; new `PERIODIC_RESCAN_MS=900L` constant. BUG B: new `lastNotFoundNudgeAt` state, `notFoundNudgeAllowed()` + pure `shouldAllowNotFoundNudge()`, wired into `speakTargetDescription()`'s `"Look for"` path and `speakCantReachTarget()`'s "Please open" path; `PATIENCE_MS`'s doc updated to reflect its reuse. |
| `app/src/test/java/com/waylo/guidance/GuidanceEnginePeriodicRescanTest.kt` | New — 5 tests for `shouldContinuePeriodicRescan()` (start/stop/no-stack contract). |
| `app/src/test/java/com/waylo/guidance/GuidanceEngineNotFoundNudgeTest.kt` | New — 5 tests for `shouldAllowNotFoundNudge()` (throttle interval math, including the exact boundary). |

## Verification

`./gradlew compileDebugKotlin compileDebugUnitTestKotlin testDebugUnitTest` —
BUILD SUCCESSFUL, all 61 tests pass (0 failures, 0 errors), including the 10
new tests above. No existing test needed updating.

## What to watch on the next on-device run

```
# Confirm the periodic rescan is running and how often it finds the target
adb logcat -s WAYLO_VERIFY:D | grep "PERIODIC_RESCAN"

# Confirm the nudge throttle is suppressing repeats (should see this instead
# of a new spoken description on every escalation cycle, for image-only
# targets especially)
adb logcat -s WAYLO_VERIFY:D | grep "SPOKE_DESCRIPTION"
```

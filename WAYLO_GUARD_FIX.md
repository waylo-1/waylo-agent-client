# Wrong-app guard no longer blocks confident element placement

Android-only, nothing pushed, backend/EC2 untouched.

## Root cause (before any code)

Traced `locateStep()`'s per-scan loop (the LOCATING-phase search) and
`revalidatePlacement()`'s loop (the WAITING_FOR_ACTION re-check). Both had
the **same structural bug**: the wrong-app package check ran *before* the
element search, and short-circuited (`continue`/park) the moment it failed —
so a confident element match was never even attempted, let alone placed,
while the package reading was wrong.

The evidence matches exactly: at 17:50:36 the accessibility tree found
"History" at score=130 (gap=35, `isConfident()`=true — comfortably clears
the 35/10 floor). But `locateOnDevice()` — the function that actually runs
that search — was never reached for 8 seconds, because
`if (!isInExpectedApp(index))` short-circuited the loop on every single
iteration first. And `isInExpectedApp()` was reading `lastKnownForegroundPackage`
as `com.oplus.screenrecorder` / `com.android.systemui` instead of
`com.google.android.youtube` — both transient system-overlay packages, not
genuine navigation away from the app.

Two independent causes compounded into this 8-second block:

1. **Priority inversion**: the package check gated the search entirely,
   instead of being a fallback signal consulted only when the search itself
   comes up empty. A package mismatch — even a real one — says nothing about
   whether the *current step's own target* is confidently on screen; a
   confident tree/OCR/YOLO match is direct, first-party evidence of "right
   place," strictly stronger than an indirect signal like the foreground
   package name.
2. **No filtering at the source**: `onWindowStateChanged`/`onContentChanged`
   overwrite `lastKnownForegroundPackage` unconditionally on *every*
   `TYPE_WINDOW_STATE_CHANGED`/`TYPE_WINDOW_CONTENT_CHANGED` event, from *any*
   package (`WayloAccessibilityService` watches "ALL packages" by design).
   A screen-recorder toggle notification, the notification shade, a
   permission dialog, or an IME popping up all fire these events and briefly
   become "the foreground package" as far as `GuidanceEngine` is concerned,
   even though the user never left the target app.

## Fix

### 1 & 2 — element confidence now takes priority over the package check

**`locateStep()`** (`GuidanceEngine.kt`): reordered so `locateOnDevice()` runs
*first*, unconditionally, every scan. If it returns a confident result, the
dot is placed immediately and the function returns — the wrong-app check is
never even reached for that scan. Only when `locateOnDevice()` returns `null`
(no confident match this scan) does the loop fall through to the wrong-app
check, now purely as a fallback signal for "why isn't anything being found."

**`revalidatePlacement()`** (`GuidanceEngine.kt`): same reorder. Screen-aware
step skipping (`checkLookaheadSkip`) keeps its pre-existing, deliberate
"runs every tick regardless of the current target's status" behavior
(unchanged — see its own comment, preserved verbatim) and now *also* runs
independent of the package check, for the same reasoning as the current
target's own recheck: it's a confidence-gated match search too. The dot is
only parked on a package mismatch once *neither* the current target *nor* a
lookahead target produced a confident match that tick.

`checkLookaheadSkip` inside `locateStep()`'s LOCATING phase was deliberately
**left unchanged** (still gated behind `isInExpectedApp()` passing first) —
that's a different, riskier proposition than the current step's own target:
it searches for *other, later* steps' descriptions, and running that search
against what might genuinely be a different app's tree (not just a
transiently-misread package) is exactly the cross-app false-positive
`isInExpectedApp()` exists to prevent. This fix's explicit scope was "the
current step's target element," so lookahead's own gating in `locateStep()`
was not touched.

When a confident match is found *despite* a package mismatch, both
functions log:

```
PLACEMENT_OVERRIDES_PACKAGE | stepIndex=<int> | score=<float> | currentPackage=<pkg> | expectedPackage=<pkg>
```

### 3 — transient/overlay packages never corrupt the tracked foreground package

`onWindowStateChanged()`/`onContentChanged()` now check
`isTransientForegroundPackage(pkg)` **before** doing anything else,
including before `lastKnownForegroundPackage = pkg`. If the event's package
is transient, the entire event is treated as a no-op for guidance purposes —
`lastKnownForegroundPackage` keeps its previous (real) value, and no
verification/rescan logic runs for that event at all. Logged:

```
TRANSIENT_PACKAGE_IGNORED | source=<onWindowStateChanged|onContentChanged> | package=<pkg> | keptForeground=<pkg>
```

**Transient packages ignored** (`GuidanceEngine.TRANSIENT_PACKAGES` — exact
match — plus `TRANSIENT_PACKAGE_PATTERNS` — substring, catches OEM variants):

| Exact match | Why |
|---|---|
| `com.android.systemui` | notification shade, quick settings, recents, volume panel, system dialogs |
| `com.oplus.screenrecorder` | the exact package from the reported run |
| `com.google.android.permissioncontroller` | Android runtime-permission dialogs |
| `com.android.permissioncontroller` | AOSP naming variant on some OS versions |
| `com.google.android.inputmethod.latin` | Gboard |
| `com.samsung.android.honeyboard` | Samsung's keyboard |
| `com.touchtype.swiftkey` | SwiftKey |

| Substring pattern (case-insensitive) | Catches |
|---|---|
| `screenrecord` | any OEM's screen-recorder package containing "screenrecord" or "screenrecorder" (Samsung, MIUI, etc. each ship their own under a different exact package) |
| `inputmethod` | IME packages not in the exact list above |

Not an exhaustive enumeration of every OEM's package names — the task asked
for "at minimum" this set; the pattern-based fallback is the pragmatic way
to cover unlisted OEM variants without hardcoding every manufacturer's exact
package string (mirrors how `KNOWN_PACKAGES`/`LAUNCHER_PACKAGES` already use
simple heuristics elsewhere in this file rather than querying
`PackageManager`/`InputMethodManager` directly).

### 4 — no reintroduction of the deleted "wrong place" phrase

Confirmed: no `speak()`/`speakQueued()` call was touched or added in this
fix. The wrong-app guard's only remaining user-facing behavior is silence
(dot hidden, `WRONG_LOCATION_SUPPRESSED` logged) — unchanged from the
previous session's fix — now simply reached less often, since it's a
fallback rather than a gate.

## New priority order

1. **Try to locate the current step's target** (`locateOnDevice`) —
   unconditionally, every scan, regardless of the foreground-package
   reading.
2. **If confident** (clears the existing floor/gap — `isConfident()`,
   unchanged): place the dot immediately. Log `PLACEMENT_OVERRIDES_PACKAGE`
   if the package check would have failed (informational only — never
   blocks).
3. **If not confident**: consult the foreground-package check
   (`isInExpectedApp`) as a *fallback* signal — park/hide the dot and wait
   silently (never spoken) if it indicates a genuine wrong screen; otherwise
   continue the normal not-found escalation (lookahead-skip → partial-match →
   vision → description nudge, all pre-existing and unchanged).
4. **Foreground-package tracking itself** now filters out known/likely
   transient overlay packages *before* step 3 ever sees them, so a
   screen-recorder/systemui/IME/permission-dialog blip can't trigger step 3
   at all in the first place.

## Files changed

| File | Change |
|---|---|
| `app/src/main/java/com/waylo/guidance/GuidanceEngine.kt` | Reordered `locateStep()`'s and `revalidatePlacement()`'s scan loops so element confidence is checked before the wrong-app package guard. Added `TRANSIENT_PACKAGES`/`TRANSIENT_PACKAGE_PATTERNS`/`isTransientForegroundPackage()`, wired into `onWindowStateChanged()`/`onContentChanged()`. Added `isPlacementOverridingPackageMismatch()`, wired into both fixed loops' `PLACEMENT_OVERRIDES_PACKAGE` logging. |
| `app/src/test/java/com/waylo/guidance/GuidanceEngineWrongAppOverrideTest.kt` | New — 13 tests: reproduces the exact reported package mismatch against `isInExpectedApp()` (proving the guard's own detection still works correctly as a fallback signal), confirms `isPlacementOverridingPackageMismatch()` correctly classifies "confident match + wrong/transient package" as an override (not a block), and covers `isTransientForegroundPackage()` for the exact reported package, OEM substring variants, IME packages, permission dialogs, and negative cases (real apps not flagged). |

## Verification

`./gradlew compileDebugKotlin compileDebugUnitTestKotlin testDebugUnitTest` —
BUILD SUCCESSFUL, all 74 tests pass (0 failures, 0 errors), including the 13
new tests above. No existing test needed updating.

## What to watch on the next on-device run

```
# Confirm placements are no longer blocked by a package mismatch
adb logcat -s WAYLO_VERIFY:D | grep "PLACEMENT_OVERRIDES_PACKAGE"

# Confirm transient overlays are being filtered at the source
adb logcat -s WAYLO_VERIFY:D | grep "TRANSIENT_PACKAGE_IGNORED"

# Should now be rare/short-lived rather than firing ~20 times over 8s
adb logcat -s WAYLO_VERIFY:D | grep "WRONG_LOCATION_SUPPRESSED"
```

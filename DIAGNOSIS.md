# Regression diagnosis: commit b0ec09f (guidance pacing overhaul)

Source: `pacing_log.txt` (UTF-16LE logcat capture, one run of "how to find
youtube history" — same app-open + in-app-tap shape as "open youtube and
search for a song"). Filtered to the `WAYLO_DOT` tag (444 lines). Log line
numbers below refer to line numbers inside the raw `pacing_log.txt` file
(shown as the first number in each quoted line).

## Bug 1 — instruction speech is flushed by the "found" prompt

### Evidence

Every `speak()` call in `GuidanceEngine.kt` is preceded by an `Log.e` at the
same call site, so the log lets us reconstruct exactly what was queued to TTS
and when, even though `Speaker.kt` itself never logged the spoken text (fixed
below).

Step 1 (home screen → YouTube), run 1:

```
3903  17:01:31.434  executeStep called for index 0: Swipe up from the bottom of the screen to see all
                     your apps, then tap the red YouTube picture button.
                     [immediately followed by speaker.speak(step.instruction)]
4149  17:01:31.476  Target located for step 1: source=accessibility confidence=80.0
                     [immediately followed by speaker.speak("Now tap the red dot.")]
```

Gap: **42 ms.**

Step 2 (profile picture), same run:

```
21187 17:02:20.579  executeStep called for index 1: Tap the profile picture at the top right corner...
21230 17:02:20.594  Target located for step 2: source=accessibility confidence=75.0
```

Gap: **15 ms.**

Same pattern repeats in the second run in the file (step 1: 28 ms gap at
124484→124632; step 2: 77 ms gap at 134154→134277). Even the slowest instance
in the log (step 4, index 3, second run) is only 764 ms:

```
167073 17:06:47.873  executeStep called for index 3: Tap the History picture button in the Settings menu.
169265 17:06:48.637  Target located for step 4: source=accessibility confidence=100.0
```

### Root cause

`Speaker.speak()` (`voice/Speaker.kt`) always calls
`tts.speak(text, TextToSpeech.QUEUE_FLUSH, ...)`. `QUEUE_FLUSH` cancels
whatever is currently playing (even mid-utterance) and starts the new text
immediately.

`GuidanceEngine.executeStep()` calls `speaker.speak(step.instruction)`, then
launches the locate loop. `GuidanceEngine.onTargetLocated()` — which fires
the instant the on-device pipeline finds the target, often within tens of
milliseconds for elements already on screen (as seen above) — calls
`speaker.speak("Now tap the red dot.")`. Because both calls use
`QUEUE_FLUSH`, the second call cancels the first before more than a word or
two has been spoken. This reproduces the reported symptom exactly: the user
hears almost nothing of "Swipe up from the bottom... tap the red YouTube
picture button," only "Now tap the red dot."

This is a direct, unambiguous consequence of how commit b0ec09f split
"speak the instruction" from "found → say the dot prompt" into two separate
`speak()` calls without accounting for `QUEUE_FLUSH` semantics. It is not
timing-dependent/flaky in the sense of "sometimes works" — it fires on
*every* step where the target is found before the instruction sentence
finishes playing, which for a single-sentence instruction (2-4 seconds of
speech) is nearly always, since the on-device pipeline usually resolves in
under a second.

### Fix (implemented after your confirmation)

- `onTargetLocated()` now calls `speaker.speakQueued(...)` instead of
  `speaker.speak(...)` for the found-target prompt, so it's appended to the
  TTS queue instead of flushing the in-progress instruction. Wording changed
  to "When you see the red dot, tap it." per your spec.
- Guarded with a new `hasAnnouncedFoundThisStep` flag (reset per step) so it
  can only be queued once per step — belt-and-braces on top of the fact that
  `onTargetLocated` was already structurally called at most once per step
  (see Bug 2 investigation below; no log evidence of it firing twice for one
  step).
- Added logging in `Speaker.kt` itself (`speak()`/`speakQueued()` now log the
  exact text and queue mode) so future captures show the real TTS calls
  directly instead of requiring this kind of call-site reconstruction.

## Bug 2 — dot lands on the wrong element ("erratic" placement)

### Evidence

Step 2 (`findDescription="profile picture"`, `elementType=ICON_BUTTON`),
run 1:

```
21223  Candidate: score=75 desc='Notifications' text='null' pkg='com.google.android.youtube'
21224  Candidate: score=75 desc='Search'        text='null' pkg='com.google.android.youtube'
21225  Candidate: score=75 desc='Home'          text='null' pkg='com.google.android.youtube'
21226  findElement: FOUND 'Notifications' score=75
21230  Target located for step 2: source=accessibility confidence=75.0
```

The dot is placed on the **notification bell**, not the profile picture —
and it clears the new ≥50 confidence floor doing it. Run 2 of the same task
picks the same wrong element again (line 134270, score=75, desc=
'Notifications'), so this isn't random noise, it's systematic.

The arithmetic proves why: `ElementFinder.scoreNodeWithBreakdown()` gives
**+50** to any node whose package equals `targetPackage`, **+15** if
clickable, **+10** if visible — that's 50+15+10 = **75**, with **zero**
contribution from any actual text/description/viewId match to "profile
picture" (none of "Notifications"/"Search"/"Home" contain those words). Any
clickable, visible, in-app icon gets 75 "for free."

Compare to a step where this bonus isn't corrupting the result — step 4
(`findDescription="history button"`), run 2:

```
169258  Candidate: score=100 desc='null' text='Manage all history' pkg='com.google.android.youtube'
169265  Target located for step 4: source=accessibility confidence=100.0
```

100 is still partly inflated by the same +50 (60 exact/partial text match +
50 package + wordMatch would be even higher normally — the exact 100 here is
30(partial text)+50(pkg)+10(visible)+10(wordMatch)=100 by inspection), but
the real textual signal is strong enough to win anyway. Step 2's "profile
picture" query has weaker exact-token overlap with YouTube's actual
accessibility labels (it's an icon with no matching content-description
text), so the flat +50 in-app bonus is enough to let a totally unrelated
icon win.

**Why this floor doesn't already exist:** the ≥50 confidence floor added in
b0ec09f (`ELEMENT_CONFIDENCE_FLOOR`, and `ScreenAnalysisPipeline`'s existing
`ACCESSIBILITY_CONFIDENCE=50`) is applied on every placement path
(`locateOnDevice`'s home-screen shortcut, the general pipeline call, and the
vision fallback's `Found` result trusts Gemini's own answer) — the floor
*is* being checked everywhere. The bug is that the floor is too easy to
clear once inside the target app, because `currentAppPackage` is passed as
`targetPackage` to `ElementFinder.findElement()`/`ScreenAnalysisPipeline` for
**every** step, not just the step-1 home-screen search it was designed for
(CLAUDE.md: "fixes e.g. the Play Store logo outscoring the real YouTube
icon" — a home-screen, multi-package disambiguation problem). Once we're
already inside YouTube, *every* visible interactive node shares that same
package, so the bonus provides zero discriminating signal but is large
enough alone (+50, or +75 combined with clickable/visible) to beat real but
weaker textual signal, or to clear the floor with none at all.

**Dot movement / "wanders across re-scans":** the log does *not* show
`onTargetLocated`/`showDot` firing more than once for a single step (each
step has exactly one `Target located for step N` line before its advance) —
so there's no evidence the *already-placed* dot itself glides to a new spot
mid-step. What the log does show is a large volume of duplicate, overlapping
`findElement` calls fired back-to-back within the same step's
WAITING_FOR_ACTION phase, e.g. 19 near-identical `findElement` calls for
"profile picture" within 270ms (lines 136603–136872) and a burst of ~40 for
"history button" within 15ms (lines 176322–177844). This comes from
`onContentChanged()` → `checkTapInAppEvidence()` spawning a brand-new async
`ElementFinder.findElement()` lookup on *every single* content-change event
with no debouncing; Android can fire dozens of `TYPE_WINDOW_CONTENT_CHANGED`
events per second during a scroll/transition animation. This doesn't move an
already-shown dot (confirmed: `checkTapInAppEvidence` never calls
`OverlayManager.showDot*`), but it is wasted, uncoalesced work that could
plausibly read as "erratic" behavior (CPU contention, log noise) and is
worth fixing while in this code, so it's included below.

### Gap in the evidence — flagged, not guessed around

One candidate doesn't fully add up from the log alone:

```
26718  Candidate: score=90 desc='More options' text='null' pkg='com.google.android.youtube'
```

for query "settings" (`findDescription="settings button"`). By the same
arithmetic (50 pkg + 15 clickable + 10 visible = 75), a pure affordance-only
match should score 75, not 90 — the extra 15 implies a further match
(e.g. `viewId` containing "settings" even though the visible
`contentDescription` is the generic "More options" overflow-menu label), but
`findElement`'s existing candidate logging only prints
`score`/`desc`/`text`/`pkg` — it does not print `viewId` or the per-field
score breakdown that `scoreNodeWithBreakdown()` already computes internally
(only `findOnHomeScreen()` logs that breakdown, and only at `Log.d`, which
this capture didn't retain — the whole file only contains `E/`-priority
lines, so `Log.d` calls are invisible to whatever captured this log).

**This does not block the fix above** — the general root cause (unconditional
+50 in-app package bonus) is proven independently of this one case. But per
your instruction, I'm not guessing at *this specific* number. I've added
`viewId` + full score breakdown to `findElement`'s candidate logging (and
promoted `findOnHomeScreen`'s equivalent logging to the same `Log.e` level so
it's actually captured), so a re-capture will show exactly which field gave
"More options" its extra 15 points, if it still scores anomalously after the
package-bonus fix below.

**Please re-capture a pacing log after this fix lands** if you want that
specific residual question answered — it is not required to validate the
main fix, since the dominant +50 flat bonus is what let it (and the
"Notifications"/"Search"/"Home" ties) clear the floor in the first place, and
removing it drops "More options" back down into safely-below-floor territory
regardless of the extra 15's exact source (90-50=40, still under 50).

### Fix (implemented after your confirmation)

- `GuidanceEngine.locateOnDevice()`: the general on-device pipeline call now
  only passes the target package for step index 0 (the actual home-screen
  app-icon disambiguation case); every other step passes `null`.
- `GuidanceEngine.checkTapInAppEvidence()`, `onTextChanged()`, and
  `pollTextInput()`: all three re-verification lookups now pass `null`
  instead of `currentAppPackage` — they only ever run once we're already
  confirmed inside the target app (never step 0), so the package bonus was
  always meaningless noise there.
- `ElementFinder.findElement()`: switched to the same
  `scoreNodeWithBreakdown()` used by `findOnHomeScreen()`, and now logs
  `viewId` plus the full per-field breakdown for the top 3 candidates (at
  `Log.e`, matching this capture's retained level). Removed the now-dead
  private `scoreNode(node, cleanedDescription, tokens, ...)` wrapper.
  `findOnHomeScreen()`'s candidate logging got the same `viewId`+breakdown
  treatment, promoted from `Log.d` to `Log.e`.
- `GuidanceEngine.checkTapInAppEvidence()`: added an in-flight guard
  (`tapEvidenceCheckInFlight`) so a burst of `onContentChanged` events
  coalesces into at most one outstanding async lookup instead of piling up
  dozens of concurrent, duplicate `ElementFinder.findElement()` scans.

I verified the "never move an already-placed dot unless the target genuinely
disappeared" requirement is already satisfied structurally: `OverlayManager`
is only ever asked to place/move the dot from `onTargetLocated()`, which is
called at most once per step (the locate loop `return`s immediately after
calling it, and no other path calls it for an already-`WAITING_FOR_ACTION`
step). No change was needed there — I did not find log evidence of an
already-placed dot moving, only of it being placed on the wrong element
initially, and of wasted duplicate lookups that don't touch the dot. This is
called out explicitly rather than silently assumed.

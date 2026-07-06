# Regression diagnosis 2: commit de0e02f (speech-flush + scoring fix)

Source: `pacing_log2.txt` (UTF-16LE logcat capture, same "how to find youtube
history" task, captured with the viewId+score-breakdown logging added in
de0e02f). Filtered to the `WAYLO_DOT` tag (plus two `D/Waylo` lines that
slipped through — see finding 1). Line numbers below are raw
`pacing_log2.txt` line numbers.

## Finding 1 — the wrong dot placement (step 1)

### Full score breakdown, including what should have been the correct target

Step 1 never actually saw the home screen. The very first (and only) locate
attempt ran while Waylo's own `MainActivity` was still in the foreground:

```
6560  17.702  executeStep called for index 0: Swipe up... tap the red YouTube picture button.
6580  17.715  D/Waylo: findOnHomeScreen: 'youtube' across 0 launcher nodes.
6581  17.715  D/Waylo: findOnHomeScreen: no launcher nodes (is the home screen visible?).
6599  17.720  findElement: scanning 14 nodes for 'youtube'
6600  17.722    Candidate: score=80 desc='null' text='how to find youtube history' viewId='com.waylo:id/editTask' pkg='com.waylo' [text partial +30, alternateLabels x1 +15, clickable +15, visible +10, wordMatches x1 +10]
6601  17.723    Candidate: score=65 desc='null' text='how to find youtube history' viewId='com.waylo:id/recentTitle' pkg='com.waylo' [text partial +30, alternateLabels x1 +15, visible +10, wordMatches x1 +10]
6603  17.723  findElement: FOUND 'null' score=80
6607  17.723  Target located for step 1: source=accessibility confidence=80.0
```

`findOnHomeScreen` correctly found **zero** launcher nodes (the real home
screen wasn't visible yet — the user hadn't swiped up in the ~20ms since the
instruction started) and correctly returned nothing. But `locateOnDevice`
then falls through to the *general*, package-unrestricted pipeline, which
scanned whatever *was* on screen — Waylo's own `MainActivity`, showing the
recent-task list — and matched its own `editTask`/`recentTitle` widgets,
because their displayed text ("how to find youtube history") literally
contains the word "youtube" and matches the `youtube` alternateLabel. Score
80 (30 text-partial + 15 alt-label + 15 clickable + 10 visible + 10
word-match) comes entirely from matching **our own app's UI**, not any home
screen icon. There is no evidence anywhere in this log of the real YouTube
launcher icon ever being scanned or scored — the session ends (user force-
stops the app) before the user ever gets a legitimate scan of the real home
screen while step 1 is still active.

**Checking the hypothesis** ("removing the targetPackage bonus dropped the
correct icon below the floor too"): this does not hold for step 1, for a
structural reason independent of anything I changed. `AccessibilityNodeInfo.getPackageName()`
reflects the *window owner* — for a home-screen icon that is always the
**launcher app** (`com.android.launcher`, confirmed later in this same log,
e.g. line 22301), never the target app itself (`com.google.android.youtube`).
So `targetPackage != null && node.packageName == targetPackage` can **never
match a home-screen icon** — this bonus has been dead weight for its stated
purpose ("fixes the Play Store logo outscoring the real YouTube icon") since
it was written, before *and* after de0e02f. Nothing was dropped for step 1;
the actual bug is the fallthrough matching our own app's UI when the home
screen legitimately isn't visible yet.

By the existing scoring rules, once the real home screen genuinely is on
screen, a well-labeled "YouTube" icon should score very high on its own
merits (contentDesc exact +60, alternateLabels +15, wordMatch +10,
clickable +15, visible +10, homeScreenNode +25, launcherIconClass +20 ≈ 155)
— comfortably clearing any reasonable floor. The problem was never "the true
icon can't clear the floor"; it's "we scored the wrong screen entirely, and
never looked again."

### The hypothesis *does* hold, one step later, for a different reason

Step 2 ("profile picture", `elementType=ICON_BUTTON`) never finds anything
either — but here the correct target *is* on screen and genuinely does score
low:

```
19392  20:47:34.208    Candidate: score=40 desc='Accounts' viewId='null' pkg='com.google.android.youtube' [alternateLabels x1 +15, clickable +15, visible +10]
19395  20:47:34.208  findElement: FOUND 'Accounts' score=40
```

"Accounts" is almost certainly the real profile/account button (YouTube's
own accessibility label for it, matched via the `account` alternateLabel).
`findElement`'s own internal gate (`> MIN_SCORE`, i.e. > 30) accepts it, but
`ScreenAnalysisPipeline`'s stricter `ACCESSIBILITY_CONFIDENCE` gate (> 50)
and `GuidanceEngine`'s `ELEMENT_CONFIDENCE_FLOOR` (50) both reject it — so
the pipeline reports failure on a screen where the answer was sitting right
there. Every *wrong* candidate around it — 'Notifications'/'Search'/'Home'/
'Navigate up'/'More options' — scores exactly **25** throughout this log,
every single time (e.g. lines 15098-15100, 20501-20503, 24527-24529): pure
`clickable(+15) + visible(+10)`, zero textual relevance. So the real
distribution here is: **pure noise caps at 25; any genuine signal (even one
weak alternate-label hit) pushes to ≥35-40.** The current absolute floor of
50 sits *above* real single-signal matches and rejects them, while a floor
calibrated to the actual noise ceiling would not.

## Finding 2 — why the dot never moves: it's not a "moved" bug, it's a "never hidden" bug

Every dot placement/removal event in the whole file:

```
6608  showDot called at centre x=486 y=609        (step 1's wrong placement)
...no further showDot / hideDot calls anywhere in the file...
29370 Guidance stopped.   (user force-stops the app ~30s later)
```

Step 2 runs for ~30 seconds (6560→24589, then the session is killed) and
never finds anything (`OCR` can't run either — "Layer 2 capture returned
null (no screen-capture permission?)" repeats on every attempt, line 16640
onward). Since `onTargetLocated()` — the *only* place that calls
`OverlayManager.showDot*()` — never fires for step 2, and **nothing in
`locateStep()`'s not-found loop ever calls `OverlayManager.hideDot()`**, the
step-1 dot placed at (486,609) simply sits there, completely unrelated to
step 2's search, for the rest of the session. This is the literal, exact
mechanism behind "the dot appears in ONE wrong place and never moves/updates
— taps there open wrong apps": it isn't that a validation rule is
*protecting* a bad placement — no such validation exists at all. `locateStep`
never re-checks an already-shown dot once `onTargetLocated()` hands off to
`WAITING_FOR_ACTION`, and it never hides a stale dot from a *previous* step
when the *current* step's search comes up empty. This directly confirms your
question 2: nothing "invalidates" a placement, because nothing was ever
built to. This was a gap in the original requirement-2 implementation
("hide/park the dot" while not found) — I implemented the park/re-scan loop
but never actually added the `hideDot()` call.

## Finding 3 — speech: instructions are spoken and completed, mechanically

Every `Speaker` call in this log, in order:

```
6482  Speaker.speak (flush): "Got it. Finding the steps for you."
6562  Speaker.speak (flush): "Swipe up from the bottom of the screen to see all your apps, then tap the red YouTube picture button."
6620  Speaker.speakQueued: "When you see the red dot, tap it."
15015 Speaker.speak (flush): "Tap the profile picture at the top right corner of the screen."
```

Only four calls in the whole ~30-second capture. The dot-found prompt now
correctly uses `speakQueued` (`QUEUE_ADD`), not `speak` (`QUEUE_FLUSH`) — it
will wait for the instruction (already in the TTS engine's queue via the
flush 58ms earlier) to finish before playing, instead of cutting it off.
Mechanically, the de0e02f speech fix is working as designed: this log gives
no evidence of instructions being cut off. Step 2's instruction is spoken
once and *never* followed by a dot prompt, correctly, since no target was
ever found for step 2 to announce.

Given only one "tap it" prompt exists in this entire capture, "still
primarily hear tap the red dot" is not literally reproducible from this
log's TTS call inventory. The most likely explanation, consistent with
everything else in this log: the user's *lived experience* was dominated by
a wrong, frozen dot from the first exchange onward (finding 1+2 above) —
step 2 provided a spoken instruction and then thirty seconds of a stale,
irrelevant dot with no further guidance, which reads as "the dot is the only
thing I'm getting" even though literally only one "tap it" utterance was
ever queued. **Please re-capture after this fix** if the instruction-cutoff
sensation persists once the dot itself is behaving correctly — that would
point to something this log doesn't currently show (e.g. a longer multi-step
run where a later step finds its target quickly and repeats the cutoff
pattern). Nothing here suggests the speech mechanism itself regressed.

## Fix (implemented after write-up, per your direction)

1. **Never treat our own UI as a target.** `ElementFinder.findElement()` now
   excludes nodes belonging to Waylo's own package (`com.waylo`) before
   scoring. This directly eliminates the step-1 false match — a guidance app
   should never point its own dot at itself.
2. **Hide the dot immediately when a new step begins**, before its own
   search runs. `executeStep()` now calls `OverlayManager.hideDot()` right
   after speaking the instruction. A stale dot from a finished/failed
   previous step can no longer linger into the next step's search.
3. **Confidence floor recalibrated from the observed distribution**, and
   made relative rather than a single flat number:
   - Every pure-affordance candidate (no real text/desc/viewId/label match)
     caps at exactly 25 (clickable+visible) throughout this log, in every
     app screen and step. Any genuine signal (a word, label, or partial
     text/desc match) adds at least +10, so a real match is always ≥35.
   - New `MatchResult.isConfident()`: requires the top score to be ≥35
     **and** to beat the runner-up by ≥10. The first condition admits
     genuine single-signal matches like "Accounts"=40 that the old flat 50
     rejected; the second still rejects near-ties/noise (the
     'Notifications'/'Search'/'Home' = 75/75/75 pattern from the *previous*
     regression, and would still reject a 25/25/25 noise-only screen).
   - This alone would **not** have fixed finding 1 (Waylo's own UI scored
     80 with a 15-point gap over its own runner-up, which clears both the
     new absolute and relative bars) — fix 1 above is what actually
     prevents that. The two fixes are independent and both necessary; I
     verified fix 3 alone doesn't regress finding 1's case back in.
   - `ScreenAnalysisPipeline`'s L0 gate and `GuidanceEngine`'s
     `checkTapInAppEvidence()`/`locateOnDevice()` gates now use
     `isConfident()` instead of a flat `score > 50`.
4. **Periodic re-validation of an already-placed dot.** A new
   `revalidatePlacement()` loop starts once a step's dot is shown and runs
   every 4 seconds while the step is in `WAITING_FOR_ACTION`:
   - Re-runs the same on-device search. If it can no longer confirm the
     target at all, the dot is hidden, `hasAnnouncedFoundThisStep` is reset,
     and the step re-enters the normal locate/re-scan loop (reusing the
     existing park-and-rescan + vision-fallback-escalation machinery rather
     than duplicating it) — exactly the "target genuinely disappeared, move
     it" case you asked for.
   - If a confident match is found at a meaningfully different position
     (>60px in either axis) than what's currently shown, the dot is quietly
     moved (glided) there — no re-announcement, since the guidance moment
     hasn't restarted, just been corrected.
   - If the same confident match is still in the same place, nothing
     happens (no needless dot churn).

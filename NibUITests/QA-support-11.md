# QA support 11

## Round 11a

Windows source-only work on work/ui-round-11, based on 57b4670. Read all four Round 10 parts, README, and all five assigned R12 families and paired verifier verdicts. Corrections win. No Swift/Objective-C compiler or simulator is available; every runtime target below requires CI.

### H1 - lazy reveal from the current offset

Confirmed R12:chrome-customise#0 and correction against ToolbarCustomization.list (On the Palette, In More, Saved Layouts, Reset) and revealFormElement. Reset previously returned to its starting 90% offset in eight moves / 41-42 s. Optional top/bottom/nearest hints now select a direction from the current offset; named targets are found inside the cached list snapshot and hittability is queried only inside the viewport. A repeated signature permits one reversal. Unhinted callers retain their prior search semantics. One post-drag list snapshot replaces repeated target exists/frame queries; the dismissal-cover check is deliberately retained to preserve 10d's lost-modal protection. All downward gestures still require a proven nonzero offset and start below the header. Slow gesture delivery remains.

Chrome derives hints only during Customise Toolbar. Reset checks visit saved layouts first, then Show rows, then Hide rows, retaining every check. ApplySavedLayout's Show/Hide checks are retained: their distinct assertions are not removed just to save a crossing. Should unblock ApplySavedLayoutRestoresVisibility and the three Reset tests, and provide budget for reordered-layout coverage. Next CI: Reset reveal 1-2 moves instead of 8, no top homing for Apply/Reset, no idle-form dismissal, all original outcomes under unchanged allowances. Rough savings: 30-35 s per Reset crossing plus reduced AX round trips; <140 s overall remains an unmeasured estimate, not a promise.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Customise layout/reset and shared reveal callers | Form reveal path / Form search reverse / Form reveal timing | Which hint and offset selected the direction, did an edge repeat, and how many moves/seconds resulted? |

### H2 - alert clearing and moved ruler confirmation

Confirmed R12:chrome-customise#2: the one observed default-handler cancellation occurs inside public typeText(Delete), while KeyProbe demonstrates HID Delete editing 12 to 1. Both first and fallback clear deletions now use existing HID usage 0x2A; exact waitForNativeText remains. The unexplained interruption trigger is not declared fixed, nor attributed to this run's ruler failure.

R12:chrome-timer-ruler#4 verifier correction wins: retained prepareCoveredControl's number-pad dismissal. Pre-tap stability alone cannot prevent the touch-triggered re-dock. Confirmation records alert/button/keyboard geometry, then waits boundedly for disappearance or an actual geometry change. Only a changed layout with the alert still present permits one newly resolved, stable confirmation tap; closure remains mandatory. Should unblock SaveLayoutRejectsBlank and ruler Set Position, preserving Angle and value assertions. CI must show exact empty/replacement values, no default cancellation during Delete, and a closed Set Position alert at the corrected frame. No sleep or allowance change.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Native clear callers / Save Layout | Native clear HID | Did Delete use device synthesis instead of the interruption-monitored public route? |
| Ruler confirmation tests | Ruler alert confirm / Ruler alert shifted retry / Ruler alert after tap | Did touch move the alert with the keyboard, which stable geometry received the retry, and did it close? |

### H3 - keyboard ancestry is not a form

Confirmed R12:chrome-singles#1 against presentedFormSnapshot: containsBackground rejected ancestors of Keyboard but traversal still admitted its inner Other at (0,1028,1032,345). Prune keyboard/input-view/assistant subtrees, then prefer the foreground candidate with its own close control using snapshot-only inspection. Plain Other forms and no-close popovers retain their routes. Should unblock MoreActionsStayScopedAcrossNotebookAndWhiteboardAndRotation. CI must choose Go to Page's Other with sheet.dismiss/Cancel, then log Modal form closed; no keyboard frame may be chosen.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Strict dismissal / rotated More | Modal form chosen | Which subtree was selected, and was it preferred for its close control after keyboard exclusion? |

### H4 - focused input and slow AX diagnostics

Confirmed R12:canvas#1: go() ran three identical focus passes, each scanning Alert/Sheet/Popover. It now binds the typed Page field, checks focus once with explicit app scope, waits again only after an actual focus tap, and prepares digits using the existing runner SPI. Exact field value, panel closure, requested-page HUD and paper assertions remain.

Confirmed R12:capture-and-probe#2 correction: public input paid two 60 s idle waits, while app-side window children fetching separately blocked about 33 s. KeyProbe reuses its field until the panel closes, prepares with SPI Select All/digits, and samples HID/SPI routes in the text matrix. The public app/field routes that wait for idle are no longer invoked on focused input; non-text public comparison and the control-delivery assertion remain. No assertion is skipped and no allowance grows.

Added measuredSnapshot and measuredQuery around shared list/form snapshots, findControl's existence query, focus lookup, probe reads and the Canvas/KeyProbe field reads. Over 10 s logs the request and duration, returned tree count and exposed keyboard-focus attributes. Scalar queries log immediately before taking one diagnostic app snapshot, explicitly labelled diagnosticTree=true; missing/failed trees say unavailable. This does not time out or fix XCTest's internal blocking call. R12:chrome-customise#1 and canvas#3 remain unexplained; no speculative app/host fix. Next run must correlate slow query lines with app AX logs/thread samples, and show no public focused-input idle waits. Expected go() saving about 16 s/call (about 128 s over RotateAllPages' eight calls), unmeasured and dependent on AX latency.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| KeyProbe text matrix; Canvas go(); Chrome Customise and shared queries | slow query | Which AX request exceeded 10 s, how many elements returned, and which keyboard-focus attributes were exposed? |
| Canvas go() callers | Go to Page focus | Was autofocus reused once and was input sent through SPI? |

### H5 - one retry for a proven undelivered chord

Confirmed R12:capture-and-probe#1 against chord and capture16Settings: the bounded Settings postcondition failed and both keyLog and keyLogTotal were unchanged. The catch path now requires decoded before/after logs and nonnil equal totals, plus an explicitly non-text responder, before resending once with existing sendHardwareKey. It logs keyboard frames/responder/key-window facts. The same bounded postcondition runs again; an arrived chord with no effect fails as before (existing proven modifier-loss handling remains). No retry follows missing probe evidence. Should unblock test16SettingsDarkLandscape and other proven dropped global chords without hiding app failures. CI must show arrival in App key log, Settings navigation/Done, or one failed retry with facts; no second retry.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Capture Settings / global chord callers | Chord undelivered retry / App key log activity | Was the log demonstrably unchanged after the bounded action wait, and did the single SPI resend arrive? |

### C1 - establish the reorder precondition

Confirmed R12:chrome-customise#3 correction and ToolbarCustomizationModel.show's append behavior. ApplySavedLayoutRestoresReorderedToolsWithLassoFirst now hides then shows Highlighter through the real controls, as its passing sibling does. The held drag remains. Its order wait compares both rows from one list snapshot instead of two Any queries. All save/reset/apply, lasso-first, handle, order and drawing assertions remain. CI must log Pen before Highlighter before the drag and Highlighter before Pen afterwards, then reach saved-layout restoration within the allowance; H1's savings are necessary for the tail.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Both reorder tests | Toolbar reorder before / after; slow query | Was the initial ordering non-vacuous, did the real drag reverse it, and was the order snapshot slow? |

### C2 - Layers setup shortcut

Confirmed R12:chrome-customise#4 and correction: the 32 s launch/77 s canvas window is unexplained; replacing setup cannot rescue that entire host slowdown. layers() now defaults to its already-supported Command-Option-L route after enabling Layers. LayersSettingMenuAndShortcutReflectFiveLayers explicitly keeps More because that test covers the menu. Rename and every selection/ink/lasso assertion remain. CI should reach ActiveLayerLimitsLassoSelectionToChosenLayer's lasso steps before 90 s on a normal host; estimated saving is one 10-19 s reveal, not a host-stall fix.


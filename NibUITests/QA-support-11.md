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


# QA support 11

## Round 11a

Windows source-only work on work/ui-round-11, based on 57b4670. Read all four Round 10 parts, README, and all five assigned R12 families and paired verifier verdicts. Corrections win. No Swift/Objective-C compiler or simulator is available; every runtime target below requires CI.

### H1 - lazy reveal from the current offset

Confirmed R12:chrome-customise#0 and correction against ToolbarCustomization.list (On the Palette, In More, Saved Layouts, Reset) and revealFormElement. Reset previously returned to its starting 90% offset in eight moves / 41-42 s. Optional top/bottom/nearest hints now select a direction from the current offset; named targets are found inside the cached list snapshot and hittability is queried only inside the viewport. A repeated signature permits one reversal. Unhinted callers retain their prior search semantics. One post-drag list snapshot replaces repeated target exists/frame queries; the dismissal-cover check is deliberately retained to preserve 10d's lost-modal protection. All downward gestures still require a proven nonzero offset and start below the header. Slow gesture delivery remains.

Chrome derives hints only during Customise Toolbar. Reset checks visit saved layouts first, then Show rows, then Hide rows, retaining every check. ApplySavedLayout's Show/Hide checks are retained: their distinct assertions are not removed just to save a crossing. Should unblock ApplySavedLayoutRestoresVisibility and the three Reset tests, and provide budget for reordered-layout coverage. Next CI: Reset reveal 1-2 moves instead of 8, no top homing for Apply/Reset, no idle-form dismissal, all original outcomes under unchanged allowances. Rough savings: 30-35 s per Reset crossing plus reduced AX round trips; <140 s overall remains an unmeasured estimate, not a promise.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Customise layout/reset and shared reveal callers | Form reveal path / Form search reverse / Form reveal timing | Which hint and offset selected the direction, did an edge repeat, and how many moves/seconds resulted? |


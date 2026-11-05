# QA support 10

## Round 10a

Base: 503f337 integration lineage, work/ui-round-10. Read both parts of QA-support-9, README and r10 findings/verdicts; verifier corrections win. Windows has no Swift/Objective-C compiler or simulator. All runtime targets below require macOS CI; no measured speedup or pass is claimed.

### H1 - bounded lazy-list reveal

Confirmed chrome-timeouts#0: 18 ApplySaved drags, 4.6–5.7 seconds per cycle, short 48-point row-gap move and wrong-way end probes. Current reveal retained these mechanics (the current container ranking already prefers hittable candidates). An absent target now homes toward the top with at most six gestures, requires a repeated visible range to establish the edge, then scans toward the bottom without reversal. It re-queries after every page. Slider-bearing forms retain slow delivery; other forms use fast homing and default-velocity page gestures, cached app geometry, and row-gap/plain-row starts spanning at least half the viewport. Existing clipping, value guards and transient-container checks remain. Reset/Apply/Delete/Save layout callers should spend less time traversing; CI must show a confirmed edge, no short gap drags, exact original assertions, and timings within the unchanged allowance. Savings are unmeasured and cannot be added independently to H2 estimates.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| All reveal callers; Chrome layout/reset tests | Form reveal timing / Form move timing / Form lazy edge | How many moves and seconds, and was the edge confirmed before the one-direction scan? |

### H2 - typed row probes

Confirmed chrome-timeouts#1 and correction: 55 Any existence probes cost 52.3 seconds in ApplySaved; present typed neighbours cost about 0.16 seconds, but absent/modal typed costs are not established. findControl already accepts a type, so preserved that API and the untyped default. requireControl now optionally scopes every lookup/reveal to the caller's container. Chrome supplies button types for known toolbar row names and all More actions. Reset/Apply/Delete/Save and rotated More should avoid Any row probes. CI must measure query counts and actual modal costs; the logged 50–70-second potential saving per layout test is an estimate, overlapping H1 and H3.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| Chrome setup | Typed probe estimate | What baseline estimate is being tested, without claiming measured savings? |

### H3 - scoped modal text and ruler confirmation

Confirmed chrome-timeouts#2 and chrome-singles#0 correction. Round 9b already scopes textEditor and focusField: lack of scope is NOT the isolated cause of alert cancellation. Chrome replace now uses fillNativeForm, resolving one container, supporting typed text views/search/secure editors as well as fields so existing Graph/Search callers remain valid. Optional explicit container enables the Time Keeper batch. Save Layout disabled checks use the alert's button. Ruler confirming actions require an enabled/hittable button, log its facts and the post-tap alert count, and require disappearance before the next action. The logging-only interruption monitor returns false; it never claims to handle the app alert. Layout-name, rename, timer and ruler tests retain exact text/action expectations. CI must show reduced field durations and either actual ruler dismissal or the interruption/confirmation evidence; the cancellation trigger remains unknown.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| Chrome native forms | Native form field duration | What did one scoped field cost? |
| Chrome interruptions | Chrome interruption | Which element did XCTest report before its default handler? |
| Ruler angle/position tests | Ruler alert confirm / Ruler alert after tap | Was confirmation enabled/hittable at which frame, and did the alert remain? |

### H4 - menu closure is a postcondition

Confirmed chrome-state-pdf#1, chrome-singles#6 corrections and insert-pickers-audio#6: More is a labelled ScrollView (not a native Popover), and Replay Options leaves a PopoverDismissRegion. Added a shared query-only bounded menu-disappearance assertion with element/probe/screenshot failure evidence. Chrome More, title/Add Page/Share menu actions, tool-More selections and draw now use it. dismissSheets first closes identifiable native/custom popovers through a safe outside point and verifies disappearance; unidentified dismissal-region geometry explicitly reports an open popover; a remaining toolSettingsOpen probe likewise reports instead of silently returning. Existing sheet/panel close ordering remains, including preserving Audio behind a dismissed share surface. All dismissSheets callers were inventoried. CI must show no cover before canvas input, successful Replay mode iteration or explicit unknown-surface facts. The reason a More action failed to close remains unproven; no automatic extra tap hides that failure.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| Chrome More/tool-More and draw; shared dismissal callers | Menu remained open / State step | Which menu frame survived, and what panels/probe state followed its action? |
| Insert Replay and shared dismissal callers | Popover still open | Was a dismissal region exposed without safe surface geometry? |

### H5 - ruler touch coordinate conversion

Confirmed chrome-singles#1 verifier diagnosis: AX frame points were sent directly to the screen-point API, transposing ruler contacts into pen input in landscape. Added synthesizeInterfacePaths using the exact app-coordinate-to-screenPoint conversion of pressWithoutIdle and the existing checked synthesis completion/error route. The rotation test now uses it; NibTouchPaths.m is unchanged. CI must show two ruler contacts, snapped 45 degrees and unchanged document/ink counters. This is a coordinate fix, not a gesture-timing hypothesis.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| RulerTwoFingerRotation | Interface touch conversion / Touch path orientation | Which interface and converted screen points were delivered? |

### H6 - unproven stalls remain diagnostic

Confirmed chrome-timeouts#3/#4, create#3 and insert-timeouts-state#1 corrections: sleeping app threads do not identify the animation/overlay or host cause. Removed the entire rotated-More after/final facts read on success (not merely its overlap snapshot). Rename Layer uses the existing Command-Option-L opening route after enabling Layers, avoiding that repeated More traversal; other menu-coverage tests retain their menu route. Round 9b already supplies cheap focus checks. Immediate runner log boundaries now precede focus tap, modified native typeKey, clear's typeText Delete and Insert Finish Editing tap. No HID Delete experiment was made; clearNativeText still has its exact empty-field verification. No speculative stall fix, timeout change or retry. CI thread samples must be correlated with these markers. App layer census/sampling schedule changes are outside this job's allowed paths; existing CI sampling remains the evidence route.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| Rename Layer / Create SuggestedTitle / native text callers | Stall boundary (focus / typeKey / Delete) | Which exact XCTest action was about to enter the stall? |
| Insert CopyTextUsesActualSelectedText | Stall boundary (Finish Editing) | Did the stall begin at the finish tap after paste? |
| Rotated More | Stall boundary / Rotated More failed | Did the tap fail, without paying post-tap facts on success? |

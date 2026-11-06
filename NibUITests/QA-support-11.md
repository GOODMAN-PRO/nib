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

### C3 - Time Keeper viewport, discard and history boundary

Confirmed R12:chrome-timer-ruler#0 correction: merely passing the panel scope does not reveal an existing clipped field. Added opt-in fullyVisible reveal geometry and explicitly reveal Timer name before the preset test's first tap; its whole frame must be within the clipped list viewport before reveal returns successfully. Existing callers retain centre-point behavior. #1 confirms empty Duration disables Start by design; after Discard the test now enters 1:00 before retaining its enabled/reachable Start expectation. The pause/save/discard flow also reuses the already-open idle panel instead of closing and reopening it. All clock, name, history and discard checks remain. CI must show the name reveal before focus, keyboard/text readiness and enabled Start only after valid Duration.

**History budget remains unresolved within this job's constraints.** R12 #2's proposed split depends on seeding six TimerRecord entries in the app fixture, which is outside NibUITests/**. Current TimeKeeperPanel.startTimer always dismisses the panel on this notebook (dismissIfBarShows), start clears/creates a new running session, and Stop and Save returns to an empty newly presented setup. History rows only expand laps; they cannot restart or rename records. Start Again preserves the same label. Thus setting up once cannot produce the six distinct named records whose simultaneous presence/document counts the existing test asserts. Splitting into two three-record fixtures would weaken the six-coexisting-record and Show All (>5) coverage. No fixture mutation, assertion reduction, speculative runtime claim or allowance increase is substituted. The six-session test remains unchanged pending an authorized app fixture scenario (then split named UI creation and six-record expansion), or an app-supported reusable setup route. The verifier measured ~330 s versus 180 s, so it is still expected to time out. This is an explicit incomplete portion, not a claimed fix.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| TimerPresetStartsCountdownAndCustomNameAdvances | Form reveal timing / Native form field duration | Did full viewport reveal precede the formerly clipped Timer name focus? |

### C4 - ruler menu row type

Confirmed R12:chrome-timer-ruler#3 verifier's passing-run StaticText evidence and current RulerView UIEditMenu actions. Toolbar-prefix typing is now restricted to Customise Toolbar; rulerMenu resolves top-level rows explicitly as StaticText with a bounded non-scrolling lookup. Options submenu callers retain normal button resolution. Missing menu rows capture evidence before any form drag could dismiss them. Should unblock RulerPaletteAndKeyboardToggleWithoutDocumentItems; CI must tap Hide Ruler StaticText, close the overlay and preserve document invariants. Set Position's race is handled in H2, not attributed to the type mismatch.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Ruler menu callers | Ruler menu row missing | What transient menu tree existed immediately after double-tap if the typed row was absent? |

### C5 - release the page scroll without momentum

Confirmed R12:chrome-singles#2: the current-page change was correct for the fling's final offset (595.5), so deleting the original-page assertion would change coverage. Per this job's instruction, added opt-in held release to twoFingerScroll: the movement remains 0.4 s, then both fingers remain at the endpoint for 0.4 s before lifting. This uses the existing equal-time synthesis samples, not a sleep. All other callers retain two points and original duration. PageScrollCollapsesOptionsAndChoosingToolRestoresThem retains the exact page identity, visible Page 1 drawing, stroke +1, Undo and strip assertions. CI must show a stopped scroll with the original page current, followed by ink on its clipped visible frame.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| PageScrollCollapsesOptionsAndChoosingToolRestoresThem | Page scroll held release / Page scroll ink geometry | Was stationary contact delivered before lift, and did the counted page receive the stroke? |

### C6 - iOS 26 dictionary close identity

Confirmed R12:chrome-singles#3 against its tree (DDUIDone, label close), current PDFTextMenu's system UIReferenceLibraryViewController and the stale Done lookup. PDFDefineOpensDictionaryForSelectedText now requires the typed DDUIDone button, retains the navigation-bar assertion, taps it, requires dismissal and retains sameContent. CI must reach the system dictionary and close it without expecting installed dictionary content. This lane runs iOS 26.5; no unverified older-OS fallback is added.

### C7 - Canvas export and layout split

Confirmed R12:canvas#0 against Panels.header and the failure tree: Share & Export is an Alert containing Button identifier xmark, label Close. The board-export test now scopes that exact button to the Alert, retains both selected-board assertions, taps it and checks non-hittability/disappearance before unchanged content. No stale Close export options lookup remains.

H4 handles canvas#1 go() focus cost. For #2, kept the existing test declaration as the horizontal half (its historical name is retained to avoid deleting a test) and moved the complete vertical half into testVerticalSinglePageLayoutPersistsAfterHorizontal. The new half explicitly sets Horizontal then Vertical as the verifier requires. Every page-frame/gap, horizontal and vertical scroll, reopen, width and no-spread assertion remains across the two tests; no allowance is raised. CI should report Canvas +1 test, both halves under 180 s (estimated ~80-125 s each), RotateAllPages under its existing 300 s, and board export reaching scope/cancel assertions. General query slowdown #3 remains diagnostic through H4.

### Final source review and checks

Reviewed changed Swift blocks and surrounding control flow, all helper signatures/callers across every UITest class, and unchanged NibTouchPaths.h/.m event/completion contracts. No Objective-C edits. Rechecked optional bindings, predicate argument counts, throwing closures, field scope, snapshot attributes, stable geometry and equal-time touch samples. Source review corrections were folded into their owning cluster commits: preserve initial native-control priority before cached reveal matching; prefer that identity over same-named captions; reject keyboard input ancestors; fail explicit full-field reveal if no complete viewport was reached. Apple documents snapshots as an attributes protocol with children and [dictionaryRepresentation](https://developer.apple.com/documentation/xcuiautomation/xcuielementsnapshot/dictionaryrepresentation); slow diagnostics use that dictionary rather than an assumed snapshot debugDescription. If this SDK omits its keyboard-focus attribute the log explicitly says not exposed, rather than inventing focus.

Shared-caller audit: Create/Ink/native replacement retain exact clear verification with HID Delete; Calendar/Ink/Library/Pages/Insert/Selection reveal callers retain default direction, clipping, value guards and target priority. Chrome alone supplies Customise edge hints. Canvas/Capture/Create/Ink/Insert/Library/Pages/Selection chord callers retain postconditions and default behavior on observed delivery; empty postconditions cannot trigger a retry. Two-finger callers in Canvas, Ink and Smoke keep the original movement unless they opt into held release (only the named Chrome test does). Strict modal dismissal retains plain-Other close controls and advisory callers remain unchanged. No changes to Capture's assistant readiness or Bridge/Tabs failure expectations.

Required validation: `python Scripts/lint.py` reports **0 errors, 25 existing warnings**. `git diff --check` and `git diff --check 57b4670` pass after removing the documentation's trailing blank line. A UTF-8 source inventory preserves every existing test declaration and every existing XCTAssert line, all executionTimeAllowance assignments and sleep/skip calls; Canvas gains one test. Five paths changed, all under NibUITests. Twelve cluster commits carry the exact requested attribution body; no push.

No Swift build or simulator run is claimed. Reviewer/CI risks: SPI key delivery and HID clear in native alerts; keyboard-focus attribute exposure; lazy list percent/target snapshots; full Timer name clipping; ruler touch-triggered re-dock; stopped-scroll page identity; iOS 26 dictionary and export AX types. Slow-query diagnostics can themselves incur AX latency and explicitly label extra diagnostic trees. Estimated savings are **30-35 s per former Reset crossing**, **~16 s per go() / ~128 s across RotateAllPages**, and **10-19 s per Layers setup**; these are unmeasured, overlapping with shared AX improvements, and not a suite-total promise. Canvas halves target ~80-125 s each. **Remaining: C3 six-distinct-session history setup**, documented above, still needs authorized fixture support or a proven reusable UI route; its assertions are intact and its 180 s allowance unchanged.

### Review fixes - round 1 (2026-11-06)

1. **Slow-query diagnostic amplification (major):** confirmed that every slow scalar query, including findControl's hot existence probe, fetched another full app tree. Superseding H4's original policy, measuredQuery now attempts at most one extra tree per NibUI instance (every test constructs a fresh instance), consumes that allowance before the attempt even if it fails, and skips the extra fetch when the original query exceeds 20 s. Later slow queries retain asked/duration logs with the skip reason. measuredSnapshot still reports counts/focus from its already-returned tree. CI must show at most one extra diagnostic-tree attempt per instance and none triggered by a >20 s query; the one permitted snapshot can still block inside XCTest, so outcome-neutral timing is not claimed.
2. **Toolbar-prefix typing (minor):** restored .button lookup for Hide/Show/Apply/Reset and Save current layout everywhere reachable is used; only the reveal edge hint depends on customizingToolbar. This supersedes C4's typing restriction. The ruler menu retains its independent .staticText lookup. CI must exercise Show Tools and Hide Time Keeper outside the customiser as well as the Customise rows.
3. **Ruler dismissal race (minor):** retry eligibility now compares only alert/button frames, while stability still includes the keyboard geometry. The post-tap stability wait accepts alert disappearance as success (including disappearance at its timeout boundary), and the retry checks existence again before tapping. Initial confirmation still requires a stable enabled/hittable button and the final closure wait remains. CI must cover keyboard-only dismissal, disappearance while resolving shifted geometry, and one retry for a genuinely moved confirmation button.
4. **C3 history budget (minor, accepted carry-over):** the six-distinct-session test remains intact and is still expected to exceed 180 s (~330 s in R12). Carry the seeded-history fixture work to a job allowed to edit the app fixture. No optional preset optimization is claimed or substituted for that fix; six coexisting records, document counts, duplicate checks and Show All/Show Less coverage remain required.
5. **Diagnostic continuity / probe scope (minor):** restored a one-line Stall boundary immediately before the first HID Delete without adding another AX query, alongside Native clear HID. KeyProbe intentionally continues to omit app.typeKey and field.typeKey from Route.text per H4; public app.typeKey remains in the canvas matrix. CI log consumers can again search the historical Stall boundary prefix for native clearing.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Shared measuredQuery callers in every class | slow query | Was the one permitted tree attempted, or skipped because of prior use / >20 s latency? |
| Native clear callers | Stall boundary / Native clear HID | Was the next Delete sent through HID, preserving historical stall-log searches? |

Validation: `python Scripts/lint.py` passed with **0 errors, 25 warnings**; `git diff --check` passed. Reviewed changed Swift source, measuredQuery callers and per-test NibUI construction across all test classes, Chrome prefix callers and all ruler-confirmation callers. Compilation, simulator behavior and runtime savings remain for GitHub Actions on macOS. No app files, test assertions, test declarations, sleeps, skips or time allowances are changed.

## Round 11b

Merged integration at b20b2f22 (fast-forward). Read job 11a, Round 11a above, README, all four Round 10 parts, and the full R12 ink-colours, ink-tools and library findings/verdicts. Verifier corrections govern; app-side unknowns remain unknown. Windows has no Swift toolchain or simulator. Only NibUITests changes; no push.

### H6 - horizontal row reveal

Confirmed R12:ink-tools#0 against EraserFilterChips and NibScrollView: Tape starts at x=372.5 beyond the scroller's x=372 edge; its 16 pt cue lane is outside the viewport. Added a separate bounded horizontal helper: resolve the smallest containing ScrollView by the control or a named sibling, compare current target/row frames, drag along x with slow delivery and a 0.4 s endpoint hold, and require centre containment plus hittability. Eight moves maximum; repeated child-position signatures stop a stuck row. Physical frame direction handles either LTR or RTL without assuming which side owns the cue. A centred but covered control fails instead of an invented corrective gesture. Existing vertical reveal is unchanged. I4 will use this helper; CI must show horizontal movement, a visible Tape centre, and no changed chip selection from scrolling.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| EraserFiltersEraseOnlyEnabledPenPencilHighlighterAndTape | Horizontal reveal / Horizontal reveal failed | How many moves and seconds revealed the chip; which row/target geometry failed? |

### H7 / L1 - commit the Files inline name

Confirmed R12:library#0 and verdict: exact replacement passed, but Return at t=74.12 left DOC.inlineRenameField open through t=87.42 with the software keyboard. Why Return failed is unknown. Replace public typeText(Return) with one observed keyboard Return/Done key (Files process first, hosted picker keyboard second), then only if the editor remains, tap verified empty space in its containing browser collection. Each delivered route has a bounded field-disappearance wait. No app activation, repeated key or blind tile tap. The older Create-alert route retains its 12 s postcondition. Failure preserves the original message and first attaches XCUIScreen.main, then logs Files/hosted hierarchies and keyboard buttons. Both nameNewFilesFolder callers (Library external drop and saveSharedPNG) retain exact name replacement and downstream folder verification.

R12:library#1 remains an environment limit: the next Library run should get past naming and reach **External drop setup requires iPad multitasking controls** again. The cross-app drop test, that message and all import/destination assertions remain unchanged; no simulated drop hook is substituted.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| ExternalFilesDropImportsIntoCurrentFolder; saveSharedPNG callers | Files rename key / Files rename commit | Which observed commit route ran, and did the editor disappear? |
| Same, on failure | Files rename hierarchy / Files rename hosted hierarchy / Files rename keyboard buttons | What did Files and its keyboard actually expose after both routes failed? |

### H8 / L2 - diagnose native menu delivery

Confirmed R12:library#2's correction: Add to Favourites was fully visible, the action never ran and the menu never ended after the t=34.42 tap. Clipping and a test-support cause are not established; no reveal or retry is added. Library performTap now includes both Favourites rows in diagnostics and checks native card-menu closure within four seconds before any value poll. Context-open tracking also covers a native tree without a Menu/Preview marker. Shared nativeContextMenu logs every row's label, identifier, row frame and containing menu/list frame before delivery; its existing eight-second closure gate and submenu/outside-cancellation semantics remain. A surviving menu now throws **native menu row tap not delivered** with the captured facts. Library allows a same-named successor at a new frame only when it belongs to a native Alert/Sheet; a moved row alone is not closure. The shared native-menu transaction retains its existing successor-frame rule. No action is resent.

Should locate the failure in FavouriteOpenAndUnstarUpdatesMembership instead of the twelve-second Star wait; it is a diagnostic change, not a proven fix. Next run must correlate Native menu row tap with app [Nib QA menu]/[Nib QA tap] action and recognizer logs, then either menu disappearance and all original favourite assertions, or immediate delivery failure after the bounded gate. Reviewed Pages and Insert native-menu paths, including Move submenus, Delete confirmations, Rename/Share successors and explicit outside cancellation.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| FavouriteOpenAndUnstarUpdatesMembership; Library card menus; shared nativeContextMenu callers | Native menu row tap / Native menu row tap not delivered | Which row identity and menu/row frames received the one tap, and did that menu end? |
| FavouriteOpenAndUnstarUpdatesMembership | Library action first poll / Library action timeout | Were both Add and Remove Favourites rows available before delivery? |

### I1 - retain contact at the swatch drop destination

Confirmed R12:ink-colours#0 and correction against the raw test drag and PresetReorderButton's performDrop-only move: this run released seven milliseconds after destination activation and never performed the drop. Timing supports the dwell change but is not proof of the precise cancellation mechanism. RearrangeColoursDragPersistsOrderAndActiveColour now uses existing dragWithHold between slot centres (0.8 s lift, velocity 500, 1.5 s destination contact), as Insert/Pages do. All label-order, active-colour, reopen and drawing checks remain. Next run must show performDropWithItemCollection, dragEndedWithOperation:16 and the expected persisted order. A further cancellation needs app sessionDidUpdate/drop-point evidence, not another test retry.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| RearrangeColoursDragPersistsOrderAndActiveColour | System drag contact | Did the held system drag run before the unchanged order wait? |

### I2 - close the picker through its real control or safe outside geometry

Confirmed R12:ink-colours#1 and correction: the (24,24) fallback produced UIStatusBarTapAction; an earlier full tree did expose close at approximately (738,250). closeColourPicker now searches app-level close/Done buttons within the current picker surface before falling back. Outside candidates are beyond every popover's 8 pt inflation, at least 60 pt below the window/region top and 24 pt from other edges. The selected point remains logged and picker disappearance remains mandatory. Should unblock HighlighterCustomColourPersistsAndDrawsTranslucentInk and later closes in CustomColourValidHexUpdatesSlotAndInvalidHexIsRejected. CI must show the own close control or a safe point, no status-bar action, and actual picker disappearance. Outside-dismissability remains unproven.

R12:ink-colours#2's holds=false correction is retained: the picker was hosted, never ready and invalidated, but the dismissal time/cause is unknown. waitForColourSliders still requires the picker and its Sliders; no warm-up or retry. The other job's [Nib QA picker] presenting-chain/lifecycle logs must explain any repeat of **Remote colour picker and Sliders must be ready**. No test workaround for a picker torn down by the host.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| Custom/system colour-picker tests | Colour picker controls / Colour picker dismissal | Which own close control or safe outside point was used, with which surface frames? |

### I3 - distinguish an unopened palette from a missing colour

Confirmed R12:ink-colours#3's holds=false verdict against addColour/open and ColourEditor's Add a colour container: the first plus tap at t=56.32 produced no palette; the proposed hasWindow hand-over cause is unsupported. fillColourSlots now captures the plus frame, taps once, and waits at most four seconds for the palette container with its buttons before chooseColour. A missing palette throws **Add Colour opened no palette**, including plus geometry and raw QA state. Every slot count, original-prefix, capacity and digit-render assertion is unchanged. Covers AddColourPreservesExistingSlotsAndStopsAtTwelve and all five AddedColourDigits tests. CI must correlate a failure with app [Nib QA preset]/[Nib QA tap] logs; this is a precise failure boundary, not an app fix or extra tap.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| AddColourPreservesExistingSlotsAndStopsAtTwelve; AddedColourDigits tests | Add Colour opened no palette | Did the first plus tap produce any palette; what were its frame and QA state? |

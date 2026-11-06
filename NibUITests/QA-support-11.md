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

### I4 - resolve and reveal each eraser chip afresh

Confirmed R12:ink-tools#0 and verdict against the four-upfront lookup and current horizontal chip row. EraserFiltersEraseOnlyEnabledPenPencilHighlighterAndTape now resolves each chip within the current Eraser popover and uses H6 with the Pen sibling to identify its row. No chip array survives a reopen; each activation can move either direction to the current target. Enable-first ordering, every isSelected assertion, all four exact item-count decrements and Undo restoration remain. CI must reach Tape through a held horizontal drag (rather than the old 13.3 s vertical search) and complete all four filter iterations. Offset reset on reopen is handled without relying on it.

Diagnostics use H6's Horizontal reveal prefix for every chip, including zero-move hits. Runtime savings are unmeasured; successful coverage adds real horizontal navigation that the old failing path never completed.

### I5 - go directly to Stabilisation

Confirmed R12:ink-tools#1 and verdict against settings' default Fountain Pen lookup and PenSettingsView's lazy type grid. The pencil iteration opened scrolled at 83%, with Stabilisation visible but the tile unrealised, and spent 23.74 s failing to reveal an irrelevant top tile. PenAndPencilStabilisationChangesInkAndKeepsEndpoints now calls settings(tool, revealTop: false), as the existing highlighter stabilisation test does. All four slider changes, raster comparisons, endpoint coverage and Undo checks remain. CI must show four Stabilisation drags and no Fountain Pen search in this test, whether the app opens settings at the top or restores an offset. Estimated saving: roughly 20-40 s of the observed unnecessary pencil top traversals; not measured here.

### I6 - stable Pencil detail binding and cheap successful toggles

Confirmed R12:ink-tools#2's correction: the collection query depended on the lazy Switch between current tool and eraser row, which disappeared and let liveList re-rank onto the 220 pt sidebar. revealPencilPreference now identifies the wider detail collection adjacent to the stable Settings sidebar ScrollView (SettingsSidebar uses ScrollView/LazyVStack, not a collection), using the observed shared bottom edge and either left/right adjacency, then binds it from the unfiltered indexed query, independent of every lazy detail row. It supplies edge: .bottom and the typed name, verifies the pane is retained, and returns immediately for an already hittable preference. Both initial and reopened passes use the same helper. Ambiguous or missing detail geometry fails explicitly instead of falling back to generic ranking or scrolling the sidebar. The current recorded frames differ by only 0.5 pt at their shared edge; the geometry match allows 2 pt.

Ink toggle no longer scans scrollPanels while its actual thumb is hittable. Shared setSwitch keeps its value check, nested-thumb route, optional reveal, exact eight-second value wait and failure overlap evidence; successful presses log only cheap label/frame facts. Overlap snapshots occur only for a non-hittable target or failed value change. Re-grepped shared callers in Chrome, Capture, Library and Ink; their defaults and required values remain. All hover/haptics off/on, reopen and no-mark assertions are retained.

CI must show no sidebar drift, Pencil Form reveal timing below roughly 15 s, and quick Switch before press delivery. Estimated saving is about 30 s from two avoided sidebar detours plus up to 20 s of switch overhead per affected test (about 50 s/test); overlapping AX costs and the unexplained class-wide slowdown prevent a measured claim.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| PencilHoverSettingPersistsWithoutCreatingMarks; PencilHapticsPreferencePersistsWithoutMarks | Pencil detail anchor / Form reveal timing | Did a stable collection frame retain the detail scope, and how long did the bottom-directed reveal take? |
| Shared setSwitch callers | Switch before press / Switch value failed | Was the thumb hittable before delivery; which overlaps existed only if delivery/value failed? |

### I7 - split the long highlighter test and measure each colour cycle

Confirmed R12:ink-tools#3's holds=false correction: the old test used 161 s of 180 s; this run reached Thickness at t=178.3 after colour cycles grew from approximately 16 s to 29 s. Neither app nor runner is established as the cause. Retained the existing test declaration as widths + all six colours, including every raster, undo and per-colour reopen-selection assertion. Moved the complete Thickness/Stabilisation/Draw and hold tail into testHighlighterThicknessStabilisationAndDrawHoldPersist with its own fixture and the same third width slot selected. It also explicitly checks Thickness persistence, alongside the original smoothing/switch checks and final draw. No allowance changes.

Each colour iteration logs wall time on success or throw, with separate open settings, choose, both closes, draw preparation, draw (including visible-ink verification), undo and reopen (including persisted selection) timings. CI should report Ink +1 test, both halves within 180 s, and comparable timing series that locate any growing cost. The split removes roughly 20-30 s of tail work from the old test but adds fixture setup overall; it is not a slowdown fix and does not guarantee the widths/colours half fits a contended runner. Fixed-time process sampling remains CI-owned and outside this job.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| HighlighterWidthsColoursStabilisationAndDrawHoldPersist (widths/colours half) | Highlighter colour timing | Does time grow per iteration, and is it in settings open, choose, close, draw, undo or reopen? |

### Final review and validation

Re-read all changed Swift blocks and surrounding paths in NibUI, InkUITests and LibraryUITests, and checked NibTouchPaths.h's unchanged signatures. No Objective-C edits. Reviewed XCTest element/query/snapshot types, optional bindings, throwing/rethrowing closures, predicate placeholders and argument counts, gesture overloads, coordinate origins, bounded waits and string expressions. Current SettingsRootViewController confirms the sidebar is a ScrollView with a LazyVStack beside the detail List, separated by a divider; the frame binding does not assume a CollectionView sidebar. Source-review corrections were folded into their owning cluster commits: Files keyboard existence before descendant access and both process keyboard exclusion frames; explicit process names rather than an assumed application bundleIdentifier getter; card-menu-only closure checks (including Trash); and no acceptance of a merely moved Library row as a closed menu.

Caller audit covered every class file. The existing vertical reveal implementation and every existing caller retain their behavior. H6 is opt-in from I4 only. nameNewFilesFolder still verifies exact replacement and serves both Library's external export and saveSharedPNG. setSwitch callers in Chrome, Capture, Library and Ink retain their values and failure checks. nativeContextMenu callers in Pages/Insert retain synthesized contacts, submenu traversal, same-named successor handling, outside cancellation and the existing eight-second closure gate; only the new evidence and failure wording change. Library's new four-second closure gate applies to known card rows, not App Menu/document More or arbitrary menu successors. dragWithHold and settings signatures are unchanged; only the named Ink call sites opt in. All colour-picker close callers keep the picker-gone wait, and no picker warm-up or Add Colour/native-row retry exists.

Required checks: **python Scripts/lint.py: 0 errors, 25 existing warnings**; **git diff --check** and **git diff --check b20b2f22** pass. A Python UTF-8 source inventory against the merged base confirms all **598 existing test declarations** and every existing XCTAssert line remain, with **one new test (599 total)**; execution allowances and sleep/skip inventories are unchanged. Exactly four paths changed, all under NibUITests. Ten cluster commits have the exact required subject prefix and two-line attribution body. Worktree clean after committing; no push.

No local Swift compilation or simulator execution is claimed. CI/reviewer focus: Files process versus hosted remote keyboard/tree and empty browser geometry; app-level remote picker close exposure; native menu/list ancestry and same-named confirmations; horizontal chip-scroll interception and stable row signatures; Pencil pane geometry/index retention as its lazy children change; and highlighter timing under contention. XCTest's synchronous AX calls retain their internal timeouts; outer predicate budgets cannot interrupt them. A menu frame absent from the returned tree is explicitly logged as unexposed rather than invented. Diagnostic snapshots can add latency.

Estimated, unmeasured savings: I5 removes roughly **20-40 s** of needless top searches; I6 targets roughly **50 s per hover/haptics test** from sidebar detours and success-path switch diagnostics. The highlighter split moves roughly **20-30 s** to a fresh test but adds fixture setup overall; no suite-total speedup is claimed. All 11b clusters are implemented or explicitly explained. Remaining external work: the three unproven app/environment failures need their app QA logs; real Files-to-Nib Split View is still unavailable here, so L1 should next reach **External drop setup requires iPad multitasking controls**. The earlier 11a six-session Time Keeper budget limitation remains outside this job.

### Review fixes - round 3 (2026-11-06)

Reviewed only job 11b changes against their pre-11b base and the three supplied findings. These corrections supersede the affected I6, I7 and H8 notes above; job 11a and app sources are unchanged.

1. **Clipped switch centre (major, superseded by round 4 below):** this round restricted the fast path using the native Popover count. That did not restore the check for Nib tool popovers, which expose labelled ScrollViews even when the native Popover count is zero. The major remained open until the explicit caller opt-out in round 4.
2. **Native menu snapshot cost (minor):** nativeMenuRowFacts now searches snapshots of at most eight Menu elements and the exposed Preview element, stopping when it finds the row's ancestor. It never snapshots the whole application for these tap facts. Label, identifier, row frame and menu/list frame are still captured before delivery; absent ancestry remains explicitly unexposed. Library, Pages and Insert callers keep their existing tap routes, closure waits, successor handling and no-retry behavior. CI must verify scoped frame diagnostics and menu closure; no measured latency saving is claimed.
3. **Unrequested Thickness persistence (minor):** removed only the equality assertion newly introduced by the highlighter split and discarded the now-unused return value. The Thickness drag still verifies a visible value change; original Stabilisation and Draw and hold persistence assertions and the final draw remain. CI must run both split tests under their unchanged allowances.

Diagnostic prefixes remain unchanged: **Native menu row tap / Native menu row tap not delivered** now obtain ancestry from scoped snapshots. No new diagnostics, sleeps, retries, skipped tests or allowance changes. Re-read changed Swift blocks and inventoried all toggle/native-menu callers; the existing snapshot/query APIs, argument labels and optional bindings remain compatible.

Validation: **python Scripts/lint.py: 0 errors, 25 existing warnings**; **git diff --check** passes. Only three NibUITests paths changed. Swift compilation and simulator execution remain unavailable on Windows and require GitHub Actions; scoped AX reads can still block internally, and Menu/Preview ancestry exposure must be confirmed there. One new review commit, no amendment or push.

### Review fixes - round 4 (2026-11-06)

**Clipped switch centre (major):** removed the native Popover-count bypass from Ink toggle. Run 42136488712 exposes the Draw and hold and Auto-deselect settings as labelled ScrollViews with popovers=0, so native element type cannot establish that no containing panel exists. Ordinary tool-setting toggles now reach the containing-panel inset-centre check and existing bounded reveal even when the thumb is hittable. Only the four hover/haptics off/on calls explicitly pass scroll: false, after revealPencilPreference succeeds. This supersedes I6's blanket hittability fast path and the ineffective round-3 fix; shared setSwitch remains unchanged.

Reviewed every Ink toggle caller: all other callers retain scroll: true by default, including Draw and hold, Auto-deselect and other tool settings. Existing value, persistence and no-mark assertions, reveal bounds and allowances remain. No new diagnostics, sleeps, retries or test removals. CI must show edge-clipped tool switches revealed before Switch before press without dismissing their panels, plus passing hover/haptics off/on and reopen checks without redundant panel scans. No runtime saving is claimed.

Validation: **python Scripts/lint.py: 0 errors, 25 existing warnings**; **git diff --check** passes. Re-read changed Swift control flow and call labels against the current helper signatures. Only InkUITests.swift and this review record changed, both within NibUITests; job 11a and app files are unchanged. Swift compilation and simulator execution require GitHub Actions on macOS. One new round-4 commit; no amendment or push.


## Round 11c

Merged integration 923759cf cleanly. Read prompts 11a/11b, prior support records and all six assigned R12 families including verdicts. Current source wins; only NibUITests changes. No local Swift compiler or simulator.

### H9 - cheap native-menu closure

Confirmed pages-menus-outline#0 correction and insert-menus-alerts-forms#0: the Templates/Comment/Rename successor already appeared while AX walks exhausted the eight-second double-pass gate. Capture the menu/Preview scope before the final tap and accept its first absent observation. Trees without either retain the last-row disappearance/successor-frame check. The timeout remains eight seconds; callers still verify their own result. Also replaces P1's repeated pre-press live control inventory with one snapshot and removes per-item global counts. All Pages/Insert nativeContextMenu paths, submenu and outside cancellation callers were inspected. Next CI must log menu dismissed and reach Templates, Rename and Comment postconditions; no app export stall is claimed.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| Pages/Insert native-menu callers | Native menu pre-press inventory / Native menu dismissed / Native menu row tap | Did a scoped closure observation finish within eight seconds after the single tap? |

### H10 / P2 / N1 - alert-safe replacement and Return

Confirmed pages-menus-outline#1 and insert-menus-alerts-forms#1. HID Delete is already present. Existing NibTouchPaths.sendKey route 3 directly synthesizes text with modifiers reset and supports shifted/Unicode characters without XCUIElement's interruption check; reuse it instead of introducing a second character map or pasteboard dependency. Return in an exposed Alert uses HID 0x28. Native modified keys also use the existing runner route in an Alert. Exact waitForNativeText remains. Audited every typeText: Canvas board Return, Insert author/GIPHY Return, Create's generic replacement and Ink colour fields now use the alert-aware helper; ordinary canvas text, assistant/comment composers, search and foreign Safari keep public typing. Files no longer has a public Return after 11b. No cancellation-handler workaround. Next CI must complete both Outline tests and collection rename without a default Cancel; H9 separately covers audio/comment menu successors.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| Alert replacement / board and author Return / colour fields | Native alert text | Was text delivered by runner SPI rather than interruption-monitored input? |

### H11 / N1 - clipped controls

Confirmed insert-controls#4 and correction against requireControl's hittable early return and NibScrollView's 16-point bottom cue. scroll:true now requires full target containment in its nearest snapshot ancestor ScrollView intersected with outer scrollers/window, reserving the overflowing bottom cue edge. A clipped match logs its frames and enters the existing bounded fullyVisible reveal; post-reveal/poll checks use the same requirement. Non-scroll callers are unchanged. Full reveal applies the same cue geometry. Horizontal strips retain H6's explicit path. This should unblock Fit Height to Text; CI must show a fully contained row before the unchanged false-value wait. AX ancestry/viewport exposure needs runtime verification; no canvas fall-through cause is asserted.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| TextBoxStyleAndAutosizePersist; scroll:true callers | Clipped control reveal | Which target/scroller/cue viewport rejected a partly visible control? |

### H12 / N1 - close system sharing before popover checks

Confirmed insert-menus-alerts-forms#2 correction: the failure tree has ShareSheet.RemoteContainerView and header.closeButton; the defect is strict-popover ordering, not an absent Close label. app.log bootstraps osservice<com.apple.sharinguiservice>; com.apple.sharing.sharesheet is its XPC endpoint, not the process identity. dismissSheets now resolves the sharinguiservice application when running plus the hosted app tree, taps the sheet's own header close, and waits for its header/surfaces to disappear before checking other popovers. Missing header fails with both available trees; no guessed outside contact. Audio's underlying panel remains protected by dismissedSurface. Should unblock collection export/import-cancel and audio export. Next CI must show sheet closure, retained parent handling, then the original import/cancel assertions. Remote bundle/tree visibility remains CI-only.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| Collection export; audio sharing | Share sheet close / Share sheet close missing | Which real header received the tap, or which process tree lacked it? |

### H13 / P2 - live Photos confirmation inventory

Confirmed pages-drag-photos#0 correction: selection succeeded, snapshot-clipped inventory was empty, and debugDescription exposed buttons. The cause remains unknown. Log selectionScope frame, picker existence and total snapshot button count (minus one if unavailable), then inventory live app.buttons and picker.buttons with labels, identifiers and frames. Existing named/title-bar rule, actual-button requirement, duplicate-frame removal and picker-gone wait remain; Learn More is explicitly excluded. No coordinate fallback. Should let AddImageFromPhotosPreservesOriginalPages reach its unchanged page assertions or explain the inventory discrepancy. Next run must show one evidenced confirmation and disappearance.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| AddImageFromPhotosPreservesOriginalPages; multi-select Photos | Photos confirmation scope / Photos picker buttons / Photos picker confirm | Is the scope wrong, is the snapshot empty, and which live button satisfies the existing rule? |

### H14 / S2 - direct control polls and step timing

Confirmed selection#2 correction: activateLayer's containing-ScrollView poll consumed 45 seconds; host-wide slowdown is unproven. Poll Layer N directly after the existing panel-state wait, retaining selected/Active value and closure checks. Audited containing queries across all classes: Insert's commentEditor had another repeatedly evaluated containing query and now polls/rebinds the typed editor directly; other containing queries perform one-time discovery rather than polling. Selection setup and crossPage steps log wall time including launch, document open, drawing, selection, zoom, destination query/drag, navigation and undo/count waits. Should unblock MoveObjectsToLayer and locate MoveAcross's 53-second startup. CI must correlate timings with the new eight-second silence samples before assigning app versus host cause.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| MoveAcrossPagesAndLinkedUndo; Selection setup/cross-page sibling | Selection step begin / Selection step timing | Which action, including work before the first key, consumed the time? |

### P1 - inspect outline depth without idle waits

Confirmed pages-menus-outline#2: public press/tap with an open menu incurred the observed 60-second idle stall. Use pressWithoutIdle and tapWithoutIdle for D / Move, then query the submenu before retaining the exact disabled-or-absent fourth-level assertion and both Escape closures. All nesting, outdent, order and page-count assertions remain. H9 cuts repeated pre-press tree queries; H10 avoids interruption handling and existing clearNativeText already skips Select All/Delete for empty fields, so no new fixture creation route is introduced. CI must finish under 300 seconds without menu idle waits and with all five move transactions plus depth inspection.

### P3 - unambiguous stack destination

Confirmed pages-drag-photos#2 verdict: two items had system operation zero despite the app move proposal; cause unknown, including context-menu lifecycle timing. Keep the held drag and every reorder/relative-order/set/Undo assertion. Target thumbnail 4's image area at (0.5,0.4), assert clearance from both lifted frames and log those frames and the destination. No retry, lift-duration change or app workaround. Next run must compare proposal/lifecycle logs and show performDrop items=2 plus all original outcomes; otherwise cancellation remains an app/system investigation.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| SelectedThumbnailsDragAsOneStackAndUndoTogether | Page stack destination | Was the destination in the image area, well clear of both lifted cells? |

### N2 - Save Style touch diagnostic

Confirmed insert-menus-alerts-forms#3 verdict: touch reached canvas, but window coordinates/presentation state were unknown. Immediately before delivery read Save Style's current frame, log its centre and send that exact point via existing runner touch synthesis. Exposed the existing point overload internally; no gesture implementation change. Original alert/name/style/default assertions remain. This is the verifier's experiment, not a claimed fix. CI must compare Save Style touch and Interface/Touch path conversion with the app's window-touch and prompt-guard logs.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| NamedStyleAndDefaultAffectNewText | Save Style touch | Which fresh frame and exact interface point was sent to the runner? |

### N3 - audio settings and playback budget

Confirmed insert-controls#0 correction: final playback lasted 31 ms with both options enabled; silence versus noise processing is inferred. Retain both enabled-option assertions, turn both options off and verify their absence before the final Play/Pause. Shorten skip loops using the already verified scrubbed position minus the first ten-second skip and the recorded duration: floor + one deliberately crosses each endpoint once. Every seek/endpoint/speed/close assertion remains. For the observed 31-second clip this removes three menu/action pairs and adds two; estimated net saving 6-13 seconds, not measured. CI must reach Close Player with sustained settings-off playback under 300 seconds.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| AudioPlayPauseSeekSkipSettingsAndClose | Audio settings-off playback | Were both processing options off before the final Play/Pause? |

### N4 - collection strip

Confirmed insert-controls#1 against ElementsCollectionBar and the vertical My Objects reveal. Use 11b H6 within Elements, anchored by Stickers, for the chip tap after reopen. The app owns selected-chip scrolling; the test still taps and verifies the actual saved/deleted element. CI must log Horizontal reveal and finish all source/reuse/delete checks.

### N5 - GIPHY readiness

Confirmed insert-controls#2: reveal ran while the network-dependent row did not exist. The companion app job supplies immediate fixture failure; wait boundedly for the actual Try Again button before reveal/tap. Query-retention and key removal remain. CI must expose it within about one second without network activity or an absent-row drag.

### N6 - retained Tape scroll

Confirmed insert-controls#3: History at y290 was above the restored y476 viewport. Request scroll:true before History. No app reset assumption; every pattern/width/straightness/orientation/history assertion remains. CI must reveal History then reach Clear History and the second drawing checks.

### N7 - connector point encoding

Confirmed insert-controls#5 against Geometry.Point's unkeyed [x,y] encoding. All three bends casts now use [[Double]]. Original count-one, changed geometry, Remove Bends and Undo count assertions are unchanged. CI must progress past the old nil dictionary-array cast and exercise the remaining bend edits.

### N8 / S1 - provider setup and shortcut evidence

Confirmed insert-providers-timeouts#0/#1 and selection#0: Command-S was unclaimed; lazy-row causation is inferred. Retain Command-S for the companion app shortcut fix and log Save provider existence immediately before sending it. Provider forms opt into a new keyboard batch: one initial Name reveal, field-specific focus checked after bounded HID Tab traversal, exact values read, Select All/Delete only for nonempty differing values, runner SPI typing and exact waitForNativeText for every field. ProviderEditorView source establishes Name/Base URL/API key/Chat model/Transcription ordering; intervening fields are traversed without editing. Each target allows at most eight Tabs with one-second focus waits, then fails explicitly. Shared fillNativeForm defaults/callers are unchanged. Transcript config enables Cloud transcription before AI within the same Settings visit, removing reopen/dismiss work. No seeded storage or shortcut fallback.

Should unblock NativeDiagram, both Transcript tests and AssistantAttribution. CI must show every exact field, Provider saved, transcript/assistant original assertions and setup below the observed 116-171 seconds. Estimate: one Settings reopen saves about 25 seconds; reduced focus/reveal/clear work is unmeasured. Native Tab focus/automatic scroll and runner text SPI need macOS compilation/runtime verification; failure cannot silently type into another field.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| Provider-dependent Insert/Selection tests | Native keyboard form field / Provider save shortcut / Insert provider setup | How long did verified field entry take, and was Save realised when Command-S was sent? |

### N9 - Replay contact follows settled page geometry

Confirmed insert-providers-timeouts#2 against the banner's 28-point offset change and CanvasAccessibility: strokes have no individual AX element, while their page has a transformed frame. Record the stroke midpoint relative to that page at drawing time; after recording/replay layouts, reuse settledCanvasPoint's two-read frame/offset/zoom gate and derive the contact from the current page frame. Require it inside the visible page, then retain selectionCount==1, timestamp seek, ink and zoom assertions. Ordinary text/sticky callers retain their clipped-centre behavior. No stale screen fraction, layout offset constant or app workaround. CI must show the two geometry logs separated by banner removal and successful lasso selection. Replay's pixel/closure costs remain subject to the unchanged allowance; no assertion was removed for budget.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| ReplayModesAndSeekFromRealTimestampedInk | Replay recording geometry / Replay settled contact | Did the contact follow the page's current transform after the banner disappeared? |

### N10 - remove measured diagnostic/interruption cost

Confirmed insert-providers-timeouts#3/#4: Sticky completed all assertions in 190.5 seconds with seven 3.2-4.7-second interruption blocks; Tape Photos spent about 37 seconds inventorying assets. The permission monitor now uses one predicate instead of enumerating all buttons; Sticky explicitly removes its unneeded monitor and dismisses each colour popover through the existing runner touch route at the same outside point, bypassing the default interruption path as well. All seven colours, uniqueness/text/source/author checks remain together. Removed diagnostics:true from the three diagnosed photoAsset calls; selection and failure diagnostics remain. CI must fit Sticky under 180 seconds and Tape near 140 seconds; estimated savings about 25-30 and 37 seconds respectively, unmeasured. No split is justified until these measured costs are removed and CI rechecks.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| StickySevenColoursAndSelectedOnlyRecolour | Sticky colour timing | What remains of colour delivery/copy time without interruption handling? |

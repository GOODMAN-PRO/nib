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

### C1 - tabs fixture prerequisites

Confirmed chrome-timeouts#5: eight New Notebook UI creations at 26–46 seconds each structurally exceed the allowance. Added explicit tabsOverflow cases to the runner and app scenario enums; only this test selects the scenario in setup, matching Canvas's existing launch pattern. The fixture creates eight extra persisted notebooks. Offscreen fixture cards are revealed through the bounded shared list helper before the existing clipped card tap. The test opens all nine through actual library cards, retaining overflow selection, all Command-1…8/9 assertions and hidden/restored-tabs checks. No tab state is injected. Grepped all scenario references: no exhaustive switch over either enum exists; notebookPageCount remains unchanged. CI must show eight library opens, no New Notebook loop, all nine distinct switches, and completion under the original allowance (diagnosis target <120 seconds is unmeasured).

### C2 - Time Keeper routes and form expectations

Confirmed chrome-timeouts#6 correction and chrome-singles#6–9 corrections against FeatTimeKeeperFeature, TimerCommands and TimeKeeperView. Plain K opens the idle panel; Command-Option-K records a lap. Current source also shows K toggles only the running bar, whose summary button opens details, so active-session setup uses that real button. Already-open setup reuses the panel. The stopwatch test retains its deliberate More re-open and now checks H4 independently of openPanels. Timer fields use one explicit Time Keeper container and batch, with scoped typed Start lookup. All six distinct history sessions and assertions remain. Empty Duration now explicitly requires disabled Start Timer; saved 150 seconds requires 02:30. NibChip already adds the selected trait on its button; read that typed button over a bounded two-second wait and log every sample. CI must complete the same timer/history/lap flows within unchanged allowances; selection timing vs trait failure remains diagnostic, not a claimed cause. Savings from the 74–80-second setup baseline are unmeasured.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| TimerPresetStartsCountdownAndCustomNameAdvances | Timer preset selection | Does the typed chip acquire Selected during the bounded observation? |
| Stopwatch deliberate More reopen | Menu remained open / State step | Did the menu actually disappear even if the panel was already open? |

### C3 - scoped Hide/Show Tools rows

Confirmed chrome-state-pdf#1 correction against current More row actions: the open More/swallowed stroke is proven; selection of the separate Show Tools droplet remains inferred. More now resolves the button exclusively inside its labelled ScrollView, including the rotated Go to Page action, logs both frames and uses H4 before returning. HideShowTools retains all palette, content and ink assertions. CI must show the row inside More, disappearance before drawing, and stroke count +1/undo available without a chrome.popover.more dismiss-cover rejection.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| HideShowTools; every Chrome More action | More scoped row | Did the selected button belong to More rather than the palette's same-labelled reveal droplet? |

### C4 - draw on the visible counted page

Confirmed chrome-state-pdf#2 correction: fixed canvas y=671 was on Page 2 while the probe counted Page 1 (whose visible bottom was y=553). The scroll test now asserts the original page is still counted, intersects its real AX frame with window and canvas, and derives the stroke inside that visible rectangle. Exact stroke +1 and Undo assertions remain. Raw probe logs retain inkInput/nativeStrokeCount and geometry before/after. CI must show committed ink on the counted page; a missing surface on Page 2 remains an independent unproven app hypothesis, requiring app contact/hit-view logs rather than an invented test fix.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| PageScrollCollapsesOptionsAndChoosingToolRestoresThem | Page scroll ink geometry / State step (Page scroll wet ink) | Which page/visible rectangle received the stroke and which native wet-ink facts bracket it? |

### C5 - ruler callers and unchanged outcomes

Completed ruler callers through H3/H5 for chrome-singles#0/#1. Position fields share one alert batch; confirmation geometry must agree on two bounded reads before the real tap. Angle/position dismissal is required before any later ruler interaction. Rotation completion now also logs raw state and baseline stroke count on failure, distinguishing misplaced pen contacts from no ruler action. All 0/45/90-degree, 4/5-position, 45-degree gesture, content-invariance and constrained-ink Undo/Redo assertions remain. CI must prove confirmation actions and two-finger ruler delivery; the unknown interruption trigger is not declared fixed.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| RulerTwoFingerRotation | State step (Ruler rotation ink invariants) | Did a failed rotation instead add pen ink? |

### C6 - reorder evidence and bounded gesture preparation

Confirmed chrome-singles#2 correction: an identical drag passed in a sibling, so no-hold cancellation is not a proven cause. Kept the actual drag and original destination; require the list frame to match on two bounded reads, log visible row order before/after, and hold the destination 0.4 seconds as the requested gesture experiment. No accessibility Move action or weakened order assertion. Both reorder tests must show Highlighter initially below Pen and finally above it, including saved-layout restoration; the next run distinguishes geometry readiness from an unchanged/cancelled drag.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| Both Customise reorder tests | Toolbar reorder before / Toolbar reorder after | Was the initial ordering non-vacuous, and did the held drag change it? |

### C7 - Bridge failure evidence only

Confirmed chrome-singles#3 correction: the app logged off, AX retained the pill/popover, but the screenshot did not show the popover. No evidence identifies a NavBar rebuild defect. Kept the pill-disappearance expectation exactly. Only on failure, take screenshot plus pill/popover facts twice, separated by a bounded one-second diagnostic interval, then rethrow the original failure. CI must compare those observations with app turnOff/compactStatus logs; this does not claim an app fix. App status-provider/body instrumentation remains outside scope.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| BridgeStatusPillOpensDetailsAndTurnOffHasEffect | Bridge after Turn Off first / second | Do pixels and AX facts agree, and does the retained pill/popover disappear between failure observations? |

### C8 - current settings/strip and export contracts

Confirmed chrome-singles#4/#5/#10 corrections. Highlighter top-dock settings now select the middle visible width-labelled preset and require its Selected trait (not a nonexistent Thickness 2). Export reads the Format menu button's PDF value, retaining All-selected and cancel-inert assertions; pre-reveal PDF and scroll geometry are logged. AX exposes no direct scroll contentOffset, so child/viewport frames are recorded without inventing an offset. The single-chevron assertion moved to closed settings and checks the active tool's exact Settings label; open settings are checked through toolSettingsOpen.

Read ToolbarModel.optionsState/toolReselected, NibToolOptionsState and the probe. Current strip-job commits 1ea1e22/bdec046/aee67a9/479550b already migrated Capture, Ink, Insert and Selection to openToolSettings; their old second-tap settings assumption is already resolved. Grepped EVERY class file for settings helpers, selectTool, raw tool taps, menu.toolSettings and preset/strip dependencies; Canvas, Create, Library, Pages, Smoke and CaptureReadiness introduce no remaining double-tap-settings helper. Shared selectTool preserves selection; openToolSettings unfolds a folded strip and uses its chevron, while tools without a strip reselect for settings. Existing manual-fold Chrome test now explicitly requires nil settings after folding and unfolding, then the chevron opens settings. No unrelated class edits were needed. CI must verify both strip states, settings replacement, width selection and Format PDF under the existing assertions.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| ShareExportOpensCorrectSheetAndCancelIsInert | Export before reveal / Export content geometry | Where were PDF and the scroll content before reveal, including negative-y frames? |

### C9 - Files hand-off diagnostics

Confirmed chrome-state-pdf#0 down to the verifier's proven boundary: the immediate presentingViewController-nil guard throws despite picker presentation; why it is nil remains inferred. Current ImportDialog.swift still contains that guard and the active delegate defer at this worktree, so the app job's hand-off fix is not assumed present. Added raw probe plus typed picker/target facts before/after New, Import Files, provider/container/folder navigation, PDF selection and Open, and at completion even on failure. Kept every import/page/text-selection/copy/dictionary/speech/annotation expectation. CI must correlate the last runner stage with app didPick count=1/picked=1 and document/pageCount=1; no test workaround for the app hand-off.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| All six PDF tests | PDF picker <stage> / State step (PDF import <stage>) | Did presentation, navigation, selection, Open or the app hand-off fail, and what probe/picker facts bracket that step? |

### Final source review and validation

Re-read the changed Swift blocks and surrounding callers in Chrome, Create, Insert, NibUI, UITestFixture and NibUITestMode; compared the unchanged NibTouchPaths.h/.m signatures and screen-coordinate contract. Checked throwing closures, optional bindings, scope defaults, typed queries, snapshot attributes, predicate placeholders, geometry conversions, XCTest waiter/gesture APIs and small string expressions. No Objective-C edits. Shared reveal callers in Ink/Library/Pages/Selection retain clipping/value guards and bounded fallback; Selection's form batch keeps its default signature and exact text checks; all native-clear callers retain waitForNativeText. Create's direct replacement focus tap (outside focusField) also has its own immediate stall boundary. Sheet dismissal retains panel ordering and explicitly reports unknown popover geometry. Offscreen cards in the larger fixture get bounded real scrolling before the existing visible-card tap. PDF stage facts use compact typed snapshots rather than repeated overlap/global-window inventories.

`python Scripts/lint.py`: **0 errors, 25 warnings**. `git diff --check 503f337` and `git diff --check`: pass. Python source audit preserves **593 test declarations and 14 executionTimeAllowance assignments**, with no added sleep/skip calls. Assertion review preserves original outcomes; changed expectations are the explicitly requested Format/empty-duration/mm:ss contracts, the chevron assertion moves to its valid state, and ruler synthesis now propagates the existing shared completion timeout/error rather than duplicating it. Seven changed paths are within scope, including only the two C1-authorized app fixture files. There are **15 cluster commits**, each with the exact requested two-line attribution body; review fixes were folded into their owning commits. No push.

No Swift/Objective-C compilation or simulator run is possible on this PC. CI must verify native AX container types (especially Customise collection, Time Keeper and droplet menus), fast edge detection/default paging, retained popover copies and disappearance, scoped remote editors, gesture synthesis and the held reorder. The tests still fail honestly for unproven app/host problems. The Files app fix is not present at this worktree; Bridge rebuild/census instrumentation and an earlier CI sample cadence remain app/CI-owned, as explained above. Every H1–H6/C1–C9 cluster has a committed implementation or explicit evidence-limited explanation; none is deferred.

Runtime saving is **estimated, not measured**: typed row probes could save roughly **50–70 seconds per affected layout test**, overlapping the navigation and text-entry savings. Tabs removes eight UI creation flows (observed 26–46 seconds each), replacing them with real library opens; no net saving can be claimed until their reveal/navigation cost is measured. Timer setup previously cost 74–80 seconds per call; plain-K/scoped-entry savings remain unquantified. New query-only closure checks and diagnostics also cost time. No allowance was raised and no idle-stall removal is claimed.


## Round 10b

Base: bc4a146 (Round 10a), on work/ui-round-10. Read Round 9a/9b, README, all four Insert/Create diagnosis families and paired verdicts. Only NibUITests changes; no local Swift compiler/simulator. Verdict corrections override speculative fixes.

### I1 - native context menus

Confirmed insert-timeouts-state#0 against current raw press/action pairs and Elements contextMenu: two observed 60-second waits. Migrated Elements, patterns, comments, recordings, transcript and page menus to the existing nativeContextMenu transaction. Added default-compatible normalized press position and explicit outside-dismiss point for the comment cancellation coverage; every menu action uses synthesized delivery and the existing bounded closure check. Separate confirmation dialogs retain their actions. Should unblock CreateElementSourceRemainsRenameDeleteAndReuse and prevent the same menu-idle route in the remaining callers. CI must show Native menu opening/item/dismissed and all original content/undo assertions, with no menu idle waits.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| Insert native context-menu callers | Native menu opening / item / dismissed | Which target and action were delivered and did the menu close? |

### I2 - selection after keyboard avoidance

Confirmed insert-timeouts-state#2: sticky at y303-507 while the fixed tap was y671; current avoidance deliberately retains its scroll offset. The four diagnosed tests now resolve their exact committed text/sticky value, wait for keyboard absence plus two equal clipped item frames and content offsets, then touch that live frame. Both Styled box re-edit double taps use the same live geometry. The diagram setup also names its committed text. Existing explicit canvas-point callers retain their semantics. CI must reach the four original style/sticky/link assertions and log a point inside the moved object.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| StickySevenColours, StickyCollapseExpand, TextBoxStyleAndAutosize, URLLinkSaveRemove; diagram setup | Insert settled item | Which visible frame and stable scroll offset supplied the contact after keyboard avoidance? |

### I3 - keys and field-scoped focus

Confirmed insert-timeouts-state#5 correction: preset selection was repeated at 36/81/143/188 seconds, but an earlier run passed in 146 seconds. Resolve/focus the preset editor once and reuse it for all four native chords and selection checks. The expensive field-focus identity scan is bypassed only for this explicit session; fresh Command-A, text equality and Cut/Copy verification remain on **every** preset. This intentionally follows the verifier over interpreting “once per field” as permission to drop fresh-selection coverage. Round 9b already provides cheap post-tap focus; defaults preserve every other class.

For insert-timeouts-state#3, insert-singles#3 and insert-pickers-audio#4, cause remains unproven. Before every global modified key and the Insert/SuggestedTitle native modified keys, runner log records route, keyboard presence and raw responder/key-window/key-log probe; opted-in native delivery also logs after. Native diagnostics reuse the attachment's existing raw read and default off in other classes; chord snapshots now read the full value attribute to avoid JSON truncation and report current keyWindowState. Global postcondition/no-event logging was already corrected in 9b. No Unicode substitution, flyout workaround, missing-event retry or changed paste expectation. Input-mode/layer ownership is not exposed by the current runner probe; authoritative app internals remain app-owned. CI must show all four fresh selections and original typography results within allowance; missing Command-A/V/comma must have attributable before/after key logs.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| NativeTextInputRetainsUnicode; ObjectCommentCopiesDeepLink; TranscriptSearch; all chord/native-key callers | Key before delivery / Key after delivery | Which route, responder, keyboard presence and raw key-window/log state bracketed delivery? |

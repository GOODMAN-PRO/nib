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

### I4 - Elements system drag destination contact

Confirmed insert-timeouts-state#4 correction: proposal operation 1 at 22.880, release at 23.036, cancelled operation 0, no performDrop. Timing is proven; the cancellation mechanism is inferred. Extracted the **existing Pages round-9b gesture unchanged** into shared dragWithHold (0.8 lift, velocity 500, 1.5 destination contact) and used it for Elements. Pages retains its result diagnostics and gesture parameters. No sleep or allowance change. CI must show ElementDragInsertsAtDropPoint reaches count 5 and the original drop-position assertion; app proposal/performDrop logs must distinguish cancellation from actual insertion. Current CanvasDragDrop still has no DEBUG sessionDidUpdate/performDrop instrumentation. That requested app-side evidence is outside NibUITests scope; existing DragUI logs and runner count/position checks remain available.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| ElementDragInsertsAtDropPoint; Pages thumbnail drags | System drag contact | Did the shared held contact run before the existing result/probe checks? |

### I5 - Settings form setup

Confirmed insert-timeouts-state#6/#7 corrections and insert-pickers-audio#5: the transcript test never reached transcript actions, and provider fields cost 25-65 seconds. Round 9b/10a already supply scoped modal batches and cheap focus. configureProvider now fills four fields in one fillNativeForm batch and saves through the last native editor, using the existing Selection-class route and one typed saved-status query. GIPHY key/search also use batches; sidebar/page actions use typed button lookup and the existing bounded reveal. No deep link, fixture injection or shared provider state. SettingsSidebar currently uses Buttons; fresh test fixtures remain independent.

CI must show exact field values, Provider saved and original diagram/transcript/GIPHY assertions. Target: setup below 60 seconds and transcript regeneration before 120 seconds, unmeasured. Long native-menu stalls beyond setup were never observed in the baseline transcript test; I1 prevents that route without claiming measured savings there.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| NativeDiagram; both transcript tests; GIPHY save/search | Native form field duration / Insert provider setup | Which field or total setup still consumes the unchanged allowance? |

### I6 - remote picker readiness and export destination

Confirmed insert-pickers-audio#0/#1 corrections: loading remote views exhausted the old Any-query budget; non-hittability/AX transport failure remains possible. The save location was **unknown**, since both optional location taps were skipped. Added a bounded 45-second query-only wait for observed Photos grid/sidebar or Files Browse/sidebar markers. Typed Cancel waits separately, logs frame/hittability, and inventories all buttons/cells on failure; disappearance is required. photoAsset uses the same readiness gate before its existing selection logic (including Pages callers); the existing legacy Photo-cell route also qualifies readiness.

Image/collection/GIF/tape cancel paths use the helper. Collection save and reimport both require and tap On My iPad after readiness, with file inventory on a missing Stickers package. No Recents assumption and no guessed coordinate Cancel. CI must show ready markers, actual Cancel facts and dismissal, and the exported file in the explicitly selected location with all original asset/count assertions. Remote AX failures may remain.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| Image Photos/Files, image replacement, collection import/export, GIF Files, tape pattern; shared Photos callers | Remote picker readiness / Remote picker Cancel / Remote picker inventory | Did the remote tree load, was Cancel hittable at its frame, and what controls/files actually existed? |
| CollectionExportSaveAndReimport | Collection Files location | Which named location was actually tapped in save and import? |

### I7 - audio playback duration and audible-input boundary

Confirmed insert-pickers-audio#3: a five-second clip ended before the 7-10-second Pause lookup. Rename/export/delete now records at least 30 seconds through the existing observed-clock wait, retaining every assertion and the 180-second allowance. CI must resolve Pause while playing and complete the original rename/share/cancel/delete checks.

For #2 correction, the 27 ms run with Skip Silence/Reduce Noise is proven; an empty audible map is still inference. Current Player builds a plan from SilenceMap.audible and the UI exposes neither the map nor an audio-import route. The verifier proposes turning both settings off, but this job explicitly requires sound while Skip Silence is **on** and unchanged assertions. Consequently that workaround is not applied. NibUITests cannot make the simulator microphone receive a tone: runner speaker playback is not a proven microphone-input path, and changing the app recording fixture or CI audio input is outside the allowed paths. No silent-file mutation or injected recording is substituted for the real recording test. An audible app fixture/CI microphone feed and app-side SilenceMap span logging are required to finish this part; the enabled-settings Play/Pause expectation remains, with a pre-play options/raw-state boundary. This is an explicit scope-limited explanation, not a claimed audio fix.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| AudioPlayPauseSeekSkipSettingsAndClose | Audio enabled-settings playback / State step (Audio before Play with Skip Silence and Reduce Noise) | Which settings and exposed state preceded the potentially immediate end? SilenceMap itself is unavailable to the runner. |

### I8 - Replay Options closure

Confirmed insert-pickers-audio#6 and current 10a H4: dismissSheets already closes identified native popovers and requires the dismissal region to disappear. Reused it, adding the Replay in Full Screen content sentinel through 10a waitForMenuClosed before pixels or the next More action. No second dismissal implementation. ReplayModesAndSeek must reach Spotlight/Reveal/Static and retain both pixel-difference and stroke/seek/zoom assertions. Existing Menu remained open and State step diagnostics identify a surviving surface.

### I9 - touch visible content under Selection AX wrappers

Confirmed insert-singles#0 against SelectionOverlay/HandleAccessView (non-interactive) and the failing Connector end/text frames. AX occlusion is inferred, not a UIKit hit-test result. Connector start/end/bend and committed text now require enabled visible geometry and touch a point inside its canvas/window-clipped frame. Non-hittable targets log all covering AX frames through existing elementFacts. Text double-tap no longer relies on AX activation. Every connector attachment/route/bend/undo and text/edit/undo assertion remains. CI must reach the original expected geometry/content changes, with covering Selection evidence if isHittable remains false.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| ConnectorDragAnchorRoutesBendsAndUndo; TextInsertCommitEditAndUndo | Insert covered target | Which Selection/other AX frames cover the visible target that receives the coordinate contact? |

### I10 - singles and unproven hit/stall evidence

Confirmed insert-singles#4: TapeTool uses a destructive-only iPad confirmation. Replaced the Cancel lookup with existing cancelConfirmation; count 6/strokes 3 after cancel remains. Failure diagnostics no longer open History behind the modal and mask the first failure.

For #1/#2/#5 and insert-timeouts-state#1, corrections win: Save Style and Straight tape touches were at the correct positions inside stable popovers; no moving-frame cause is claimed. Per this job's requested observation, these two targets require two equal target/popover frames, then log target facts and overlapping AX elements before/after the unchanged tap. This is diagnostic preparation, not a proven fix. Public XCUITest cannot report UIKit hosting-layer hitTest; app viewport/contentHeight/hit-test instrumentation remains outside scope. The invalid-GIF immediate snapshot now inventories matching toast identifiers/text across **all** types, keeping the original StaticText error oracle. Failure additionally captures the hierarchy after dismissal.

Round 10a already added the immediate Finish Editing stall marker. Added pre-step screenshot/hierarchy for CopyTextUsesActualSelectedText and runner-log failure hierarchy before termination; screenshots retain keepAlways. Timeout screenshot extraction/sample cadence is CI-owned and cannot be changed under NibUITests-only scope. CI must pass original Tape cancel/remove/undo, style, switch, toast and clipboard outcomes or correlate these observations with app contacts/idle samples.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| NamedStyleAndDefault; TapePatternWidthStraightness | Insert stable control / Save Style after tap / Straight tape after tap | Was the actual tap inside the stable target/popover and what AX elements covered it? Did the alert/value change? |
| GIFLocalInvalidLink | Invalid GIF toast any type / Invalid GIF after dismissal | What AX type/identifier represents the visible toast, and does dismissal change exposure? |
| CopyTextUsesActualSelectedText | Finish Editing before stall / Stall boundary / Insert failure hierarchy | What overlay/tree and pixels preceded the idle wait, and what survived at teardown? |

### K1 - decimal clearing evidence and disappearing-keyboard diagnostic

Confirmed create#0/#1 corrections. NewNotebookSheet still binds TextField(value:format:) to Double, uses decimalPad, and calls applyCustomSize on change/submit; applyCustomSize clamps draft size without directly assigning customWidth/customHeight. Neither dropped deletion nor numeric-value reassertion is proven. Added opt-in Width/Height clear-stage value, character count, Unicode scalars and raw key log after Select All and each existing Delete delivery (first Delete and fallback batch). The batch remains one action, avoiding an unproven change in event timing. Exact empty-field and numeric replacement/zero-size assertions remain.

The proven diagnostic race is removed: initial keyboard buttons come from one immutable application snapshot; **all post-Hide stages only query keyboard existence**, never a live descendant label/frame. The conditional second Hide and final keyboard-gone wait are unchanged. CI must proceed beyond successful Height dismissal without “No matches found ... Keyboard”, and show whether Select All/first delete/fallback leaves 210 and what the fourth scalar is. Clearing itself is diagnostic-only until that evidence exists.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| CustomSize; InvalidCustomSizePreventsCreation | Decimal clear stage / Decimal clear key log | What exact value/scalars and delivered keys remain after each clear action? |
| Same | Width keyboard after Hide / after docked Hide / completion / frame | Did the keyboard disappear, without dereferencing a vanished descendant? |

### K2 - Calendar setup cost and environment boundary

Confirmed create#2 correction: the observed 52.9-second activation/sample timeout is an environment event, not a diagnosed app problem. At current HEAD, the claimed existence-only grant loop is **already resolved**: eventNote explicitly taps SpringBoard Allow Full Access during the bounded 15-second readiness poll and then allows lazy-row scrolling. Kept that behavior and the allowance. Calendar Title now uses the existing scoped form batch after one cheap foreign-app focus check, eliminating the generic creation scroll/duplicate focus path. Event reveal uses 10a's bounded list helper; unique-event action scoping and all linked-package/count/reopen assertions remain.

Logged immediately before activate and elapsed wall time after it returns; a synchronous XCTest activate cannot be forcibly timed out safely by this runner helper. CI must show prompt acceptance during readiness, completed Title entry, bounded reveal and original note creation/reuse. No claim to fix host latency.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| Both Calendar note tests | Calendar activation boundary / Calendar activation duration; Native form field duration; Form reveal timing | Did time disappear inside activation, title entry or event reveal? |

### K3 - unproven idle and nil-probe failures

Confirmed create#3/#4 corrections: two animation-idle timeouts with an asleep app do not identify a caret animation; nil runner reads do not establish whether the probe was absent or valueless. Round 10a already logs immediately before focus and modified typeKey; retained both actions and the exact expectations. SuggestedTitle now captures pre-focus screenshot/AX facts, and Create failure hierarchy is sent through logQA (text attachments alone are unavailable). Layer-owner/animation census at the stall needs app instrumentation and CI sample timing outside this job's paths.

TypeSwitch enables diagnostic-only per-read begin/result logs. readState reuses its existing single exists and single value read, reports exists, valueIsNil, decode outcome and elapsed duration even on throw; all other callers default off. No caching, retries, poll-based extension or deadline change. CI must distinguish absent versus nil value and locate long round trips while retaining creation identity/type/title assertions. The AX getter's own timing cannot be measured from the runner; app-side instrumentation is explicitly still needed.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| SuggestedTitleUseReachesCreatedDocument | Create suggested title before focus / Stall boundary / Create failure hierarchy | What field/overlay preceded the timeout, and which XCTest action was in progress? |
| TypeSwitchRetainsTitleAndChangesFields | State read begin / State read result | Was each probe absent or present with nil value, did decoding succeed, and how long did that poll cost? |

### Round 10b final source review and validation

Re-read the changed Swift blocks and surrounding callers in Insert, Create, Pages and NibUI; inspected the unchanged NibTouchPaths.h/.m contract. Reviewed XCTest element/query/snapshot APIs, optional values and bindings, throwing expressions/closures, access levels, predicate arguments, native form scoping and interface-to-screen coordinate conversion. All callers of changed shared helpers were grepped across every class. Native menu position/dismissal, native-key focus reuse and clear diagnostics have defaults preserving existing callers; Photos retains its legacy-cell route. Pages uses exactly its previous gesture parameters through the shared helper. No Objective-C file changed.

Final `python Scripts/lint.py`: **0 errors, 25 warnings**. `git diff --check bc4a146` and `git diff --check`: pass. Source audit preserves all **593 test declarations and 14 executionTimeAllowance assignments**, with no added sleep or skip calls. Every existing XCTAssert line is retained except the equivalent exported-file assertion, whose same ten-second existence result is stored once to permit a failure inventory before assertion. Additional Calendar visibility and menu/keyboard postconditions do not replace outcome checks. Exactly five paths changed, all under NibUITests. Thirteen cluster commits retain the exact required attribution bodies; review corrections were folded into their owning commits. Worktree clean after commit; no push.

Windows provides no Swift/Objective-C compilation or simulator validation. CI/reviewer must validate remote Files save/import marker/sidebar identities, Photos readiness and Cancel hittability, native menu same-named successors/outside cancellation, foreign Calendar field focus, full multiline text AX values after scrolling, and held system-drop acceptance. No unproven app/host cause is labelled fixed. The audible Skip Silence input and SilenceMap spans (I7), app hit-test/animation/getter instrumentation (I4/I10/K3), and timeout screenshot extraction/sample scheduling remain explicitly outside this job's permitted paths. All clusters have committed changes or these explicit explanations; the audible-input portion of I7 remains technically unfinished pending app/CI support.

Runtime estimate, **not measured**: I1 targets the two observed 60-second menu waits, about **120 seconds** in CreateElementSourceRemainsRenameDeleteAndReuse. Reusing one preset focus and batching provider fields should remove repeated AX work, but 9b/10a already reduced some of that baseline cost, so no additive saving is claimed. The longer recording adds up to 26 seconds and the Elements destination contact adds 1.5 seconds; remote readiness and new diagnostic reads also cost time. There is no defensible net runtime estimate until CI measures these paths under the unchanged allowances.

## Review fixes (round 1) - 2026-11-06

These corrections supersede the menu-frame closure rule in H4/I8, modal-only field lookup in H3, and class-wide Insert key diagnostics in I3. Read both job prompts, current shared helpers and their callers, the Replay finding/verdict, and the baseline Replay failure hierarchy. All changes remain under NibUITests; no app or fixture implementation changes.

| Review issue | Root correction and evidence | Next-run requirement |
| --- | --- | --- |
| Retained menu shells (major) | ChromePopovers builds rows only for the open menu; the supplied Replay tree has empty More/More tools ScrollViews with visible frames. Closure now tests button content within scroll surfaces, including disabled rows, instead of treating those frames as presentation. Empty buds never authorize dismissal taps. Active content still fails the bounded query-only closure check with facts. | Drawing and Time Keeper accept empty shells but reject a surviving menu. |
| Replay dismissal (major) | FeatReplayFeature registers a sheet; baseline hierarchy contains an unnamed 496 x 650 ScrollView with Replay handwriting and Replay in Full Screen under Other ancestors, and no Popover node. The shared helper resolves the ScrollView containing the unique Replay handwriting switch. Its frame joins native popover exclusion frames; the outside point must be inside the native dismissal region when present. One tap is followed by a joint bounded content-and-cover disappearance wait. | All three modes close Replay and PopoverDismissRegion before pixels or the next More action. |
| Show document tabs typing (major) | TabStripView uses a Toggle. Chrome toggle explicitly requests .switch, overriding the toolbar-button prefix optimization. | All showTabs callers retain their original switch-value, overflow and tab-switch assertions. |
| Retained modal field lookup (minor) | fillNativeForm searches all four editor types in the resolved container, then app, before reveal/failure, matching textEditor's scopes rule. Focus/replacement receives the scope that actually contains the editor. | Title, Layer name and Timer name remain reachable with an unrelated retained modal. |
| Shared dismissal timing/taps (minor) | A non-nil toolSettingsOpen now triggers waitForState(timeout: 8) for nil instead of an immediate throw. Corner taps require a native popover or native dismissal region; More buds alone receive only closure queries and fail if still active. | Shared Canvas/Capture/Ink/Library/Selection callers tolerate asynchronous probe clearing without canvas corner taps for retained buds. |
| Non-lazy reveal velocity (minor) | Restored .slow whenever the search is non-lazy or has sliders. Only lazy homing/paging keeps .fast/.default. Existing start-point safety and bounded search remain. | Settings and other non-lazy forms reach rows without the new flick velocity; lazy toolbar timing remains measurable. |
| Per-key diagnostic cost (minor) | Removed Insert setup's class-wide opt-in. Only the Unicode and comment deep-link tests enable native-key diagnostics, with defer restoring the default. Command-comma already goes through chord(), which logs its responder/raw probe and keyboard facts before hardware delivery independently of that flag. | Preset and ordinary native keys avoid the extra diagnostic reads; the three unproven chord paths retain evidence and expectations. |
| Unproven text AX values (minor) | If item-frame settling cannot resolve sticky/link/clipped multiline text, log the target facts and use the former canvas point after bounded keyboard-gone and two-read canvas/offset stability checks. This also covers the subsequent double-tap helper calls. Selection count, edit and content assertions are unchanged. | Known committed text uses its live frame; other text representations can reach the original assertions through the logged fallback. |
| Fixture documentation (minor) | Added tabsOverflow and Chrome tab 2 through Chrome tab 9 to CanvasFixtures.md, checked against UITestFixture's existing seeding loop. | Engineers can identify and invoke the nine-tab prerequisite. |

Custom DismissCatcher is explicitly accessibilityHidden and is created from DropletField.hasOpenBud; it has no queryable AX identity. Bud checks therefore use active row exposure as presentation evidence (Droplet releases input and accessibility on dismissal), not a claim that the runner directly observes that hidden cover. The native Replay cover is separately queryable and is required to disappear. A successor sheet's cover is not incorrectly attached to the preceding More-menu closure. Unknown native dismissal regions still fail with facts rather than authorize an unverified outside point.

| Diagnostic affected | Log prefix | Question |
| --- | --- | --- |
| Menu/native Replay closure failure | Menu remained open | Which active content or relevant native cover survived? |
| Asynchronous tool-settings close | Popover closure pending | Which setting was awaiting bounded probe publication? |
| Missing or unstable canvas text AX target | Insert item point fallback | Which target facts forced use of the previous point? |

Validation: `python Scripts/lint.py` reports **0 errors, 25 warnings**; `git diff --check` passes. Reviewed changed Swift signatures, typed queries, labeled loop, optional cover closure, throwing waits and all changed-helper call sites. No test, assertion, allowance, skip or sleep changes. No Swift toolchain/simulator is available on this Windows host: compilation, retained-shell closure, native Replay geometry, fallback selection and net runtime still require macOS CI. Savings from removing class-wide key diagnostics are unmeasured. Earlier app/CI-only limitations recorded in Round 10b remain unchanged.

## Review fixes (round 2) - 2026-11-06

These corrections supersede round 1's fixed-point fallback for unavailable item frames. Read both job prompts, the relevant findings/verdicts, current canvas accessibility and Elements secure-field implementations, and shared-helper callers. Only NibUITests files change.

| Review issue | Root correction / decision | Next-run requirement |
| --- | --- | --- |
| GIPHY masked key (major) | ElementsSecureField starts secure and its Show text button toggles isSecureTextEntry. Resolve the existing native form once, tap its typed Show text control, then wait for the revealed TextField in that same scope before replaceNativeText. Expose the existing nativeFormContainer helper to the test without changing its resolution rules. Exact clear/replacement verification and every save/remove/search/retry assertion remain. | The revealed field verifies the exact invalid test key before Save Key; the complete save, retry-query retention and remove flow finishes. |
| Stale canvas fallback (major) | CanvasAccessibility gives text and sticky items page-container frames; UIKit exposes their current transformed AX frames. Require two consecutive equal reads of the full item, canvas, window and app frames plus content offset, zoom and page identity, with no keyboard. Derive both selection and re-edit coordinates from the visible item intersection and the sampled app origin. If item geometry is unavailable, the current probe has no independent item/page-local geometry from which to reconstruct a safe fallback: preserve the fallback log, add screenshot/hierarchy diagnostics and throw explicitly. Remove the former insertion-point route entirely from settledCanvasPoint. | TextBoxStyle, StickySevenColours, StickyCollapse, URLLink and NativeDiagram use the moved item's current frame; missing/unstable geometry fails before a selection or double tap, with no stale insertion-point tap. Original selection/edit/content assertions remain. |
| Shared dismissSheets risk (minor) | Retained behavior as the review conditionally recommends: no new full-suite failure establishes a non-Chrome regression, and changing closure requirements speculatively would undo H4. Inventoried Canvas, Capture, Ink, Library, Selection, Insert and Chrome callers. | Full-suite CI must check unidentified native dismissal regions, active More rows and delayed toolSettingsOpen; if non-Chrome regressions occur, scope the final closure checks to an opt-in Chrome parameter. |
| Non-lazy reveal direction (minor) | Restore the previous false default when a non-lazy target disappears between the initial snapshot and first iteration. Lazy homing/paging and all existing move bounds remain unchanged. | Ordinary forms retain their bounded reveal path instead of returning silently on that race. |
| Chrome inferred button type (minor) | No change needed per review: current prefix-matched callers are buttons/action rows, and Show document tabs explicitly passes .switch. | CI retains typed button lookup and the explicit switch override; any future non-button caller must pass its actual type. |

| Diagnostic affected | Log prefix | Question |
| --- | --- | --- |
| Missing/unstable item geometry | Insert item point fallback; Insert item geometry unavailable | Why could no safe current item coordinate be established before refusing the tap? |
| Successful selection/re-edit | Insert settled item | Which current visible item frame and content offset produced the tap? |

Source review covered Swift optional comparisons, CGRect arrays and coordinate conversion, closure captures, typed field queries, helper access/signatures, and all callers of the changed helpers. No test declarations, assertions, allowances, sleeps or skips changed. Required checks: `python Scripts/lint.py` **0 errors, 25 warnings**; `git diff --check` passes. No Swift compiler or simulator is available here; compilation, revealed-field AX typing, item-frame availability and the shared dismissal risks still require macOS CI. No measured runtime improvement is claimed. One new review commit with the requested attribution; no amendment or push.

## Round 10c

Base: f067280, work/ui-round-10, 2026-11-06. Read both job prompts, Round 9/10 notes, the four current reviewer findings and current app/helper sources. These corrections supersede the earlier decision to retain strict shared dismissal, the default-velocity lazy scan and the unconditional half-viewport start bound. Only NibUITests changes.

### 1. Chrome menu identity and closure audit

`ChromeMenuList.rowStack` in `NibKit/Sources/FeatDocChrome/NavBar.swift` builds a Button whose label is the title and whose identifier is `cmd.` plus the command (or row.id). `menu()` now finds the non-canvas, hittable ScrollView with an identifier-OR-label predicate, then resolves the enabled button in that surface. This removes the title-as-identifier miss and prevents an app-wide same-title tap. The existing strict closure wait remains.

All **14 calls in 11 tests** below run descriptor rows. `DocumentContainerViewController.menuRows` maps each descriptor through `row(_:section:context:)`; its action sets **openMenu = nil before chrome.run(item)**. `ChromeWindow.run(_ item:)` resolves parameters and dispatches the command through tap. `ChromePopovers` binds presentation to openMenu and builds row content only while that menu is selected. More's overflow Add Page entries are flattened into sections through the same row wrapper, not a submenu navigation action. Therefore every listed row closes its original droplet even when its command opens a successor sheet. No current caller needs an exemption from the closing wait. Start Live Session is a later tap in Share Live, not an argument to menu().

| Caller (test name without `test`) | menu arguments / count | What closes the droplet; subsequent command |
| --- | --- | --- |
| TitleRenameChangesLibraryTitleAndKeepsDocumentIdentity | title, Rename (1) | row wrapper clears openMenu; panel.open chrome.rename |
| TitleMoveActuallyMovesNoteAndPreservesContent | title, Move to Folder (1) | same wrapper; panel.open chrome.move |
| TitleRecognitionLanguageAppliesAndReopens | title, Recognition Language (2) | same wrapper; panel.open convert.language |
| TitleCollaboratorsOpensSharePanelAndCloses | title, Collaborators (1) | same wrapper; panel.open collab.share |
| AddPageMenuAddsExactlyOnePageAndUndoRedo | addPage, Current Template (1) | same wrapper in Add Page or More overflow; page.add with current-template parameters |
| ShareExportOpensCorrectSheetAndCancelIsInert | share, Export all… (1) | same wrapper; export.present with scope all |
| SheetDismissAndEscapeDoNotRenameDocument | title, Rename (2) | same wrapper; panel.open chrome.rename |
| TitleCloseOtherTabsKeepsChosenDocumentWithoutDeletingOthers | title, Close Other Tabs (1) | same wrapper; tab.closeOthers |
| ReadOnlyButtonBlocksInkAndTitleEditRestoresTools | title, Edit (1) | same wrapper; view.setReadOnly with on false |
| PDFCopyPastesSelectedTextIntoRenameField | title, Rename (1) | same wrapper; panel.open chrome.rename |
| PresenceDoesNotInventPeersAndTitleDetailsRetainLiveSession | title, Collaborators (2) | same wrapper; panel.open collab.share |

Checked descriptors in FeatDocChromeFeature, FeatConvertTextFeature, FeatCollabFeature, AddPageMenu, FeatExportUIFeature and FeatReadOnlyFeature (the latter suppresses its duplicate Edit entry when Chrome supplies one). CI must reach the original rename/move/language/collaboration/page/export/tab/read-only/PDF/presence assertions and observe closure before subsequent input.

### 2. Opt-in strict popover dismissal

`dismissSheets(requireClosedPopover: false)` preserves the pre-round-10 close-button/sheet loop. The default path does not run the new native-popover dismissal transaction or the eight-second settings/More/More tools closure waits. At the old return point it logs surviving settings, native surfaces/dismissal regions and active bud rows with `Popover closure advisory`, then returns. A missing or undecodable probe is also log-only. The pre-existing eight-iteration failure for sheets that cannot dismiss remains. All eight Chrome and ten Insert call sites explicitly pass true, retaining H4/I8 native-popover geometry checks, strict closure waits and Audio panel ordering. Other classes acquire no new throw or closure timeout.

Re-read every dismissal caller found by grep: Canvas pencil-only input; Capture document-tabs setup; Ink closePreferences; Library external Files-drop export; Selection comment creation, Layers, alignment/snapping and both AI setup/result dismissals. Their existing argument-free calls use the compatible default. Chrome closeEditing, language (twice), collaboration, export, rotated Go to Page, Bridge and presence opt in. Insert provider, AI result, both collection exports, invalid-GIF failure diagnostics, GIPHY, Audio export, Replay modes, timestamp-link setup and transcript opt in. No class outside Chrome/Insert opts in.

### 3. Small viewport and scan gesture compatibility

The row-gap and plain-row passes of formDragStart use the original **24pt** minimum when the clipped viewport height is below **300pt**, retaining the half-viewport minimum for taller lists. Slider/holding-control clearance and leading-inset rules are unchanged. Lazy scan gestures now use `.slow`; `.fast` is restricted to lazy edge homing without sliders. Existing targets and slider-bearing forms remain slow. No sleep or gesture hold was added; six homing moves and sixteen total moves remain the bounds.

Re-read the sole formDragStart call inside revealFormElement, both reveal overloads and all direct class callers: Create Calendar summaries; Ink Squeeze heading/scoped row, switch reveal and Pencil preferences; Library's wrapper and its folder-name, favourite (twice), hex, emoji and About version uses; Pages button fallback; Insert/Selection provider presets. Also checked shared requireControl, setSwitch and focusField reveal paths, including the class-level wrappers in Canvas, Capture, Chrome, Ink, Insert and Selection, and Chrome's scoped menu/Time Keeper calls. Target re-querying, ancestor/window/keyboard clipping, value checks, transient-surface failure handling and ordinary-form fallback are unchanged. CI must show short popovers finding safe starts and one-way scans observing target rows without coasting past them, while retaining every caller's original outcomes.

### 4. Settings typed lookup with fallback

Replaced Insert's button-only settingsButton with one settingsControl helper. It first tries findControl with `.button`; a miss immediately uses the existing untyped requireControl, including lazy reveal and bounded readiness, rather than spending a typed-only timeout. Both paths require an enabled control. Every helper caller was reviewed: configureProvider (Editing chord check, AI, Add provider), GIPHY (both Remove Key actions, Editing chord check, Elements and GIFs) and transcript (Editing chord check, Recording Settings). The two existing three-second chord postconditions retain that budget; transcript retains its prior eight seconds. All row reveals retain eight seconds. Show text stays typed because the current secure-field implementation establishes that it is a button; exact revealed-key verification and all save/remove/search/retry assertions remain.

### Validation and remaining runtime evidence

`python Scripts/lint.py`: **0 errors, 25 warnings**. `git diff --check`: clean. Python comparison against f067280 confirms unchanged test declarations, XCTAssert lines, execution allowances and sleep/skip inventory in all three edited Swift files; only NibUITests paths changed. Re-read changed Swift blocks and all callers above for API signatures, throwing closures, predicate placeholder counts, optional state reads, CGFloat inference and gesture velocity types. No new XCTest API is introduced: containing(NSPredicate), scoped requireControl and the slow/fast gesture overload already exist in this target. Default argument and explicit opt-in labels match every call; native-state errors cannot escape the advisory path.

No Swift toolchain, Objective-C compiler or simulator is available on Windows. Compilation and runtime accessibility/gesture timing remain for GitHub Actions: particularly label-based menu containment, successor-sheet transitions, short viewport safe starts, slow lazy scan coverage and Settings cells/static text fallback. No measured speedup is claimed; typed hits retain their query saving, while slow scans may cost more per move. All four review items are addressed; earlier app/CI-owned limitations remain as documented in Round 10b. One new commit with the requested two-line attribution, no amendment and no push.

## Review fixes (round 4) - 2026-11-06

Read jobs 10a, 10b and 10c, the previous QA notes, the current review findings, the Replay diagnosis/verdict and recorded failure hierarchy, and the current Replay, Elements and palette implementations. Only NibUITests files change.

| Review issue | Root correction / decision | Required CI evidence |
| --- | --- | --- |
| Replay dismissal (major, I8) | ReplayOptionsView supplies Replay handwriting as a label; the recorded tree has that Switch inside a ScrollView with no native Popover. Replace identifier-only containment with the identifier-OR-label descendant predicate used for Chrome menus. Preserve the identified surface exclusion frames, safe outside point, and joint eight-second content/PopoverDismissRegion disappearance check. | ReplayModesAndSeekFromRealTimestampedInk closes each of Spotlight, Reveal and Static before the original pixel and seek assertions. |
| Collection export transitions (major) | ElementsModel.export sets its child share sheet without clearing toolbar settings. Both export tests explicitly pass closingToolSettings: elements to strict dismissSheets. After the native-sheet loop, the helper matches the probe's settings owner, verifies it is the selected tool, then taps tool.elements through requireControl. Palette.tap delegates reselection to ToolbarModel.toolReselected; NibToolOptionsState closes open settings for tools with or without a strip. The existing nil-settings wait now also runs unconditionally for this explicit opt-in. Both tests additionally require ActivityListView to disappear before reopening Elements and Import Collection. Native dismissal and every import, cancellation, destination and content assertion remain. | Both tests reach Import Collection after native sharing and the settings bud close; cancel preserves the fixture, and save/reimport finds Stickers in On My iPad with its assets intact. |
| Lazy reveal coverage (minor) | Increase only the lazy-search move limit from 16 to 22 so up to six top-homing moves do not consume the subsequent scan budget. Non-lazy limit, six-move homing bound, repeated-range exits, slow scan velocity and safe gesture geometry remain. | Deep lazy rows are reached within the unchanged test allowance; short and ordinary forms preserve their prior path. |
| Chrome menu-selection inference (minor) | No change, as requested unless CI demonstrates a command that legitimately retains More tools. No new CI evidence is available on this host. | Full-suite CI identifies any cmd.* exception before narrowing selectsTool. |

Caller audit: all dismissSheets uses in Canvas, Capture, Ink, Library, Selection, Chrome and Insert retain their existing defaults/strict mode; only the two collection exports request a settings-closing action. Replay still uses strict dismissal and its separate Replay in Full Screen disappearance assertion. Reviewed reveal callers in Create, Ink, Library, Pages, Insert, Selection and Chrome, plus shared requireControl, setSwitch, focus and command paths. No signatures lose compatibility; absent lazy targets alone receive the larger bounded search.

| Diagnostic affected | Log prefix | Question |
| --- | --- | --- |
| Both collection export transitions | Popover close retained settings | Which identified tool button closed the retained parent bud after native dismissal? |
| Lazy reveals | Form move timing / Form reveal timing | How many homing/scanning moves were needed, and what was their elapsed cost? |
| Replay dismissal failures | Menu remained open / Popover still open | Did content or the native cover survive, or was safe geometry unavailable? |

Validation: `python Scripts/lint.py` reports **0 errors, 25 warnings**; `git diff --check` passes. Source review covers changed Swift blocks, caller argument labels/defaults, predicate placeholders, optional-binding scopes, existing query APIs and bounded waits. Existing test declarations, XCTAssert lines, execution allowances and sleep/skip inventory are preserved. Compilation and XCUITest execution remain unavailable on Windows and require GitHub Actions, particularly native sharing, palette reselection and Replay dismissal. No runtime saving is claimed; the extra lazy moves can increase worst-case search time. Earlier app/CI-owned limitations in Round 10b remain. One new round-4 commit with the requested attribution, no amendment or push.

## Review fixes (round 5) - 2026-11-06

Read jobs 10a, 10b and 10c, the prior QA notes, the current reviewer findings and shared-helper callers. NewNotebookSheet and QuickNoteFlow still use interactiveDismissDisabled(model.isWorking), so an idle sheet can accept a downward dismissal gesture. No simulator evidence establishes that dismissal occurred; this correction removes the reviewed gesture regression at its source. Only NibUITests files change.

| Review issue | Root correction | Required CI evidence |
| --- | --- | --- |
| Lazy reveal can dismiss an idle sheet (major) | For an absent target with a visible app sheet, scan toward the bottom first and reverse only after a repeated visible range, using the existing two-direction search. Other lazy lists retain bounded top homing followed by a downward scan. All reveal drags now use slow velocity, including homing when AX does not expose a sheet. Preserve the six-homing-move cap, 22 total lazy moves, 16 ordinary moves, safe starts, clipping and value checks. | Create, Settings and provider sheets stay presented while lazy fields are revealed; Customise Toolbar still reaches deep rows within the unchanged allowance. |
| Array inference (minor) | Declare fillNativeForm's search scopes explicitly as [XCUIElement] and resolve that list once per batch. | UI test target compiles in Swift 5 mode. |
| Default modal lookup escapes its container (minor) | Default nativeFormContainer entry searches only that container. App-wide fallback is retained only for an explicit non-app scope; explicit app scope searches app once. Missing default-modal fields therefore reveal or fail instead of selecting a same-named background field. | Modal Title/Name entry never edits a background field; Calendar and explicit Time Keeper entry retain their prior lookup routes and exact value checks. |

Caller audit: re-read direct reveal calls in Create (Calendar summary), Ink (Pencil scoped headings/rows, switch and preferences), Library (folder editor, favourite, hex, emoji and About), Pages (button fallback), Insert and Selection (provider preset), plus shared requireControl, setSwitch, focusField and command paths. Signatures and existing-target direction behavior are unchanged. Re-read every fillNativeForm call: Chrome replace/ruler defaults, explicit Time Keeper form, Insert/Selection provider defaults, Insert GIPHY search and explicit Create Calendar app. Default callers keep modal scope; both explicit non-app callers retain fallback. No caller, test assertion, allowance, sleep or skip changes.

| Diagnostic | Log prefix | Question |
| --- | --- | --- |
| Every reveal with a container snapshot | Form reveal path | Was the path sheet bottom-first, slow home then scan, or target-directed? |
| Two-direction search reaches a repeated range | Form search reverse | Which path reversed, in which drag direction, after how many moves? |
| Existing move/reveal timing | Form move timing / Form reveal timing | Does slower homing remain within the test allowance? |

Validation: `python Scripts/lint.py` reports **0 errors, 25 warnings**; `git diff --check` passes. Source review checked the changed search branches, existing hasVisibleFrame/snapshot/gesture APIs, optional and identity comparisons, explicit array typing and caller compatibility. Windows has no Swift toolchain or simulator, so compilation, sheet accessibility exposure, gesture dismissal behavior and runtime cost remain for GitHub Actions. Slow homing may add time; no speedup or runtime pass is claimed. One new round-5 commit with the requested attribution, no amendment or push.

## Round 10d

Merged current integration successfully before editing. Its labelled popover scrollers and direct single-page Settings sections remain authoritative; no anonymous-container lookup fallback or intermediate Plugins/Bridge row was added. Only NibUITests files are edited. Windows cannot compile Swift or run XCUITest.

### 1. Close ordinary modal forms before strict popover rejection

The review is confirmed by the plain-Other modal representation and NibSheetHeader's sheet.dismiss control. Strict dismissal now resolves the foreground Other subtree following PopoverDismissRegion, excludes document/library probe ancestors, and matches its own enabled close control by identity and frame before trying outside dismissal. cmd.panel.close is excluded from this form lookup. A form without a close control supplies its exclusion frame to the existing outside-region route; Replay's labelled ScrollView route remains. A bounded postcondition checks the form/cover before continuing, with facts on failure. Default advisory callers retain their old path and budgets.

Re-read every dismissSheets caller in Canvas, Capture, Ink, Library, Selection, Chrome and Insert, including closeEditing, settings/provider setup, collection exports, Replay, Audio and successor share forms. Strict callers can close Document Editing through Done; closing a child still prevents closing the background Audio panel. No assertions, tests or allowances changed.

| Diagnostic | Log prefix | Question answered |
| --- | --- | --- |
| Strict modal dismissal | Modal form close control | Which foreground form and scoped close control received the tap? |
| Successful form dismissal | Modal form closed | Did the form and its dismissal cover disappear? |
| Failed form dismissal | Modal form remained open / Modal form hierarchy | Which form, cover and tree survived the close action? |

CI must verify plain-Other ancestry, close-button identity/frame binding, Document Editing closure and Replay/Audio ordering. Existing XCTest snapshot/query APIs are reused; no local compile/runtime pass is claimed.

### 2. Reveal from observed list position, without pull-down probing at the top

Removed the app.sheets guard entirely. The list snapshot supplies its own percent value or vertical scroll-bar percent (the recorded native hierarchy exposes `Vertical scroll bar, ...` / `0%`); nested scroll views are excluded. Without a percent, an instantiated first row above the list's top proves a nonzero position. A row inside the viewport does not prove it is the first logical row of a lazy list. Zero and unknown positions skip homing and scan bottom-first. Every subsequent downward drag, including reversal and existing-target searches, rechecks this evidence; top/unknown stops safely instead of probing by pulling the form down. Homing switches to scanning as soon as the top is reached. Repeated ranges, six homing moves, 22 lazy/16 existing-target moves, slow delivery, clipping and slider/switch value checks remain bounded and unchanged in strength.

All downward start-point passes now share a minimum inside the content: at least 80pt or 35% below the clipped viewport top, and at least 96pt below the known Other form's top (or list top if unclassified). No pass or fallback can start at the grabber/header. A resolved Other form also clips the viewport; losing its dismissal cover after a gesture fails immediately. A missing top signal is logged and may leave an above-fold target for the caller's existing failure rather than risking dismissal; CI must establish native percent coverage.

| Modal/form callers reviewed | Protection |
| --- | --- |
| Customise Toolbar (Chrome layout/show/hide/reset/apply) | Its lazy collection starts bottom-first at zero/unknown; only observed nonzero position permits a content-interior downward gesture. |
| Document Editing (Chrome) and Settings: Editing/Tabs/Layers/Alignment, Writing/Shape Recognition, Stylus/Apple Pencil/Squeeze/haptics, AI, Elements and GIFs, Recording Settings, Plugins, Bridge, About (Canvas, Capture, Chrome, Ink, Insert, Library, Selection) | All untyped/typed requireControl and explicit detail-list reveals use the same position guard, clipped viewport and minimum start; no Sheet-node dependency or extra single-page navigation. |
| Add provider (Insert, Selection) | Preset reveal and missing Name/Base URL/Chat model/Transcription model through fillNativeForm/focusField inherit both the initial and per-move guard. |
| New Notebook and other creation forms / Quick Note | Any shared missing-field/focus reveal has the same guard; Create's existing direct field/keyboard routines are not changed into drags. |
| Customise Folder (Library) | Name/hex/emoji/favourite existing-target reveals cannot drag down at zero/unknown; control-value checks stay intact. |
| Rename/Save Layout/ruler alerts, Share and Export/collection or Audio share sheets, colour/import forms, Delete Specific Items and Go to Page | Shared fallback reveal uses the same rule even when no Other form can be classified; small viewports retain the 24pt travel rule. No new swipe is added. |
| Time Keeper, tool buds, object menus, Pages fallback, library cards, Calendar event summary | Nonmodal callers also use their own position, retaining target re-querying and caller assertions. Explicit Time Keeper and Pencil scopes remain compatible. |

Re-grepped every class and read all direct reveal callers, requireControl/findControl wrappers with scroll enabled, setSwitch, fillNativeForm, focusField and shared command/PNG-share fallbacks. No caller signature or control-value postcondition changed.

| Diagnostic | Log prefix | Question answered |
| --- | --- | --- |
| All reveals | Form reveal path | Which list-position evidence, cover and Other form selected homing or bottom-first? |
| Each downward attempt | Form downward drag prevented / Form lazy edge | Was the top reached, or was the position unknown, before another drag? |
| Delivered gestures | Form drag before | What percent/first-row evidence and minimum content y justified this start point? |
| Lost modal | Form container changed | Did the cover vanish during reveal? |

Validation for items 1-2: python Scripts/lint.py reports 0 errors, 25 existing warnings; git diff --check passes. Swift APIs, optional Bool comparisons, numeric conversion and all three start-point passes were reviewed statically. CI must verify percent exposure, plain-Other clipping and retained below-fold field access; no local runtime pass or speedup is claimed.

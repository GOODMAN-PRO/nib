# QA support 12

## Round 12a

Windows source-only work from integration 5040b001. Read Round 11a/11b/11c, README and the complete V3 findings and paired verdicts; corrections take precedence. Only NibUITests changes. No local Swift/Objective-C compiler or simulator; CI owns runtime verification.

### G1 - mounted document editor

Confirmed V3:whiteboard#1 and its holds=true verdict: the light portrait attachment at 05:32:32.108 preceded editor chrome layout at 32.385. Current openDocument and capture predicates still accept the session model before mounting. openDocument now additionally waits up to 15 seconds for a visible editor surface and logs time from the opening tap. Canvas notebooks/whiteboards expose nib.canvas; TextDocViewController exposes the Text document collection. StudySetEditorView has no root accessibility identifier: its own Cards header plus Language menu identify its mounted root in both compact and regular layouts, including empty sets. This uses actual source-exposed elements, not a guessed identifier or a document title in the library.

Audited all openDocument callers in Canvas, Capture, Chrome, Create, Ink, Insert, KeyProbe, Library, Pages, Selection and Smoke. The signature and model predicate remain; Create's empty/reopened text and study sets, Library's every-kind loop and Capture's mixed-kind tabs do not require a canvas. Should unblock all whiteboard variants and protect every shared caller. Next CI must log the correct root before returning, preserve the non-canvas creation/reopen tests, and show the editor rather than the library. Visible AX geometry proves mounting, not rendered tiles (G2).

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| All openDocument callers, especially Capture test18 and Library every-kind | Document editor mount | Which actual editor mounted, and how long after the tap did it become visible? |

### G2 - rendered canvas content

Confirmed V3:whiteboard#0 with the verifier correction: grey placeholders and the missing render gate are proven; whether the renderer regressed is UNKNOWN. New dark portrait waited 4.7 seconds versus old 3.8 and still showed placeholders, so faster capture alone cannot explain all variants. Current capture() only reads model state; all notebook routes, direct whiteboard capture and presentation/tabs pass through it. After that predicate it now requires qa.canvasSettled == true for page-bearing documents, sharing the original 15-second deadline rather than adding another allowance. The companion app owns the fact (every visible tile has real content and none pending); tests do not reconstruct it. Missing/malformed facts fail, with the last value/error and the named reason 'canvas did not settle' in ui.log.

Text/study documents have no pages and retain their own content gates. The deliberate failedRender fixture is the explicit exception: capture33 must display the error, not await impossible successful rendering; its original scenario, failure-count and Try Again gates remain. The assistant's existing foreground contrast/geometry gate is retained unchanged. Should unblock capture18 and protect every page screenshot (04-14, 17, 21-22). Next CI must show true canvas facts before normal attachments, no normal attachment after a timeout, and the error fixture still captured. Compare app render timing before assigning a latency cause.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Every page-bearing Capture screenshot except intentional render error | Capture fact ready / Capture fact timeout | Did the app report settled tiles within the shared 15-second budget, or was the last fact false, malformed or missing? |

### G3 - sidebar thumbnail images

Confirmed V3:sidebar#0 and its holds=true verdict: the light landscape shot followed the tap at t=16.92 by about 1.75 seconds, between the cache probes at 05:25:16.086 and 16.273-16.372. Current capture12 waits only for sidebar.pages. The Pages screenshot now also requires qa.thumbnails visible > 0 and loaded == visible, after state/canvas readiness and within the same capture deadline. Missing/malformed facts fail with their last value; no test-side thumbnail reconstruction or retry. Outline keeps its separate No outline yet gate. Should unblock all four capture12 variants. Next CI must show a positive complete thumbnail count before attachment18, or a named failure rather than a blank-thumbnail review image. Why that pipeline started late and the app's nil-image retry policy remain app-owned questions.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Capture test12, all variants, Pages shot | Capture fact ready / Capture fact timeout (fact=thumbnails) | How many visible cells had images at the capture boundary; was the fact absent? |

### G4 - Settings bar evidence

Confirmed V3:sheets#0 with holds=false correction. Done is blurred in three editing screenshots, but the double declaration and push structure also existed in the crisp build; cause remains UNKNOWN. Current source still pushes SettingsPageHost and supplies sheet.dismiss in its navigation toolbar. After both Document Editing and Stylus pushes, capture16 now requires the containing navigation bar and hittable sheet.dismiss, plus identical full-resolution RGBA crops from two screenshots at least 300 ms apart, within five seconds. Reuses the assistant's uprightImage and CaptureReadiness.cropRect infrastructure; its existing checker is contrast plus stable geometry, not pixel equality, so a reusable region equality check is added without weakening that assistant policy. XCTest predicate polling determines the actual sample interval (logged), with a 300 ms minimum; no sleep/fixed delay.

A timeout throws 'Settings bar did not settle', logs geometry/byte count/interval/equality, and preserves the last two full frames as keepAlways screenshot attachments before further diagnostics. No normal settings shot follows a failure. Should unblock capture16's pushed-page images if transient; a persistently changing bar fails for the app investigation. A stable blurred bar can still pass equality: this gate proves stability, not correct typography; the next visual review must inspect it. Next CI must show stable bar pairs or deliver both failed frames to the companion job, without claiming a UIKit/app cause.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Capture test16, Editing and Stylus, all variants | Capture pixel settle / Capture pixel timeout | Was the actual navigation bar hittable and pixel-identical across the logged interval, or did it keep changing/miss its region? |

### G5 - audit every capture boundary

Reviewed every capture call and all 96 declarations against current sources. The shared capture path now adds the requested observable content-region pixel check for grid/list/folder covers (LibraryGridView.LibraryCover's async load), the actual search.open result rows headed Physics — Motion (LibrarySearchView.SearchResultRow, not an underlying library card), the continuous New Notebook form containing No cover and Paper (TemplatePreview's async raster), the plugin list (PluginListView), the practice face (PracticeView), and the export form (ExportDialog). Each region is resolved from a fresh snapshot, clipped to real ancestor scrollers/window, then compared at full pixel resolution with the G4 helper. These checks share the original capture deadline after state/canvas facts. Missing regions fail with named screen reasons, last geometry and two keepAlways images; no fixed delay was added.

Plugin readiness additionally requires a loaded Enable switch or No plugins yet and no Loading plugins; Install from alone was not evidence of a loaded list. Practice additionally requires Question side containing one of the three fixture fronts (Velocity, Acceleration, Force), so the always-present Flip Card header cannot substitute for a loaded card. Current export defaults to All, and ExportPageChoice thumbnails exist ONLY for Selected: capture17 has no asynchronous page preview in this source. We retain its route and check the content region enclosing File name and Save to Files, which also contains page-choice images when present, rather than change the screenshot to a different scope. Document search already waits for the result count's 'Search result ... of ...' AX element; its page pixels additionally get G2. Text capture already waits for the actual fixture paragraph. No speculative app fixes.

The assistant policy and its existing regression-test entry point are preserved, but its private real-app wrapper now throws after the original diagnostic/XCTFail if readiness was not confirmed. This closes the existing continueAfterFailure path that could still emit a normal review attachment after a failed assistant gate. The private Capture wait now subtracts the first predicate's elapsed time before polling, so snapshot work does not start a fresh full budget. Settings also requires the destination's real navigation title before comparing its bar; an unchanged old bar cannot stand in for the pushed page.

Should protect capture01/02/03/15/17/20 (all four variants) and prevent a misleading capture14 after failure. Next CI must show content-region coordinates and two identical samples before each normal image, no ordinary attachment after timeout, actual result rows rather than background library cards, a loaded plugin/empty-list state and the study front text. Review the images as well as logs: pixel equality is the requested fallback where source hides bitmap readiness from AX; a static placeholder or persistent blur can be stable. It is not an app-owned completion signal like canvasSettled/thumbnails. The next visual audit must identify any such residual case for an app fact rather than silently treating stability as proof of image semantics.

#### Complete capture inventory

All rows retain their original state predicate. 'AX' means a mounted accessibility element/geometry, not proof of raster completion. 'Pixels' means identical real cropped screenshots at least 300 ms apart. 'Canvas' means the companion app's rendered-content canvasSettled fact, after state and inside the same 15-second deadline. Every row applies to all four appearances/orientations of the named test group.

| Attachment / test group | Existing gate and what it actually established | Final drawn-content gate / decision |
| --- | --- | --- |
| 01 library-grid / 01 | library model + notebook card AX; cover could load later | Visible document-card region Pixels |
| 02 library-list / 01 | library model + notebook card after List; cover could load later | Visible document-row region Pixels |
| 03 open-folder / 01 | library model + Back to Documents and Lecture notes AX | Visible folder document-card region Pixels |
| 04 library-search / 02 | library model + notebook label, potentially the background card | Actual search.open result row with notebook heading + result-region Pixels |
| 05 new-menu / 03 | library model + Notebook choice AX | Static menu content already offered; no async content in this menu |
| 06 new-notebook / 03 | library model/panel + New Notebook title; preview/tiles could load later | Continuous form containing cover and paper sections + Pixels |
| 07 canvas-palette-left / 04 | document/dock model + visible More and Colour 1 | Canvas; existing palette visibility checks retained |
| 08 canvas-palette-top / 04 | document/dock model + visible More and Colour 1 | Canvas; existing palette visibility checks retained |
| 09 canvas-palette-bottom / 04 | document/dock model + visible More and Colour 1 | Canvas; existing palette visibility checks retained |
| 10 options-bar / 04 | document/pen model + menu.toolSettings AX | Canvas; static options controls already mounted |
| 11 pen-options / 05 | document/tool model + Fountain Pen AX | Canvas + existing actual settings-title requirement |
| 12 highlighter-options / 06 | document/tool model + Highlighter AX | Canvas + existing actual settings-title requirement |
| 13 eraser-options / 07 | document/tool model + Eraser AX | Canvas + existing actual settings-title requirement |
| 14 lasso-options / 08 | document/tool model + Lasso AX | Canvas + existing actual settings-title requirement |
| 15 shapes-options / 09 | document/tool model + Shapes AX | Canvas + existing actual settings-title requirement |
| 16 text-options / 10 | document/tool model + Text AX | Canvas + existing actual settings-title requirement |
| 17 lasso-object-menu / 11 | stroke/selection model + duplicate action AX | Canvas + existing selection/menu requirements |
| 18 page-sidebar / 12 | sidebar.pages model only after toggle | Canvas + thumbnails visible > 0, loaded == visible |
| 19 outline / 12 | outline.tab model + No outline yet AX | Canvas + actual empty-outline text; no async entries in fixture |
| 20 document-search-matches / 13 | document model + Search result ... of ... count AX after query | Canvas + existing result-specific element; count proves results, not a toolbar title |
| 21 ai-assistant / 14 | document/items/panel model + rendered pen/note contrast and 0.5-second geometry gate | Canvas + retained 20-second assistant foreground gate; abort ordinary capture on its failure |
| 22 plugin-manager / 15 | library model + Install from action AX; list may still load | Loaded/empty-list marker, no Loading plugins, list-region Pixels |
| 23 settings-general / 16 | library model + visible Settings navigation and Done control | Static root section content, no push; existing surface gate retained |
| 24 settings-editing / 16 | library model + Open documents in tabs AX | Destination title + hittable sheet.dismiss + whole bar Pixels within 5 seconds |
| 25 settings-stylus / 16 | library model after push (no destination content wait) | Destination title + hittable sheet.dismiss + whole bar Pixels within 5 seconds |
| 26 export-sheet / 17 | document model + Save to Files AX | Canvas + actual export form Pixels; current All scope has no page-choice preview |
| 27 whiteboard / 18 | document/itemCount == 3 model only | G1 mounted canvas + Canvas |
| 28 text-document / 19 | document model + fixture paragraph AX | G1 Text document collection + retained actual paragraph requirement; no tiled canvas |
| 29 study-session / 20 | practice panel model + Flip Card header geometry/hittability | Actual Question side/front text + card-region Pixels |
| 30 presentation-mode / 21 | external-display capability, Stop Presenting AX + document model | Canvas + existing capability/action requirements; four existing device-only skips unchanged |
| 31 three-document-tabs / 22 | document model + Tab 3 of 3 / 3 open documents AX | G1 mounts each kind + Canvas for final notebook; tab count AX retained |
| 32 empty-folder / 23 | library model, folder breadcrumb and zero document controls | Intentional empty content, no thumbnails to await; existing empty-folder gate retained |
| 33 page-render-error / 24 | failedRender/failureCount == 1 model + settled hittable Try Again | Intentional error UI; successful tile fact is inapplicable, all error assertions retained |

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Capture 01/02/03/15/17/20, all variants | Capture content region | Did the source-defined content/loaded marker exist, and which clipped pixels were tested? |
| Same content captures | Capture pixel settle / Capture pixel timeout | Did real content pixels stop changing within the existing budget; what did the last two frames show? |
| Capture 14, all variants | Assistant readiness timeout (existing) plus thrown failure | Was unconfirmed foreground rendering diagnosed without emitting a normal review image afterwards? |

### Final review and verification

Re-read all changed Swift blocks and surrounding control flow, the unchanged NibTouchPaths.h signatures, all openDocument class callers and both CaptureReadinessUITests callers of checkAssistantReadiness. No Objective-C changes or new SPI calls. Reviewed XCTest queries/snapshot attributes, optional bindings (no same-scope guard rebinding), enum cases, escaping/nonthrowing predicate closures, region coordinate mapping, CG image buffer formats, deadlines, and all call labels. The shared openDocument signature and strict model-state assertion remain unchanged. Capture's private assistant wrapper is its only changed throwing call site; the static regression-test API is unchanged. Existing predicates, assertions, 96 capture test declarations, other class test declarations, allowances, sleeps and skips are preserved.

Required validation: python Scripts/lint.py reports **0 errors, 25 warnings**; git diff --check (including against 5040b001) passes. Source inventory checks preserve all existing test declarations, XCTAssert lines, allowances and sleep/skip calls. Only three NibUITests paths changed. Five cluster commits with the requested attribution body; no push.

Runtime saving estimate: **0 seconds claimed**. These gates intentionally add necessary readiness work. The 32 new content-region checks plus eight bar checks require at least 12 seconds of sample separation across the class, plus AX/screenshot cost and actual loading time; roughly 1-3 additional minutes on an otherwise healthy run is an unmeasured planning estimate, not a runtime result. All existing test allowances remain. Synchronous XCTest AX/screenshot requests cannot be interrupted by outer deadlines; late render observations are rejected and their cost is logged.

Unverified until macOS CI: Swift/XCTest compilation; UIKit/SwiftUI AX exposure of the text collection, study header/face children, navigation title/bar, scroller anchors and result labels; full-resolution crop equality in both orientations; the companion canvasSettled/thumbnails facts and their latency. Exact pixel equality may expose continuing animations and fail, intentionally retaining evidence. A stable placeholder remains a limitation of pixel fallback, documented above. The failedRender and All-scope export decisions are explicit source-backed exceptions, not missing work. All G1-G5 clusters are complete; none left unstarted.


## Round 12b

Merged integration 702e1519 cleanly (fast-forward). Read the original 12a brief, 12a support record, Round 11a-11c, README, and both complete R13 Chrome families with paired verdicts before edits. Current source and verifier corrections govern. Windows source-only work; no Swift/Objective-C compiler or simulator. Only NibUITests changes; no push.

### K1 - verify inside chord delivery

Confirmed R13:chrome-new-failures#0 and holds=true: ActiveLayerRoutes sent l/24 at t=70.99 but the t=72.44 log recorded flags 0; BackgroundReopen similarly sent 1/16 at t=136.88. Current Chrome key() supplied an empty closure, making both existing evidence-gated retry branches unreachable. It now accepts a defaulted throwing postcondition, executes it after native-field delivery or inside global chord(), and forwards Escape verification too. Moved existing panel, tool, palette, ruler, timer, tab restoration, rename undo/redo and independent-scene waits inside delivery. Layers setup and later open-panel chords verify the panel before subsequent actions. State-returning tab restoration now reads the verified state for the unchanged tool/zoom/ink assertions.

Audited every class's chord/key wrapper. Ink's digit/tool/undo/redo/palette waits and Library's Escape selection waits now run inside chord; width/colour immediate assertions are retained with bounded throwing readiness checks. Canvas/Selection require verification already; Capture/Create/Insert and other Pages chords already provide it. Insert key() is native-field-only. Pages' two consecutive Escape closures have no intervening effect wait and remain unchanged. Chrome's layer-number keys followed by drawing, lap recording followed by opening More, native Select All, and editing-end Escape have no isolated existing action predicate; no mutation was moved into a retry closure. Default empty verification remains only for those callers, not an existing deferred wait. The cause of modifier loss remains unknown.

Shared diagnostics remember the previous delivered key (including launch semicolon, HID/native/SPI input) and explicit runner action boundaries. Each proven loss logs a monotonic delivery timestamp, elapsed seconds since that preceding key, its name, and the preceding recorded action captured before delivery/postcondition polling. This is explicit helper instrumentation, not access to XCTest's private activity stack; raw test element taps outside these helpers are not automatically intercepted. No diagnostic query, sleep or extra retry is added. Existing retry evidence requirements remain unchanged.

Should unblock ActiveLayerRoutesNewInkAndKeyboardChangesSelectionScope, LayerVisibilityChangesViewerWithoutDeletingContentAndPersists, RenameLayerKeepsItsContentAndSupportsUndoRedo and BackgroundReopenRestoresTabsPageAndSavedEdits; protects other audited callers. Next CI must show one modifier-loss/undelivered retry only when proven, correct flags and the real action afterwards, or a failing postcondition after the single resend. Lost-chord context must identify the interval from the preceding key and preceding action; persistent loss remains a runner investigation.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| All shared chord callers, especially the four R13 regressions | Chord lost context | How long since the previous delivered key, which key was it, and which recorded action preceded this failed delivery? |

### K2 - Cancel under the decimal pad

Confirmed R13:chrome-still-failing#1 and holds=true: reopened Set Position's Cancel was polled t=84.69-98.99 under a full-window PopoverDismissRegion and decimal-pad Popover, although values 4 and 5 had already persisted. Current prepareCoveredControl only recognised Move Ruler. Its number-pad branch now requires the named button to belong to the exposed alert, plus the existing cover and Popover. Other covered-control cases (Insert Ivory/Save Style and Library Emoji) keep their keyboard-overlap logic. All callers were grepped.

RulerUnitsDigitsAndPositionChoicesPersist now sends Cancel through confirmRulerAlert, which already scopes its button to the alert, prepares keyboard coverage, requires stable enabled/hittable geometry and permits one retry only after observed alert/button movement. Both persisted-value assertions and the following sameContent remain. Should unblock that test. Next CI must show name=Cancel numberPad=true when covered, Ruler alert after tap action=Cancel alerts=0, then unchanged document content. The hit-test explanation remains inferred from geometry; no app change.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| RulerUnitsDigitsAndPositionChoicesPersist | Covered control preparation / Ruler alert confirm / Ruler alert shifted retry / Ruler alert after tap (existing, now Cancel) | Was the pad dismissed, did the alert shift, and did scoped Cancel close it before the content assertion? |

### K3 - More assertions in three bounded tests

Confirmed R13:chrome-still-failing#2 and holds=true: the portrait leg ran from t=16.07 to 151.68, Show Tools reveal alone logged 40.567 seconds, including redundant cover queries at t=87.13/92.75 followed by the 14.5-second gap. Landscape then exhausted 180 seconds; estimated whole flow was about 310 seconds. Current reveal still fetched a form snapshot then queried cover existence/frame again.

Preserved the original test declaration as portrait, extracted the identical notebook checks into a helper, and added landscape and whiteboard tests. Both notebook legs retain Go to Page, panel/dismissal, Hide Tools/palette absence, Show Tools and reachable Pen; whiteboard retains no Go to Page, outside dismissal and real drawing/count/Undo readiness. Fresh fixtures replace only cross-leg setup. Show Tools supplies the known bottom hint through the existing scoped More row helper; menu closure and row enabled checks remain.

presentedFormContext now returns the chosen form and visible cover from the same already-fetched application tree. revealFormElement consumes both instead of two more live cover queries. The existing presentedFormSnapshot wrapper preserves dismissal callers and form selection/keyboard pruning; failed snapshots conservatively retain the already-observed cover. All reveal/requireControl callers in every class retain default hints and modal protection. This removes the diagnosed redundant AX work; the cause of slow AX requests remains unknown.

Should unblock all three More legs. Next CI must retain all assertions, finish each below about 150 seconds and show Show Tools Form reveal timing near/below 15 seconds. Estimated saving is about 20 seconds for the observed expensive cover-query pair, plus shorter hint-directed traversal; splitting itself redistributes work and adds fixture setup, not a suite-total speedup.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Three More tests / shared reveal callers | Form reveal path / Form reveal timing / More scoped row (existing) | Was the cached cover retained, was Show Tools bottom-directed, and how many moves/seconds did reveal cost? |

### K4 - seeded tabs, overflow and setting split

Confirmed R13:chrome-still-failing#3 and holds=true: about 43 seconds enabling tabs plus 57 seconds of eight library opens, keys t=136.86-157.09, then timeout during the second settings visit at t=180; full flow estimated 275 seconds. Current UITestFixture executes settings.set editing.showTabs=true and doc.open newTab in notebook/Chrome tab 2...9 order, then AppDelegate returns to the library. The seed-time selection comment does not override that final startup state. Current DocumentTabsOverflow exposes windows.tabs.overflow, label N more open documents, renders +N, and uses the same complete DocumentTabsMenuItems as windows.tabs.menu.

Both tests opt into tabsOverflow, assert the library/no-document startup and nine-open-documents control, then open Physics from the library before document actions. The original test retains overflow and Command-1...8/9; the new DocumentEditingHidesAndShowsOpenTabs retains off/absent Tabs, Command-1 while hidden, on/Tabs/Chrome tab 9 and exact document identity. Added the +N control's positive hidden count, active-tab visibility bound, exact accessibility label and complete menu-title inventory; hidden tabs also require the +N control absent.

Decision: the probe does not publish ordered tab IDs. To preserve the original exact identity comparisons (rather than substitute title-only keyboard checks), the keyboard test first selects the already-open tabs through Tabs and records their IDs, then runs the original key comparisons. This adds menu traversal but removes setting-on and all eight library round trips. No notebooks are created/opened from library for those eight tabs. Nine distinct IDs are additionally required. All original assertions remain across the split; the last-tab identity in the settings test is established independently through its menu before hiding.

Should unblock TabsOverflowAndKeyboardOneThroughEightAndNineLast and the new setting test. Next CI must show nine ordered fixture tabs, usable +N leading to all nine names, each exact key destination, Tabs and +N absent when disabled, and restored last-tab navigation. App logs must include showTabs=false shown=false. The fixture removes the diagnosed ~100-second setup; conservative identity-oracle menu traversal adds ~50-70 seconds back, so estimate ~110-150 seconds for overflow/keys and ~120-150 seconds for hide/show, versus ~275 unsplit. These are unmeasured; no allowance grows.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Both tabs tests | Existing Requested chord / App key log; named fixture and overflow assertions | Were all seeded destinations usable, did each chord reach the independently observed document ID, and did tab visibility track the setting? |

### K5 - two live saves and six seeded history rows

Confirmed R13:chrome-still-failing#4 and holds=true: timer cycles began t=24.63/68.12/116.42/165.54 and the fourth exhausted 180 seconds; each costs ~47 seconds. Current TimeKeeperHistorySection collapses at five, so Show All needs six, and TimeKeeperHistoryRow builds its subtitle from docTitle, elapsed/duration, then date. No timerHistory scenario exists in merged app sources yet; this job implements the supplied companion-job contract only in the runner enum/launch arguments. Setup throws 'Missing timerHistory fixture scenario' if the probe does not echo it. It never substitutes UI creation, passes on missing records, or skips.

Original TimerHistoryShowsDocumentDurationsAndNoDuplicateRows now saves two named sessions through the unchanged timer UI path, then checks both names exactly once and both document rows. New TimerHistorySeedShowsAllAndLessWithoutDuplicateRows launches timerHistory and retains Show All, all six exact-once names, the original >=6 document-title assertion, Show Less, Show All and the final history-6 exact count. Shared row verification additionally checks the document/duration/date subtitle directly after each name in the Time Keeper snapshot's text reading order (the source's NibInspectorRow VStack can be flattened in AX) and exact total row count. Show Less checks five rows. Names are searched independently, never asserted in any session/time order.

Should unblock live saving and the formerly unreachable six-record expansion tail. Next CI must execute two real saves below ~150 seconds, and seeded expansion below ~60-90 seconds, with all names, per-row document/duration subtitles, exact counts, collapse and re-expansion. AX text ordering/lazy retention needs CI confirmation; missing row metadata fails rather than falling back to the old aggregate title count. Roughly four ~47-second UI cycles (~190 seconds) are removed, offset by the new test launch and row checks; no sleep, allowance increase or timer() optimisation is introduced without further evidence.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Both timer history tests | Timer history row | Which exact session name was paired with which document/duration/date subtitle? |
| Seeded history test setup | Missing timerHistory fixture scenario (failure) | Did the companion app actually recognise the scenario rather than silently launch standard? |

### K6 - page-scroll evidence without a speculative gesture fix

Confirmed R13:chrome-still-failing#0 with holds=false correction: the options strip survived the held-release gesture at offset y=578 and the page changed; the proposed clipped-rect/publish-cadence cause and shorter-scroll cure were not proven. Current ToolbarView.canvasDidScroll reads the canvas UIScrollView contentOffset and logs [Nib QA toolbar] scroll moved/travel/samePage/offset/zoom. Its remaining guards are app-owned and are not declared runtime-proven here.

Kept PageScrollCollapsesOptionsAndChoosingToolRestoresThem, its exact normalized two-finger start/end, held release, offset-change/fold waits, original-page identity and all later tool/ink/Undo assertions. Added before and after-fold-wait logs with wall times, normalized/interface endpoints, canvas frame, page and contentOffset. The after log runs on failure as well as success, before any later tool selection; unavailable probe data is explicit. No shorter scroll or allowance change.

Should make the repaired app's T-109 test readable against its own scroll lines; no test-side behavioral fix is claimed. Next CI must show the strip folding under the same gesture and then all preserved assertions, including original page identity. If the page still changes, that remains a genuine failure; logs now expose the geometry rather than disguising it.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| PageScrollCollapsesOptionsAndChoosingToolRestoresThem | Page scroll boundary | What exact endpoints and canvas frame were used, and how did the actual offset/page change before the fold wait finished or failed? |

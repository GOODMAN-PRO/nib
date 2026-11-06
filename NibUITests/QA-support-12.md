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

### K7 - the selected sidebar owns its menu

Confirmed context 4 against current SidebarHost.hostsOwnPlacementMenu/panelContext and OutlineHeaderMenu: Outline receives chrome.panelOptions in its own Outline Options, with Panels and Panel Options sections below its outline items; the redundant tab-row host button is absent. Pages, Bookmarks and History keep Panel Options. PanelPlacementMenu.actions supplies the mode and left/right/floating actions; the current side is disabled, not absent.

RegisteredSidebarPanelsAndCloseButton now visits all four panels, opens each selected panel's correct menu, and asserts Show as Window, Move to Left Side, Move to Right Side and Float Panel are present. It selects the next tab from that open menu, then deterministically closes History's menu before the original panel-close/content/drawing assertions. All existing panel ID and title checks remain. Insert.panel recognises either header before deciding to reopen the sidebar, uses Outline Options when exposed, checks its three placement actions without demanding the disabled current side be enabled, and then chooses the requested panel. Primary-tab direct selection remains unchanged.

Grepped both labels in every class. Chrome's separate placement test remains on Pages, Ink's History test starts from fresh Pages, and Pages' Show as Window callers explicitly select Pages first; they correctly retain Panel Options. Pages' outline-sort test already uses Outline Options. Capture selects Outline directly and has no stale header label. No other class has either label.

Should protect Chrome's registered-sidebar test and Insert Comments/Audio routing when the current panel is Outline. Next CI must log each matching menu, find all placement rows on Outline, reach Bookmarks and History, close the final panel and preserve content/drawing. Section headings are source-confirmed; tests assert their real actions rather than assume native menus expose section-header AX nodes.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| RegisteredSidebarPanelsAndCloseButton | Sidebar placement menu | Which selected tab supplied the menu, and were all placement actions present in it? |

### K8 - verify the existing alert text route

Confirmed R13:chrome-new-failures#1 and holds=true: at t=46.16 the second Set Angle replacement used public typeText(45), the default interruption handler cancelled at t=47.92, and the field no longer existed. Current code already contains job 11c's repair. All three loop values 0/45/90 in RulerMoveAndAngleControlsSnapToZeroFortyFiveNinety take Chrome.replace -> fillNativeForm -> replaceNativeText -> typeNativeText. nativeFormContainer selects the exposed Alert; default scopes do not fall through to the app. While that alert is up, typeNativeText calls focusedText, which invokes NibTouchPaths.sendKey(text, modifiers: 0, route: 3) with the exact signature declared in NibTouchPaths.h. The public field.typeText branch only runs with no exposed Alert. Clear uses runner key SPI for Select All in an Alert and HID Delete, then exact empty and replacement-value waits. Other Set Angle replacements in rotation/ruler-ink tests take the same path.

No further Swift change is warranted; this cluster is a committed source-verification record. The test should be unblocked by 11c, not by a speculative new input route. Next CI must show Native alert text route=runner text SPI for characters=1,2,2, no default interruption cancellation, and all exact 0/45/90-degree waits followed by sameContent. Local compilation/runtime remain unavailable.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| RulerMoveAndAngleControlsSnapToZeroFortyFiveNinety | Native alert text / Native clear HID (existing) | Did every replacement bypass interruption-monitored public text input while retaining exact clear/value verification? |

### K9 - fixture contracts

Updated Support/CanvasFixtures.md from current tabsOverflow source and supplied timerHistory context. Tabs now documents settings enablement, nine ordered command-opened documents, library/no-active-document startup and both +N/Tabs entry points. Timer history documents the six exact names, shared notebook, distinct durations, end-time spacing, unspecified ordering, count/duplicate/document checks and five-row collapse. Explicitly records that the companion implementation is absent at merged 702e1519 and must produce a named failure when missing. No app code or fixture storage is edited.

This supports the K4/K5 tests; next CI must prove the app-side prerequisites before their UI assertions. Documentation alone is not runtime evidence. No additional diagnostic prefix; K4/K5 own the fixture checks.

### Final source review and validation

Re-read the changed Swift blocks and surrounding control flow in Chrome, Ink, Insert, Library and NibUI, and checked the unchanged NibTouchPaths.h/.m key signatures. Reviewed XCTest element/query/snapshot APIs, named/defaulted parameters, throwing postconditions versus nonthrowing predicate closures, optional types/rebinding, tuple/array inference, NSPredicate argument counts, and string construction. No Objective-C source changed. All new helper calls resolve in current NibUI; no app module types were imported into the runner. New history-collapse count waits boundedly before asserting instead of racing the tap's repaint.

Re-grepped every class for shared chord, reveal/requireControl, timedAction, covered-control and fixture-enum callers, and both sidebar labels. Existing signatures/defaults are preserved; only named callers opt into the new verification or bottom hint. The form-only dismissal wrapper still returns its previous optional snapshot; no failure case makes a known cover safe to pull down. FixtureScenario has no exhaustive caller switch to update. Hardware-event retry requirements and count remain unchanged. Empty closure exceptions without isolated effect waits are documented in K1.

Required checks: **python Scripts/lint.py: 0 errors, 25 warnings**; **git diff --check** and **git diff --check 702e1519** pass. Python source inventory confirms **599 existing test declarations preserved, 603 total**, identical executionTimeAllowance assignments and identical sleep/skip calls throughout Swift/Objective-C test sources. The two removed XCTAssert source lines are relocations only: ruler existence is now on its own line, and the six-row exact-once assertion uses the helper's identical title string. All original checks remain across the splits, including six simultaneous history names/documents, exact tab IDs and the scroll's original-page requirement. Seven changed paths, all under NibUITests. Nine final cluster commits carry the exact requested two-line attribution; no push.

Runtime estimates are unmeasured: shared reveal removes the observed ~20-second redundant cover-query work; tabs eliminate ~100 seconds of old setup but spend ~50-70 seconds independently resolving exact IDs through open-tab menus; timer history eliminates four ~47-second UI save cycles (~190 seconds), offset by setup/row checks. More targets <150 seconds per notebook orientation; tabs ~110-150 seconds and ~120-150 seconds; history UI <150 seconds and seeded ~60-90 seconds. Splits add launches and diagnostic/AX checks add cost, so these are not a suite-total speedup promise.

No local Swift/XCTest compilation or simulator execution is claimed. Reviewer/CI risks: AX exposure of the new +N control/native menu and row counts; history subtitle text reading order/lazy-row retention; native decimal-pad dismissal and moved-alert retry; modifier resend availability; synchronous AX latency beyond an outer wait. timerHistory is intentionally not implemented in this baseline's app and must fail by name until the companion scenario lands. The existing scroll may still change the selected page: that assertion is retained and the new logs must explain any repeat. All K1-K9 clusters have committed changes or the explicit K8 verification explanation; no cluster remains unfinished.

### Review fixes - round 2 (2026-11-06)

Reviewed job 12b against its integration baseline 702e1519; job 12a and app sources are unchanged. The companion timerHistory implementation remains outside this branch's scope.

- K1 (major): Ink.wait and Library.eventually now throw on timeout without first calling XCTFail. Library.visible follows the same policy because existing folder/search chord postconditions also call it. The original 8/12-second bounds, predicates, signatures and final assertions remain; source file/line are retained in the thrown message. All ordinary callers propagate these errors (the Library tap diagnostic catch rethrows), so non-retry failures still fail their throwing test methods. chord's unchanged evidence checks and single-resend limit decide whether an initial error may retry; rejected evidence or a failed resend propagates the final error to XCTest. Checked the nested Ink control lookup: its default non-scrolling route and waitForState already throw without recording failures. CI must demonstrate that a proven dropped chord can recover without an earlier recorded failure and that rejected/exhausted retries still fail.
- K1 context (minor): capture keyContext plus precedingAction before openHardwareKeyRoute, so the first process key reports the real preceding context rather than the route-opening semicolon. No extra query, wait or retry is added. CI's Chord lost context should report none recorded when no prior key exists.
- K5 history exposure (minor): replace only the new final form-wide exact-count assertion with Timer history exposure, logging expectedVisited and exposedAfterTraversal. A LazyVStack can release previously visited AX rows. Keep each app-wide per-name exactly-once assertion and every document/duration subtitle check, plus all original aggregate document, Show All/Show Less and final history-6 checks. Rechecked More, tabs and history splits against their original bodies: their assertions remain across the parts. This supersedes K5's statement that the final exposed total is an assertion; lazy exposure is now diagnostic at that boundary.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Both timer history tests | Timer history exposure | How many history names are currently exposed after individually verifying every expected row? |
| Shared chord callers | Chord lost context (corrected) | Which key and activity preceded route opening, including the first-key case? |

Validation: python Scripts/lint.py reports **0 errors, 25 warnings**; **git diff --check** passes. UTF-8 source checks confirm unchanged Ink/Library test bodies, test declarations, allowances and sleep/skip calls, retained retry count and per-row assertions, correct context ordering, and NibUITests-only edits. Reviewed changed Swift signatures, throwing paths, retry callers and assertion preservation. No local Swift compiler or simulator is available; compilation and actual dropped-key/lazy-AX behavior require GitHub Actions. Synchronous AX queries can still outlast an outer wait's timeout. No app edits, allowance changes, sleeps, skips or test removals.

### Review fixes - round 3 (2026-11-06)

- K5 complete inventory (blocker): supersedes round 2's diagnostic-only total. Both history tests now assert an exact complete inventory of two/six records and exactly one occurrence of every expected name, in addition to the existing per-name live queries, document/duration/date checks, aggregate document counts, Show All/Show Less and collapsed-five checks. The helper first reveals the complete History heading, then scans toward the bottom with overlapping viewports (12 snapshots / 30 seconds maximum). Each title is keyed by its vertical position relative to the non-lazy History heading, not by its name: snapshots of the same row overlap without inflating the total, while a second physical row with the same name remains a duplicate. Unexpected history text fails explicitly. Every step requires continuous coverage with at least half a viewport of overlap; missing anchor/geometry, changed row identity, a coverage gap or exhausted bounds fails rather than returning a partial count. TimeKeeperPanel places history last; completion requires its content scroller to report 100% and a further upward drag to leave the heading position unchanged, so a rounded percentage alone cannot stop traversal. An extra Chrome history 7 therefore increases the total or causes a bounded failure, never a pass based only on the expected six names.
- K5 subtitle format (minor): confirmed from `NibKit/Sources/FeatTimeKeeper/TimeKeeperView.swift` (`TimeKeeperHistoryRow.subtitle`) and `NibKit/Sources/NibDesign/Components/Panels.swift` (`NibInspectorRow`). The subtitle joins document title, elapsed time (optionally "of" duration), optional laps and date using ` · `; title and subtitle are consecutive texts in the leading VStack. `TimerFormat.clock` produces mm:ss or h:mm:ss, both accepted by the existing regex. Retained every subtitle assertion and added the source rationale at the check; no speculative format relaxation or app edit.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Both timer history tests | Timer history inventory | Which heading-relative viewport ranges were scanned, which scroll percentages prove the bottom, and which physical row positions make up the exact inventory? |

Validation: `python Scripts/lint.py` reports **0 errors, 25 warnings**; `git diff --check` passes. Reviewed changed Swift APIs, throwing paths, both helper callers and preservation of all pre-existing history assertions. Only ChromeUITests.swift and this support record changed; job 12a and app sources are untouched. No sleep, skip, allowance increase, test removal or fixture substitution. Swift compilation and real AX traversal remain for macOS CI: the non-lazy heading must remain in snapshots while offscreen, content scroll indicators must expose their percentage, and row-relative geometry must remain stable. Missing evidence fails explicitly. Synchronous AX calls can exceed the outer deadline; no runtime saving is claimed for this additional verification. The companion timerHistory scenario remains another branch's responsibility.


## Round 12c

Merged integration ff8eeefc cleanly (fast-forward). Read both prior prompts, README, Round 11a-11c and Round 12a/12b, and both complete R14 families (findings and verdicts). Corrections govern. Windows source-only: compilation and simulator results belong to the next macOS CI run. The removed app sampler is not compensated for by a test allowance, delay or environment change.

### H15 - reveals cannot draw

Confirmed R14:canvas#0 and its holds=true verdict against current tapControl/liveList: an existing non-hittable sidebar toggle went immediately to reveal; a non-hittable retained Fountain Pen scroll view was accepted solely for window overlap. Meeting's t=13.10 drag and Rename's t=15.74 drag correspond to native pen strokes in the app log. The exact reason the toggle was briefly non-hittable remains unproven.

An existing control now gets a three-second element-predicate hittability wait before reveal, with elapsed time/result logged. Existing targets must belong to the chosen list. Non-hittable containers need live presented ancestry/descendants; window intersection alone is no longer a fallback. Presentation/cover classification reuses the same root snapshot. Explicit retained containers are checked too. Every form/horizontal reveal checks the whole straight travel against nib.canvas before contact. A canvas rectangle behind a proven live foreground popover/form is occluded; only that proven foreground intersection can protect a drag. With no foreground protection, candidate points on canvas fail explicitly instead of drawing. No canvas-scroll opt-in is exposed on reveal helpers: intentional canvas scrolling uses the existing dedicated gesture paths.

Audited all class-local drags and shared callers. Create's local form reveal and Pages' More/template reveals use the same guard. Held drags now require a hittable actual source and its centre (coordinate-space equality is checked before mapping to interface geometry): Ink swatch slots, Pages thumbnails and Insert Star supply it. Selection's deliberate canvas-source transfer opts in explicitly. Only the source is guarded for these system transfers because Insert intentionally drops on canvas. Palette grip resolution now rejects non-hittable retained Tools copies; its existing same-snapshot anchor/gap checks remain. Slider dragging already requires a hittable track. Canvas writing/scrolling, item manipulations and Library card transfers are intentional actions, not reveal fallbacks. No test assertion, skip or allowance changes.

Should unblock BoardFrameworkMeeting and BoardRenamePersistsAfterReopeningDocument and protect all reveal callers. Next CI must show the hittability wait resolving the toggle, no reveal drag/pen-native-stroke before either board operation, and successful real form/horizontal reveals in Ink/Insert/Create/Pages. Foreground AX ancestry/hittability and landscape coordinates need runtime verification; failure is conservative, never a canvas fallback.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Shared command taps, especially both board failures | Control hittable wait | How long did an existing control take to become hittable before reveal was considered? |
| Shared and class-local reveals | Canvas drag prevented / Form reveal unavailable | Was the proposed path on exposed canvas or backed by a live presented scrolling surface? |
| Held-drag callers | System drag requires a live source (failure) | Was the start the actual hittable source centre rather than a retained container coordinate? |

Validation: python Scripts/lint.py: 0 errors, 25 warnings; git diff --check passes. No local compilation/runtime claim.

### H16 - replace a selection without Delete

Confirmed R14:canvas#1's correction: type 5 began at t=43.14, idle waits ended at 103.16 and 164.54; HID Delete preceded hide/show and loss of field focus. The animation monitor's persistent non-idle cause is NOT proven. Merely switching typeText to SPI while retaining Delete would leave subsequent ordinary actions exposed to the same stall.

replaceNativeText now proves this exact field's focus, uses focusedKey Command-A for existing text and focusedText's existing runner text-event SPI to type over the selection. No Delete is sent for a nonempty replacement, including the invalid-page loop. Exact waitForNativeText verification is retained. Selection focus is checked boundedly before typing without retapping or destroying the selection. Unicode/punctuation use the existing route 3 full-string API, not an ASCII-only key mapping. Empty replacements retain clearNativeText/HID Delete; immediately after every such Delete, the helper waits up to five seconds for exact field focus and an unchanged keyboard frame across at least 300 ms of predicate observations before further actions/value diagnostics. Explicit clearNativeText callers also get this recovery gate, with unchanged empty-value and decimal diagnostic checks.

Keyboard visibility is observed at replacement boundaries and each focus/value/recovery poll. Logs include elapsed transition times and a flap line when multiple transitions are observed, plus the replacement start uptime. This is runner AX sampling, not a complete app-notification stream: a hide/show entirely between observations can be missed. No timer, sleep, swizzle, app change or claimed monitor-cause fix is added. Compare these observations with the app's existing idle/keyboard lines and missing idle replies in CI.

Audited replacement/clear/type callers in all classes: Canvas, Chrome via fillNativeForm, Create, Ink, Insert, Library, Pages, Selection and internal Files naming. Existing signatures stay source-compatible through defaulted diagnostic parameters; explicit Return/commit paths and numeric-format callers retain their behavior. fillNativeForm's separately opted-in keyboard traversal already verifies explicit clearing and is unchanged. Should unblock GoToPageRejectsInvalidNumbersAndNavigatesValidTarget; next CI must show Select All/no Delete for 5, -1 and 3, exact text and every existing assertion, no repeated 60-second idle waits, and bounded recovery on intentional empty clears. Native SPI/focus AX exposure remains uncompiled here.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| All replaceNativeText callers, especially invalid-page loop | Native replacement selection | Was Select All followed by replacement typing with no Delete? |
| Same | Native replacement keyboard / Native replacement keyboard flap | Which hide/show transitions were observed, at what elapsed times, during this replacement? |
| Intentional empty clears | Native Delete recovery (failure) | Did the exact field regain focus and the keyboard frame stabilize before the next action? |

Validation: python Scripts/lint.py: 0 errors, 25 warnings; git diff --check passes. Runtime saving is not measured; removing the observed 121-second idle stall is a CI hypothesis, not a guaranteed saving.

### H17 - typed direction rows from the current offset

Confirmed R14:canvas#2 with correction: the measured Horizontal reveal took four moves/21.22 seconds; the second choice was still in lookup when the test hit 180 seconds. Episodic environment slowness is supported; stderr blocking in THIS test is not proven. Current FeatDocChromeFeature gives both buttons cmd.doc.setScrollDirection and distinct exact labels, orders 100/110 at the list end. Selecting either closes More, so keeping a single presentation open is impossible.

Canvas setDirection now binds a scoped Button query with identifier AND exact label, uses edge .bottom only if needed, then requires enabled/hittable and the existing menu-closure helper. Reopening for the second choice preserves the app's retained offset; the helper never homes or resets it. All layout/navigation/content assertions remain. No environment settings or sampler compensation. Next CI should log fewer queries/moves and lower per-choice time than the measured reveal, with both Horizontal and Vertical selected and all reopen/page-frame assertions passing. No fixed runtime saving is claimed; the app may rebuild at top, which still gets bottom-directed reveal rather than a test-side reset.

Compatibility check found an important current-source distinction for H15: Chrome/palette buds use AX-hidden DismissCatcher (DropletContainer), not a native PopoverDismissRegion. The already-existing menuHasActiveContent closure policy distinguishes live rows from retained empty shells. The safety classifier now also accepts that source-backed custom scrolling surface ONLY with a matching live hittable host and actual button rows, excluding every subtree containing nib.canvas. Explicit More scopes use one list snapshot, reused for the reveal, instead of a whole-app ancestry walk; this source-defined custom bud has no native cover. Every reveal contact rechecks live content before trusting cached foreground geometry. Native modal ancestry remains supported. This preserves More/horizontal tool menus without reviving the non-hittable retained fallback implicated in R14.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Canvas layout tests using setDirection | Canvas direction row / Form reveal timing | What is the full per-choice cost, and how many bottom-directed moves were needed without homing? |

Validation: source query uses two predicate placeholders/two arguments and current helper signatures. Compilation and timing await CI.

### C8 - remove happy-path diagnostic work

Confirmed R14:create#0 and correction against current code and remeasured the raw logs. Run 42136488712 has 525 timed activities, passes in 151.340 s; Width typing t=90.89 to Height tap t=113.31 is 22.42 s. Run 42175781057 has 472 timed activities before the allowance kill; the equivalent t=65.06 to 83.37 is 18.31 s. The latter heading-existence query stalls from 126.78 to 152.08 (25.30 s); the surrounding 115.82->126.78, 152.08->157.97 and 161.96->169.28 gaps measure 10.96, 5.89 and 7.32 s. Those four late gaps total 49.47 s, not a new measured app-hang claim. The sampler overlaps the late stalls and is already removed externally.

CustomSize no longer requests either Width snapshots or millimetre clear diagnostics. InvalidCustomSizePreventsCreation retains both diagnostic modes and its existing allowance. The happy path resolves New Notebook's heading frame once after choosing Custom, reuses that immutable frame for both inert-header dismissals, and relies on the valid default draft title because it never asserts a title. This removes the title replace/dismiss cycle entirely. dismissNativeKeyboard accepts an additive optional cached frame, validates it against current window/keyboard geometry, skips the unused Hide lookup for an inert-header route, and keeps the observed conditional second-contact and keyboard-gone gates. Other callers retain their element/default routes.

All creation/persistence/dimension assertions are unchanged. Expected saving is approximately 20-30 s per the verifier, NOT the finder's speculative 40-60 s, and is unmeasured on the changed code. The default-title shortcut additionally removes observed title work but is not double-counted in that estimate. H16's safety recovery can add polling cost. This reduces budget exposure and cannot guarantee immunity to another 25-31 s stall.

Next CI must show no Width keyboard/Decimal clear logs for CustomSize, one cached heading frame, the unchanged exact size oracle, and a lower runtime without an allowance increase. InvalidCustomSize must retain diagnostic snapshots/clear logs and every rejection/package assertion.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| Create testCustomSize | Custom size timing | What is the new body duration after removing happy-path diagnostics/title editing? |
| Create testCustomSize | Custom size heading | Which single heading frame was reused for both numeric keyboard dismissals? |

Validation: current dismissNativeKeyboard/replace callers audited; new arguments are defaulted. Runtime saving and cached-heading geometry need CI verification.

### C9 - name helper ink at the board boundary

Confirmed R14:canvas#0 and its verdict against current UITestFixture: Concept map has an ellipse, text and sticky, with zero strokes (the notebook's separate ink seed does not belong to this board). Meeting's extra stroke survived template Undo; Rename had four items without a Duplicate action. H15 owns the cause fix.

Both BoardFrameworkMeeting and BoardRenamePersistsAfterReopeningDocument now assert strokeCountOnPage == 0 immediately after boards(), before Templates/rename actions. The message explicitly says a helper drew on the page. This uses the fixture's known count, not a baseline captured after the bad helper, and retains all original item-count, Undo/Redo, rename and reopen assertions. The framework guard is limited to Meeting Notes as requested; no added per-test cost for the other templates.

Next CI must log zero before either first board operation, no native pen stroke from setup, and pass all original assertions. A regression should fail at the named helper boundary instead of a later count timeout.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| BoardFrameworkMeeting; BoardRenamePersistsAfterReopeningDocument | Board helper ink guard | Did setup leave any stroke beyond the fixture's zero before the first board operation? |

### C10 - retain the complete invalid-page loop

Confirmed R14:canvas#1 with the verifier correction and current test: 0, 5 and -1 must each disable Go and preserve the page; 3 must navigate, preserve four pages, and the final go(1)/unchanged check must hold. All these exact assertions and the loop remain. Each call now receives H16's nonempty selection replacement, so none sends HID Delete. Added lightweight value-boundary logs (no extra AX query) to align the four replacements with H16's keyboard observations and app idle logs. No speculative animation-monitor fix is claimed.

Next CI must show all four boundaries, exact replacement values, every original invalid/valid/restoration assertion, no Delete between values and no repeated 60-second animation-idle timeout. A persistent failure without Delete refutes that trigger as a sufficient explanation; retain the runner/app idle evidence instead of adding a delay or allowance.

| Tests | Log prefix | Question answered |
| --- | --- | --- |
| GoToPageRejectsInvalidNumbersAndNavigatesValidTarget | Go to Page replacement | Which of 0/5/-1/3 preceded a keyboard transition or missing idle reply, and what result was expected? |

### Final source review and validation

Re-read every changed Swift hunk with its surrounding helper/caller flow, including Canvas/Create and the held-drag callers in Ink/Insert/Pages/Selection. Checked the unchanged NibTouchPaths.h and existing Objective-C SPI implementation/signatures: no Objective-C source changes or new SPI selector. Reviewed optional CGRect/snapshot inference, XCTest query/coordinate/wait APIs, field-specific focus, throwing call sites, closure captures, predicate argument counts and defaulted labels. Hittability is tested on live XCUIElement properties rather than an invented snapshot predicate attribute. Horizontal rows can be live through their hittable content when the container itself is non-hittable; retained empty shells remain rejected. Full gesture paths use interface coordinates; held-source coordinate equality is compared in screen space before mapping its known centre to interface space. Explicit More uses one scoped snapshot, and ordinary post-drag snapshots are retained.

Grepped every class for changed replacement/clear/dismiss/reveal/held-drag APIs. All four held-drag callers supply their real source or explicit canvas intent and propagate errors; other signatures keep their defaults. No test was removed or split in this round. Python inventory confirms 603 test declarations, 14 allowance assignments and all existing sleep/skip sites unchanged, and every original XCTAssert source line retained. All eight changed files are under NibUITests. Required python Scripts/lint.py: **0 errors, 25 warnings**; git diff --check against ff8eeefc passes. Six cluster commits carry the requested exact two-line attribution; no push.

Runtime/compile limits: Windows has no Swift/Objective-C compiler or simulator. Swift compilation, native focus/keyboard stability, custom/popover AX ancestry, actual drag hit-testing, cached heading geometry and new runtimes remain unverified until GitHub Actions. Synchronous XCTest AX calls can exceed outer predicate deadlines; no sleep or allowance compensates for that. Keyboard transition logs are sampled observations and cannot rule out an unobserved between-poll flap. Foreground protection fails conservatively if its identity/geometry cannot be proved. More may rebuild at top; the tests never home it. Safety checks add some queries, so only CI can establish net savings. CustomSize's expected saving remains **20-30 seconds, unmeasured**, against the remeasured 151.340-second baseline; no guaranteed immunity to stalls and no suite-total speedup is claimed. All H15-H17/C8-C10 clusters are complete; none left unstarted or partially committed.

### Review fixes - round 5 (2026-11-06)

Reviewed the six job 12c commits on this branch against the supplied round-5 findings, current helpers/callers and R14 evidence. Jobs 12a/12b are already integrated; this is one additional test-support review commit, with no app changes or integration merge.

1. **Custom-size heading (major):** the C8 cache was captured before Width focus, when New Notebook still had its unkeyboarded layout. Capture now follows the first Width replacement and a bounded five-second predicate requiring unchanged heading/keyboard frames across at least 300 ms. Both dismissals reuse that keyboard-visible frame and the same heading query. The cached-frame route checks the live static-text heading's four edges within one point before contact, in addition to window containment and keyboard exclusion. A shifted heading fails before tapping paper controls. Happy-path Width/clear diagnostics remain off; the invalid-size test retains them.
2. **Library reveal guard (major):** `guardRevealDrag` now returns immediately when `nib.canvas` is absent, before any container liveness requirement or snapshot. With a canvas, a non-hittable host can qualify through hittable visible content. This restores the safe Create/library route and non-hittable native scrolling hosts without accepting empty retained buds over canvas.
3. **Class-local reveals (major):** Time Keeper history now calls the shared guard immediately before its drag. Its `context.scroller` is an `XCUIElementSnapshot`, so the guard receives the live owning Time Keeper form; the existing inner-scroller viewport still supplies both points. Coordinates now subtract the app-frame origin. Pages `tapThumb` also needed protection: replaced `grid.swipeUp()` with an explicit, window/keyboard-clipped upward path guarded immediately before contact. Existing Create and Pages More/template guards remain. The remaining Library menu swipes run on library surfaces; canvas scroll/writing, slider/scrubber actions, item manipulation and explicit transfers are deliberate gestures rather than reveal fallbacks.
4. **Horizontal reveal cost (major):** no foreground snapshot or ancestry resolution occurs without a canvas. With a canvas, resolve presentation lazily once per call, then reuse it across moves. Every contact still verifies the row's live visible content and unchanged frame before checking the full path against exposed canvas. The existing per-move row snapshot is reused for content filtering. A four-move reveal now takes at most one whole-app presentation snapshot instead of four (zero when no canvas); elapsed savings require CI measurement.
5. **Form liveness (major):** the per-contact check runs only for a classified foreground surface or when canvas exists. The shared content probe filters snapshot descendants by visible frame before live hittability queries, without the old first-24-row cutoff. Buttons, switches, sliders, fields, text views and static text qualify. It reuses the current list snapshot and checks live list geometry; missing/closed content still fails before any contact over canvas. This preserves long non-lazy and switch/text-only forms.
6. **Custom panels without buttons (minor):** custom foreground classification now requires a real hittable visible descendant of any supported content type, rather than `menuHasActiveContent`'s button-only menu-closure heuristic. Empty retained shells still cannot qualify. Menu-closure behavior itself is unchanged.
7. **System-drag sources (minor):** collection views and tables now qualify alongside scroll views as live foreground hosts, covering docked thumbnail and element panels. `dragWithHold` retains its actual hittable source-centre requirement and guards only that source; intentional canvas destinations and Selection's explicit canvas-source opt-in remain. The mandated three-second `tapControl` wait is unchanged. Pages thumbnail and Insert Star transfers must be confirmed in CI.

| Tests / helper | Log or failure | Next-run question |
| --- | --- | --- |
| Create CustomSize | Custom size heading / Numeric keyboard heading moved | Was the cache acquired with the keyboard visible, and did both dismissal layouts match it? |
| Ink/Insert horizontal rows | Horizontal reveal / Horizontal reveal surface closed or moved | Did the row stay live while presentation resolution happened at most once? |
| Time Keeper inventory; Pages thumbnail reveal | Canvas drag prevented / Reveal requires a live hittable scrolling container | Did the foreground host still cover the complete path immediately before contact? |
| Long native/custom forms | visible scrolling content snapshot / scrolling surface is no longer live before drag | Did an actually visible descendant qualify even beyond the first 24 rows or without buttons? |

Source review covered every changed Swift block, all cached-header calls, horizontal and form reveals, the four held-drag callers, and class-local drag/swipe sites. No tests, assertions, skips or allowances were removed or relaxed; no sleep was added. Required validation: `python Scripts/lint.py` reports **0 errors, 25 warnings**; `git diff --check` passes. Only `NibUITests/**` changes. No local Swift/XCTest build or simulator run is possible on this Windows host. CI must verify compilation, keyboard layout equality, native/custom AX liveness, Time Keeper inventory within its existing deadline, Pages/Insert transfers, and net reveal timing. Safety queries still cost time and cannot make synchronous AX requests interruptible; no runtime improvement is claimed as measured.

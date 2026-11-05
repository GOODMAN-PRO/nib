# QA support 8

Base: `b9e4e68`, branch `work/ui-round-8a`. Read QA-support-7.md and README.md first. Scope is the automatic form-container binding defect and missing row reveal calls; only NibUITests files may change. No Swift/Objective-C compiler or simulator is available on this Windows machine. No push.

## Confirmed evidence

Local artifacts: `G:/Projects/Nib-ci-logs/ui-ci/41961796255/results.json`, each `ui-<Class>/ui.log`, and `G:/Projects/Nib-ci-logs/r8-clusters.json`. Results identify integration SHA `74787f2367e14e35b40d4d00cffde0d511dfff9a`: 391/584 passed, 193 failed. The controls cluster has 95 entries, 19 marked passedInPreviousRun. Correction to the brief's shorthand: 82 entries contain `Missing hittable control`, four `Action is not enabled and hittable`, two `No enabled control`; seven have other control errors (one Create scrolling assertion, one missing Library folder, five Pages button errors). The 328 previous-run pass count is supplied campaign context, not independently recomputed here.

Counted exactly 141 `[Nib QA] Form reveal unavailable [0] No live container snapshot` lines: Chrome 44, Insert 40, Ink 28, Library 12, Canvas/Create/Capture four each, Selection three, Pages two. Only two `Form drag before` lines exist, both Ink lines 26294/26326 in testPencilDoubleTapAndSqueezeBindingChoicesPersist (starts line 26106), container `(528.5,126,539.5,770)`. Its squeezePaletteBinding helper passes the collection explicitly. Automatic lookup did not produce an observed drag in this run.

Ink testDeleteSpecificItemsPageScopeKeepsNonInkAndUndoRestores starts at line 18196. Lines 18336-18340 show, in order, Find Target Application, Find Window (First Match), Checking existence of Any (Element at index 0), Find Any (Element at index 0), then unavailable. The error hierarchy at line 18368 contains More `(1048,104,312,520)`, its 2180.5pt content, and `cmd.panel.open` / Delete Specific Items… at `(1064,900.5,280,44)` below that viewport. It also contains Pen `(190.2,397.8,299.5,204)`, Fountain Pen and More tools scroll views. Thus one visible chained probe does not explain which sub-expression failed, nor establish that the other candidates were absent.

Current liveList built live elements while traversing snapshot children and returned the first existing/hittable chain. `git show 3179563:NibUITests/Support/NibUI.swift` confirms the earlier type-scoped descendants queries and bounded element(boundBy:) enumeration. App source inspected read-only: NibSpacing.popoverMaxHeight is 520; NibDesign/Components/Panels.swift supplies NibBudPopover's capped ScrollView; FeatDocChrome/NavBar.swift supplies More, Share and Export, and Add Page rows through that component.

## Container binding and acceptance (items 1-3)

Keep the single application snapshot and the complete round 7 comparator unchanged: surface, same-labelled smaller copy, target containment/tightest containing area, overflow, native list type, area. Remove live elements from snapshot candidates and visit(). Resolve each ranked node lazily through `app.descendants(matching: node.elementType)`, applying identifier and label equality predicates independently when nonempty (both mean AND). Walk at most 24 matches. Require existence and all four frame edges within 1pt, then stop that query at its first frame match. Stop ranked resolution immediately at the first hittable result; normally only the leading one or two candidate queries are needed. Only the no-hittable path must exhaust the ranked candidates.

Remember the first resolved result intersecting the window by more than 1pt in width AND height. Use it only if no ranked result reports hittable. The container supplies snapshots/scoped queries; the unchanged drag uses app coordinates. Its own AX hittability is not necessary for that gesture. Frame identity and window overlap reject off-screen copies without relying on the failed chain's unknown behavior. Equal-geometry retained copies remain a runtime identity limitation; first frame match and the requested hittable preference are deliberate.

`Form reveal container` logs type, label, live frame, one-based rank/count and hittable. When automatic binding fails, `Form reveal unavailable` logs snapshotCandidates and the first eight ranked candidates' type, label, snapshot frame, surface, contains, overflow, walked query matches, existing match count, frameMatched, matched exists and isHittable. `n/a` means no frame-matched element, not a false hittability observation. An unavailable app snapshot explicitly logs that candidates were not collected (count zero). Existing outer snapshot-failure and post-drag failure messages remain unchanged. Explicit caller-supplied forms keep their original contract and bypass automatic ranking/logging.

All diagnostics use existing logQA's 1200-character payload chunks. No extra diagnostic snapshots or per-row scans were added. Everything after liveList, including control-safe contact choice, bidirectional search, cached container/recovery, slider/switch value guard, 16-drag bound and existing logQA lines, remains byte-for-byte unchanged after normalizing line endings.

## Other snapshot addressing (item 4)

Searched every Swift file in NibUITests for children(matching:), .children, element(boundBy:) and allElementsBoundByIndex. liveList was the sole snapshot-child-index-to-live-element chain. Remaining snapshot recursion only computes containment, overflow, visible row signatures, value groups, drag exclusions, palette/focus geometry and diagnostic frames; Create's rows traversal likewise computes strings only. No ordinal from those traversals addresses a live query. Existing boundBy uses enumerate live typed/predicate queries (findControl, Library buttons, Ink fields/presets/history, Chrome mode controls, Create Carbon tile), or reflect intentional test ordering. They do not need snapshot rebinding. Create's scroll helper is untouched.

## Control discovery audit (item 5)

Exactly three throw sites contain the specified messages. findControl is a bounded lookup only: it does not reveal, prefers typed native editors, checks visible frames/hittability, and deliberately returns visible disabled controls so caller enabled assertions can inspect them. requireControl returns immediately for a found control; after a miss it reveals only with scroll:true, including absent lazy rows, then re-queries and retains its bounded wait/throw. Neither contract changes.

| Class / wrapper or throw site | Reaches shared reveal before giving up? | Decision |
| --- | --- | --- |
| Support requireControl / Missing hittable control | Yes only when scroll:true; default false. | Preserve signature, wait and disabled-control behavior. Use explicit flags on known row paths. |
| Support tapControl / No enabled control; tapCommand and selectTool callers | Yes for an existing unavailable target, and unconditionally after each accessible overflow menu is opened, even if its row is absent. No reveal when both target and overflow trigger are absent. | More / Add Page / export command paths already reach reveal. Keep immediate visible-control tap, waits, enabled guard, and overflow routing. Do not invent scrolling for missing toolbar triggers. |
| Chrome reachable -> tap -> menu/more | Yes, requireControl(scroll:true). | Share and Export, Add Page and More already covered. Existence-only require deliberately has a different contract. |
| Canvas performTap -> tap | Yes, requireControl(scroll:true). | Keep Zoom Window options' explicit button type and enabled guard. |
| Library performTap -> tap / Action is not enabled and hittable | Yes on a candidate miss, including absent targets. | Context-sheet/menu rows already covered; label-prefix matching and enabled/hittable checks stay intact. Its revealFormElement forwarding helper also already delegates. |
| Ink control/tap; toggle, slider, settings, squeezePaletteBinding | Conditional. Lower tool-settings rows, More/Delete Specific Items, Clear Page, gestures, sliders and toggles already pass true; settings reveals the top grid; Squeeze/clipped toggles pass explicit forms. | Keep those paths. Swatch-menu actions now explicitly pass true; their long-press trigger is unchanged. Native colour-picker tabs Spectrum/Sliders and palette chrome are not scrolling rows. |
| Insert control -> performTap -> tap; menu/documentMenu | Conditional. Toggles and several individual rows already pass true; menu path wrappers previously passed false. Native editors use textEditor/focusField instead. | Now pass true for menu/documentMenu row arguments, text-style inspector actions, provider preset/choice, and playback Speed/choice rows. Leave the menu triggers, native text path, Cancel/Save chrome, Connector end canvas handle and cmd.panel.close unchanged. |
| Selection control -> tap; menu | Conditional; toggle and explicit row calls pass true, but menu path and provider preset/choice previously defaulted false. | Now route just those menu/form rows through reveal. Object More trigger, quick actions and canvas geometry remain unchanged. |
| Capture tap and toolOptions | Conditional. Settings rows and Presenter Page already pass true. ToolOptions' static heading is a fresh top-of-popover presentation check. | Share and Export is the toolbar trigger; export.present then goes through tapControl. No new reveal for that trigger or static presentation checks. |
| Pages | Does not call requireControl or emit the three messages. tap reveals an existing unusable candidate after its bounded wait; require is existence-only. more already has a bounded scoped scroll loop. | Preserve separate helpers and expectations; no snapshot child-index addressing here. |
| Create | No direct requireControl/revealFormElement call; tapCommand uses Support tapControl. | Add Page already gets shared reveal on the overflow route. Own scrollTo is explicitly out of scope. |
| Smoke | No direct requireControl/revealFormElement call; command/tool actions delegate to Support. | No additional row wrapper. |

Row decisions derive from inspected sources: FeatObjectMenu/ObjectMenuView.swift builds native More/submenus; FeatAISettings/ProviderEditorView.swift places Preset in Form; FeatAudio/AudioPanel.swift places Speed and values in the options menu; FeatTextBox/TextFormatInspector.swift places Save Style and default-style actions in the capped Format popover. Ink swatchMenu is a dedicated long-press menu-row wrapper, so its argument also opts in without changing any palette trigger. These changes provide bounded discovery, not a claim that every named failure is caused by scrolling. No default scroll flag was broadened to toolbar chrome.

## Validation and next run

Container commit: `python Scripts/lint.py` reports **0 errors, 25 warnings**; `git diff --check` passes. A Python source comparison confirms the ranking comparator and every line after liveList are unchanged from base. Static review checked query APIs, NSPredicate placeholder counts, tuple optionals, local declaration/capture order, access and existing helper signatures. Swift compilation and all runtime outcomes remain unverified until macos-26 CI.

Next CI must show `Form reveal container` for automatic forms, especially More `(1048,104,312,520)` in the cited Ink test, followed by existing `Form drag point`/`Form best clearance`, `Form drag before` and `Form drag after` lines with changed row geometry and no `Form drag changed controls`. Hittable=false selections must still reveal rows safely; they are not proof of a valid drag until geometry changes and caller assertions pass. Fallback binding failure must now be preceded by snapshotCandidates and per-candidate resolution evidence, distinguishing zero matches, frame mismatch, existence loss and non-hittability. A chosen-container line followed by the old no-snapshot message identifies a later snapshot failure instead of a binding failure.

Exercise the prior-pass regressions, Ink lower settings rows, Chrome Customise bidirectional search, Library context sheets, Add Page and export paths. Newly opted-in row paths must show reveal before their own failure wait when initially unavailable. Preserve final content/value/persistence assertions and unchanged time allowances; earlier exits or merely selecting a container do not establish a pass. Compare common paths and query counts; the all-non-hittable fallback can be more expensive because it must inspect every candidate (24 matches maximum per candidate). Do not infer repaired rendering, native dialogs, missing conditional features, text focus or chord delivery from this fix.


Final row-routing review: re-read the changed Swift blocks in Support, Ink, Insert and Selection with their surrounding declarations and current helper signatures. Checked every requireControl/revealFormElement call across all ten class files, including explicit forms and closure/element overloads. Queries, optional tuple/map expressions, NSPredicate argument counts, Swift interpolation quoting, throwing calls, access and nested captures were reviewed statically. No Swift API or signature changes were required for callers.

Final validation: `python Scripts/lint.py` reports **0 errors, 25 warnings**; `git diff --check b9e4e68` and `git diff --check` pass. Python source comparisons preserve all **585 test names and their order across ten classes**, assertion lines, allowances, skip/sleep inventory and chord call lines. The three changed class files differ only by explicit `scroll: true` arguments. Support differs only inside liveList; the ranking comparator and all code after lookup are unchanged. Only five NibUITests paths changed. These are source checks, not Swift compilation or XCUITest execution. Review/CI must verify live query rebinding, container AX hittability, equal-frame duplicates, newly reachable row gestures and timing under the existing allowances.


## H2 - typed control lookup

Confirmed D:controls-menus#3 and D:controls-forms#5 (verifier correction): indexed Any element 1 fails exists while the typed Cancel Button is hittable. findControl now tries concrete firstMatch queries in its existing editor-first priority order before the Any indexed fallback. Visible disabled controls still return for enabled assertions; scope and fallback contracts remain. Expected: six Files/Photos Cancel/Save flows, including Chrome More Image and Insert collection export/import and Tape import. Next CI must tap the visible picker button and retain each cancel/content/save assertion. No runtime proof on Windows.

## H1 - launch key route and evidence-gated retry

Confirmed S:singles-insert#1 correction (a/c) and D:keyboard-and-state#1: first native Cmd-V is consistent with lost initialization; Quick Note n arrived flags 0 after the opener. launchFixture, full-screen fixture recovery and Capture variants now call the best-effort opener before text focus; other launches are Safari/Calendar, not Nib. Existing lazy hardwareKey guard stays. Launch synthesis/observation failure logs rather than throws. chord retries once only after its existing bounded postcondition throws, a fresh printable-key press lacks requested UIKit modifier bits, and the current probe is non-text. A retained-log suffix proves freshness; absent/ambiguous logs never retry. Escape/Delete/Return routes and encodings are unchanged. Expected: three Insert native paste tests, first partial-range key initialization, Create Quick Note. Partial selection's cause remains unproven; sticky/shape Escape is expressly not claimed fixed. Next CI must show launch route evidence before native input and correct modifier flags/result; retries must name the fresh bare press.

| Test | Log prefix | Question |
| --- | --- | --- |
| All Nib launch paths | Hardware key route opened / unobserved | Was the first keyed press observed before text focus? |
| Global modified chords, especially Create Quick Note | Chord modifier loss retry | Did a fresh requested printable key arrive without its modifiers before the single resend? |

## H3 - dismiss only presented surfaces

D:controls-forms#9 confirms header.closeButton followed by cmd.panel.close closed Audio after export. dismissSheets now searches only visible Sheet/Popover/ActivityListView descendants for their own close controls, includes the observed activity header close identifier, and never uses cmd.panel.close or a swipe. No surface returns without acting; an unclosable presented surface fails explicitly. Audited all callers: their generic dismissals must preserve sidebar/floating panels; explicit panel-closing remains with callers. Expected Audio rename/export/delete retains Motion lecture after sharing. CI must confirm native and custom sheet containment and that only the activity sheet closes.

## H4 - Photos grid coordinate selection

S:singles-insert#0 and S:singles-rest#0 correction show real visible Photo frames and false hittability. Only photos_sectioned_layout assets now bypass hittability, retaining existence/visible-frame and centre-in-grid checks; legacy collection cells keep their old gate. Actual selection callers tap the frame centre in app coordinates and wait for enabled Add/Done or asset disappearance, logging the outcome before continuing. All four callers request diagnostics. The save-to-Photos availability/cancel test still only inspects the asset (it intentionally cancels without insertion). Expected: Insert replacement, saved asset availability, Tape photo pattern and Pages Add Image. Coordinate delivery remains a probe, not a proven remote-view fix; CI must show selection confirmation then the existing result/content assertions.

| Test | Log prefix | Question |
| --- | --- | --- |
| Three Photos selection flows | Photos asset coordinate selection / selection unobserved | Did the coordinate tap enable Add/Done or close the picker? Failure retains hierarchy and screenshot. |
| All four Photos lookup callers | Photos assets before/after lookup | Are grid assets visible and still reported non-hittable? |

## H5 - expanded image share actions

S:singles-rest#7 confirms actionGroupCell View More and no Save to Files in the image activity sheet. saveSharedPNG now searches buttons, cells and static texts, opens View More only if Save to Files is absent, and uses the existing shared reveal on the resulting list when needed. Existing unique-directory PNG-byte and dismissal assertions stay. Expected Selection screenshot and page-region screenshot exports. Next CI must expose Save to Files after expansion and save a decodable PNG; the resulting list was not observed in the baseline.

| Test | Log prefix | Question |
| --- | --- | --- |
| Both Selection PNG export tests | PNG share View More | Which action types and rows appear after expansion? Existing export-failed diagnostics retain screenshot. |

## H6 - interface versus device coordinates

S:singles-rest#9 proves the landscape mapping (1032-y,x), including the wrong (381.8,660.5) container drop. Added interfacePoint from canvas.frame. Audited every screenPoint: Selection frame comparisons and drag destination, Canvas pinch focal oracle, Ink picker outside check, Insert dropped-element assertion and geometry/comment diagnostics now use interface space. recordGeometry describes that space. Two-point stroke distance uses interface endpoints (distance is rotation-invariant); multi-tap validates interface contacts and converts only for NibTouchPaths. Remaining screenPoint uses feed NibTouchPaths exclusively (Ink path, Insert image path, shared multi-tap/path). screen()/drag callers otherwise already consume frame-derived interface geometry.

Previously passing by accident: Selection testRectangleSelectsAnIntersectingStroke compared maxX against the rotated y-derived x; testBlankPageContextMenuAnchorsAndInsertSpaceActsAtPoint's half-canvas tolerance admitted the wrong anchor. The lasso unrelated-stroke exclusion also used a wrong point (inside an otherwise failing test). Word-selection and ElementDrag location checks were not reached and are not claimed previous passes. Expected lasso, moving-container attachment and Canvas pinch tests now check the intended geometry; existing assertions/tolerances remain. CI must show the (660.5,650.2) drop, attachment persistence, and focal projection within the unchanged 45pt tolerance.

## H7 - guard native Select All focus

D:app-round-4#6 verifies the second Folder name Cmd-A reached the shell and selected five library items. clearNativeText explicitly focuses the field (tapping when needed); nativeKey now rejects Command-A unless that field reports keyboard focus or the probe reports a text responder immediately before delivery. It never falls back to global routing. All nativeKey/clear/replace callers retain exact text and selection checks. Expected Library MoveFolder and other native replacement paths avoid shell Select All. Next CI must show the folder editor focused and Destination opening normally after Move Here. A text probe alone cannot identify the particular field, so focusField still verifies that field first.

## H9 - numeric keyboard dismissal

D:keyboard-and-state#8 proves the Hide key tap leaves Width focused and the keyboard present; why remains unknown. Both Create custom-size tests now explicitly dismiss through the visible inert New Notebook heading, using its live frame centre (the existing inert-header pattern), then retain the bounded keyboard-gone wait. Other dismissNativeKeyboard callers keep their route. Round 7 before/after/completion screenshots and button/focus facts remain, with the route updated. No Return/Escape delivery changes or allowances. CI must show keyboard absent after both dimensions and exact size/invalid-create outcomes.

| Test | Log prefix | Question |
| --- | --- | --- |
| Create CustomSize / InvalidCustomSize | Width keyboard frame | What are keyboard frames before and after the inert-header dismissal? |

## H10 - success-path query costs

D:timeouts#3/#4/#5 and verdicts confirm 10.4s empty-modifier overhead, doubled probe resolutions, and per-swatch label faulting amplified by ~4x runner latency. Selection drag calls its exact gesture body directly for empty modifiers. readState uses one probe snapshot per read, keeping decode/fixture-error behavior. Ink swatches resolves the group once, traverses one immutable snapshot for button identifiers/labels, and constructs lazy typed scoped element references only for tap/press/isSelected; labels/counts/poll comparisons need no per-slot AX reads. swatchMenu reuses one collection per call. Native clear reads the focused value before Cmd-A and returns only for proven empty/placeholder values; replacement still verifies exact text. H2 covers the independently evidenced typed lookup cost. No speculative scopes or idle-wait changes.

All swatch callers audited: only label/count/indices/iteration, tap/press and isSelected are used; labels are snapshot data, selection state stays live. All existing assertions and allowances remain. Estimated, unmeasured savings: ~20.8s in Selection AlignmentSnapping (~177s/class), roughly half the ~470s Insert probe cost (~235s), and up to much of the ~87-91s swatch lookup cost in Ink RestoreDefaults. Empty clears remove one chord/delete pair each (~3s estimate); they reduce stall exposure, not prove a stall fix. CI must complete the same final assertions under current allowances and compare passing common paths, especially RestoreDefaults and AlignmentSnapping.

## H11 - idle wait selector discovery

D:timeouts#0/#1 and verifier correction prove unanswered animation-idle notifications after native text keys/context-menu holds, not the owning animation or app cause. Each class calls a shared once-per-class inventory of instance selectors on XCUIApplicationProcess and XCUIApplicationImpl, filtered case-insensitively for uiescen/Idle/nimation, through Swift ObjectiveC runtime functions and chunked logQA. Missing classes/method lists are explicit. No selector is invoked or swizzled; waiting behavior stays unchanged. KeyProbe and Objective-C files are untouched. Next CI supplies actual SDK selector names for a later bounded-wait investigation, not a claimed repair.

| Test | Log prefix | Question |
| --- | --- | --- |
| First test in each class | XCTest idle selectors | Which instance selectors for quiescence/idle/animation waiting exist in this XCTest runtime? |

## H8 - explicit covered-control preparation

D:controls-forms#4 correction and D:controls-menus#1 show keyboard overlap/degenerate Format viewport and the number-pad PopoverDismissRegion above Move Ruler. Added one opt-in helper, used only before Save Style, Ivory, Emoji and Move Ruler. It dismisses a keyboard intersecting the target (or the Format container for lazy Ivory) through existing native dismissal; Move Ruler uses a live dismiss-region point outside alert and keypad, then waits for the popover to disappear. Focused readable values are compared after dismissal, never restored. Ivory still uses shared reveal. Expected named-style, text-box style, folder customization and ruler-position tests. Next CI must retain typed values and reach the named control; coverage/render order for Ivory and Emoji remains bounded by the verifier's caveat.

| Test | Log prefix | Question |
| --- | --- | --- |
| Four covered-control callers | Covered control preparation | Which target/keyboard frames or number-pad surface justified dismissal? |

## C1 - cancel iPad confirmations

D:controls-forms#6 shows destructive-only confirmation Sheets, with cancellation through PopoverDismissRegion. Shared cancelConfirmation scopes Cancel to the presented confirmation, otherwise taps its live dismiss region outside all popovers, and waits for the captured heading to disappear. Applied to the four Insert destructive-cancel paths and Pages group/batch-trash cancellation. The already-correct Pages purge path retains its geometric assertions and outside cancellation. No ordinary edit Cancel changed. CI must reach the original retained-content checks, then confirmed deletion, with heading disappearance on cancel.

## C2 - provider preset button

D:controls-forms#7 confirms Button label Preset, Anthropic and a separate non-actionable Preset caption. Both provider setup paths now match the Button prefix Preset, and choose Custom OpenAI-compatible through the existing row helper. Expected three Insert provider/diagram/transcript cases and Selection Assistant attribution. Later provider fields/save are unobserved; CI must show the custom preset and then exact field/save assertions.

| Test | Log prefix | Question |
| --- | --- | --- |
| Insert/Selection provider setup | Provider custom preset selected | Did the next previously unobserved menu choice complete? Facts and screenshot retained. |

## C3 - inline playback speeds

D:controls-forms#8 shows inline 0.5x/2x/1x actions and no Speed submenu. Removed only the nonexistent intermediate tap in AudioPlayPauseSeekSkipSettingsAndClose. Each speed still checks Playback Options value. CI must reach all three speed assertions and the remaining playback settings/close checks.

## C4 - Pages control types and Rotate submenu

D:controls-forms#10 correction confirms Show hidden is a Switch, Imported second page a Cell, and the parent Rotate is visible while its children were unobserved. Pages button/tap now match those types in addition to Buttons, keeping visible/hittable selection and enabled taps. selectionAction opens Rotate when its requested leaf is unavailable. Expected hide/restore builtins, imported PDF outline navigation and rotate selection. CI must confirm the inferred leaf in the newly logged menu and the unchanged scope/undo assertions.

| Test | Log prefix | Question |
| --- | --- | --- |
| Pages rotate selection | Pages Rotate submenu | Which children appear after opening Rotate? One tree and screenshot per test. |

## C5 - dismiss thread menu before closing panel

D:controls-forms#11 confirms the open thread menu and two cmd.panel.close buttons; the Edit Message absence predicate was vacuous. The resolve/filter/reopen test now taps outside and waits for its actual Show on Page row to disappear, then scopes close by both command ID and the observed thread-specific Close Comment label (excluding Close Comments). Escape transport remains untouched. CI must reach second-page navigation and Show on Page back to the original page.

## C7 - geometry-aware Chrome outside tap

D:app-round-4#3 arithmetic proves (0.83,0.82) is inside the right-docked Fountain Pen settings. Chrome outside now selects a canvas point excluded by live popover/settings-sized scroll frames from one snapshot, with the old point only as a verified-free fallback. Failure to find geometry fails without a guessed tap. Existing callers retain their own state/content assertions. Expected DockRight dismissal before ink; CI must show settings close and the stroke/undo checks, across dock geometries.

## C6 - close settings before quick width

D:controls-menus#5 proves Highlighter settings covers Thickness 2. PageScrollCollapsesOptionsAndChoosingToolRestoresThem now dismisses settings and waits until no visible Highlighter settings scroll view is hittable before the same quick-strip tap. Existing before/after overlap diagnostics and ink checks remain. CI must show closed settings and a successful Thickness 2 action.

## C8 - retained tool settings assertions

D:app-round-4#4 correction confirms settings=true->false before highlighter selection while the old Fountain Pen ScrollView remains retained. QAState decodes optional toolSettingsOpen. The switch test replaces its two impossible existence assertions with bounded presentation assertions: when the JSON key is present (including null), expect nil after switching and highlighter after reopening; older probes require no in-window hittable old-tool ScrollView. Existing Straight line readiness proves the new settings in fallback mode. This proves dismissal/replacement intent without requiring destruction of a retained AX node. CI with app round 5 must report exact probe values; absent-field runs remain compatible.

## C9 - bounded creation scroll stalls

D:controls-menus#4 correction / D:app-round-4#7 show Size stopped at y869.5 below viewport bottom823 after one no-change drag; lost versus unsettled gesture remains unknown. scrollTo now requires two consecutive unchanged target frames with the same nonempty unchanged visible-row signature, varying the start 16pt inward on a stall. Missing snapshots/signatures never prove exhaustion. Twelve-drag bound and final reachability assertions remain. Expected B5; CI must show the new signature and either progress on the alternate start or two genuine unchanged observations.

| Test | Log prefix | Question |
| --- | --- | --- |
| Create scrolling, especially B5 | Creation scroll unchanged | Did target and visible rows remain unchanged twice, or was one drag a no-op? |

## C10 - clear outside selected content

D:keyboard-and-state#3 correction proves the fixed clear tap is inside the comment-extended selection, not on its pin. Selection clear now obtains current selection bounds and chooses a canvas point outside them with a 12pt margin; no candidate fails explicitly. The selectionCount==0 wait remains. Expected FilterCommentsIndependently; CI must reach its filter loop with a real cleared selection and retain all other filter results.

## C11 - settle deselection before page-text chord

D:keyboard-and-state#4 proves selectionCount changed 5->0 during chord focus preparation after outside. Added the bounded zero-selection wait at that exact PageTypingUsesMarginsAndReusesItsBoxWithPresets transition. Chord invariants remain strict. CI must send Cmd-Option-T after deselection and retain the single-box/content/frame assertions.

## C12 - nonwaiting zoom-box predicate

D:keyboard-and-state#2 correction identifies the inner page waiter only on a transient miss in the final outer poll. Added boxRectNow for predicates: one page/box/probe read, nil when unavailable, no require/page/state waiting helper. The Option-Return predicate uses it; other boxRect calls keep readiness. CI must report the actual Option-Return timeout or pass, never interrupted waiter rawValue5. Return non-arrival remains owned by the separate key probe job.

## C13 - observe library template sheet

D:keyboard-and-state#6 confirms the visible Notebook Templates sheet while the library probe openPanels remains empty. Only the App Menu route now waits for Notebook Templates and Import Template UI; document shortcut probe checks remain. Expected ManageTemplatesShortcutAndAppMenuDisplayBuiltinAndCustomEntries reaches its Covers assertions. CI must show both title and action after the library route.

## C14 - Go to Page focus observation

D:app-round-4#10 / keyboard-and-state#9 show repeated typing without focus on the fourth route; cause remains unknown. go logs native focus, preserves existing autofocus, waits on the actual field-focus predicate, retaps at most once on absence and refuses unfocused typing. Decision on the brief's ambiguous 'do not type when autofocus already holds it': preserve autofocus without another tap, and skip typing only when the requested value is already present; omitting the page number merely because focus exists would prevent navigation. All Go/page assertions remain. CI must distinguish initial/retap focus and reach RotateAllPages' exact scope/undo checks.

| Test | Log prefix | Question |
| --- | --- | --- |
| Canvas Go to Page callers | Go to Page focus / focus retap / focus failed | Was autofocus present, did one tap acquire focus, or was one bounded retap needed? Failure includes screenshot. |

## C15 - Pages thumbnail and persistence readiness

S:singles-rest#2 correction places the caption-inclusive centre on the pen options edge; tapThumb now restricts contact to the upper image centre and passes visible Tools/preset-strip frames as obstructions. S:#1 unbookmark now waits on a successful persisted-page read (a read failure cannot count as false). S:#6 correction: Add to Outline waits for a finite stable alert frame on two reads plus keyboard presence before replacement; no interruption monitor. Expected two thumbnail selection/stack tests, bookmark persistence and outline add flow. CI must show two selected pages without New Colour, persisted unbookmark, and no default Cancel during outline typing; interruption cause remains unknown.

## C16 - Insert singles

S:singles-insert#3: json adds withoutEscapingSlashes, making URL positive and removal assertions meaningful. Audited all contains needles with slash: the remaining matches are filesystem paths or HTTP request strings, not reserialized JSON. S:#6: forge-spec F032 says edge-dot tap creates a connected shape and diagram.create groups the transaction; it specifies no selection change after addConnected. Current DiagramAddConnected puts shape/connector without changing selection. Use the already-taken select-all copy and the connector destination item ID to identify the added shape (avoids both source and preexisting fixture shapes), then keep every side/anchor/undo assertion.

S:#7: Replay records minimumSeconds30 and uses one direct Pause predicate/tap. S:#1 correction: finish's TextView polling treats invalid/infinite frames and undetermined hittability as not ready. A small separate runner-only Objective-C exception boundary returns optional NSNumber for the latter; Swift loads its class by name because the protected bridging header cannot change. project.yml already compiles the entire NibUITests source directory. Escape delivery remains untouched. This does not claim sticky Escape fixed. Expected URL, Quick Diagram sides and Replay timing; sticky waits should fail normally instead of throwing on transient inf geometry. CI must verify the new ObjC helper links/loads and the unchanged final assertions.

| Test | Log prefix | Question |
| --- | --- | --- |
| QuickDiagramEachSide | Quick Diagram added shape | Does the destination shape differ geometrically from the source in the requested direction? |

## C17 - explicit colour picker close

S:singles-rest#12 correction proves Done was tapped while the picker remained, but not Done's ownership. closeColourPicker records that candidate frame and its snapshot parent, then explicitly waits for/taps the picker-scoped close button and retains picker-disappearance assertion. The old OR-Done selection and outside fallback are removed. Expected valid/invalid HEX and other picker-close paths. CI must show Done ownership, a close tap, picker disappearance and exact retained swatch colours.

| Test | Log prefix | Question |
| --- | --- | --- |
| Ink colour picker close callers | Colour picker Done candidate | What frame and parent did the ambiguous Done have? |

## C18 - explicit Apple Pencil detail container

D:controls-forms#2 shows absent lazy Hover/Haptics rows and successful explicit-container Squeeze scrolling. Both preference tests now pass the collection containing Switch between current tool and eraser to shared reveal before initial use and reopen assertions. No reveal implementation changes. CI must show detail-pane drags and persisted on/off state with no marks; initial absent-target direction remains measured by existing reveal diagnostics.

## X1 - committed Text failure evidence

S:singles-insert#2 verifier rejects the guessed selection occluder: exists versus hittability is not distinguished. visibleCanvasText retains its exact predicate/action and captures full hierarchy, element facts/centre overlaps and screenshot on wait failure. Expected diagnostic in TextInsertCommitEditAndUndo, not an asserted unblock.

| Test | Log prefix | Question |
| --- | --- | --- |
| Insert TextInsertCommitEditAndUndo | Committed Text wait failed | Is the Text absent/replaced or visible but non-hittable, and which AX frames overlap it? |

## X2 - invalid GIF immediate hierarchy

S:singles-insert#5 correction leaves toast timing, posting and exposure unresolved. Immediately after Add GIF, capture static texts/frames, full hierarchy and screenshot before the unchanged error predicate. No new toast oracle or behavior fix. Diagnostic overhead can consume transient-toast lifetime; the captured early snapshot is the decisive evidence, not a new pass criterion.

| Test | Log prefix | Question |
| --- | --- | --- |
| Insert GIFLocalInvalidLinkReportsErrorAndFilesCancelInsertsNothing | Invalid GIF immediately after Add | Was any error text exposed immediately after submission, and where? |

## X3 - unresolved control facts

D:controls-forms#12/#16/#15 verifiers leave Connector end, Spectrum, and Library Move to Trash/Save to Files causes unknown. Added facts/AX centre overlaps plus screenshot before connector/Spectrum lookup; Library performTap records the first poll screenshot, then every button match and popover/menu/sheet counts at timeout. No guessed coordinate actions, retries or visibility fixes. CI must distinguish absent surfaces, retained copies and non-hittable live controls.

| Test | Log prefix | Question |
| --- | --- | --- |
| Insert ConnectorDragAnchorRoutesBendsAndUndo | Connector end before lookup | What exists/frame/hittability/overlap evidence describes the handle? |
| Ink HighlighterCustomColourPersistsAndDrawsTranslucentInk | Colour Spectrum before lookup | Is Spectrum covered, missing, or otherwise non-hittable? |
| Library TrashPageBrowsingSelectionAndRecovery / ExternalFilesDropImportsIntoCurrentFolder | Library action first poll / action timeout | Was a menu/share surface present before polling, and which matches survived at timeout? |

## X4 - toast, tabs and touch orientation evidence

D:app-round-4#11/#14/#15 corrections leave ownership unknown. Toast Undo now records its typed Button snapshot frame and descendant Undo label frames (empty means no label exposed), tapping the Button frame centre, with immediate after-tap screenshot; stable-frame and restore-parent assertions remain. Capture three-tabs logs the toggle value and one snapshot inventory of every Tab-prefixed value/open-documents summary before its unchanged wait, with screenshot. Shared touch synthesis and the direct ruler path log device orientation plus first/last supplied screen points for every path; ruler screenshots remain at the gesture boundary. No transform, tab-setting repair or handler workaround is inferred.

| Test | Log prefix | Question |
| --- | --- | --- |
| Library DragDocumentIntoFolderAndToastUndo | Toast Undo button and label / immediately after tap | Which Button centre was tapped versus the label frame, and what remained immediately afterward? |
| Capture four ThreeDocumentTabs variants | Capture tabs toggle / tabs before wait | Did the setting change, and which tab values exist? |
| Chrome ruler rotation and shared NibUI paths | Touch path orientation | Which device orientation and first/last screen points were actually supplied? |

## X5 - window-control inventories

S:singles-rest#3 verifier rejects an environment classification without AX evidence. The two protected cross-window/cross-app tests add only a pre-lookup diagnostic: Nib and SpringBoard window/multitasking/Split View matches with type/id/label/frame/value, full trees through logQA and screenshot. Original selectors, waits, gestures and assertions are unchanged. CI must establish absence versus a differently exposed control before assigning capability/owner.

| Test | Log prefix | Question |
| --- | --- | --- |
| Pages DragPagesBetweenWindows / Selection ExternalDragToSafari | Window control inventory / hierarchy Nib / hierarchy SpringBoard / before lookup | Which process exposes which window controls, or do both trees lack them? |

## X6 - per-step unresolved state evidence

D:keyboard-and-state#9 establishes five failing state waits without causes. Added raw probe logging after meaningful steps in Cut/paste/undo, Batch duplicate/trash, Element drag, Tape visibility/history and RotateAll navigation/undo. Cut opts into shared tap diagnostics on the exact resolved Button, with frame/hittability/AX overlaps and before/after screenshots (AX overlap is not a UIKit hit-test result). Batch's existing tap wrapper logs the actual Duplicate and other action targets, with screenshots, without changing resolution. Element drag retains its action geometry and gains a post-drop screenshot; rotation gains a post-action screenshot, and Tape retains existing boundary diagnostics. No state mutation workaround or wait relaxation. CI must show the first divergent step and the actual command identities.

| Test | Log prefix | Question |
| --- | --- | --- |
| Selection CutMenuRemovesAndPasteRestoresContent | State step / Command tap resolved / returned | Which Cut Button was tapped, was it AX hittable, and did counts/clipboard change? |
| Pages BatchDuplicateAndTrashCancellationScope | State step / Batch page action resolved / completion | Did Duplicate resolve to the selected-pages action and when did count diverge? |
| Insert ElementDragInsertsAtDropPoint | State step | Did the drop insert/select anything before the geometry assertion? Post-drop screenshot retained. |
| Insert TapeDrawHideRevealDoesNotAddUndoAndRemoveAllRestores | State step | Which visibility/history transition first changes counts or undo state? |
| Canvas RotateAllPagesChangesEveryPageAndUndoesTogether | State step / Go to Page focus | Does navigation/focus or rotation state fail first, before or after Undo? |

## Final local verification - 2026-11-05

Completed H1-H11, C1-C18 and X1-X6 in 35 cluster commits. Re-read the changed Swift code and shared-helper callers against current signatures. Review corrections retained offscreen typed Pages matches for reveal, rebound covered editors independently of keyboard focus, kept the thumbnail viewport tall enough for the shared geometry helper, corrected the non-waiting Canvas lookup, and scoped Photos completion buttons to its observed Photos surface. No app source or protected key/touch source changed.

`python Scripts/lint.py`: 0 errors, 25 warnings in untouched app/architecture declarations. `git diff --check e6abd81`: clean. A separate local source audit retained all 585 test declarations (including the separate key probe), every executionTimeAllowance assignment, all four Capture presentation test bodies, and the original revealFormElement/liveList/form helpers plus openHardwareKeyRoute/hardwareKey/sendHardwareKey implementations. The two protected external-window tests differ only by the requested X5 diagnostic call. All shared NibUI method references resolve by name and all 35 evidence sections are present. Autosquash preserved the exact source tree; final history has one commit per cluster with the required attribution body. No push.

These are static checks, not Swift/Objective-C compilation or simulator proof. This Windows host has no relevant compiler/simulator. CI must especially compile/load C16's new runner-only NibUIReadiness Objective-C class via NSObject.perform, validate the XCTest runtime selector inventory, and confirm remote-picker and modal containment. The existing project.yml includes the whole NibUITests source directory, so no project or protected bridging-header edit is needed. Unknown failures remain diagnostic-only; no assertion tolerance or allowance was raised. C8's replacement presentation assertions are justified above. Estimated savings remain unmeasured: about 177s per Selection class from empty-modifier drags, about 235s in Insert probe reads, plus reduced swatch and empty-clear queries; launch priming and diagnostics add overhead. No 60s idle-stall saving is claimed. No clusters remain unfinished.

## Review fixes (round 1) - 2026-11-05

These corrections supersede the H3 caller-audit claim, C7 candidate order, H6 multi-tap description and C14 focus-failure policy above. Compared the review against current sources, the cited diagnosis/verdict pairs and the baseline implementation at e6abd81. Only test support changes; one review commit, no push.

| Issue | Confirmed evidence and change | Expected next-run result |
| --- | --- | --- |
| H3 blocker: panel dismissal | Chrome's baseline ui.log for testTitleCollaboratorsOpensSharePanelAndCloses taps cmd.panel.close at 23.52s (line 31131) and passes. closeEditing, Go to Page and Bridge callers also need panel closure. When the first iteration has no presented surface, dismissSheets now taps the enabled panel close once. Subsequent iterations remain surface-scoped and return when no surface remains. Restored the prior hittable-sheet swipeDown fallback when no own close control exists, retaining the eight-iteration bound. | Collaborators/editing/Go to Page/Bridge panels close; D:controls-forms#9 Audio export closes its share surface without then closing Audio. Sheets without close controls can still dismiss by swipe. |
| C7 major: outside point | D:app-round-4#3 proves the old point overlaps right-docked settings but works on the left. Put (0.83,0.82) first; alternative points are considered only if live geometry rejects it. | All 17 outside callers retain their prior contact when free; DockRight still uses a free alternative and completes the ink assertions. |
| H2 minor: missing-control cost | Typed firstMatch resolution still fixes the indexed remote-picker mismatch (D:controls-menus#3). Move the existing firstMatch.exists guard before the typed loop; absent Any controls now return after one query. Disabled-control and offscreen fallback behavior is unchanged. | Cancel/Save typed lookup still succeeds; missing-control polls do not enumerate eleven types. Savings require CI timing and are not measured locally. |
| H10 minor: transient swatches | swatches is used in wait predicates and deferred traceSwatch diagnostics. A missing group snapshot now silently returns [], retaining snapshot-based labels and live action/selection elements. | Tool transitions do not fail from this getter; callers' existing slot/content assertions and waits remain responsible for missing presets. |
| C15 minor: upper obstructions | The shared viewport helper clips height at obstruction.minY and can collapse for upper chrome. tapThumb now excludes obstruction frames starting at or above corridor.minY, while retaining lower palette/options clipping and the upper-image target. | Thumbnail selection/stack tests obtain a nonzero viewport with upper chrome, and avoid the lower options strip. |
| H6 minor: multi-tap contacts | e6abd81 offsets device-space centre.x by (index - 1) * 20. Restored those exact NibTouchPaths inputs. Only the clearance check and geometry attachment use interfacePoint; an 80pt centre inset reserves the original 60pt clearance plus the maximum 20pt contact offset in any orientation. | Ink two-/three-finger taps retain the original contact arrangement and undo/redo assertions without comparing rotated screen points to interface frames. |
| C14 minor: focus observation | D:app-round-4#10's verdict leaves the cause unknown. Keep the bounded three-second focus observation and at most one re-tap, log the resulting focus, then continue to the existing typeText/value logic. Removed the extra five-second wait and helper-thrown focus failure. | Go to Page callers rely on XCTest to report a real typing-focus failure; undetectable focus alone does not abort navigation. Existing page assertions remain. |

Reviewed dismissSheets callers across all class files, both canvasMultiTap calls, swatch waits/deferred diagnostics and the unchanged shared viewport implementation. No test declarations, product assertions, allowances, key delivery, revealFormElement/liveList, app files or protected files are changed.

| Diagnostic affected | Log prefix / attachment | Question |
| --- | --- | --- |
| Canvas Go to Page | Go to Page focus / Go to Page focus retap (existing logQA) | What focus was observable before typing, including after the single re-tap? |
| Ink multi-tap | Stationary multi-tap centre (contacts within 20pt) (existing geometry attachment) | Where is the interface-space centre used for edge clearance? It no longer labels device-space contacts as interface points. |

Local verification: `python Scripts/lint.py` reports **0 errors, 25 existing warnings**; `git diff --check` passes. A UTF-8 source comparison against the pre-review HEAD preserves all **585 test declarations**, assertion lines, execution allowances and skip/sleep lines, and confirms only the six intended NibUITests paths changed. Re-read all changed Swift blocks and current helper signatures for query APIs, optional binding, closures and coordinate spaces. Swift compilation and simulator behavior remain for GitHub Actions on macOS.

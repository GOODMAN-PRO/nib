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

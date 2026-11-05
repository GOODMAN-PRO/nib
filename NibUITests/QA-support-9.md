# QA support 9

Base: 6df0cbf, work/ui-round-9a. Read QA-support-8.md, README.md and both complete r9 diagnosis arrays; verdict corrections take precedence. Only NibUITests changes. Windows has no Swift/Objective-C toolchain or simulator; runtime claims below are next-run requirements, not measured results.

## H1 - non-idle touch delivery

D:idle-stalls#0/#1 and verdicts confirm seven Canvas and two Create 60-second idle timeouts despite sleeping app threads. The particular counted animation and editor-teardown trigger remain unconfirmed. Current NibTouchPaths.perform already supports a one-point hold/lift, selector checks, completion timeout and error propagation; no Objective-C change is needed. Split the Swift synthesis wrapper into canvas and screen inputs; pressWithoutIdle/tapWithoutIdle use frame-to-screen conversion. openDocument retains its clipped visible-card point and immediately waits for document state. No other ordinary taps change here. Should remove two 60-second waits in NewTextDocumentHasEditableFirstBlock; Canvas callers follow in C1. CI must show real navigation and no idle timeout, retaining all content assertions.

## C1 - board menu callers

D:idle-stalls#0: current board rows still use native SwiftUI contextMenu. The three named Canvas tests now synthesize only menu opening/item selection through H1, wait for the Duplicate button on open and for both the selected item and Duplicate to disappear on close. Rename accepts the evidenced pencil label. All original assertions and allowances remain. CI must retain board counts/content/rename and both-window probes, with zero menu idle timeouts. Estimated saving: four 60-second waits in duplicate, two each in rename and new-window (480 seconds of potential waits; only seven completed waits were observed before the duplicate allowance stopped the baseline).

## H2 - shared native switch press

D:capture#1, L:#3 and D:ink-three#0: current Capture and Library tap the wide labelled row; Chrome/Ink have separate native-thumb implementations. Circle to Lasso's 17ms contact is a leading hypothesis, not a proven cause. Added setSwitch on the caller-resolved labelled switch, native descendant or trailing thumb, 0.05-second press, pre-touch facts and an eight-second exact value wait (false requires 0, never a missing value). Capture tabs and Library favourite/All folders use it before continuing; Chrome and Ink delegate their delivery/value check while retaining existing visibility preparation and assertions. CI must show tabs value 1 before dismissal, favourite persistence, and both pen gesture switches changing; subsequent tabs/model faults remain possible.

| Test | Log prefix | Question |
| --- | --- | --- |
| Capture tabs; Library favourite/All folders; Chrome/Ink toggle callers | Switch before press / Switch value failed | Which row/thumb received the press, what overlaps it, and did the labelled value change? |

## H3 - ancestor-clipped reveal viewport (C7 reorder)

L:#0 and verifier confirm the 1032pt collection inside a 520pt panel, and the y961 drag outside that panel. Current reveal clips only to the window. Carry the selected container's intersection with every nonempty finite ancestor frame from the existing app snapshot (explicit forms obtain that ancestry too), then pass the clipped scroll frame to NibUITestScrollGeometry.viewport. The shared geometry source is outside NibUITests, so it remains unchanged. After a drag, disappearance or a type/frame change greater than 1pt records/fails immediately; requireControl and Library performTap propagate the failure without their later missing-row poll. Cached container/rebinding, ranking and control-value checks remain. Library Move earlier/later joins existing action diagnostics. CI must drag inside the panel, reach both rows and preserve all boundary/order assertions; a dismissed menu must instead report the container change.

| Test | Log prefix | Question |
| --- | --- | --- |
| Library AccessibleMoveEarlierLaterAndBoundaries; all reveal callers | Form container changed / Form drag point | Was the drag inside the ancestor clip, or did the original surface disappear/change? |

## H4 - chord loss evidence

D:capture#4 correction: no UIKit event arrived; cause and relation to the wide window are unknown. Current chord correctly excludes missing events from retry. Capture probe snapshots immediately before and after delivery, compare both log tail and optional total, and log both on no change. Existing modifier-loss retry alone remains. Current QAStateProbe exposes keyResponder/keyLog/keyLogTotal but **does not expose key-window identity or window frame**. Tests cannot obtain those app internals under the NibUITests-only rule: log these as unavailable, preserve the complete raw probe (including future fields), and separately label the first AX window frame, never claim it is the key window. This is the explicit scope-limited explanation for the unavailable part of H4. CI must show the actual responder, log totals, frames and any added probe fields in the next lost Command-comma; an app-side probe extension is needed for authoritative key-window identity/frame.

| Test | Log prefix | Question |
| --- | --- | --- |
| Capture PluginManager; all chord callers | Chord no new key event | Which probe responder/log and observed AX window frame bracketed delivery without a new event? |

## C2 - Pencil query mitigation

D:idle-stalls#2 verdict rejects query shape as the proven root cause: unchanged flow passed in 107s on the previous host; AX round trips inflated 4-20x despite fewer faults. Current squeezePaletteBinding repeatedly enumerates panels/sections and live boundary frames. Resolve the Apple Pencil collection once within this flow, reuse it for both reveals, and decide Squeeze boundaries/row geometry from one list snapshot per observation. Bind only the same-labelled row whose live frame matches the chosen snapshot; no snapshot-child ordinal addressing. Preserve all selection/persistence assertions and heading/row readiness. Add runner timings for collection resolution and snapshot/binding. CI must complete the original test within its unchanged allowance and compare timings with app snapshot logs. Savings unquantified; this mitigates query count and does not resolve host/transport latency.

| Test | Log prefix | Question |
| --- | --- | --- |
| Ink PencilDoubleTapAndSqueezeBindingChoicesPersist | Pencil AX duration | Does latency remain in collection resolution or snapshot/row binding despite fewer queries? |

## C3 - decimal keyboard dismissal

D:escape-and-keyboard#2 and verdict: the inert-header contact removes the floating pad while the docked keyboard and Width focus remain. Only the four existing inertHeader calls in the two custom-size tests now re-check keyboard existence, re-resolve the visible system Hide key and send at most one additional coordinate tap. Retain the five-second keyboard-gone wait and all dimension/validation assertions. Other dismissal callers are unchanged. CI must show pad removal, the conditional docked-Hide contact, keyboard disappearance, then the exact custom-size results. The second contact's effect on decimal input is inferred from the working Title keyboard route and remains runtime-unverified.

| Test | Log prefix | Question |
| --- | --- | --- |
| Create CustomSize / InvalidCustomSizePreventsCreation | Decimal keyboard remaining / Width keyboard after docked Hide | Was a docked keyboard still present and did the second observed-state contact remove it? |

## C4 - Calendar permissions and event readiness

D:create-calendar#0/#1 and verdicts: the first early interaction missed late system alerts; query-only polling could not invoke the monitor. The second test created its event but the test monitor declined the later full-access prompt, allowing XCTest's default denial. openCalendarEvent now explicitly dismisses observed SpringBoard permission alerts during its bounded readiness poll, logs alert count and actual Add facts each poll, and resolves/taps Add after that state clears. Retain Calendar's own XCUIApplication.typeKey Command-N fallback (the finding establishes that foreign-app route, not Nib's hardware route); its earlier loss remains unexplained. A readiness timeout with no remaining alert retains the original fallback when Add is absent; a remaining system alert fails explicitly. eventNote's monitor accepts Allow Full Access variants, and each test waits up to 15s to accept a late prompt and observe its unique event before scrolling. Existing grants take the same event-readiness path, so no test-order grant dependency remains. CI must show Add/editor, full-access acceptance with no default denial, linked note path/count, and reuse without duplication.

| Test | Log prefix | Question |
| --- | --- | --- |
| Both Create Calendar tests | Calendar readiness / readiness failed / Command-N | Which alert state and Add enabled/hittable/frame preceded the editor route? |
| Both Create Calendar tests | Calendar full access | Was the late full-access prompt explicitly accepted before event scrolling? |

## C5 - native colour picker presentation and dismissal

D:ink-three#1 and correction confirm remote tree instability as well as the short Sliders lookup race. Both pen slot-editor opens now wait for UIColorPicker plus a fresh hittable Sliders query before the existing action/HEX checks. D:ink-three#2 correction rejects assuming every picker has close; current highlighter source uses NibCustomColourPicker/SwiftUI ColorPicker. closeColourPicker logs the actual presented surface tree (types, labels, frames), uses its close or Done when hittable, otherwise taps outside only an identified containing native popover. A sheet without a dismissal control still fails explicitly. All routes retain the bounded picker-gone assertion and original valid/invalid colour, persistence and translucent-ink checks. CI must reveal the actual highlighter presentation, dismiss it, and reach all previously unexercised HEX steps; no current simulator presentation is assumed proven.

| Test | Log prefix | Question |
| --- | --- | --- |
| Ink CustomColourValidHex / HighlighterCustomColour | Colour picker controls / Colour picker dismissal | What controls and presentation type really exist, which dismissal route was used, and did the picker disappear? |

## C6 - Sort menu postcondition

D:capture#3 and verdict: a UIKit touch pair arrived but no library.setView/menu log followed; the 24pt layout shift is only a candidate cause. capture01Library resolves the labelled button, logs its facts immediately before the single tap, and waits for the actual Sort and View ScrollView in the main window. Failure records before/after button facts, raw probe, hierarchy and screenshot before propagating the error. No second tap or command workaround. CI must either reach the menu then original List/gallery captures, or provide evidence to pair with the new app library hit-test log.

| Test | Log prefix | Question |
| --- | --- | --- |
| Capture test01Library and variants | Capture Sort before tap / Capture Sort menu absent | Did the button frame change, which state followed the touch, and did the real menu appear? |

## C7 - Library failure boundaries

L:#0 is implemented with H3 and the original reorder/boundary assertions remain. L:#1: the observed card context menu after drag is now recorded with a screenshot and reported immediately as lift losing to the native menu, rather than missing Combine. No repeat gesture or outside-tap workaround; the app job owns the arbitration fix. L:#2 correction refutes the expiry explanation: an earlier run also failed with several seconds left. Remove the two-frame loop and snapshot, require Undo hittability in the existing toast/moved-document predicate, log that toast query's message/button/first frame and tap immediately. Retain restoration and destination-removal assertions. This saves queries, not a claimed fix of the action/hit-test defect. L:#4 correction leaves capability/selector unknown: before the unchanged multitasking lookup, log Files buttons/windows, its full tree, SpringBoard tree and retain a screenshot. No selector change, seam or skip. CI must show Combine confirmation/pages/trash, real Undo action and root restoration (compare app hit-test/action logs), and what iOS 26 actually exposes for external drag setup.

| Test | Log prefix | Question |
| --- | --- | --- |
| Library CombineNotebooksRequiresConfirmationAndPreservesPages | Combine context menu after drag | Did the native card menu survive the drag instead of arming Combine? |
| Library DragDocumentIntoFolderAndToastUndo | Toast Undo before tap | Which toast/button frame received the immediate hittable tap? Pair with app library tap/hit-test and toast action logs. |
| Library ExternalFilesDropImportsIntoCurrentFolder | Files window controls / Files hierarchy before multitasking / SpringBoard before Files multitasking | Is a differently labelled window control available, or is the expected flow absent? |

## Final source review and validation

Reviewed all changed Swift blocks and the unchanged NibTouchPaths.h/.m perform implementation: XCTest queries/snapshots and coordinate APIs, optional decoding, closure captures/throws, predicate placeholders, helper access/signatures and string expression sizes. All ordinary canvas paths retain the same screen conversion and completion/error handling. Re-read shared-helper callers across every class, including Insert/Pages/Selection: signatures/defaults are compatible; those classes are not edited. Explicit form ancestry failure returns without an unsafe drag; a detected post-drag container change fails and is propagated by requireControl, command taps, native focus and PNG-save wrappers. Existing nonthrowing direct callers stop via their continueAfterFailure=false setting. Capture's continueAfterFailure=true paths use the throwing wrappers.

A Python source audit against 6df0cbf preserves all **586 test declarations**, every existing XCTAssert line, all executionTimeAllowance assignments and the skip/sleep inventory. Removed only the explicitly requested toast stability wait; colour dismissal now checks the actual presented route and still requires disappearance. Eight files changed, all under NibUITests. Eleven commits, one for each H1-H4/C1-C7 cluster, with the exact requested attribution body; review corrections folded into their owning clusters. No push.

`python Scripts/lint.py`: **0 errors, 25 existing warnings**. `git diff --check 6df0cbf` and `git diff --check`: clean. These checks do not compile Swift/Objective-C or run XCUITest. CI must particularly validate native-menu screen coordinates, ancestry clipping and frame-change detection, native switch presses, remote colour-picker surface containment, late Calendar permission timing, and foreign-app AX availability. No Objective-C source/header changes were necessary. H4's missing authoritative key-window probe fields are explicitly explained above; no other cluster remains unaddressed.

Estimated, unmeasured runtime saving: nine observed 60-second idle waits (seven Canvas, two Create), about **540 seconds** across those paths; the additional duplicate-menu wait interrupted by the baseline allowance makes the potential avoided total about **600 seconds**. Pencil and toast query reductions are unquantified and do not establish a latency or toast-action fix. New diagnostics and state waits add AX overhead, so net runtime and test passes require the next macOS CI run. App-owned Escape, toast action and lift/menu defects retain their original expected behavior and receive no test workaround.

## Review fixes (round 1) - 2026-11-05

These corrections supersede the H3 failure/fallback policy, C3 second-contact timing, C4 pre-scroll readiness requirement and corresponding final-review statements above. Re-read both diagnosis arrays and their verdicts, current helpers and all reveal/dismissal callers. Only NibUITests changes; one new review commit, no amendment or push.

| Review issue | Change and evidence | Next-run requirement |
| --- | --- | --- |
| Keyboard binding blocker | Bind the optional Hide match directly once with `guard let dockedHide = ...first(where:)`, then use its frame. | UI test target compiles; four custom-size calls retain the actual keyboard-gone assertion. |
| Pencil binding blocker | Bind the snapshot row directly once with `guard let match = ...first(where:)`; live candidate matching still uses that snapshot frame. | UI test target compiles and Squeeze selects its own palette row with all persistence assertions intact. |
| Reveal container regression (major and duplicate minor) | Record whether the original container belongs to a menu/popover before dragging, so replacement lookup cannot overwrite that evidence. Only those surfaces fail immediately on a changed type/frame. L:#0's native menu uses Other ancestors and a Preview sibling (baseline ui-LibraryUITests/ui.log:13406-13418), which is also recognized. Ordinary type/frame changes and any unavailable post-drag snapshot log and return to the caller's existing wait/fallback without setting formRevealFailure or calling XCTFail. | Reorder still fails promptly if its native menu is replaced by the library; normal library/settings rebuilds and keyboard resizing do not create helper-level failures. Ancestor clipping and slider/switch guards remain. |
| Explicit form ancestry regression | Reset optional ancestry state on lookup; if either snapshot or the cross-snapshot match fails, return the caller's form with the existing window clip. Ancestry narrows a successful match and no longer gates scrolling. Keep the existing snapshot approach: current helpers expose no upward ancestor traversal, so explicit-form AX overhead remains unmeasured. | Pencil/settings explicit-form reveals can scroll despite an ancestry miss; CI must measure the unchanged snapshot cost under the existing allowance. |
| Keyboard animation race | Before considering a second contact, wait up to two seconds for disappearance, then recheck presence and resolve the Hide key. Keep at most one extra tap and the final five-second disappearance assertion. | A keyboard already animating out receives no second contact; a remaining decimal keyboard gets one observed-state Hide tap. |
| Calendar lazy-row wait (duplicate minors) | Keep the 15-second permission/readiness poll and Allow Full Access monitor, but make summary existence only an early exit. Timeout logs and proceeds to tapEventAction/scrollTo, whose event/action and linked-note assertions remain unchanged. | Lazy events can be revealed by scrolling; late permission prompts are accepted and both event-note outcomes remain required. |
| H4 unavailable probe fields | No source change: the probe still lacks authoritative keyWindow/windowFrame. Existing raw probe, responder, AX frame and keyLog entries retain the available evidence. | Lost chords remain diagnostic-only with no new retry; app keyLog may report keyWindow, but the AX frame is not claimed to be its frame. |

| Diagnostic affected | Log prefix | Question |
| --- | --- | --- |
| Explicit form ancestry miss | Form reveal ancestry unavailable | Did reveal retain the supplied form with a window clip? |
| Ordinary rebuild / missing post-drag snapshot | Form container changed / Form reveal unavailable | Did the helper hand control back to the caller without recording a failure? |
| Calendar readiness timeout | Calendar readiness | Was event discovery deferred to the existing bounded scroll? |

No new tests, sleeps, retries, skips or allowances. Static verification and CI limitations are recorded below.

Local validation: `python Scripts/lint.py` reports **0 errors, 25 existing warnings**; `git diff --check` passes. Source comparison against the pre-review HEAD preserves all **586 test declarations**, every XCTAssert line, execution allowances and skip/sleep lines, and confines changes to these four NibUITests files. Re-read each changed Swift block for optional bindings, tuple/closure syntax, XCTest query and waiter APIs, and all shared reveal/dismissal callers. No Swift compiler or simulator is available here; compilation, native-menu classification, explicit-form AX latency, keyboard transitions and lazy Calendar rows remain CI checks.

## Review fixes (round 2) - 2026-11-05

These corrections supersede the round 1 ordinary-container return policy and explicit-form snapshot approach, plus the original immediate H4 comparison. Re-read the diagnosis findings and verifier corrections, current shared-helper callers and the touch synthesizer. Changes remain confined to NibUITests; no app-side workaround, new retry, sleep, skip, assertion removal or allowance change.

| Review issue | Correction | Next-run requirement |
| --- | --- | --- |
| Ordinary reveal stops after a container rebuild (both major reports) | Log type/frame changes and continue with the post-drag snapshot. Clear the stale ordinary ancestor clip so the next iteration computes its viewport from the new frame. Only the original transient surface triggers containerLost. | Library/settings/sheet rebuilds, detent changes and lazy firstMatch rebinding continue revealing; Insert, Pages and Selection retain the shared helper contract. |
| Transient container disappears without a replacement | The missing post-drag snapshot branch now calls containerLost when wasTransient, setting formRevealFailure and recording XCTFail before returning. Ordinary missing snapshots retain the caller fallback. | A dismissed menu/popover reports disappearance immediately, including when no main-list replacement is found. |
| Offscreen switch thumb | setSwitch reveals the labelled row once when its existing target is not hittable, propagates reveal failure, then resolves the native-thumb choice again before the enabled/hittable guard and 50 ms press. | Capture tabs and Library All folders/favourite reach offscreen rows and still require the exact requested value; Chrome/Ink keep their existing preparation. |
| Premature no-key-event diagnostic / absent probe fields | Compare the log only after the caller's postcondition fails, taking a fresh probe then. Keep the before-delivery snapshot and label the later observation accurately. Key-window identity and its frame still require app-side probe fields; the AX first-window frame is a separate observation. No missing-event retry was added. | A late event observed during the bounded postcondition produces no spurious no-event line. A lost chord records responder/raw probe and available frame facts at the two stated times. |
| Popover picker bypasses close/Done readiness | Give close/Done a predicate-based two-second opportunity for a popover (eight seconds for other presentations). Only a popover can then fall back to an outside tap, chosen inside the visible PopoverDismissRegion frame and outside all popover frames with an 8 pt margin. | Late dismissal controls win over outside dismissal; fallback logs the region and point and still requires UIColorPicker disappearance. |
| Non-idle taps have 10 ms contact | tapWithoutIdle and openDocument now request a 0.05-second press. NibTouchPaths adds its existing 0.01-second lift offset, yielding about 60 ms scheduled contact. D:ink-three#0's verifier observed 37-85 ms successful switch contacts versus the lone 17 ms failure; the contact-length explanation remains a hypothesis. | Board menu actions and all document-entry callers deliver their tap and pass their existing bounded menu-gone/document-state postconditions without idle waits. |
| Frame-comparison type-check complexity | Compute four explicitly typed CGFloat deltas separately, then combine simple comparisons against 1.0. | Xcode compiles the helper; the 1 pt tolerance is unchanged. |
| Empty ancestry clip and explicit-form full-tree cost | When the ancestor-clipped viewport is unusable, log and retry the original list/window viewport with the same keyboard obstructions. Explicit forms inspect only presented popover/menu snapshots; the observed native-menu Preview marker permits the whole-app fallback for that menu representation. Ordinary explicit forms no longer take an additional form/app snapshot pair for ancestry. Automatic discovery reuses its existing single app snapshot. | Degenerate wrapper frames do not stop a reveal that has a valid window viewport. Verify actual menu clipping and explicit-form query latency under the unchanged allowances; typed surface queries still incur AX work. |

| Diagnostic affected | Log prefix | Question |
| --- | --- | --- |
| Reveal viewport | Form viewport fallback | Was the ancestor clip unusable, and which container/window frames supplied the fallback? |
| Ordinary rebuild / transient disappearance | Form container changed | Did ordinary search continue, or did the original transient surface disappear or change? |
| Failed chord | Chord no new key event | Was the key log still unchanged after the caller's postcondition failed? |
| Colour picker outside dismissal | Colour picker dismissal | Was the selected point inside the observed dismissal region and outside the popovers? |

Swift compilation and XCUITest execution are unavailable on this Windows host. CI must verify live ancestry, AX latency, native contact delivery and remote-picker timing; no runtime success or additional measured time saving is claimed.

Validation: `python Scripts/lint.py` reports **0 errors, 25 warnings**; `git diff --check` passes. The source audit against the pre-round-2 HEAD preserves all **586 test declarations, 943 XCTAssert lines and 14 allowance lines**, with no skip/sleep lines added. Exactly three files changed: Support/NibUI.swift, InkUITests.swift and this report. Re-read the changed Swift blocks and shared callers, checking optional bindings, XCTest queries/waiters, closure captures, helper signatures and bounded postconditions. No Objective-C changes.

## Round 9b

### H1 - form focus query cost

Confirmed S:selection-timeouts-and-ink#1 and its verdict against the current focus/clear/replace path: Name/Base URL/Chat model consumed 66/25/33 seconds; the success path polled global focus then built debugDescription. After a tap, focus now requires the keyboard and one responder-probe read per observation. Initial field-specific focus checks remain scoped to the presented container (so another focused editor cannot qualify); Attributes inspection remains only the occluded-editor fallback. Native Select All reuses already-verified focus, preserving empty-before-type and exact replacement postconditions. A form batch resolves the container once and each typed field once; Assistant saves with native Command-S before dismissing the keyboard and polls one typed saved-status query. Other native callers keep their signatures and selection-preservation contract.

Should unblock Selection Assistant attribution; next CI must show exact three values, Provider saved and the final provenance assertions, with per-field durations materially below the baseline. A sub-10-second field / sub-100-second test is a target, not measured. Host AX inflation remains possible.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| Selection Assistant attribution | Native form field duration | Which scoped field still consumes the allowance? |
| All native replacements | Native replacement duration | How long do focus, clear, type and exact verification take? |

H1 caller review: the batch also reuses its resolved container for initial field-specific focus checks; absent lazy fields retain the existing bounded reveal path. Public callers retain defaults. Native Select All tries the cheap UIKit probe first and retains the existing field-specific fallback for remote editors whose focus the Nib probe cannot classify, preserving Insert/Chrome native selection behavior.


### H2 - native context menu transaction

Confirmed P:pages-outline-templates#0 (including the Move-opening post-event stall correction) and #2. Current pressWithoutIdle/tapWithoutIdle and NibTouchPaths.perform support a stationary contact without element idle waits. Added nativeContextMenu: two equal consecutive visible-frame reads, one 0.8-second centre press, query-only named item waits, synthesized taps for every path component, then a bounded menu-gone wait. Captured item frames distinguish the dismissed menu from a same-labelled Rename alert/Delete confirmation. A missing item logs target facts, raw probe, full hierarchy and screenshot and throws that message; there is no second press. Existing board callers and public synthesis signatures stay compatible; Pages callers follow in C2/C4.

Next CI must show menu opening/item/dismissed in seconds without any 60-second idle wait, including Move, then all original assertions. Stable geometry mitigates the unproven custom-tile timing hypothesis; it does not prove its cause.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| Native menu callers (Pages outline/thumbnail/template) | Native menu opening / item / dismissed | Which stable frame and named path received contacts, and how long did dismissal take? |
| Same, on failure | Native menu missing / dismissal failed | Was the item absent after the single press, and what target/probe/tree remained? |

### H3 - system window control evidence

Confirmed S:selection-timeouts-and-ink#3 and L:#4 with the latter verifier rejecting a proven simulator-capability limit. Current selectors only recognize the old labels. Selection external Safari drag and Library external Files drop now use one bounded lookup, retaining both tests' control/Split View/drag/import expectations. A miss inventories every top-100pt button from snapshots of Nib, SpringBoard and (for Library) Files, logs full trees and per-window raw probes, hovers the visible window's top-leading +16pt point, then inventories again. Pointer support is checked; absence is logged, never skipped. No new window-management flow is guessed.

Current QAStateProbe now exposes keyWindowState.isKey/dimensions/sceneActivation, but no UIScene identifier or authoritative keyboard-focus scene. Multiple probe-bearing AX windows are logged as evidence of multiple scenes; raw window count alone is not scene count. Missing scene ownership is explicit, not manufactured. Next CI must show the actual iOS 26 controls before/after hover and the original transfer/persistence assertions if the expected flow is available. Hover API verified against Apple's [XCUICoordinate documentation](https://developer.apple.com/documentation/xcuiautomation/xcuicoordinate).

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| Selection external Safari / Library external Files | Window top controls / Window control hierarchy / Window control hover | What labels and identifiers exist in the top 100pt, and does pointer hover expose controls? |
| Same | Window scene probe / Window scene count | Which AX windows carry document probes and report isKey, and is more than one scene observable? |

### C1 - thumbnail drag destination contact

Confirmed P:pages-drag-select#0/#1 and corrections: reorder's touch ended before the session replied; stack reached a proposal but never performDrop. The source of the 1.7-1.9s startup latency and operation=0 remains unproven. Both tests now use one helper with the original 0.8s lift and explicit 500pt/s travel, plus 1.5s destination hold (continuous gesture contact, not a sleep or allowance change). Reorder previously lasted about 1.85s, so this leaves about 1.45s after the latest observed startup; stack previously had only 0.55s after startup and now has about 2.05s. This is enough to test the timing hypothesis, not proof of proposal acceptance. Every reorder, adjacent-stack and whole-stack Undo assertion remains.

Next CI must pair the runner result with app dragSessionWillBegin, move proposal and performDrop (two items for stack); operation=0 with the dwell keeps the cause unresolved, and the earlier split-stack symptom must still fail its assertion.

| Test | Log prefix | Question it answers |
| --- | --- | --- |
| Pages reorder / selected-stack drag | Thumbnail drag result / State step (thumbnail drag completed) | Did a native context menu survive the gesture, and what selection/page/responder state followed? |

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

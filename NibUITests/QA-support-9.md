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

D:escape-and-keyboard#2 and verdict: the inert-header contact removes the floating pad while the docked keyboard and Width focus remain. Only the two existing inertHeader custom-size callers now re-check keyboard existence, re-resolve the visible system Hide key and send at most one additional coordinate tap. Retain the five-second keyboard-gone wait and all dimension/validation assertions. Other dismissal callers are unchanged. CI must show pad removal, the conditional docked-Hide contact, keyboard disappearance, then the exact custom-size results. The second contact's effect on decimal input is inferred from the working Title keyboard route and remains runtime-unverified.

| Test | Log prefix | Question |
| --- | --- | --- |
| Create CustomSize / InvalidCustomSizePreventsCreation | Decimal keyboard remaining / Width keyboard after docked Hide | Was a docked keyboard still present and did the second observed-state contact remove it? |

## C4 - Calendar permissions and event readiness

D:create-calendar#0/#1 and verdicts: the first early interaction missed late system alerts; query-only polling could not invoke the monitor. The second test created its event but the test monitor declined the later full-access prompt, allowing XCTest's default denial. openCalendarEvent now explicitly dismisses observed SpringBoard permission alerts during its bounded readiness poll, logs alert count and actual Add facts each poll, and resolves/taps Add after that state clears. Retain Calendar's own XCUIApplication.typeKey Command-N fallback (the finding establishes that foreign-app route, not Nib's hardware route); its earlier loss remains unexplained. A readiness timeout with no remaining alert retains the original fallback when Add is absent; a remaining system alert fails explicitly. eventNote's monitor accepts Allow Full Access variants, and each test waits up to 15s to accept a late prompt and observe its unique event before scrolling. Existing grants take the same event-readiness path, so no test-order grant dependency remains. CI must show Add/editor, full-access acceptance with no default denial, linked note path/count, and reuse without duplication.

| Test | Log prefix | Question |
| --- | --- | --- |
| Both Create Calendar tests | Calendar readiness / readiness failed / Command-N | Which alert state and Add enabled/hittable/frame preceded the editor route? |
| Both Create Calendar tests | Calendar full access | Was the late full-access prompt explicitly accepted before event scrolling? |

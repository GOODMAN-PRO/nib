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

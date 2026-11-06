# Format popover QA notes

Round 1 review, 2026-11-06, branch `work/ui-app28-format`.
Paths below are relative to `NibKit/`. These are source findings, not simulator results.

## F1: Save Style touch and prompt delivery

No host behaviour change was made because the cause is unproven.

- `Sources/NibDesign/Components/NibFloatingHost.swift:42` stores/replaces view entries;
  `:113` renders them in a full-size SwiftUI ZStack. The host has no cached per-entry
  hit rectangle. Its `anchors` are placement sources, and `layerOrigin` is for
  coordinate conversion (`:89`, `:130`), not touch admission. The reference view
  is noninteractive and always returns false from `point(inside:with:)` (`:190`).
  SwiftUI/UIKit hit-test the currently laid-out content and its transforms.
- `Sources/FeatTextBox/TextBoxEditor.swift:178` updates the anchor and retained
  popover geometry on keyboard changes. `:1133` updates the published viewport
  and height budget without replacing the view. `TextFormatInspector.swift:875`
  applies that viewport; `Sources/NibDesign/Components/Panels.swift:298` computes
  the panel's available size and position from current geometry and source anchor.
  `Sources/NibDesign/Liquid/Droplet.swift:308` observes laid-out frame changes;
  `DropletField.swift:460` derives the visual frame used by our diagnostic.
  That diagnostic frame is not a host touch gate. There is no old host hit frame
  that can explain the failure. Timing disagreement between native layout and
  rendered geometry remains a runtime question, not an established defect.
- The Save Style action is in the section header's ordinary HStack/VStack layout
  (`Panels.swift:348`), inside `TextFormatInspector`'s content stack
  (`TextFormatInspector.swift:594`) and the padded scrolling panel (`Panels.swift:76`).
  It is not positioned in an out-of-bounds overlay. Its label participates in
  content bounds, but `Sources/NibDesign/Components/Controls.swift:685` expands
  its vertical hit shape by 13 pt without expanding layout. Source alone cannot
  certify the expanded hit target against every UIKit ancestor at the failed tap.
  The DEBUG content/scroll/visible frames and ancestor containment flags are
  intended to settle that question in the next run; no too-small host is proven.
- `TextFormatInspector.swift:670` can return with naming still true: no window,
  an existing weak prompt, or another presented controller. A no-window return
  gets another attempt from `viewDidAppear`; representable updates also queue
  another attempt (`:627`, `:655`, `:660`). An existing prompt normally means the
  request is already served. A busy presenter has no explicit dismissal retry,
  so the request can remain pending until a later update/appearance. There is no
  evidence that this guard caused the reported failed tap. The action log and
  `not-requested`, `no-window`, `existing-prompt`, `presenter-busy`, `present`
  outcomes distinguish action delivery from guard rejection.

## F2: Fit Height to Text and the cue lane

No inset change is needed. `Sources/NibDesign/Components/Panels.swift:76` puts
the header and entire inspector in the same scroller with 16 pt padding on all
sides (`NibSpacing.l`, `Sources/NibDesign/Tokens/NibSpacing.swift:9`).
`Sources/NibDesign/Components/NibScrollView.swift:29` puts the 16 pt overflow cue
in a separate sibling below the scroll viewport, not over the last row.
At the maximum scroll offset, the bottom of the content (including its bottom
padding) reaches the viewport bottom, so the last row ends 16 pt above the cue
lane. The partially visible initial row does not demonstrate an unreachable row.

## Round 1 diagnostics and CI log interpretation

- The canvas log computes `details` separately and appends it by interpolation;
  the pre-existing message text is preserved byte-for-byte. No canvas decision,
  state mutation, or other log is changed.
- The prompt log computes the optional presenter description separately and
  uses one interpolated literal, avoiding concatenation and a closure in it.
- `floating scroll-claim` reports `claimedByScroll=false` with the frames.
  This is explicitly a scroll ancestry observation, not proof that the floating
  surface missed the touch. Chrome outside the scroller can legitimately own it;
  a missing scroller also produces false. Check `windowHit` and ancestor frames.
- `contactDetails` calls `window.hitTest`, which may re-enter the canvas report.
  The nested contact line has `windowHit=probe-in-progress` and is a diagnostic
  duplicate, not another delivered touch. Exclude those lines when counting or
  parsing contacts. The guard bounds recursion; the nested admission path uses
  `decision(remember: false)`. This review uses the requested documentation option
  so canvas changes stay confined to constructing its DEBUG log statement.

## Callers, tests, and validation

`contactDetails` has one production caller, the local canvas admission report,
plus `FloatingHitDiagnosticsTests`. The surface probe is installed only by
`TextFormatPopover`. Its ancestor formatter is called only by `contactDetails`.
`presentIfNeeded` is queued by `updatePresentation`, called by the representable
update and controller appearance. The shared inspector is used for selection,
text-tool defaults, the keyboard Format panel and its system-popover fallback.
These all receive identical diagnostic formatting; presentation guards are unchanged.
Other floating-host consumers (spellcheck, Math Assist, teacher score/hints and
Zoom Window options, as well as document/library chrome) keep their existing
layout and hit behaviour: this review changes only DEBUG diagnostic text in the
host, and adds no touch gate, hosting-view search, or frame cache.

Existing tests read and preserved:

- `Tests/NibDesignTests/FloatingHitDiagnosticsTests.swift`:
  `testWindowHitProbeDoesNotReenterAndResetsAfterEachContact`,
  `testDetachedContactDoesNotAttemptAWindowHitTest`.
- `Tests/FeatTextBoxTests/FeatTextBoxTests.swift`:
  `testMoreBudsTheInspectorFromTheWindowsFloatingHost`,
  `testStyleNameAlertHasAPersistentAccessibleName`,
  `testFormatPopoverHasOneVerticalScrollOwnerForBoxControls`.
- `Tests/NibDesignTests/ScrollOverflowTests.swift`: all three tests, including
  `testCueReservesSpaceOutsideControlsAndKeepsTheScrollHost`.
- `Tests/NibDesignTests/NibDesignV2Tests.swift`:
  `testFloatingHostPresentsReplacesAndDismissesByID`, `testFloatingHostAnchorsAndToasts`.
- `Tests/FeatCanvasTests/CanvasInputTests.swift`:
  `testSpeculativeAndEndedHitTestsDoNotReserveTheNextDrawingContact`.

No assertions or behaviour changed; no new test is needed for string construction
and diagnostic wording. Static review checked DEBUG actor isolation, optionality,
existing signatures and callers. Swift compilation and simulator tests are not
available on this Windows PC and remain for GitHub Actions. Local checks:
`python Scripts/lint.py`: 0 errors, 25 warnings in unrelated files/registrations;
`python Scripts/a11y_lint.py`: 0 warnings. `git diff --check`: passed.
A source comparison also confirmed all non-DEBUG code is unchanged, and the
canvas diff is confined to the log construction with the original message intact.

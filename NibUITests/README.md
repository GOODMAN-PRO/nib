# Simulator UI tests

Run from any directory:

```sh
/Users/Nice/Projects/Nib-tools/nib-build.sh uitest /Users/Nice/Projects/Nib-wt/integration "NibUITests/SmokeUITests"
```

The `NibUITests` scheme builds the real Nib app and a separate UI test runner. The existing `Nib` and package schemes and `ios.yml` do not run UI tests. Signing settings are inherited from the app's project settings; deployment is iOS 17.

`NibUI.launchFixture()` sets `-NibUITestFixture`, English labels, and landscape orientation. Every launch gets a new temporary disk library and reset fixture-only preferences, with the saved library bookmark cleared before library construction. It skips onboarding and scene restoration, uses finger drawing, and reduces motion. It never switches on `NibApp.isHostlessTest`. The fixture has Semester Notes/Lecture notes, Physics — Motion (four pages, text, shape, sticky, ink), Concept map, Lab report, and Motion flashcards (three cards). Seed errors fail the state wait with the original error.

```swift
let ui = NibUI()
try ui.launchFixture()
try ui.openDocument("Physics — Motion")
try ui.selectTool("pen")
let before = try ui.state()
try ui.drawStroke([CGPoint(x: 0.4, y: 0.6), CGPoint(x: 0.6, y: 0.7)])
try ui.waitForState { $0.strokeCountOnPage == before.strokeCountOnPage + 1 }
try ui.tapCommand("edit.undo")
try ui.pinchZoom(scale: 1.5)
ui.doubleTap(at: CGPoint(x: 0.5, y: 0.5))
try ui.twoFingerScroll(from: CGPoint(x: 0.10, y: 0.7), to: CGPoint(x: 0.10, y: 0.6))
try ui.dismissSheets()
try ui.tapCommand("window.showLibrary")
```

Coordinates are fractions of `nib.canvas`, so choose points on paper and clear of chrome. Two-point strokes use `XCUICoordinate.press` and drag. Longer paths, pinches, and simultaneous two-finger pans use XCTest touch synthesis in `NibTouchPaths.m`; this SDK-private API is confined to the test runner, checked at runtime, and fails explicitly if unavailable. Double taps use the public XCUITest API. Pinches use two bounded contact paths with staggered touch-downs. The default centre is on the canvas margin, clear of the palette and PencilKit; pass `at:` to choose a different location. On the tested iOS 26.5 simulator, pinching over the PencilKit surface with the pen selected loses a contact and does not reach the outer scroll view. The same gesture works on paper with the lasso, or on the canvas margin with the pen. The smoke test keeps the pen selected and checks real zoom and scroll changes from the margin; it does not inject app-side navigation. On the simulator only, fixture mode normalizes XCTest’s synthetic ~37-point contact radius to a fingertip (8 points), so palm rejection does not discard every simulated drag or pinch. Fixture mode also accommodates the simulator’s empty hit-test events and delayed final PencilKit drawing callback. Ink still comes from PencilKit and commits through the real command bus. Normal launches retain their existing input handling. `selectTool` avoids opening settings when the tool is already active.

The transparent `nib.qa.state` accessibility element exists only in fixture mode. Reading its value takes a fresh compact JSON snapshot, with no timer or production observer. `QAState` decodes document/page IDs (null in the library), page count, tool, **UIScrollView.zoomScale**, content offset in scroll-view points, live item/stroke counts, selection count, undo/redo availability, registered open panel IDs, and the effective palette dock. `screen` is loading, fixtureError, library, or document. Tests wait on state predicates instead of fixed sleeps.

Command controls use `cmd.<registered command ID>` and palette tools use `tool.<tool ID>`, including plugin contributions and overflow items. Multiple controls can share a command ID; narrow by label or ancestor when parameters differ. VoiceOver labels remain unchanged. `tapCommand` searches hittable controls, then document More (`menu.more`) and palette More (`tool.more`). Use `NibAction(command:)`, `.nibCommand(...)` (SwiftUI and native menus), or `.accessibilityIdentifier(...)` when adding a command control. Non-command navigation controls use `menu.*` / `sheet.dismiss`.

# Capture tour

`NibUITests/CaptureUITests.swift` defines routes to these screens through the app's normal controls.
Each tour state is scheduled with isolated fixtures for light/dark appearance and portrait/landscape.
Every kept image is named `<NNN>-<screen>-<appearance>-<orientation>`; numbering follows
onboarding, library, creation, editing, sharing, audio, document types, and settings.

The main application window must actually reach the requested orientation. No image
is relabelled to stand in for a failed orientation. Diagnostic and unreachable
attachments remain separate from review images, and every failed route fails its test.

## Device-dependent screens

- iPhone offers top and bottom palette docks. The left dock is iPad-only (DESIGN §10.11).
- Without an external display, the presentation capture shows the Share menu with
  presentation controls absent. With a display, it shows the actual presenter UI
  (DESIGN §14.12; F063). These alternatives share tour position 070.
- Onboarding's storage confirmation appears when retaining notes inside the app;
  an already-selected external library advances directly to the Pencil step.
- The assistant answer uses an explicitly opted-in fixture model provider. The real
  agent, context gathering, conversation storage and assistant UI handle the turn.
  Normal app launches still use the user's configured Nib Agent or other provider.

## Reachability fixes

- Launch the fixture before requesting orientation, wait for the foreground main
  window, and verify the actual screenshot dimensions before naming a variant.
- With Liquid Off or Reduce Motion, docking now clears the previous drag transform
  when the palette changes axis. The old offset moved tool controls outside the
  app window; a later test drag could hit iPadOS window controls. The tour also
  checks that the palette is visible and inside its window before another drag.
- The pen expectation now uses the actual Fountain Pen settings. The original
  generic Pen heading contradicted the pen-type presentation in DESIGN §14.3.
- The presentation expectation follows F063's external-display requirement;
  an unattached simulator captures the disconnected Share menu explicitly.
- Compact routes enter Documents from the Library sidebar, open Settings through App Menu, and use the real More menu and scrollable settings index. The keyboard tutorial is dismissed through its Continue button. Study
  cards are flipped before grading, and creation forms use the shared type picker
  when a direct New-menu shortcut creates a document immediately.
- First-run and model-response fixtures are explicit launch options. Regular
  launches keep their normal onboarding and configured-provider behavior.
- AI onboarding and settings lead with the user's Claude or ChatGPT subscription
  through Nib Agent; API-key providers remain a secondary option.
- Bottom-docked assistant panels move above the keyboard, keeping their detent
  height where space permits. Docked assistant sidebars also clear the keyboard.
- Closed native popovers release focus and hit testing; collapsed hosts disappear
  immediately instead of exposing invalid accessibility frames.
- Search assertions follow the visible results panel: the library remains behind
  its overlay, and an empty document search retains its zero-match counter.
  Document search uses its actual Find field, export opens its format picker, and
  secondary sidebar panels are reached through Panel Options.
- Palette and native page-menu sweeps split light/dark into separate test methods.
  All four variants and assertions remain; a native context-menu animation can
  consume a minute of XCTest's idle wait, exceeding the per-test limit otherwise.

Package validation on 2026-10-04: `NibDesignTests FeatAISettingsTests FeatOnboardingTests`
passed through `nib-build.sh targets` in the integration worktree (230 tests), and
against an isolated HEAD snapshot with this job's package changes (216 tests).
Both runs include the hosted palette dock regression and ordinary-motion check.
The subsequent `NibDesignTests FeatDocChromeTests` checks also passed in integration
(251 tests) and in the isolated snapshot (232 tests), including the assistant
keyboard geometry and collapsed-popover lifecycle regressions.
After later shared popover and navigation changes, the isolated design/chrome
checks were repeated: 232 tests passed. The popover's keyboard viewport and UIKit
reader remain private to its file so the listed files do not require another
job's uncommitted helper file.
The final app build was repeated after the latest shared modal/popover edits and
passed against HEAD `1ce4872` plus this job's listed files. `CaptureUITests.swift`
also passed Swift type checking with HEAD's complete test-support sources and
Objective-C bridging header. No simulator UI tests ran locally.

Both final CI snapshots failed before running tests: the shared app shell had
acquired a reference to another job's uncommitted `HardwareKeyModifiers` type.
Physical modifier tracking is now private to the shell, preserving the same chord
and focus-reset behavior without that dependency. A complete app build from HEAD
plus this job's 15 listed files passed afterward. This correction has no subsequent
CI validation because all eight permitted runs were already submitted.

Final whole-class results: [iPad run 7](https://github.com/GOODMAN-PRO/nib/actions/runs/37152370356)
and [iPhone run 8](https://github.com/GOODMAN-PRO/nib/actions/runs/37152388223) each
reported 0 tests, 0 passed, 0 failed, with xcodebuild exit 65. Both stopped at
`ShellViewController.swift:24:36`, before the test runner launched. Therefore there
are **no final-run captures** in either `/Users/Nice/Projects/Nib-design/tour-1/ipad`
or `/Users/Nice/Projects/Nib-design/tour-1/iphone`. Earlier images are not substituted.
The inventory below describes the implemented tour, not verified final coverage.

The preceding whole-class runs executed 63 tests per device: iPad run 5 passed 35
and failed 28; iPhone run 6 passed 1 and failed 62. The iPhone failures stayed on
the compact Library sidebar or failed to open Settings; onboarding alone passed
all four variants. The final harness adds the missing Documents and real Settings
navigation, but the final compile failure prevented verification of those routes.

GitHub returned HTTP 503/504 errors during result retrieval. The iPad's small result
artifact was recovered with a download retry; no result bundle was needed.
The shared screenshot exporter keeps at most six failure-associated images (or the
last two) for a failing test, which can omit earlier kept tour captures. Recovering
every capture from a future partially failing tour will require its full result
bundle. The workflow and `tools/qa` were not changed.

The app also lacks DESIGN §14.16's global command bar; the existing document ⌘K
shortcut opens the link editor. That command-bar screen remains uncaptured and
unimplemented in this pass. Complete screen coverage and green runs remain outstanding.

## Screen inventory

| Order | Attachment screen | Test method |
| --- | --- | --- |
| 001 | `onboarding-library` | `test44FirstRun` |
| 002 | `onboarding-storage-confirmation` | `test44FirstRun` |
| 003 | `onboarding-pencil` | `test44FirstRun` |
| 004 | `onboarding-ai` | `test44FirstRun` |
| 005 | `onboarding-ready` | `test44FirstRun` |
| 006 | `library-sidebar` | `test01Library` |
| 007 | `library-grid` | `test01Library` |
| 008 | `library-list` | `test01Library` |
| 009 | `open-folder` | `test01Library` |
| 010 | `library-sort-view-menu` | `test01Library` |
| 011 | `library-document-context-menu` | `test25LibraryContextMenu` |
| 012 | `library-search` | `test02LibrarySearch` |
| 013 | `library-search-empty` | `test02LibrarySearch` |
| 014 | `new-folder` | `test23EmptyFolder` |
| 015 | `empty-folder` | `test23EmptyFolder` |
| 016 | `library-favourites` | `test47LibraryCollections` |
| 017 | `library-shared` | `test47LibraryCollections` |
| 018 | `library-recents` | `test47LibraryCollections` |
| 019 | `library-study-sets` | `test47LibraryCollections` |
| 020 | `library-gallery` | `test47LibraryCollections` |
| 021 | `library-trash-empty` | `test47LibraryCollections` |
| 022 | `library-calendar` | `test47LibraryCollections` |
| 023 | `new-menu` | `test03Creation` |
| 024 | `new-notebook` | `test03Creation` |
| 025 | `new-notebook-covers` | `test26CreationCoversAndPaper` |
| 026 | `paper-template-library` | `test26CreationCoversAndPaper` |
| 027 | `new-whiteboard` | `test27CreateWhiteboard` |
| 028 | `new-text-document` | `test28CreateTextDocument` |
| 029 | `new-study-set` | `test29CreateStudySet` |
| 030 | `canvas-palette-left` | `test04CanvasPalette` / `test04CanvasPaletteDark` |
| 031 | `canvas-palette-top` | `test04CanvasPalette` / `test04CanvasPaletteDark` |
| 032 | `canvas-palette-bottom` | `test04CanvasPalette` / `test04CanvasPaletteDark` |
| 033 | `options-bar` | `test04CanvasPalette` / `test04CanvasPaletteDark` |
| 034 | `more-tools` | `test45AdditionalToolOptions` |
| 035 | `pen-options` | `test05PenOptions` |
| 036 | `pencil-options` | `test45AdditionalToolOptions` |
| 037 | `highlighter-options` | `test06HighlighterOptions` |
| 038 | `eraser-options` | `test07EraserOptions` |
| 039 | `lasso-options` | `test08LassoOptions` |
| 040 | `shapes-options` | `test09ShapesOptions` |
| 041 | `text-options` | `test10TextOptions` |
| 042 | `tape-options` | `test45AdditionalToolOptions` |
| 043 | `sticky-note-options` | `test30StickyNote` |
| 044 | `sticky-note-editor` | `test30StickyNote` |
| 045 | `image-source-picker` | `test31ImageInsertion` |
| 046 | `elements-library` | `test46Elements` |
| 047 | `laser-options` | `test45AdditionalToolOptions` |
| 048 | `ruler` | `test32Ruler` |
| 049 | `ruler-menu` | `test32Ruler` |
| 050 | `lasso-object-menu` | `test11LassoSelection` |
| 051 | `three-document-tabs` | `test22ThreeDocumentTabs` |
| 052 | `zoom-window` | `test33ZoomWindowAndScales` |
| 053 | `canvas-zoomed-in` | `test33ZoomWindowAndScales` |
| 054 | `canvas-zoomed-out` | `test33ZoomWindowAndScales` |
| 055 | `page-sidebar` | `test12PageSidebarAndOutline` |
| 056 | `outline` | `test12PageSidebarAndOutline` |
| 057 | `bookmarks-empty` | `test12PageSidebarAndOutline` |
| 058 | `page-context-menu` | `test34PageMenu` / `test34PageMenuDark` |
| 059 | `go-to-page` | `test35GoToPage` |
| 060 | `clear-page-confirmation` | `test36ClearPageConfirmation` |
| 061 | `document-search-matches` | `test13DocumentSearch` |
| 062 | `document-search-empty` | `test13DocumentSearch` |
| 063 | `document-title-menu` | `test48DocumentMenus` |
| 064 | `document-more-menu` | `test48DocumentMenus` |
| 065 | `ai-assistant` | `test14Assistant` |
| 066 | `ai-assistant-answer` | `test37AssistantAnswer` |
| 067 | `export-sheet` | `test17Export` |
| 068 | `export-images` | `test17Export` |
| 069 | `print-options` | `test17Export` |
| 070 | `presentation-disconnected-share-menu` | `test21Presentation` |
| 070 | `presentation-mode` | `test21Presentation` |
| 071 | `collaboration-share-live` | `test49ShareLive` |
| 072 | `page-render-error` | `test24RenderError` |
| 073 | `audio-empty` | `test53AudioAndTranscriptEmpty` |
| 074 | `audio-recording` | `test54AudioRecordingAndPlayback` |
| 075 | `audio-recording-paused` | `test54AudioRecordingAndPlayback` |
| 076 | `audio-recordings` | `test54AudioRecordingAndPlayback` |
| 077 | `audio-playback` | `test54AudioRecordingAndPlayback` |
| 078 | `transcript-empty` | `test53AudioAndTranscriptEmpty` |
| 079 | `whiteboard` | `test18Whiteboard` |
| 080 | `whiteboard-templates` | `test50WhiteboardTemplates` |
| 081 | `text-document` | `test19TextDocument` |
| 082 | `text-document-slash-menu` | `test55TextDocumentBlockMenus` |
| 083 | `text-document-turn-into` | `test55TextDocumentBlockMenus` |
| 084 | `study-set-editor` | `test20StudySession` |
| 085 | `study-session-front` | `test20StudySession` |
| 086 | `study-session-back` | `test20StudySession` |
| 087 | `study-session-summary` | `test20StudySession` |
| 088 | `study-options` | `test51StudyOptionsAndSmartLearn` |
| 089 | `study-smart-learn` | `test52SmartLearn` |
| 090 | `settings-general` | `test16Settings` |
| 091 | `settings-profile` | `test38SettingsGeneralPages` |
| 092 | `settings-appearance` | `test38SettingsGeneralPages` |
| 093 | `settings-password` | `test38SettingsGeneralPages` |
| 094 | `settings-accessibility` | `test38SettingsGeneralPagesPart2` |
| 095 | `settings-language` | `test38SettingsGeneralPagesPart2` |
| 096 | `settings-recording` | `test38SettingsGeneralPagesPart2` |
| 097 | `settings-keyboard` | `test38SettingsGeneralPagesPart3` |
| 098 | `settings-calendar` | `test38SettingsGeneralPagesPart3` |
| 099 | `settings-collaboration` | `test38SettingsGeneralPagesPart3` |
| 100 | `settings-notifications` | `test38SettingsGeneralPagesPart4` |
| 101 | `settings-editing` | `test16Settings` |
| 102 | `settings-tabs` | `test39SettingsEditingPages` |
| 103 | `settings-toolbar` | `test39SettingsEditingPages` |
| 104 | `settings-undo` | `test39SettingsEditingPages` |
| 105 | `settings-snapping` | `test39SettingsEditingPagesPart2` |
| 106 | `settings-elements` | `test39SettingsEditingPagesPart2` |
| 107 | `settings-layers` | `test39SettingsEditingPagesPart2` |
| 108 | `settings-apple-pencil` | `test40SettingsWritingPages` |
| 109 | `settings-stylus` | `test16Settings` |
| 110 | `settings-smart-ink` | `test40SettingsWritingPages` |
| 111 | `settings-recognition` | `test40SettingsWritingPages` |
| 112 | `settings-shape-recognition` | `test40SettingsWritingPagesPart2` |
| 113 | `settings-writing-aids` | `test40SettingsWritingPagesPart2` |
| 114 | `settings-ai` | `test41SettingsAIPages` |
| 115 | `settings-claude-subscription` | `test41SettingsAIPages` |
| 116 | `settings-chatgpt-subscription` | `test41SettingsAIPages` |
| 117 | `settings-other-provider` | `test41SettingsAIPagesPart2` |
| 118 | `settings-meeting-ai` | `test41SettingsAIPagesPart2` |
| 119 | `settings-backup` | `test42SettingsSyncPages` |
| 120 | `settings-webdav` | `test42SettingsSyncPages` |
| 121 | `settings-relay` | `test42SettingsSyncPages` |
| 122 | `settings-repair` | `test42SettingsSyncPagesPart2` |
| 123 | `plugin-manager` | `test15PluginManager` |
| 124 | `settings-bridge` | `test42SettingsSyncPagesPart2` |
| 125 | `settings-troubleshooting` | `test43SettingsAboutPages` |
| 126 | `settings-developer` | `test43SettingsAboutPages` |
| 127 | `settings-about` | `test43SettingsAboutPages` |
| 128 | `settings-privacy` | `test43SettingsAboutPagesPart2` |
| 129 | `settings-parity` | `test43SettingsAboutPagesPart2` |

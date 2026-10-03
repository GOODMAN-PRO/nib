# Capture tour

`NibUITests/CaptureUITests.swift` reaches these screens through the app's normal controls.
Each test launches an isolated fixture for light/dark appearance and portrait/landscape.
Every kept image is named `<NNN>-<screen>-<appearance>-<orientation>`; numbering follows
onboarding, library, creation, editing, sharing, audio, document types, and settings.

The main application window must actually reach the requested orientation. No image
is relabelled to stand in for a failed orientation. Diagnostic and unreachable
attachments remain separate from review images, and every failed route fails its test.

## Device-dependent screens

- iPhone offers top and bottom palette docks. The left dock is iPad-only (DESIGN §10.11).
- Without an external display, the presentation capture shows the Share menu with
  presentation controls absent. With a display, it shows the actual presenter UI
  (DESIGN §14.12; F063). These alternatives share tour position 068.
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
- Compact routes use the real More menu and scrollable settings index. Study
  cards are flipped before grading, and creation forms use the shared type picker
  when a direct New-menu shortcut creates a document immediately.
- First-run and model-response fixtures are explicit launch options. Regular
  launches keep their normal onboarding and configured-provider behavior.
- AI onboarding and settings lead with the user's Claude or ChatGPT subscription
  through Nib Agent; API-key providers remain a secondary option.

## Screen inventory

| Order | Attachment screen | Test method |
| --- | --- | --- |
| 001 | `onboarding-library` | `test44FirstRun` |
| 002 | `onboarding-storage-confirmation` | `test44FirstRun` |
| 003 | `onboarding-pencil` | `test44FirstRun` |
| 004 | `onboarding-ai` | `test44FirstRun` |
| 005 | `onboarding-ready` | `test44FirstRun` |
| 006 | `library-grid` | `test01Library` |
| 007 | `library-list` | `test01Library` |
| 008 | `open-folder` | `test01Library` |
| 009 | `library-sort-view-menu` | `test01Library` |
| 010 | `library-document-context-menu` | `test25LibraryContextMenu` |
| 011 | `library-search` | `test02LibrarySearch` |
| 012 | `library-search-empty` | `test02LibrarySearch` |
| 013 | `new-folder` | `test23EmptyFolder` |
| 014 | `empty-folder` | `test23EmptyFolder` |
| 015 | `library-favourites` | `test47LibraryCollections` |
| 016 | `library-shared` | `test47LibraryCollections` |
| 017 | `library-recents` | `test47LibraryCollections` |
| 018 | `library-study-sets` | `test47LibraryCollections` |
| 019 | `library-gallery` | `test47LibraryCollections` |
| 020 | `library-trash-empty` | `test47LibraryCollections` |
| 021 | `new-menu` | `test03Creation` |
| 022 | `new-notebook` | `test03Creation` |
| 023 | `new-notebook-covers` | `test26CreationCoversAndPaper` |
| 024 | `paper-template-library` | `test26CreationCoversAndPaper` |
| 025 | `new-whiteboard` | `test27CreateWhiteboard` |
| 026 | `new-text-document` | `test28CreateTextDocument` |
| 027 | `new-study-set` | `test29CreateStudySet` |
| 028 | `canvas-palette-left` | `test04CanvasPalette` |
| 029 | `canvas-palette-top` | `test04CanvasPalette` |
| 030 | `canvas-palette-bottom` | `test04CanvasPalette` |
| 031 | `options-bar` | `test04CanvasPalette` |
| 032 | `more-tools` | `test45AdditionalToolOptions` |
| 033 | `pen-options` | `test05PenOptions` |
| 034 | `pencil-options` | `test45AdditionalToolOptions` |
| 035 | `highlighter-options` | `test06HighlighterOptions` |
| 036 | `eraser-options` | `test07EraserOptions` |
| 037 | `lasso-options` | `test08LassoOptions` |
| 038 | `shapes-options` | `test09ShapesOptions` |
| 039 | `text-options` | `test10TextOptions` |
| 040 | `tape-options` | `test45AdditionalToolOptions` |
| 041 | `sticky-note-options` | `test30StickyNote` |
| 042 | `sticky-note-editor` | `test30StickyNote` |
| 043 | `image-source-picker` | `test31ImageInsertion` |
| 044 | `elements-library` | `test46Elements` |
| 045 | `laser-options` | `test45AdditionalToolOptions` |
| 046 | `ruler` | `test32Ruler` |
| 047 | `ruler-menu` | `test32Ruler` |
| 048 | `lasso-object-menu` | `test11LassoSelection` |
| 049 | `three-document-tabs` | `test22ThreeDocumentTabs` |
| 050 | `zoom-window` | `test33ZoomWindowAndScales` |
| 051 | `canvas-zoomed-in` | `test33ZoomWindowAndScales` |
| 052 | `canvas-zoomed-out` | `test33ZoomWindowAndScales` |
| 053 | `page-sidebar` | `test12PageSidebarAndOutline` |
| 054 | `outline` | `test12PageSidebarAndOutline` |
| 055 | `bookmarks-empty` | `test12PageSidebarAndOutline` |
| 056 | `page-context-menu` | `test34PageMenu` |
| 057 | `go-to-page` | `test35GoToPage` |
| 058 | `clear-page-confirmation` | `test36ClearPageConfirmation` |
| 059 | `document-search-matches` | `test13DocumentSearch` |
| 060 | `document-search-empty` | `test13DocumentSearch` |
| 061 | `document-title-menu` | `test48DocumentMenus` |
| 062 | `document-more-menu` | `test48DocumentMenus` |
| 063 | `ai-assistant` | `test14Assistant` |
| 064 | `ai-assistant-answer` | `test37AssistantAnswer` |
| 065 | `export-sheet` | `test17Export` |
| 066 | `export-images` | `test17Export` |
| 067 | `print-options` | `test17Export` |
| 068 | `presentation-disconnected-share-menu` | `test21Presentation` |
| 068 | `presentation-mode` | `test21Presentation` |
| 069 | `collaboration-share-live` | `test49ShareLive` |
| 070 | `page-render-error` | `test24RenderError` |
| 071 | `audio-empty` | `test53AudioAndTranscriptEmpty` |
| 072 | `audio-recording` | `test54AudioRecordingAndPlayback` |
| 073 | `audio-recording-paused` | `test54AudioRecordingAndPlayback` |
| 074 | `audio-recordings` | `test54AudioRecordingAndPlayback` |
| 075 | `audio-playback` | `test54AudioRecordingAndPlayback` |
| 076 | `transcript-empty` | `test53AudioAndTranscriptEmpty` |
| 077 | `whiteboard` | `test18Whiteboard` |
| 078 | `whiteboard-templates` | `test50WhiteboardTemplates` |
| 079 | `text-document` | `test19TextDocument` |
| 080 | `text-document-slash-menu` | `test55TextDocumentBlockMenus` |
| 081 | `text-document-turn-into` | `test55TextDocumentBlockMenus` |
| 082 | `study-set-editor` | `test20StudySession` |
| 083 | `study-session-front` | `test20StudySession` |
| 084 | `study-session-back` | `test20StudySession` |
| 085 | `study-session-summary` | `test20StudySession` |
| 086 | `study-options` | `test51StudyOptionsAndSmartLearn` |
| 087 | `study-smart-learn` | `test52SmartLearn` |
| 088 | `settings-general` | `test16Settings` |
| 089 | `settings-profile` | `test38SettingsGeneralPages` |
| 090 | `settings-appearance` | `test38SettingsGeneralPages` |
| 091 | `settings-password` | `test38SettingsGeneralPages` |
| 092 | `settings-accessibility` | `test38SettingsGeneralPagesPart2` |
| 093 | `settings-language` | `test38SettingsGeneralPagesPart2` |
| 094 | `settings-recording` | `test38SettingsGeneralPagesPart2` |
| 095 | `settings-keyboard` | `test38SettingsGeneralPagesPart3` |
| 096 | `settings-calendar` | `test38SettingsGeneralPagesPart3` |
| 097 | `settings-collaboration` | `test38SettingsGeneralPagesPart3` |
| 098 | `settings-notifications` | `test38SettingsGeneralPagesPart4` |
| 099 | `settings-editing` | `test16Settings` |
| 100 | `settings-tabs` | `test39SettingsEditingPages` |
| 101 | `settings-toolbar` | `test39SettingsEditingPages` |
| 102 | `settings-undo` | `test39SettingsEditingPages` |
| 103 | `settings-snapping` | `test39SettingsEditingPagesPart2` |
| 104 | `settings-elements` | `test39SettingsEditingPagesPart2` |
| 105 | `settings-layers` | `test39SettingsEditingPagesPart2` |
| 106 | `settings-apple-pencil` | `test40SettingsWritingPages` |
| 107 | `settings-stylus` | `test16Settings` |
| 108 | `settings-smart-ink` | `test40SettingsWritingPages` |
| 109 | `settings-recognition` | `test40SettingsWritingPages` |
| 110 | `settings-shape-recognition` | `test40SettingsWritingPagesPart2` |
| 111 | `settings-writing-aids` | `test40SettingsWritingPagesPart2` |
| 112 | `settings-ai` | `test41SettingsAIPages` |
| 113 | `settings-claude-subscription` | `test41SettingsAIPages` |
| 114 | `settings-chatgpt-subscription` | `test41SettingsAIPages` |
| 115 | `settings-other-provider` | `test41SettingsAIPagesPart2` |
| 116 | `settings-meeting-ai` | `test41SettingsAIPagesPart2` |
| 117 | `settings-backup` | `test42SettingsSyncPages` |
| 118 | `settings-webdav` | `test42SettingsSyncPages` |
| 119 | `settings-relay` | `test42SettingsSyncPages` |
| 120 | `settings-repair` | `test42SettingsSyncPagesPart2` |
| 121 | `plugin-manager` | `test15PluginManager` |
| 122 | `settings-bridge` | `test42SettingsSyncPagesPart2` |
| 123 | `settings-troubleshooting` | `test43SettingsAboutPages` |
| 124 | `settings-developer` | `test43SettingsAboutPages` |
| 125 | `settings-about` | `test43SettingsAboutPages` |
| 126 | `settings-privacy` | `test43SettingsAboutPagesPart2` |
| 127 | `settings-parity` | `test43SettingsAboutPagesPart2` |

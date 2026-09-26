# Nib — Architecture

Nib is a native iPhone/iPad note-taking app with Goodnotes 6 parity, plus three things Goodnotes does not have:

1. **JavaScript plugins** that can read, add, edit and delete anything.
2. **Bring-your-own AI** (Anthropic, OpenAI or any OpenAI-compatible endpoint including Ollama, LM Studio and OpenRouter, or a custom HTTP endpoint). The AI works on the library and documents through tools.
3. **An in-app MCP/HTTP bridge** so an external agent, such as Claude Code on a PC over LAN or Tailscale, can drive the app with the same tools.

This document is the build contract for ~110 parallel agents (111 features). Companion documents:

| Document | Contents |
|---|---|
| `CONTRACTS.md` | The exact shared Swift source, build files and app shell. |
| `FEATURES.md` | The parity inventory. |
| `PLUGIN_API.md` | The plugin API. |
| `AI.md` | AI providers and the bridge. |
| `forge-spec.json` | The build decomposition. |

**Fixed decisions:**

- Swift 5 language mode, iOS 17.0 deployment target, universal app (iPad first).
- XcodeGen project, built and tested only on GitHub Actions `macos-26` (Xcode 26.6 pinned, iOS 26 SDK, because the locked UI uses Liquid Glass; every API newer than the iOS 17.0 deployment target sits behind `#available`). The output is an unsigned IPA for sideloading. Tests run only through `xcodebuild test` on the iOS simulator: `NibContracts` imports UIKit, PencilKit and SwiftUI, so `swift test` on macOS/Linux is not supported (ponytail: split a `NibContractsUI` target if fast macOS runs of pure logic ever matter).
- Core logic lives in the local package `NibKit`.
- PencilKit handles input only. The model stores platform-neutral strokes.
- One CommandBus for every mutation.
- Plugins run in JavaScriptCore.
- Sync works without paid Apple entitlements.
- Secrets live in the Keychain.
- The document format is a `.nibnote` package (`.nib` is the system Interface Builder type; decided before any document exists, so there is no migration).
- Third-party packages: **ZIPFoundation** (zip) and **SwiftMath** (LaTeX typesetting). Everything else is an Apple framework.

---

## 1. The one rule: everything is a command

```
  UI (SwiftUI/UIKit)   JS plugin    plugin HTML panel   in-app AI agent   MCP/HTTP bridge
        │ typed          │ JSON          │ JSON              │ JSON              │ JSON-RPC
        └───────┬────────┴───────────────┴───────────────────┴──────────────────┘
                ▼
     CommandBus.execute(Invocation)  ──  Gateway: exposure · scopes · locked docs · confirmation
                ▼
     CommandRegistry (built-in + feature + plugin commands; reads AND writes)
                ▼
     CommandContext.mutate { tx in … }   ← the ONLY way to obtain a DocTransaction
                ▼
     DocTransaction.put / delete  → Mutation(before, after)  → Changeset
                ├─► Workspace (in-memory documents)          → UI re-renders (commit observers)
                ├─► UndoHistory (per document, grouped)      → undo / redo / selective revert
                ├─► DocumentPersistence (per-device files)   → folder sync / WebDAV
                └─► EventBus (tx.committed …)                → plugins, bridge long-poll, collaboration
```

What guarantees this:

- `DocTransaction.init` and `CommandContext.init` are `internal` to `NibContracts`. No other module can write to documents except inside a command handler. The compiler enforces this, not a lint rule.
- Every toolbar item, menu item and key command descriptor points at a command id. There are no closure actions (`ToolbarItemDescriptor.command/toolID`, `MenuItemDescriptor.command`, `KeyCommandDescriptor.command`). A UI action therefore always has an equivalent that plugins, the AI and the bridge can call.
- Reads are commands too (`query.*`, `render.*`, `recognize.*`, `search.*`), so the registry *is* the complete API. `commands.list` and `commands.describe` expose it, with schemas and examples.
- Commands default to `Exposure.all`. Narrowing exposure, or adding `.security`, is reserved for secrets, grants, passwords and bridge control (§6.4). The complete list of what the AI, plugins and the bridge cannot do on their own is the "Exceptions to the modify-anything guarantee" table in FEATURES.md.
- CI runs `CommandConformance.check` over **all** features on every push. `NibApp.register` stamps each feature's commands with the feature id as `owner`, so the check covers every feature command: descriptor hygiene, no duplicate ids, every example of every `.edit` command with an undo round trip over all four fixture documents (or an unchanged undo stack for `undoable: false` commands), caller-chosen ids on creating commands, and declared settings.

---

## 2. Repository layout

```
G:\Projects\Nib\
├── project.yml                         XcodeGen (app, widget + share extensions, local package)
├── .github/workflows/ios.yml           CI: main/PRs: job test (xcodegen → lint → package tests) ∥ job ipa (archive → unsigned IPAs); feat/<FeatureID>: job feature (§19)
├── Nib/                                app target (thin): App/ shell, Intents/, Settings.bundle, Resources/
│   ├── App/AppDelegate.swift           composition root + scene delegates (CONTRACTS Part C)
│   ├── App/ShellViewController.swift   SceneNavigator, tabs model, key commands, fallbacks
│   ├── App/FeatureList.swift           generated list of every feature entry type
│   ├── Intents/NibAppIntents.swift     App Intents (F074; must live in the app target)
│   ├── Nib.entitlements                app group (used only for CI ad-hoc signing; progressive enhancement)
│   └── Resources/                      Assets.xcassets, Localizable.xcstrings, parity.json
├── NibWidgets/                         widget extension (F096)
├── NibShare/                           optional share extension (F064; App Group inbox or pasteboard hand-off)
├── NibKit/
│   ├── Package.swift                   generated from forge-spec (CONTRACTS Part B)
│   ├── Sources/NibContracts/           shared contracts (CONTRACTS Part A) — Model/, Core/, UI/
│   ├── Sources/NibTesting/             Harness, InMemoryLibrary, Fixtures, CommandConformance, service fakes
│   ├── Sources/NibDesign/              reserved design system (tokens, droplet/"liquid" components, Shaders/) — §3
│   ├── Sources/<Module>/               one module per feature: <Module>Feature.swift + files (split features add a second entry type)
│   └── Tests/<Module>Tests/            one test target per module (+ NibContractsTests, ConformanceTests, ExamplePluginsTests, IntegrationTests)
├── plugins/                            index.json (default gallery) + examples/ (F082)
├── Scripts/                            pick_sim.py, lint.py, restore_mtimes.py, make_icons.swift, extract_strings.py, a11y_lint.py, gen_parity.py
├── tools/relay/                        self-hosted collaboration relay (F092)
├── tools/smoke/                        bridge-driven on-device smoke scripts (runner F090, scripts F111)
└── docs/                               this documentation + forge-spec.json
```

---

## 3. Modules and targets

**Dependency rules:**

- A feature module imports only `NibContracts`, `NibDesign` (ui and fullstack modules only), Apple frameworks, and the packages declared for it in `Package.swift` (ZIPFoundation, SwiftMath). It never imports another feature module. `Scripts/lint.py` enforces this.
- A feature uses another feature's behaviour in exactly three ways:
  1. **Call a command by id.** Use `ctx.execute("shape.recognize", …)`, `app.perform(…)`, or `CommandIDs.*`.
  2. **Use a service protocol from `NibServices`.** Examples: `library`, `assets`, `renderer`, `recognizer`, `pdf`, `ai`, `lock`, and `get(ServiceKeys.…)`.
  3. **Use a registry.** Examples: drawers, templates, importers, menus, panels.
- Every feature exposes exactly one public type, `<EntryType>: NibFeature`, with a stable `id` (the "key" below); `NibApp.register` stamps it as the `owner` of every command the feature registers, and it is the `owner` of everything else the feature registers. A module normally holds one feature (`<Module>Feature`). **Split features** (F101–F110) add a second entry type in the same module: the second half may use the first half's internal types; the first half never references the second half and instead declares internal hooks (static closures/registries) that the second half fills in its `register`, so each half compiles on its own. Their `dependsOn` puts the second half after the first.
- `dependsOn` in the spec means "needs the other feature at runtime for its acceptance test on a device" and orders the build. Unit tests use NibTesting's fakes (`FakeRenderer`, `FakeRecognizer`, `FakeAIService`, `FakePDFService`, `FakeLockService`, `InMemorySecretStore`, `FakeCanvasHost`, `InMemoryCollabTransport`) or the Harness; cross-feature scenarios live in IntegrationTests (F111). The graph has no cycles: where two features use each other at runtime, the one that can be tested with a fake does not list the other (F077 ↔ F084, F006 ↔ F007, F072 ↔ F092, F078 ↔ F081).

| Feature | Module | Entry type / id | Layer | Priority | Complexity | Depends on |
|---|---|---|---|---|---|---|
| F001 Document package store (persistence + assets) | NibStore | `NibStoreFeature` / `store` | core | 1 | hard | — |
| F002 Library store (folders, documents, trash, prefs) | NibLibrary | `NibLibraryFeature` / `library` | core | 1 | hard | F001 |
| F003 Query, node & asset API | FeatQuery | `FeatQueryFeature` / `query` | core | 1 | medium | — |
| F004 Page renderer (tiles, ink compositing, thumbnails) | NibRender | `NibRenderFeature` / `render` | core | 1 | hard | — |
| F005 Templates: paper, covers, sizes, colours | NibTemplates | `NibTemplatesFeature` / `templates` | core | 1 | medium | — |
| F006 Canvas: scroll, zoom, page layout, tiles & whiteboard world | FeatCanvas | `FeatCanvasFeature` / `canvas` | ui | 1 | hard | F004 |
| F101 Canvas input: wet ink, touch pipeline, palm rejection & gesture routing | FeatCanvas | `FeatCanvasInputFeature` / `canvasinput` | ui | 1 | hard | F006 |
| F007 Pen & pencil tools, ink command, pen gestures | FeatPen | `FeatPenFeature` / `pen` | fullstack | 1 | hard | F006, F010, F011, F030, F031 |
| F008 Tool presets, colour picker & eyedropper | FeatPresets | `FeatPresetsFeature` / `presets` | ui | 1 | medium | — |
| F009 Highlighter tool | FeatHighlighter | `FeatHighlighterFeature` / `highlighter` | ui | 1 | simple | — |
| F010 Eraser, clear page, delete specific items | FeatEraser | `FeatEraserFeature` / `eraser` | fullstack | 1 | hard | — |
| F011 Lasso & selection | FeatLasso | `FeatLassoFeature` / `lasso` | fullstack | 1 | hard | — |
| F012 Selection transforms, guides & snapping | FeatTransform | `FeatTransformFeature` / `transform` | fullstack | 1 | hard | — |
| F013 Object menu & page long-press menu | FeatObjectMenu | `FeatObjectMenuFeature` / `objectmenu` | fullstack | 1 | medium | F004 |
| F014 Clipboard, duplicate & drag-and-drop | FeatClipboard | `FeatClipboardFeature` / `clipboard` | fullstack | 1 | medium | — |
| F015 Undo/redo UI, gestures & history panel | FeatUndoUI | `FeatUndoUIFeature` / `undo` | ui | 1 | simple | — |
| F016 Toolbar & tool switching | FeatToolbar | `FeatToolbarFeature` / `toolbar` | ui | 1 | hard | — |
| F017 Document chrome: nav bar, sidebar & panel hosts | FeatDocChrome | `FeatDocChromeFeature` / `chrome` | ui | 1 | hard | — |
| F018 Tabs, windows & session restore | FeatWindows | `FeatWindowsFeature` / `windows` | ui | 1 | medium | — |
| F019 Library browser | FeatLibraryUI | `FeatLibraryUIFeature` / `libraryui` | ui | 1 | hard | F002, F004 |
| F020 Folders, favourites & trash UI | FeatLibraryOrganize | `FeatLibraryOrganizeFeature` / `organize` | ui | 1 | medium | — |
| F021 Document creation & QuickNote | FeatCreate | `FeatCreateFeature` / `create` | ui | 1 | medium | F055 |
| F022 Page management | FeatPages | `FeatPagesFeature` / `pages` | fullstack | 1 | medium | — |
| F023 Page sidebar (thumbnails) | FeatSidebar | `FeatSidebarFeature` / `sidebar` | ui | 1 | medium | F004 |
| F024 PDF engine | NibPDF | `NibPDFFeature` / `pdf` | core | 1 | medium | — |
| F025 Folder sync engine & library location | NibSync | `NibSyncFeature` / `sync` | core | 1 | hard | F001, F002 |
| F026 Text boxes & rich text | FeatTextBox | `FeatTextBoxFeature` / `text` | fullstack | 1 | hard | — |
| F027 Settings screens | FeatSettings | `FeatSettingsFeature` / `settings` | ui | 1 | medium | — |
| F028 Full-page typing | FeatPageText | `FeatPageTextFeature` / `pagetext` | ui | 2 | medium | — |
| F029 Links | FeatLinks | `FeatLinksFeature` / `links` | fullstack | 2 | medium | — |
| F030 Shape recognition & Draw Shape tool | FeatShapeRecognition | `FeatShapeRecognitionFeature` / `shaperec` | fullstack | 2 | hard | — |
| F031 Shapes | FeatShapes | `FeatShapesFeature` / `shapes` | fullstack | 2 | hard | — |
| F032 Connectors & diagrams | FeatDiagrams | `FeatDiagramsFeature` / `diagrams` | fullstack | 2 | hard | — |
| F033 Tape | FeatTape | `FeatTapeFeature` / `tape` | fullstack | 2 | medium | — |
| F034 Images, camera, GIFs & Image Playground | FeatImages | `FeatImagesFeature` / `images` | fullstack | 2 | medium | — |
| F035 Elements (stickers) & GIF search | FeatElements | `FeatElementsFeature` / `elements` | fullstack | 2 | medium | — |
| F036 Sticky notes | FeatSticky | `FeatStickyFeature` / `sticky` | fullstack | 2 | medium | — |
| F037 Comments | FeatComments | `FeatCommentsFeature` / `comments` | fullstack | 2 | medium | — |
| F038 Zoom Window | FeatZoomWindow | `FeatZoomWindowFeature` / `zoomwindow` | ui | 2 | hard | — |
| F039 Ruler | FeatRuler | `FeatRulerFeature` / `ruler` | ui | 2 | medium | — |
| F040 Laser pointer | FeatLaser | `FeatLaserFeature` / `laser` | ui | 2 | simple | — |
| F041 Layers | FeatLayers | `FeatLayersFeature` / `layers` | fullstack | 2 | medium | — |
| F042 Read-only mode & PDF text actions | FeatReadOnly | `FeatReadOnlyFeature` / `readonly` | fullstack | 2 | medium | — |
| F043 Apple Pencil hardware (hover, double-tap, squeeze, haptics) | FeatPencilHardware | `FeatPencilHardwareFeature` / `pencilhw` | ui | 2 | medium | — |
| F044 Whiteboards | FeatWhiteboard | `FeatWhiteboardFeature` / `whiteboard` | fullstack | 2 | hard | — |
| F045 Template management & pickers | FeatTemplateUI | `FeatTemplateUIFeature` / `templateui` | ui | 2 | medium | F005, F066 |
| F046 Outline & bookmarks | FeatOutline | `FeatOutlineFeature` / `outline` | fullstack | 2 | medium | — |
| F047 Text documents: block model, commands & core editor | FeatTextDoc | `FeatTextDocFeature` / `textdoc` | fullstack | 2 | hard | — |
| F102 Text documents: slash menu, Turn Into, drag handles & inline formatting | FeatTextDoc | `FeatTextDocEditingFeature` / `textdocedit` | ui | 2 | medium | F047 |
| F103 Text documents: comments, outline & export | FeatTextDoc | `FeatTextDocExtrasFeature` / `textdocextras` | fullstack | 2 | medium | F047 |
| F048 Text document tables | FeatTextDocTables | `FeatTextDocTablesFeature` / `tables` | fullstack | 2 | hard | F047 |
| F049 Study sets: editor | FeatStudyEditor | `FeatStudyEditorFeature` / `studyeditor` | fullstack | 2 | medium | — |
| F050 Study sessions: Practice, Smart Learn, reminders | FeatStudySession | `FeatStudySessionFeature` / `studysession` | fullstack | 2 | medium | F049 |
| F051 Study set import & export | FeatStudyIO | `FeatStudyIOFeature` / `studyio` | core | 2 | medium | — |
| F052 Audio recording & playback | FeatAudio | `FeatAudioFeature` / `audio` | fullstack | 2 | hard | — |
| F053 Note replay | FeatReplay | `FeatReplayFeature` / `replay` | ui | 2 | medium | F052 |
| F054 Transcription & transcript panel | FeatTranscription | `FeatTranscriptionFeature` / `transcription` | fullstack | 2 | hard | F052, F084 |
| F055 Search index & handwriting recognition | NibIndex | `NibIndexFeature` / `index` | core | 2 | hard | — |
| F056 Search UI | FeatSearchUI | `FeatSearchUIFeature` / `searchui` | ui | 2 | medium | F055 |
| F057 Convert handwriting to text & recognition language | FeatConvertText | `FeatConvertTextFeature` / `convert` | fullstack | 2 | medium | F055 |
| F058 Smart Ink: edit handwriting | FeatSmartInk | `FeatSmartInkFeature` / `smartink` | fullstack | 2 | hard | — |
| F059 Ink synthesis & typesetter | FeatInkSynth | `FeatInkSynthFeature` / `inksynth` | fullstack | 2 | hard | — |
| F104 Handwriting spellcheck & personal dictionary | FeatInkSynth | `FeatSpellcheckFeature` / `spellcheck` | fullstack | 2 | medium | F059, F055 |
| F105 Handwriting restyle & Writing Aids settings | FeatInkSynth | `FeatRestyleFeature` / `restyle` | fullstack | 2 | medium | F059, F058, F104 |
| F060 Math items, conversion & typesetting | FeatMath | `FeatMathFeature` / `math` | fullstack | 2 | hard | F084 |
| F061 Math engine (on-device evaluator) | FeatMathAssist | `FeatMathAssistFeature` / `mathassist` | fullstack | 2 | hard | — |
| F106 Math Assist overlay | FeatMathAssist | `FeatMathAssistOverlayFeature` / `mathassistoverlay` | fullstack | 2 | medium | F061, F060, F059 |
| F107 Math graphs | FeatMathAssist | `FeatMathGraphFeature` / `mathgraph` | fullstack | 2 | medium | F061 |
| F062 Time Keeper | FeatTimeKeeper | `FeatTimeKeeperFeature` / `timekeeper` | ui | 2 | medium | — |
| F063 Presentation mode | FeatPresentation | `FeatPresentationFeature` / `presentation` | ui | 2 | medium | — |
| F064 Import | FeatImport | `FeatImportFeature` / `import` | fullstack | 2 | medium | — |
| F065 Scan documents & QR | FeatScan | `FeatScanFeature` / `scan` | fullstack | 2 | simple | — |
| F066 Export engine (PDF, images, packages) | NibExport | `NibExportFeature` / `export` | core | 2 | hard | F055 |
| F067 Export UI, share, print & save-back | FeatExportUI | `FeatExportUIFeature` / `exportui` | ui | 2 | medium | F066 |
| F068 Backup (manual & automatic) | FeatBackup | `FeatBackupFeature` / `backup` | fullstack | 2 | medium | F066, F069 |
| F069 WebDAV sync | FeatWebDAV | `FeatWebDAVFeature` / `webdav` | core | 2 | medium | — |
| F070 Sync status & repair UI | FeatSyncUI | `FeatSyncUIFeature` / `syncui` | ui | 2 | medium | F025 |
| F071 Password lock | FeatLock | `FeatLockFeature` / `lock` | fullstack | 2 | medium | — |
| F072 Collaboration: transport, session, sync & approval | FeatCollab | `FeatCollabFeature` / `collab` | fullstack | 2 | hard | — |
| F108 Collaboration: presence, follow, unseen changes & Shared tab | FeatCollab | `FeatCollabPresenceFeature` / `collabpresence` | ui | 2 | medium | F072 |
| F073 Keyboard shortcuts & pointer | FeatKeyboard | `FeatKeyboardFeature` / `keyboard` | ui | 2 | medium | — |
| F074 System integration: App Intents, quick actions, deep links | FeatSystemIntegration | `FeatSystemIntegrationFeature` / `system` | fullstack | 2 | medium | — |
| F075 Calendar (EventKit) & event notes | FeatCalendar | `FeatCalendarFeature` / `calendar` | fullstack | 2 | medium | — |
| F076 Diagnostics, troubleshooting & safe mode | FeatDiagnostics | `FeatDiagnosticsFeature` / `diagnostics` | ui | 2 | simple | — |
| F077 Plugin runtime (JavaScriptCore) | NibPluginRuntime | `NibPluginRuntimeFeature` / `pluginruntime` | core | 3 | hard | — |
| F078 Plugin host & contribution mapping | NibPluginHost | `NibPluginHostFeature` / `pluginhost` | core | 3 | hard | F077, F081 |
| F079 Plugin install & trust | FeatPluginInstall | `FeatPluginInstallFeature` / `plugininstall` | fullstack | 3 | medium | F078 |
| F080 Plugin manager, gallery & developer console | FeatPluginManager | `FeatPluginManagerFeature` / `pluginmanager` | ui | 3 | medium | F079 |
| F081 Plugin HTML panels | FeatPluginPanels | `FeatPluginPanelsFeature` / `pluginpanels` | ui | 3 | medium | — |
| F082 Example plugins & plugin test fixtures | ExamplePlugins | — (no Swift module) | core | 3 | medium | F078, F079 |
| F083 AI providers (bring your own model) | NibAIProviders | `NibAIProvidersFeature` / `aiproviders` | core | 3 | hard | — |
| F084 AI agent, tool catalogue & AIService | NibAIAgent | `NibAIAgentFeature` / `aiagent` | core | 3 | hard | F083, F078 |
| F085 AI chat panel | FeatAIChat | `FeatAIChatFeature` / `aichat` | ui | 3 | hard | F084 |
| F086 AI provider settings | FeatAISettings | `FeatAISettingsFeature` / `aisettings` | ui | 3 | medium | F083 |
| F087 AI actions (summaries, quiz, translate, diagrams, outline, titles) | FeatAIActions | `FeatAIActionsFeature` / `aiactions` | core | 3 | medium | F084 |
| F088 AI math: Solve & Teach Me | FeatAIMath | `FeatAIMathFeature` / `aimath` | fullstack | 3 | medium | F084 |
| F089 Meeting AI: live summary, notes, cloud transcription | FeatMeetingAI | `FeatMeetingAIFeature` / `meetingai` | fullstack | 3 | medium | F054, F084 |
| F090 MCP / HTTP bridge server | NibBridge | `NibBridgeFeature` / `bridge` | core | 1 | hard | — |
| F091 Bridge settings & pairing | FeatBridgeUI | `FeatBridgeUIFeature` / `bridgeui` | ui | 1 | simple | F090 |
| F092 Collaboration relay transport | FeatRelay | `FeatRelayFeature` / `relay` | core | 3 | medium | F072 |
| F093 Onboarding | FeatOnboarding | `FeatOnboardingFeature` / `onboarding` | ui | 4 | simple | — |
| F094 Appearance & app icons | FeatAppearance | `FeatAppearanceFeature` / `appearance` | ui | 4 | simple | — |
| F095 Localisation & accessibility | FeatA11y | `FeatA11yFeature` / `a11y` | ui | 4 | medium | — |
| F096 Widgets & Control Center | NibWidgets | — (no Swift module) | ui | 4 | simple | — |
| F097 Managed app configuration (MDM) | FeatManagedConfig | `FeatManagedConfigFeature` / `managed` | core | 4 | simple | — |
| F098 About, parity notes, privacy & data deletion | FeatAbout | `FeatAboutFeature` / `about` | ui | 4 | simple | — |
| F099 Teacher toolkit: answer zones & scoring | FeatTeacher | `FeatTeacherFeature` / `teacher` | fullstack | 4 | medium | — |
| F109 Teacher toolkit: lessons, assignments & roster | FeatTeacher | `FeatTeacherLessonsFeature` / `teacherlessons` | fullstack | 4 | medium | F099, F072, F108 |
| F110 Teacher toolkit: smart views, clusters & class navigator | FeatTeacher | `FeatTeacherInsightsFeature` / `teacherinsights` | fullstack | 4 | medium | F099, F109, F084 |
| F100 Performance, memory & metrics | FeatPerformance | `FeatPerformanceFeature` / `performance` | core | 4 | medium | F004 |
| F111 Integration tests & device smoke scripts | IntegrationTests | — (test target) | core | 4 | medium | F002, F004, F006, F101, F007, F015, F045, F055, F065, F066, F070, F078, F079, F084, F090 |

**Design system: `NibDesign` (reserved).** `NibKit/Sources/NibDesign` is a library module that is not a feature: no entry type, no commands, no forge-spec owner. Every module with a `ui` or `fullstack` feature depends on it (`Package.swift` puts `design` in that module's `deps`); core modules do not, and the app target gets it through the `NibKit` product. It holds the locked design system, [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md) implementing [DESIGN.md](DESIGN.md): tokens, droplet/"liquid" components, `Shaders/NibLiquid.metal` (compiled into the module bundle, loaded with `ShaderLibrary.bundle(.module)`), a string catalog, and the `DesignGallery` debug screen (Settings › Advanced › Developer, registered by the app shell). Its tests are `NibDesignTests` (physics and token contrast). Feature UI imports `NibDesign` for its styling and does not roll its own (§22). It is architect-owned like `NibContracts`: feature agents never edit it, and missing pieces go through §16. It never imports a feature module. Every iOS 26 API it uses (Liquid Glass) sits behind `#available(iOS 26, *)` with an iOS 17 fallback. `Scripts/lint.py` allows `import NibDesign` next to `NibContracts`.

**Registration.** `AppDelegate` creates `NibApp`, then registers `FeatureList.all` in the order shown above, so services come first (a split feature's second half registers right after its first half). Features whose ids are in `SafeMode.disabledFeatures` are skipped. Then, still inside `didFinishLaunching`, it registers every BGTaskScheduler identifier (§15.13). After that it `await`s `start(_:)` on each feature.

Rules for `register(_ app:)`:

- It must be fast.
- It only fills registries and services, and declares its settings (`app.settings.declare`).
- It never resolves services, never touches documents, and never calls `BGTaskScheduler`, `UNUserNotificationCenter` or permission APIs.

`start(_:)` does the rest: starting watchers, loading plugins and restoring state.

---

## 4. Library and document format

### 4.1 Library folder

The library is a folder the user chooses: on the device, iCloud Drive, OneDrive, Dropbox, Google Drive, or any Files provider. It is stored as a bookmark (`bookmarkData(options: [])` on iOS; `.withSecurityScope` does not exist there). Onboarding (F093) asks for a folder **outside the app container** (an "On My iPad" root folder or a cloud folder): sideloaded builds are often reinstalled with another signer or bundle id, which deletes the container. Keeping the library in the app's Documents folder ("On My iPad › Nib", visible because `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` are set) is a warned opt-out, and F070 shows a persistent banner while it is the case. A missing or stale bookmark prompts a re-pick; the folder is recognised by its `.nib-library` marker (F025). Nothing requires CloudKit.

```
<Library>/
├── .nib-library/
│   ├── prefs.<dev>.json            synced settings (SettingKey.synced), merged per key by rev; collections are one key per entry
│   ├── trash/                      trashed packages/folders (meta.trashedFrom remembers the origin)
│   ├── plugins/<pluginId>/         installed plugin packages ONLY (hashed; grants stay device-local in Application Support)
│   ├── plugin-data/<pluginId>/     nib.storage: storage.<dev>.json, merged per key by rev (outside the hash)
│   ├── elements/<collection>/      element fragments + index.<dev>.json (merged by id and rev)
│   ├── templates/<group>/          custom templates (PDF / image) + group.<dev>.json
│   ├── tape/                       custom tape patterns (<id>.png) + history.<dev>.json
│   └── ai/                         AI chats: <chat>.<dev>.jsonl (merged by message id)
├── Physics/                        folders are directories
│   ├── .nibfolder.<dev>.json       {id, rev, color, icon, favorite}, one file per device, merged by rev
│   └── Kinematics.nibnote/         a document package (UTType app.nib.document, conforms to com.apple.package)
```

The document title is the package filename; there is no title field, so there is only one source of truth. Renaming or moving a document is a coordinated file-system operation.

### 4.2 Document package

```
Kinematics.nibnote/
├── doc.<dev>.json                   DocumentContent (meta, pages, outline, blocks, cards, audio) — plain JSON
├── pages/<pageId>/<dev>.nibpage     LZFSE-compressed JSON [Item] (tombstones included), points in compact form
├── assets/<sha256>.<ext>            PDFs, images, GIFs, tape patterns — immutable, deduplicated
└── audio/<clipId>.caf               AAC in CAF (crash-safe) + <clipId>.transcript.<dev>.json (merged per line by rev)
```

- `<dev>` is `DeviceIdentity.hex`: 8 hex characters from a random `UInt32`, kept in Application Support (`Nib/device-id`, which wins) and mirrored to the Keychain, so a re-signed build keeps its id and its files.
- **Stroke points** are encoded as base64 of little-endian Float32 values, 10 per point (x, y, t, force, azimuth, altitude, roll, width, height, opacity), when `userInfo[.nibCompactPoints] == true`. Everywhere else (plugins, AI, bridge, clipboard) they are a flat number array `pts` with `fmt`. Decoding accepts `xy`, `xyt`, `xytf`, `xytfaa`, `xytfaar` and `full`.
- **Version gate.** `DocumentMeta.format` records `NibFormat.version`. A head whose major version is newer than the app opens read-only, with an "Update Nib" banner.
- **Extension.** `.nibnote` is defined in exactly one constant, `NibFormat.packageExtension` (plus `project.yml`). Folders named `*.nib` that contain `doc.*.json` are accepted as a legacy import (F002, F064).
- **Decoding is lenient.** Every persisted record and payload has an explicit `init(from:)` with decode defaults (only identity fields such as `kind`, `frame` or `asset` are required), so AI/plugin JSON may leave fields out and new fields can be added with defaults (§16).

### 4.3 Merge and sync rules

Each device writes only its own files and never touches another device's files, so two devices never write the same file. The only exception is deleting provider conflict copies after they have been merged. This applies to **every** store in the library, not only document packages: folder style files, prefs, element indexes, template groups, tape history, AI chats, plugin storage and transcripts are all `<name>.<dev>.<ext>` files merged by id/key and rev, and collection-valued settings are one key per entry ("calendar.notes.<eventId>", "writing.dictionary.<word>", "timer.history.<id>", "text.styles.<name>", "toolbar.layouts.<name>"). Each store has a two-device merge test in its feature.

**Merge rule.** Every persisted record (`Item`, `PageRecord`, `OutlineEntry`, `TextBlock`, `StudyCard`, `AudioClip`) is an `LWWRecord` (id, rev, deleted). `DocumentMeta` is a single last-writer-wins value. Readers load every `doc.*.json` and every `pages/<p>/*.nibpage`, then merge by id with the highest `Rev` winning (`LWW.merge`). `Rev` is a hybrid logical clock (wall ms, counter, device), encoded as a sortable string. A rev more than 24 h in the future (a device with a wrong clock) is distrusted: `Rev.effective` compares it as time 0, so it never beats correctly-clocked edits, and F025 reports it in `sync.status`.

**What each device writes.** A device writes the *full merged state* it knows into its own files. Stale files from other devices lose on rev and are harmless.

**Deletion.** Deletion is a tombstone. Page trash is `deleted && trashedAt != nil`; a purged page is `deleted && trashedAt == nil`. Item tombstones older than 30 days are dropped on write (ponytail: a device offline for more than 30 days can resurrect a deleted item; add per-device watermarks if that matters).

**Conflict copies.** Any file matching `^doc\.[0-9a-f]{8}.+\.json$` or `pages/<p>/[0-9a-f]{8}.+\.nibpage` other than the exact device names `doc.<8hex>.json` / `<8hex>.nibpage` (e.g. `doc.1a2b3c4d 2.json` or `doc.1a2b3c4d (conflicted copy).json`) is just another input. They are merged, then deleted.

**Live changes.** The Folder Sync engine (F025) watches with `NSFilePresenter` and a 30 s poll. It asks `DocumentPersistence.remoteChanges(doc)` for newer records and applies them with `CommandBus.applyRemote(patch, origin:)`. That path does no undo recording, does emit events, and does persist.

**WebDAV (F069)** mirrors the same folder three ways. It never has to merge file contents, because file sets are disjoint per device.

**Live collaboration (F072, F092)** broadcasts `Changeset.patch(for:)` and applies incoming patches with `applyRemote`. It uses the same last-writer-wins rules.

**Undo stays safe with remote changes.** Selective undo reverts a record only while it still carries the revision the undo entry wrote (`DocTransaction.revert`), so undo never overwrites a collaborator's or another device's later edit.

---

## 5. Data model (summary of `NibContracts/Model`)

- **Coordinates.** Page points (1/72 in), origin at the page's top-left, y down. Boards with `size == nil` are infinite world space. Transforms are baked into geometry: strokes and points store page coordinates, and `Frame` (x, y, w, h, rotation about the centre) is used for boxes.
- **IDs.** `NibID` holds 12 Crockford base32 characters. Callers may supply their own ids (`[A-Za-z0-9_-]{1,64}`) so they can link records inside one batch. `DocumentID`, `PageID`, `ElementID` and `FolderID` are aliases.
- **Refs.** `NodeRef` strings are `lib`, `folder:F`, `doc:D`, `page:D/P`, `item:D/P/I`, `block:D/B`, `card:D/C`, `audio:D/A` and `outline:D/O`. Every command parameter that points at something takes a ref string. `NodeRef.documentID(from:)` also accepts bare ids.
- **Items.** An `Item` has common fields (id, rev, deleted, kind, z, layer 0–4, locked, attachedTo, createdBy provenance, ext) plus exactly one payload: `stroke`, `shape`, `connector`, `text`, `image`, `sticky`, `math`, `comment` or `custom`. Tape is a stroke with `tool == .tape`. Plugins keep their data in `ext[<pluginId>]` or use `custom` items, which always render from their `DisplayList` and so survive the plugin's removal (custom item types register a `CustomItemTypeDescriptor` so search, recognition and the AI can read their text). Text documents have `BlockKind.custom` blocks (`CustomBlock`: owner, type, height, data, display) for the same purpose.
- **Z-order.** `z` is a `FractionalIndex` key, so there are no renumbering writes. Page, block, card and outline order use the same keys (`DocumentContent.orderKey`).
- **Colours.** `RGBA` is encoded as `"#RRGGBBAA"`. Rich text is `RichText` → `Paragraph` → `TextRun` with `TextAttributes`. JSON may also use a plain string. Links are `TextLink` values: URL, document/page, or audio clip/time.
- **Document kinds.** `notebook`, `whiteboard`, `textDocument` (blocks) and `studySet` (cards) all share one package format.
- **Session state** (per window, never persisted in documents) lives in `EditorSession`: document, page, tool, selection, zoom, visibleRect, readOnly, activeLayer, hiddenLayers, replay, isEditingText.

---

## 6. Commands

### 6.1 Writing a command

```swift
struct PageRotate: NibCommand {                         // conformers are @MainActor (protocol is @MainActor)
    struct Params: Codable { var pages: [String]; var degrees: Int? }
    static let descriptor = CommandDescriptor(
        id: "page.rotate", title: "Rotate Pages",
        summary: "Rotate pages 90° clockwise (or by degrees).",           // ONE line, ≤200 chars, for an LLM
        params: .obj(["pages": .arr(.ref), "degrees": .int(min: 90, max: 270)], required: ["pages"]),
        examples: [["pages": ["page:FIXTUREDOC01/FIXTUREPG001"]]],       // must validate; use Fixtures ids
        effect: .edit)                                                    // scopes derived: document:write
    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        try ctx.mutate { tx in                                           // synchronous, atomic, rolled back on throw
            for ref in p.pages {
                guard case let .page(doc, pid)? = NodeRef(ref) else { throw NibError.invalid("not a page ref", path: "$.pages") }
                guard var page = try tx.content(doc).page(pid) else { throw NibError.notFound("page \(pid)") }
                page.rotation = (page.rotation + (p.degrees ?? 90)) % 360
                try tx.put(page, doc: doc)
            }
        }
        return NoResult()
    }
}
// in register: app.commands.register(PageRotate.self)
```

**Conventions:**

- **Ids** are `namespace.verb` or `namespace.noun.verb` in lower camel case: `page.add`, `element.collection.create`. Plugin ids start with the plugin id. **Ownership is per command id**, exactly as listed in §6.5: a namespace may be shared (`doc.*` has several owners), but a feature registers exactly the ids listed for it — no more, no fewer (`Scripts/lint.py` warns on any difference; conformance fails on duplicates).
- **Effects:**

  | Effect | Meaning |
  |---|---|
  | `read` | Returns data. Nothing is recorded. |
  | `session` | Changes view or window state or device settings. Not undoable. |
  | `edit` | Changes documents through `mutate`. Undoable. |
  | `library` | Changes the file system or library: create, move, rename, trash, install. Recoverable through Trash; not on the undo stack. |
  | `irreversible` | Always confirmed for non-user callers. Examples: empty trash, purge, overwrite a source file, delete audio. |

  Mark `destructive: true` for anything that deletes or overwrites. Mark `userPresence: true` when system UI is shown (camera, picker, Face ID, print). Mark `sensitive: true` when data leaves the device or is captured (WebDAV/backup destinations, collaboration, relay, microphone, calendar, Photos, AI provider endpoints): non-user principals are then always confirmed. Mark `undoable: false` on `.edit` commands that persist through `ctx.mutate(undoable: false)` or through per-device side files (transcripts).
- **Params:**
  - Refs are strings.
  - Colours are `#RRGGBB[AA]`, points are `[x,y]` and rects are `[x,y,w,h]`, all in page points.
  - Optional fields are optional in `Params`, with defaults applied in `run`.
  - Everything a user can pick in the UI must be a parameter.
  - Flat schemas only: no `oneOf`, no `$ref`. For alternatives, use optional sibling fields.
  - Url-typed params (`url`, `urls`, `file`) resolve through `ctx.inputFile`: `tmp:<name>` refs from `asset.upload`/renders/exports, `https` URLs (downloaded), and `file://` only for the user principal or the app's tmp/Inbox. Results never hand out `file://` URLs; they return `tmp:` assets (plus base64 when asked).
  - `examples` literals: annotate nested literals (`let ex: JSONValue = […]`) or use `try! JSONValue.parse(#"…"#)` for anything longer than one line — large untyped JSONValue literals can hit "unable to type-check this expression in reasonable time" in CI.
  - **Additive params** (contracts-v2). A command may take optional params beyond its §6.5 row (`range`, `indentBy`, `payload`, `fragment`, `cursor`, `limit`). The id and the listed params keep their meaning, and omitting the extras gives the listed behaviour. The rows are generated from forge-spec.json; the spec owner adds extras there.
  - **Session defaults** (contracts-v2). Key commands, toolbar buttons and menus run with static params. So `doc`, `page` and `refs` may be omitted by the user principal where the command documents a session default. Resolve them with `ctx.documentOrSession(p.doc)`, `ctx.pageOrSession(p.page)` and `ctx.refsOrSelection(p.refs)`: the invoking window's document, current page or selection. Schemas still list the params, and AI, plugin and bridge callers pass them (`edit.undo {}` from a key command undoes the window's document).
  - **Places in a document** (contracts-v2). `doc` is a document ref `doc:D` (a bare id is accepted). `position` is `before | after | start | end` (`PagePosition`). `anchor` is a page ref `page:D/P`, required for `before`/`after`. `page.add`, `page.paste` and `import.files` all use this shape.
  - **Geometry** (contracts-v2). Every point, size, delta and radius is in **page points** (top-left origin), never view points. That includes `view.scrollBy {dx, dy}`, `item.transform` and `ink.erase {path: [[x,y],…], radius}`. Sizes are `[width, height]` (`template.choose {size}`, `page.add {size}`). A frame is `[x, y, w, h]` or `[x, y, w, h, rotation]`, with rotation in radians about the centre (`Frame(array:)` / `Frame.array`). Angles in params are degrees unless the name says radians. `ShapeItem.points` are control points (see `ShapeItem` in CONTRACTS.md).
  - **Other value types** (contracts-v2). A `template` param that has no sibling `params?` is `TemplateRef` JSON `{id, params?}` (`doc.create`, `page.add`), and a plain id string is accepted as `{id}`. `page.setTemplate` keeps its `template` id plus `params?`. Media time is in seconds as a number (`audio.play {clip: "audio:D/A", t}`). `panel.open` is `{id, params?}`: the other params reach the panel as `PanelContext.params`. `ai.ask` returns `AIResponse` JSON `{text, changes, group?, usage, chatID?}`.
- **Creating commands** (every `edit`/`library` command that creates records):
  - Default `layer` to `ctx.activeSession?.activeLayer ?? 0`.
  - Declare an optional caller-chosen `id` (one record) or `ids` (several, in creation order) param and honour it (`NibID.isValid`, else `invalid_params`). The AI links records in one batch this way (`page.add {id: "NEWPAGE00001"}` then `diagram.create {page: "page:D/NEWPAGE00001"}`); conformance checks both.
  - Return the created refs (`{"ref": "item:…"}` or `{"refs": [...]}`).
- **Result types** are named `Output` (the protocol's associated type), so `Swift.Result` stays usable; return `NoResult()` when there is nothing to return.
- **Undo groups.** Every call of one command, and every command it calls through `ctx.execute`, shares one group, so the user sees one undo step. UI gestures that span several commands (drag then drop) pass the same `group` to `bus.run`/`execute`. An AI turn and a plugin invocation are each one group.
- **State that must persist but must not be undoable** (tape reveal, Smart Learn grades, per-document view flags): use `ctx.mutate(undoable: false)` and declare `undoable: false`.
- **Read commands are read-only.** Inside a `read` command (unless it declares `forwardsCalls`, like `commands.batch` and `ai.ask`), `ctx.mutate` throws and nested calls must be `read`.
- **Slow work** (OCR, rendering, network, AI) happens before or between `mutate` calls, never inside them.
- **Results** are `Codable`. Big results (more than 20 KB) are paged with a `cursor` parameter plus `truncated: true`. The result carries the next `cursor`; callers pass it back unchanged. This applies to every read command and to the AI meta tool `nib_get`.
- **Batch writes** (contracts-v2). Importers and page-wide edits write through the batch overloads: `tx.put(items, doc:page:)`, `tx.delete(items:doc:page:)`, and `tx.put(pages|blocks|cards|entries|clips, doc:)`. Each call, and undoing, redoing or rolling it back, is linear in the records written. A per-record `tx.put` loop over a large set is quadratic.
- **Moving items keeps provenance.** Moving an item to another page uses `tx.move(item:doc:from:to:transform:z:)`; across documents, use `tx.put(_:doc:page:keepingProvenanceFrom:in:)`. A tombstone plus a fresh `put` would stamp the mover as `createdBy`.
- **Cross-document commands** that must undo as one step (`page.moveTo` between documents) call `ctx.linkUndoAcrossDocuments()` (§6.3).
- **App services.** Commands reach the app through `ctx.app`, `ctx.content` (templates, drawers, tape patterns, text layouts), `ctx.ui`, `ctx.navigator` and `ctx.isReadOnly(doc)`, never through `NibApp.shared` or untyped service keys that republish a registry.

### 6.2 Calling commands

| Caller | API | Principal | Checks |
|---|---|---|---|
| Native UI, typed | `try await app.bus.run(PageRotate.self, params, session:)` | `.user` | none |
| Native UI, by id | `app.perform("page.rotate", ["pages": …])` | `.user` | errors are shown as a toast |
| Nested (inside a command) | `try await ctx.execute("shape.recognize", …)` | caller's | full, same group |
| Plugins / AI / bridge | `bus.execute(Invocation(command:params:principal:group:dryRun:readOnly:))` | `.plugin(id)` / `.ai(chat)` / `.bridge(client)` | schema validation, exposure, scopes, locked documents, confirmation |

Every JSON and typed call also runs the registered **command hooks** (`app.bus.hooks`: read-only hook commands that may transform the params or veto). A nested call to a command that is not registered (a disabled feature, or a stub during fan-out) throws `unavailable`, not `not_found`, so callers can treat it as an optional dependency.

**Dry run.** `dryRun: true` runs the command, collects the `ChangeSummary`, then rolls back. Nothing is persisted, recorded or emitted. AI previews and `plugin.run` use it.

### 6.3 Undo

- `UndoHistory` is per document and keeps up to 200 entries. Consecutive changesets with the same group merge into one entry.
- `bus.undo` and `bus.redo` use `DocTransaction.revert`: they write back the stored before-values with fresh revisions, but only where the record still carries the reverted revision.
- **Rebasing** (contracts-v2). A revert pass records "the value that had revision r now lives at revision r′" for each record it rewrites. Older mutations of the same record, in the same entry or in later undo and redo entries, accept r′ as their expected revision. So a record written twice in one group (move then attach, debounced text commits) reverts all the way back. Consecutive undos on one record also work, and a redo chain stays valid. Records changed by anyone else since, including `mutate(undoable: false)` writes, are still skipped.
- **Linked undo** (contracts-v2). A command that changes several documents may call `ctx.linkUndoAcrossDocuments()`. Undoing (or redoing) that group in one of them then also undoes it in every other document where it is still the latest step. `UndoHistory.isLinked(group)` tells the UI.
- `bus.revert(group:doc:)` removes one entry from anywhere in the history and reverts it the same way ("Undo that AI turn" after later edits). The revert is itself recorded, so it can be undone.
- Page operations are commands, so page-level undo is automatic.
- Remote (sync) changes are never recorded.

### 6.4 Permissions

- **Scopes** are derived from effect and target: `document:read|write`, `library:read|write` and `app`, plus `destructive`. Extra scopes are `ai`, `network`, `plugins:manage` and `security`.
- **Principals:**

  | Principal | Scopes granted |
  |---|---|
  | user | all |
  | AI and bridge | everything except `security` |
  | plugins | what their manifest declared and the user consented to; never `plugins:manage` or `security` |

- **Confirmation** follows each principal's `ConfirmationPolicy` (`always` / `destructive` (default) / `never`). `irreversible`, `sensitive` and `plugins:manage` commands are *always* confirmed for non-user principals. A nested call carries the caller's policy (`Invocation.inheritedPolicy`) and the stricter of the two applies — so an AI-invoked plugin command cannot run destructive steps under the plugin's laxer policy.
- **Ask mode** ("Create mode" off) is `Invocation.readOnly`: the bus refuses any non-`read` command in the chain, including nested calls, `commands.batch` entries, `ai.ask {mode: edit}` and plugin handlers (their Invocations copy the context's `readOnly`).
- **Provenance cannot be forged.** `DocTransaction.put` stamps `createdBy` from the principal on create and keeps it on update for non-user principals; `node.set`/`item.update` reject `createdBy`, `rev`, `id`, `deleted`, `meta.format`, `meta.locked` and `meta.trashedFrom` from non-user principals (F003).
- **`security` commands and settings** are user-only. That covers password setup, bridge enable and token, confirmation policies and AI keys. A principal can never widen its own permissions. `settings.get` of `security.*` is also user-only.
- **Settings** are declared (`app.settings.declare` / `declarePrefix`) so untyped callers are routed to the right store and validated: `settings.set` rejects undeclared names (`not_found`, hint `settings.list`), values that fail the schema (`invalid_params`), and read-only `managed.*` names for every caller.
- **Locked documents** (`Gateway.isLocked`) are refused with the error code `locked` for non-user principals until the user unlocks them.

### 6.5 Command catalogue

All commands below exist at the end of the build. Each row gives the owning feature, so any feature can call any command by id. Effects: read / session / edit / library / irreversible (user presence = shows system UI; sensitive = always confirmed for non-user callers; not undoable = `undoable: false`). Params ending in `?` are optional; `id?`/`ids?` are caller-chosen ids for created records. The feature tables are generated from the "Commands owned" lists in forge-spec.json; `Scripts/lint.py` checks that every row has as many cells as its header.

### Contracts (always present, owner: NibContracts)

| Command | Effect | Params | Summary |
|---|---|---|---|
| `edit.undo` | edit | doc | Undo the last change in a document (the user may omit `doc`: the window's document; a linked group undoes in every document). |
| `edit.redo` | edit | doc | Redo. |
| `history.list` | read | doc, limit? | Undo entries with group ids and principals. |
| `history.revertGroup` | edit | doc, group | Selective revert of one undo group (e.g. an AI turn). |
| `commands.list` | read | namespace? | Commands visible to the caller. |
| `commands.describe` | read | id | Schema, examples, effect and scopes of a command. |
| `commands.batch` | read, forwards calls | calls[{command, params}], stopOnError? | Run several commands as one undo step (each call authorised; in ask mode every call must be read). |
| `tool.select` | session | tool, temporary? | Activate a canvas tool (`temporary: true` returns to the previous tool when the use ends). |
| `settings.get` | read | name | Read a setting ('security.*' user only). |
| `settings.set` | edit (app), not undoable | name, value | Change a declared setting; value validated ('security.*' user only, 'managed.*' read-only). |
| `settings.list` | read | prefix? | Declared settings with summary, synced flag and owner. |
| `settings.describe` | read | name | Schema, default and flags of one setting. |
| `window.showLibrary` | session | folder? | Show the library in the current window, optionally at a folder (contracts-v2). |

### `a11y.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `a11y.describePage` | read | page | F095 | Spoken summary of a page's items with recognised text. |

### `ai.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `ai.ask` | read, forwards calls | prompt, scope?, mode?, chat? | F084 | Run the user's AI on a prompt headlessly and return its answer (tool calls run as the caller). |
| `ai.chat.list` | read | doc? | F084 | AI conversations for a document or the library. |
| `ai.chat.rename` | session | chat, title | F084 | Rename an AI conversation. |
| `ai.chat.delete` | session, destructive | chat | F084 | Delete an AI conversation. |
| `ai.chat.feedback` | session | chat, message, rating | F084 | Rate an AI answer (thumbs up/down). |
| `ai.provider.list` | read |  | F086 | Configured AI providers (never their keys). |
| `ai.provider.save` | session, sensitive | id?, name, kind, baseURL, model, extraHeaders?, supportsVision?, supportsTools?, maxOutputTokens?, transcriptionModel?, imageModel? | F086 | Add or edit an AI provider (API keys are entered in Settings only). |
| `ai.provider.activate` | session, sensitive | id | F086 | Make an AI provider the active one. |
| `ai.provider.delete` | session, destructive | id | F086 | Delete an AI provider and its key. |
| `ai.provider.test` | read | id? | F086 | Send a tiny test request to a provider. |
| `ai.quiz` | edit | scope, count?, toStudySet?, id? | F087 | Generate quiz questions (in chat or as a study set). |

### `answerZone.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `answerZone.create` | edit | page, rect, points?, hints?, id? | F099 | Mark an answer zone with an optional score widget and teacher hints. |
| `answerZone.score` | edit | ref, score | F099 | Score an answer zone. |
| `answerZone.setHints` | edit | ref, hints | F099 | Set the teacher hints of an answer zone. |
| `answerZone.revealHint` | edit | ref | F099 | Reveal the next hint of an answer zone (usage is recorded). |

### `app.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `app.openURL` | session | url | F074 | Handle a nib:// link (open doc/page/audio time, quicknote, new, search, plugin install, bridge pairing). |
| `app.quickAction` | session | type | F074 | Handle a Home Screen quick action. |
| `app.deleteAllData` | irreversible (user presence) | includeLibrary? | F098 | Delete all Nib app data (caches, settings, keys, grants) and optionally the library folder. |

### `asset.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `asset.put` | edit | doc, base64? \| url?, ext | F003 | Store a binary asset in a document; returns an AssetRef. |
| `asset.get` | read | doc, asset | F003 | Temporary URL / base64 of an asset. |
| `asset.upload` | session | base64, ext | F003 | Store bytes as a temporary asset and return its tmp: ref for url-taking commands. |

### `audio.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `audio.record` | edit (user presence), sensitive | doc, page?, action | F052 | Start or stop recording in a document (mic). |
| `audio.play` | session | clip, t? | F052 | Play a clip from a time. |
| `audio.pause` | session |  | F052 | Pause playback. |
| `audio.seek` | session | t | F052 | Seek within the playing clip. |
| `audio.setPlayback` | session | speed?, skipSilence?, noiseReduction? | F052 | Playback speed (0.5–2×), skip silence, noise reduction. |
| `audio.rename` | edit | clip, name | F052 | Rename a clip. |
| `audio.delete` | irreversible | clip | F052 | Delete a clip and its audio file permanently. |
| `audio.export` | read | clip, format? | F052 | Export a clip as an audio file (temporary asset). |
| `audio.quickRecord` | library |  | F052 | New text document and start recording immediately. |

### `backup.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `backup.now` | session |  | F068 | Run automatic backup now. |
| `backup.manual` | session (user presence) |  | F068 | Back up the whole library to a .zip at a chosen location. |
| `backup.configure` | session, sensitive | destination, format, folder?, exclusions?, frequent? | F068 | Configure automatic backup (folder bookmark or WebDAV; nib / pdf / both). |
| `backup.chooseFolder` | session (user presence) |  | F068 | Pick the automatic-backup folder (document picker). |
| `backup.status` | read |  | F068 | Queue, last run, errors. |
| `backup.clearQueue` | session |  | F068 | Clear this device's backup queue. |

### `block.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `block.insert` | edit | doc, after?, kind, text?, asset?, url?, caption?, custom?, id? | F047 | Insert a block (paragraph, H1–H3, bullet, numbered, todo, quote, code, divider, table, image, video). |
| `block.update` | edit | ref, text?, kind?, checked?, indent?, caption?, asset?, url? | F047 | Update a block. |
| `block.delete` | edit | refs | F047 | Delete blocks. |
| `block.move` | edit | ref, after? | F047 | Reorder a block. |
| `block.comment` | edit | ref, range, text, id? | F103 | Comment on selected text. |
| `block.editComment` | edit | ref, comment, text | F103 | Edit a text-document comment. |
| `block.deleteComment` | edit | ref, comment | F103 | Delete a text-document comment. |
| `block.resolveComment` | edit | ref, comment, resolved | F103 | Resolve a text-document comment. |

### `board.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `board.add` | edit | doc, title?, template?, id? | F044 | Add a board to a whiteboard. |
| `board.rename` | edit | page, title | F044 | Rename a whiteboard board. |
| `board.insertTemplate` | edit | page, template, at?, ids? | F044 | Insert a whiteboard framework (brainstorm, kanban, SWOT, retro, mind map, timeline, meeting, flowchart). |

### `bridge.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `bridge.setEnabled` | session | enabled | F090 | Start/stop the bridge (user only; security). |
| `bridge.status` | read |  | F090 | Listening address, clients, last call. |

### `calendar.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `calendar.events` | read, sensitive | from, to | F075 | Calendar events (EventKit) in a range. |
| `calendar.createNote` | library | event, kind, id? | F075 | Create a note for an event in 'Calendar Event/{Event}/{Event} {Date}'. |
| `calendar.openNote` | session | event | F075 | Open the note linked to an event. |

### `canvas.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `canvas.decorate` | session | page, id, display, ttl? | F006 | Show a transient DisplayList overlay on a page for ttl seconds (plugins: nib.canvas.decorate). |
| `canvas.clearDecorations` | session | id? | F006 | Remove canvas decorations (all, or one id). |

### `card.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `card.add` | edit | doc, front, back, after?, id? | F049 | Add a flashcard; each side is a string or {text?, asset?, ink?: Stroke[]} (kind inferred). |
| `card.update` | edit | ref, front?, back? | F049 | Edit a card. |
| `card.delete` | edit | refs | F049 | Delete cards. |
| `card.move` | edit | ref, after? | F049 | Reorder a card. |
| `card.moveTo` | edit | refs, doc | F049 | Move cards to another study set. |

### `clipboard.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `clipboard.copy` | read | refs | F014 | Copy items (Nib fragment + PNG + recognised text). |
| `clipboard.cut` | edit | refs | F014 | Cut items. |
| `clipboard.paste` | edit | page, at?, matchStyle?, ids? | F014 | Paste Nib items, images or rich text at a point. |

### `collab.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `collab.host` | library, sensitive | doc, transport?, role? | F072 | Share a document live; returns a join code. |
| `collab.join` | library, sensitive | code, transport? | F072 | Join a session (receives the document if missing). |
| `collab.leave` | session |  | F072 | Leave or stop the session. |
| `collab.participants` | read |  | F072 | Participants with names, pages and roles. |
| `collab.approve` | session | participant, allow | F072 | Admit or reject a participant waiting to join. |
| `collab.setRole` | session | participant, role | F072 | Change a participant's role (read-only / edit). |
| `collab.revoke` | session, destructive | participant | F072 | Remove a participant from the session. |
| `collab.follow` | session | participant? | F108 | Follow a collaborator's viewport (nil = stop). |
| `collab.followMe` | session | on | F108 | Make every participant follow you. |
| `collab.markSeen` | session | pages | F108 | Clear unseen-change badges. |

### `comment.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `comment.add` | edit | page, at? \| ref?, text, id? | F037 | Start a comment thread on a spot or an object. |
| `comment.reply` | edit | ref, text | F037 | Reply in a thread. |
| `comment.edit` | edit | ref, message, text | F037 | Edit a message. |
| `comment.deleteMessage` | edit | ref, message | F037 | Delete a message (last message deletes the thread). |
| `comment.resolve` | edit | ref, resolved | F037 | Resolve / unresolve a thread. |
| `comment.tapAt` | session | page, point | F037 | Tap chain: open the thread under a tap. |

### `connector.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `connector.create` | edit | page, from, to, route?, arrowStart?, arrowEnd?, label?, id? | F032 | Connect two items (side/t anchors) or points. |
| `connector.setPath` | edit | ref, route?, bends? | F032 | Reroute: straight/elbow/curved, add/move/remove bends, change anchors. |

### `diagnostics.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `diagnostics.export` | read (user presence) | includeTitles? | F076 | Export a diagnostics zip (logs, config, feature and plugin lists; no note content). |
| `diagnostics.setFeatureEnabled` | session | id, enabled | F076 | Enable/disable a feature for safe mode (takes effect on relaunch). |

### `diagram.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `diagram.addConnected` | edit | ref, side, shape?, id? | F032 | Quick Diagramming: create a connected shape next to a shape. |
| `diagram.create` | edit | page, nodes, edges, layout, style?, origin?, ids? | F032 | Create a native, editable diagram (tree, flow, timeline, mind map; classic/gray/line styles). |

### `dictionary.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `dictionary.add` | session | word | F104 | Add a word to the personal dictionary. |
| `dictionary.remove` | session | word | F104 | Remove a word from the personal dictionary. |
| `dictionary.list` | read |  | F104 | List personal dictionary words. |

### `doc.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `doc.create` | library | kind, title?, folder?, template?, size?, cover?, pages?, id? | F002 | Create a notebook, whiteboard, text document or study set (first page/board/block included). |
| `doc.setFavorite` | edit | doc, favorite | F002 | Star or unstar a document. |
| `doc.merge` | library | source, into | F002 | Append all pages of one notebook to another and trash the source. |
| `doc.setScrollDirection` | edit | doc, direction | F017 | Vertical or horizontal page scrolling for a document. |
| `doc.open` | session | doc, page?, mode? | F018 | Open a document (and page) in the active window, a new tab or a new window. |
| `doc.quickNote` | library | folder?, id? | F021 | Create an untitled notebook with the default paper and open it. |
| `doc.convertToWhiteboard` | edit | doc | F044 | Convert a notebook into a whiteboard (pages laid out side by side on one board). |
| `doc.setLanguage` | edit | doc, language | F057 | Recognition/search language of a document (re-indexes). |
| `doc.setWritingAids` | edit | doc, spellcheck?, mathAssist? | F104 | Turn handwriting spellcheck and Math Assist on or off for a document. |
| `doc.setLocked` | edit (user presence) | doc, locked | F071 | Add or remove the lock (removing asks for the password). |
| `doc.unlock` | session (user presence) | doc | F071 | Unlock a locked document for this session. |
| `doc.suggestTitle` | read | doc | F087 | Suggest a title from content (AI, else first recognised line). |

### `element.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `element.create` | library | refs, collection, id? | F035 | Save selected items as a reusable element. |
| `element.insert` | edit | page, collection, element, at?, ids? | F035 | Insert an element (its items, grouped and selected). |
| `element.collection.create` | library | title, id? | F035 | Create a collection. |
| `element.collection.update` | library | collection, title? \| order? | F035 | Rename / reorder a collection. |
| `element.collection.delete` | library | collection | F035 | Delete a collection. |
| `element.collection.list` | read |  | F035 | List element collections (yours and content packs). |
| `element.list` | read | collection | F035 | List the elements of a collection. |
| `element.rename` | library | collection, element, title | F035 | Rename an element. |
| `element.delete` | library | collection, element | F035 | Delete an element from a collection. |
| `element.import` | library | url | F035 | Import a .nibcollection file. |
| `element.export` | read | collection | F035 | Export a collection as .nibcollection. |

### `export.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `export.run` | read | docs, pages?, format, options?, inline? | F066 | Export to PDF (editable/flattened), PNG/JPEG images, a .nibnote package or a zipped folder; returns temporary assets (tmp: refs; base64 with inline). |
| `export.present` | read (user presence) | docs, pages? | F067 | Show the export dialog and share sheet. |
| `export.saveToSource` | irreversible | doc | F067 | Overwrite the original imported PDF with the annotated version. |

### `folder.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `folder.create` | library | title, parent?, color?, icon?, id? | F002 | Create a folder. |
| `folder.setStyle` | library | folder, color?, icon?, favorite? | F002 | Folder colour / icon / favourite. |

### `gallery.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `gallery.list` | read | index? | F080 | Entries of the configured gallery indexes (plugins and content packs). |

### `gif.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `gif.search` | read | query | F035 | Search GIPHY (needs the user's GIPHY key). |

### `handwriting.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `handwriting.toText` | edit | refs, replace?, text?, id? | F057 | Convert selected handwriting to a text box (optionally with corrected text). |
| `handwriting.toTextPages` | edit | pages | F057 | Convert all handwriting on pages to text boxes. |
| `handwriting.words` | read | refs | F058 | Group strokes into lines and words (with recognised text when available). |
| `handwriting.reflow` | edit | refs, width | F058 | Reflow handwriting to a new width (moves strokes only). |
| `handwriting.straighten` | edit | refs | F058 | Straighten slanted handwritten lines. |
| `handwriting.align` | edit | refs, align | F058 | Align handwritten lines left/centre/right. |
| `handwriting.insertSpace` | edit | page, y, height | F058 | Insert vertical space, pushing ink below down. |
| `handwriting.replaceWord` | edit | refs, text | F059 | Replace handwritten word strokes with synthesised ink matching size, slant and colour. |
| `handwriting.restyle` | edit | refs, style, font? | F105 | Neaten handwriting: regularise baseline/size/slant, or re-write it in a handwriting font. |

### `image.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `image.insert` | edit | page, asset \| base64 \| url, frame? \| at?, animated?, id? | F034 | Insert an image or GIF. |
| `image.crop` | edit | ref, rect? \| mask? | F034 | Rectangular or freehand crop (normalised). |
| `image.flip` | edit | ref, axis | F034 | Mirror an image. |
| `image.replace` | edit | ref, asset | F034 | Replace the image keeping its frame. |
| `image.saveToPhotos` | read (user presence), sensitive | ref | F034 | Save to Photos. |

### `import.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `import.files` | library | urls, folder?, doc?, position?, anchor?, ids? | F064 | Import files as new documents or into a document (PDF, images, Word, PowerPoint, .nibnote and legacy .nib packages, zipped folders, library backups, CSV/TSV/TXT, plugins, collections). |
| `import.pick` | library (user presence) | target? | F064 | Show the document picker and import the chosen files. |

### `index.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `index.rebuild` | session | doc? | F055 | Re-index one document or the whole library. |

### `ink.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `ink.addStrokes` | edit | page, strokes[], ids? | F007 | Add one or more strokes (Stroke JSON; pts with fmt 'xy'… 'full'; missing nib sizes are derived). |
| `ink.setStyle` | edit | refs, style | F007 | Change style fields of existing strokes (tool, pen, width, pattern, colour). |
| `ink.setPoints` | edit | ref, fmt, pts | F007 | Replace a stroke's points (fmt 'xy'… 'full', whole array); nib sizes are re-derived. |
| `ink.erase` | edit | page, path, radius, mode, filter? | F010 | Erase along a path: precision (cut), standard (segment), stroke (whole stroke). |
| `ink.scribbleErase` | edit | page, points | F010 | Erase pen strokes covered by a scribble. |
| `ink.writeText` | edit | page, text, at, size?, font?, color?, width?, maxWidth?, slant?, ids? | F059 | Write text as handwriting-style ink strokes. |

### `item.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `item.create` | edit | page, item, id? | F003 | Create an item from Item JSON (kind + payload); layer defaults to the active layer. |
| `item.update` | edit | ref, patch | F003 | Patch an item's fields (style, frame, text, ext…). |
| `item.transform` | edit | refs, translate? \| scale? \| rotate? \| matrix?, origin? | F012 | Move/scale/rotate items (attached children and anchored connectors follow). |
| `item.moveToPage` | edit | refs, page, offset? | F012 | Move items to another page (ids kept). |
| `item.delete` | edit | refs | F013 | Delete items. |
| `item.arrange` | edit | refs, to | F013 | Bring to front / send to back / forward / backward. |
| `item.recolor` | edit | refs, color | F013 | Recolour ink, shapes (outline+fill), text and sticky notes. |
| `item.setLocked` | edit | refs, locked | F013 | Lock or unlock images, text boxes, shapes, sticky notes. |
| `item.duplicate` | edit | refs, offset?, ids? | F014 | Duplicate items with new ids. |

### `laser.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `laser.setMode` | session | mode, color? | F040 | Dot or Trail, colour. |
| `laser.point` | session | page, point? | F040 | Move the laser pointer to a point on a page (null hides it). |

### `layer.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `layer.setActive` | session | layer | F041 | Choose the layer new content goes to. |
| `layer.setVisible` | session | layer, visible | F041 | Show/hide a layer on this device. |
| `layer.rename` | edit | doc, layer, name | F041 | Rename a layer. |
| `layer.moveItems` | edit | refs, layer | F041 | Move items to another layer. |

### `lesson.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `lesson.create` | library | doc, students, folder, ids? | F109 | Create a lesson: per-student copies of a document in a class folder (shared synced folder). |
| `lesson.setState` | edit | doc, state | F109 | Assignment state on a student copy: published, submitted, returned, resubmit. |
| `lesson.importRoster` | library | csv? \| url?, folder | F109 | Import a class roster from CSV. |
| `lesson.collect` | read | doc, zone? | F110 | Collect every student's answer-zone renders (By Page / By Question views). |
| `lesson.cluster` | read | zone, mode | F110 | AI clusters of answers (compare to model answer or by similarity). |
| `lesson.setClusters` | edit | zone, clusters | F110 | Save manual answer clusters for a zone. |

### `library.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `library.list` | read | folder?, sort?, kinds? | F002 | List folders and documents. |
| `library.rename` | library | ref, title | F002 | Rename a document or folder. |
| `library.move` | library | refs, folder? | F002 | Move documents/folders; moving a notebook onto a notebook merges it. |
| `library.duplicate` | library | refs, ids? | F002 | Duplicate documents or folders. |
| `library.trash` | library | refs | F002 | Move to Trash (recoverable). |
| `library.setView` | session | folder?, layout?, sort?, filter? | F019 | Set the library window's current folder, grid/list layout, sort and filter. |
| `library.chooseFolder` | library (user presence) |  | F025 | Pick a folder (iCloud Drive, OneDrive, Dropbox, On My iPad…) as the library. |
| `library.relocate` | library (user presence) | copy | F025 | Copy the library to another folder and switch to it (e.g. On My iPad → iCloud Drive). |
| `library.locations` | read |  | F025 | Known library folders on this device. |
| `library.switch` | library | location | F025 | Switch to a known library folder. |
| `library.repair` | session | rebuildIndex? | F070 | Rebuild the catalog, re-merge packages and optionally the search index. |

### `link.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `link.set` | edit | ref, range, link | F029 | Link text to a URL, a page of any document, or an audio timestamp. |
| `link.remove` | edit | ref, range | F029 | Remove a link. |
| `link.follow` | session | url? \| doc?, page? \| clip?, t? | F029 | Follow a link (records return-to-page history). |
| `link.back` | session |  | F029 | Return to the page before the last link jump. |
| `link.autodetect` | edit | ref | F029 | Turn typed/pasted URLs in a text item into links. |
| `link.tapAt` | session | page, point | F029 | Tap chain: follow a text or PDF link under a tap (one tap in read-only, long-press in edit). |

### `lock.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `lock.setup` | session (user presence) |  | F071 | Set up (or change) the universal password, hint and Face ID. |

### `math.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `math.recognize` | read | refs | F060 | Recognise handwritten math as LaTeX lines (AI vision when configured, else on-device fallback). |
| `math.convert` | edit | refs, latex?, id? | F060 | Replace handwriting with a typeset math object (keeps the original ink). |
| `math.setLatex` | edit | ref, lines | F060 | Edit a math object's LaTeX. |
| `math.copy` | read | ref, as | F060 | Math object as LaTeX, PNG or the original handwriting fragment. |
| `math.evaluate` | read | expression, variables?, format? | F061 | Evaluate an expression or solve an equation on-device (fraction/mixed/decimal output). |
| `math.assist` | edit | page, line?, format?, ids? | F106 | Write the answer to a handwritten equation ending in '=' as ink. |
| `math.graph.create` | edit | page, expressions, rect?, id? | F107 | Insert an interactive 2D graph. |
| `math.graph.setViewport` | edit | ref, x, y, scale | F107 | Pan/zoom a graph. |
| `math.solve` | read | refs? \| latex?, mode | F088 | Step-by-step solution (solve) or hint-by-hint tutoring (teach) from the user's AI; numeric answers checked on-device. |

### `mathassist.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `mathassist.tapAt` | session | page, point, ref? | F106 | Tap handler: open Math Assist options for the glowing equation under a tap. |

### `meeting.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `meeting.summarize` | edit | clip | F089 | (Re)generate the summary of a recording. |
| `meeting.generateNotes` | edit | clip, mode, ids? | F089 | Generate notes from the transcript, or enhance the user's own notes (appended below). |

### `menu.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `menu.showAt` | session | page, point | F013 | Open the page long-press / right-click menu at a point. |

### `node.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `node.insert` | edit | parent, node, at?, id? | F003 | Insert any record (item, page, block, card, outline entry) as raw JSON. |
| `node.set` | edit | ref, fields | F003 | Merge fields into any record (JSON merge, re-validated by Codable). |
| `node.remove` | edit | ref | F003 | Tombstone any record. |
| `node.move` | edit | ref, to, at? | F003 | Reparent/reorder: item to another page, z-order, page order, block order. |

### `outline.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `outline.add` | edit | page, title, parent?, id? | F046 | Add a page to the custom outline. |
| `outline.rename` | edit | entry, title | F046 | Rename an outline entry. |
| `outline.move` | edit | entry, parent?, after? | F046 | Nest (max 3 levels) or reorder an entry. |
| `outline.delete` | edit | entry | F046 | Remove an outline entry (not the page). |
| `outline.sortByPage` | edit | doc | F046 | Sort entries by page number. |
| `outline.generate` | edit | doc, pages?, ids? | F087 | AI-generated outline entries for pages (preview then insert). |

### `page.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `page.setTemplate` | edit | pages, template, params?, size?, landscape? | F005 | Change the template (and size/orientation) of pages; page 1 = cover. |
| `page.setBackground` | edit | pages, background | F005 | Set any Background (template, pdf, image, colour) on pages. |
| `page.clear` | edit | page | F010 | Remove every item from a page (page stays). |
| `page.deleteItems` | edit | doc \| page, kinds, scope | F010 | Delete all items of chosen kinds on a page or the whole document. |
| `page.add` | edit | doc, position, anchor?, count?, source?, template?, size?, asset?, pdfPage?, id?, ids? | F022 | Add pages before/after/at end from the current template, a template, a PDF, an image or the page clipboard. |
| `page.duplicate` | edit | pages, ids? | F022 | Duplicate pages with their items. |
| `page.copy` | read | pages | F022 | Copy pages to the page clipboard. |
| `page.paste` | edit | doc, position, anchor?, ids? | F022 | Paste copied pages. |
| `page.moveTo` | edit | pages, doc, ids? | F022 | Move pages to the end of another document. |
| `page.reorder` | edit | pages, before? \| after? | F022 | Reorder pages. |
| `page.rotate` | edit | pages \| all, degrees? | F022 | Rotate pages 90° clockwise (or given degrees). |
| `page.trash` | edit | pages | F022 | Move pages to Trash. |
| `page.restore` | edit | pages | F022 | Restore trashed pages. |
| `page.purge` | irreversible | pages | F022 | Delete trashed pages permanently. |
| `page.setBookmarked` | edit | pages, on | F046 | Bookmark pages. |

### `panel.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `panel.open` | session | id | F017 | Open a registered panel (sidebar tab, floating, sheet). |
| `panel.close` | session | id | F017 | Close a panel. |

### `pdf.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `pdf.text` | read | page | F024 | Text of the PDF page behind a Nib page. |
| `pdf.links` | read | page | F024 | Hyperlinks on a PDF page (rects in page coordinates). |
| `pdf.markSelection` | edit | page, from, to, style, ids? | F042 | Highlight or strike out PDF text between two points (creates ink). |
| `pdf.copyText` | read | page, from, to | F042 | Copy PDF text between two points. |

### `plugin.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `plugin.list` | read |  | F078 | Installed plugins with version, permissions, state. |
| `plugin.enable` | session | id, enabled | F078 | Enable or disable a plugin (plugins:manage). |
| `plugin.reload` | session | id | F078 | Reload a plugin from its folder. |
| `plugin.logs` | read | id, limit? | F078 | Recent console output of a plugin. |
| `plugin.sdkTypes` | read |  | F078 | TypeScript definitions (nib.d.ts) generated from the live command registry. |
| `plugin.docs` | read |  | F078 | Manifest schema, contribution points and API reference for authoring plugins. |
| `plugin.install` | library | url? \| path? \| files? | F079 | Install a plugin from a URL, a local .nibplugin/.zip/folder, or inline files (AI authoring). Always confirmed. |
| `plugin.uninstall` | library | id | F079 | Remove a plugin and its grant. |
| `plugin.review` | session (user presence) | id | F079 | Review and approve a plugin that arrived via sync or changed on disk. |

### `present.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `present.setMode` | session | mode | F063 | External display: mirror screen, presenter page (with zoom/animations) or full page (no animation). |

### `preset.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `preset.select` | session | tool, swatch?, width? | F008 | Choose the active colour / thickness slot of a tool. |
| `preset.setSwatch` | session | tool, index, color, pattern? | F008 | Edit a colour slot. |
| `preset.addSwatch` | session | tool, color | F008 | Add a colour slot (max 12). |
| `preset.removeSwatch` | session | tool, index | F008 | Remove a colour slot (min 1). |
| `preset.moveSwatch` | session | tool, from, to | F008 | Reorder colour slots. |
| `preset.setWidth` | session | tool, index, width, pattern? | F008 | Edit a thickness slot and its line pattern. |
| `preset.reset` | session | tool | F008 | Restore the tool's default presets. |

### `print.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `print.present` | read (user presence) | doc, pages? | F067 | Print (AirPrint) with page selection. |

### `query.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `query.context` | read | session? | F003 | Where the user is: document, page, visible rect, tool, selection refs/bbox, read-only, open tabs. |
| `query.tree` | read | root?, depth? | F003 | Library tree (folders, documents with kind/page counts). |
| `query.get` | read | ref, depth?, fields?, points? | F003 | Any node as JSON; stroke points omitted unless points=true; pages list items (≤200 + cursor). |
| `query.find` | read | in, kinds?, layer?, bbox?, where?, text?, limit?, cursor? | F003 | Find items by kind, layer, area, field equality or text. |

### `recognize.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `recognize.pageText` | read | page | F055 | Recognised text blocks of a page with bboxes, sources and item ids (cached). |
| `recognize.items` | read | refs | F055 | Recognised text of strokes: {text, lines:[{text, bbox, words:[{text, bbox, refs}]}]}. |

### `relay.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `relay.configure` | session, sensitive | url | F092 | Set the collaboration relay URL (the token is entered in Settings only). |

### `render.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `render.page` | read | page, scale?, region?, marks?, layers?, background? | F004 | Render a page or region to a temporary PNG (long edge ≤ 1568 px); marks=true numbers items and returns mark → ref. |

### `replay.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `replay.setMode` | session | mode | F053 | Spotlight, reveal or static replay while audio plays. |
| `replay.seekToItem` | session | ref | F053 | Play audio from the moment an ink item was written. |
| `replay.tapAt` | session | page, point, ref? | F053 | Tap handler: while replaying, seek audio to the handwriting under a tap. |

### `ruler.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `ruler.set` | session | visible?, angle?, position?, units?, digits? | F039 | Show/hide and position the ruler. |

### `scan.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `scan.documents` | library (user presence) | doc?, position?, folder? | F065 | Scan paper (document camera + OCR) into a new or the current document. |
| `scan.qr` | session (user presence) |  | F065 | Scan a QR code and open its link. |

### `search.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `search.text` | read | query, scope?, kinds?, limit? | F055 | Full-text search over handwriting, typed text, PDF text, scans, titles, outlines and transcripts. |
| `search.open` | session | scope, query? | F056 | Open library or in-document search. |
| `search.step` | session | direction | F056 | Next / previous match (⌘G, ⇧⌘G). |

### `selection.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `selection.set` | session | refs | F011 | Select items by ref. |
| `selection.clear` | session |  | F011 | Clear the selection. |
| `selection.fromPolygon` | session | page, polygon, include? | F011 | Select items touching a lasso polygon (filtered by kinds). |
| `selection.fromRect` | session | page, rect, include? | F011 | Rectangular lasso. |
| `selection.fromLoop` | edit | page, stroke | F011 | Circle-to-Lasso: remove the loop stroke and select what it encloses. |
| `selection.selectAll` | session | page | F011 | Select everything on the page (active layer). |
| `selection.tapAt` | session | page, point | F011 | Tap chain: select the top non-ink item under a finger tap (quick selection). |
| `selection.screenshot` | read | page, rect | F013 | Render a region (PDF included) to a PNG asset for sharing/pasting. |

### `shape.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `shape.recognize` | read | points, neighbors? | F030 | Recognise a rough stroke as a line, curve, ellipse, rectangle, triangle, polygon or arrow; returns ShapeItem JSON or null. |
| `shape.create` | edit | page, shape, frame? \| points?, style?, text?, id? | F031 | Create a shape (rectangle, rounded rectangle, ellipse, diamond, triangle, polygon, line, curve, arrow). |
| `shape.setStyle` | edit | refs, style | F031 | Outline colour/width/none, fill, corner radius, pattern, arrowheads. |
| `shape.setKind` | edit | ref, shape | F031 | Change shape type keeping frame. |
| `shape.setPoints` | edit | ref, points | F031 | Edit vertices / control points. |

### `sidebar.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `sidebar.toggle` | session | mode? | F017 | Show/hide the document sidebar (sidebar or full-window thumbnails). |

### `spellcheck.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `spellcheck.tapAt` | session | page, point, ref? | F104 | Tap handler: show spelling suggestions for the underlined word under a tap. |

### `sticky.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `sticky.create` | edit | page, at, color?, text?, id? | F036 | Place a sticky note. |
| `sticky.setCollapsed` | edit | refs, collapsed | F036 | Collapse/expand. |
| `sticky.resolve` | edit | ref, resolved | F036 | Resolve a note. |
| `sticky.setColor` | edit | refs, color | F036 | Change colour. |
| `sticky.tapAt` | session | page, point, ref? | F036 | Tap handler: expand a collapsed note or edit the selected note under a tap. |

### `stopwatch.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `stopwatch.start` | session |  | F062 | Start the stopwatch. |
| `stopwatch.lap` | session |  | F062 | Record a lap. |

### `study.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `study.grade` | edit, not undoable | card, knewIt | F050 | Grade a card in Smart Learn (updates SRS; not undoable). |
| `study.resetProgress` | edit | doc | F050 | Reset Smart Learn progress. |
| `study.setReminders` | edit | doc, paused | F050 | Pause/resume review reminders. |
| `study.setTheme` | edit | doc, card?, background? | F050 | Card appearance of a study set (card and background colours). |
| `study.importText` | library | text? \| url?, format?, folder?, id? | F051 | Create a study set from CSV/TSV/TXT (Anki 'Notes in Plain Text', Quizlet tab export). |
| `study.exportCSV` | read | doc | F051 | Export a study set as CSV. |

### `sync.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `sync.now` | session |  | F025 | Check the library folder for changes from other devices now. |

### `tab.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `tab.close` | session | doc? | F018 | Close a tab (⌘W). |
| `tab.closeOthers` | session |  | F018 | Close other tabs. |
| `tab.select` | session | index | F018 | Switch tab (⌘1–9). |

### `table.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `table.edit` | edit | ref, op, row?, column?, count?, text?, color?, width? | F048 | Table operations: setCell, insertRow/Column (before/after), deleteRow/Column, merge, split, setBackground, setBorders, setColumnWidth, moveRow/Column. |
| `table.exportCSV` | read | ref | F048 | Export a table as CSV. |

### `tape.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `tape.tapAt` | edit | page, point | F033 | Tap chain: toggle the tape under a finger tap (reveal/hide; not undoable). |
| `tape.setRevealed` | edit | refs, revealed | F033 | Reveal or hide tape strips (not undoable). |
| `tape.removeAll` | edit | page | F033 | Remove all tape on a page. |
| `tape.importPattern` | session | asset \| url | F033 | Add a custom tape pattern image. |
| `tape.patterns` | read |  | F033 | List tape patterns (built-in, custom, content packs). |
| `tape.deletePattern` | session | id | F033 | Delete a custom tape pattern. |
| `tape.clearHistory` | session |  | F033 | Clear the recently used tape patterns. |

### `template.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `template.list` | read | category?, covers? | F005 | List registered templates with params and defaults. |
| `template.choose` | read (user presence) | kind, size?, color? | F045 | Show the template picker and return {background, size} (used by create flows). |
| `template.import` | library | url, group?, kind, id? | F045 | Import a PDF (first page) or image as a custom paper/cover. |
| `template.listCustom` | read | group? | F045 | List custom templates and groups. |
| `template.group.create` | library | title, id? | F045 | Create a custom template group. |
| `template.group.rename` | library | group, title | F045 | Rename a custom template group. |
| `template.group.delete` | library | group | F045 | Delete a custom template group and its templates. |
| `template.delete` | library | id | F045 | Delete a custom template. |
| `template.setHidden` | library | id, hidden | F045 | Hide or restore a built-in template. |
| `template.fromPage` | library | page, title, id? | F045 | Save a page as a custom template (flattened PDF). |

### `text.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `text.createBox` | edit | page, at \| frame, text?, style?, id? | F026 | Create a text box (RichText or plain string). |
| `text.setText` | edit | ref, text | F026 | Replace the rich text of a text box, sticky note, shape or connector label. |
| `text.format` | edit | ref, attrs, range? | F026 | Apply character attributes (font, size, colour, bold, italic, underline, strike, highlight). |
| `text.setParagraph` | edit | ref, align?, list?, indent?, lineSpacing? | F026 | Paragraph formatting. |
| `text.setBoxStyle` | edit | refs, style | F026 | Background, border, corner, padding, shadow, auto-grow. |
| `text.saveDefaultStyle` | session | name?, style | F026 | Save the current style as the default (or a named style). |
| `text.tapAt` | session | page, point, ref? | F026 | Tap handler: start editing the selected text box under a tap. |
| `text.startPageText` | edit | page, id? | F028 | Start (or continue) full-page typing on a page. |

### `timer.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `timer.start` | session | seconds, label? | F062 | Start a countdown. |
| `timer.control` | session | action | F062 | Pause, resume or end the timer/stopwatch. |
| `timer.history` | read |  | F062 | Past sessions (name, document, duration, laps). |
| `timer.saveMode` | session | name, seconds | F062 | Save a custom timer mode. |
| `timer.deleteMode` | session | name | F062 | Delete a custom timer mode. |

### `toolbar.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `toolbar.setLayout` | session | order, hidden | F016 | Save a toolbar layout (tools, accessories). |
| `toolbar.reset` | session | part | F016 | Reset toolbar, writing tools or accessories layout. |
| `toolbar.setVisible` | session | visible | F016 | Show/hide the toolbar (pull-down to collapse). |
| `toolbar.layouts` | read |  | F016 | List saved toolbar layouts. |
| `toolbar.saveLayout` | session | name | F016 | Save the current toolbar layout under a name. |
| `toolbar.applyLayout` | session | name | F016 | Apply a saved toolbar layout. |
| `toolbar.deleteLayout` | session | name | F016 | Delete a saved toolbar layout. |

### `transcript.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `transcript.get` | read | clip | F054 | Transcript segments of a clip. |
| `transcript.regenerate` | edit, not undoable | clip, engine? | F054 | Re-transcribe (on-device Speech or cloud via the user's AI provider). |
| `transcript.editSegment` | edit, not undoable | clip, index, text | F054 | Correct a transcript line. |
| `transcript.insert` | edit | clip, segments, page, id? | F054 | Insert transcript lines on a page as a text box. |

### `trash.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `trash.list` | read |  | F002 | List trashed documents, folders and pages. |
| `trash.recover` | library | refs, folder? | F002 | Restore from Trash. |
| `trash.deletePermanently` | irreversible | refs | F002 | Delete permanently. |
| `trash.empty` | irreversible |  | F002 | Empty the Trash. |

### `view.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `view.goToPage` | session | page \| index | F006 | Scroll to a page. |
| `view.zoom` | session | scale? \| fit? \| actual? | F006 | Zoom (⌘+ ⌘− ⌘0 ⌘9). |
| `view.scrollBy` | session | dx, dy | F006 | Pan (arrow keys). |
| `view.reveal` | session | ref | F006 | Scroll an item into view and flash it. |
| `view.setReadOnly` | session | on | F042 | Enter/leave read-only mode. |

### `webdav.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `webdav.syncNow` | session |  | F069 | Mirror the library with the WebDAV server now. |
| `webdav.configure` | session, sensitive | url, user, folder, allowUntrustedCertificates? | F069 | Configure WebDAV (password is entered in the settings page only). |
| `webdav.put` | session; `file` resolves through ctx.inputFile | path, file | F069 | Upload one file (used by auto backup). |
| `webdav.status` | read |  | F069 | Last sync, pending, errors. |

### `window.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `window.open` | session | doc?, page? | F018 | Open a document (or the library) in a new window. |

### `zoom.*`

| Command | Effect | Params | Owner | Summary |
|---|---|---|---|---|
| `zoom.toggle` | session | on? | F038 | Show/hide the Zoom Window. |
| `zoom.setBox` | session | page, rect | F038 | Move/resize the zoom box. |
| `zoom.newLine` | session |  | F038 | Jump to the next line (return height). |
| `zoom.setReturnHeight` | edit | page, height | F038 | Per-page return height override. |

---

## 7. Read / query API

### 7.1 Principles

Queries are ordinary `read` commands (F003, F055, F004). The AI's meta-tools (AI.md §4, `ToolCatalog` in NibContracts, shared by the agent and the bridge) and the plugin `nib.query` sugar (PLUGIN_API.md §4) are thin wrappers over them.

### 7.2 Shapes

`query.context`:

```json
{ "session": "S7K2…", "document": {"ref": "doc:D", "title": "Kinematics", "kind": "notebook", "pageCount": 12, "locked": false},
  "page": {"ref": "page:D/P", "index": 3, "size": [595.28, 841.89]}, "visibleRect": [0, 120, 595, 600],
  "tool": "pen", "readOnly": false, "activeLayer": 0,
  "selection": {"refs": ["item:D/P/I1"], "kinds": ["stroke"], "bbox": [72, 118, 210, 30]},
  "tabs": ["doc:D", "doc:E"] }
```

`query.get {"ref":"page:D/P"}` (stroke points are omitted unless `points: true`; text is included):

```json
{ "ref": "page:D/P", "kind": "page", "index": 3, "size": [595.28, 841.89], "rotation": 0,
  "background": {"kind": "template", "template": {"id": "builtin.ruled", "params": {"spacing": 24}}},
  "layers": [{"index": 0, "name": "Layer 1", "visible": true, "active": true}],
  "items": [
    {"ref": "item:D/P/S3H8", "kind": "stroke", "tool": "pen", "color": "#1A1A1AFF", "width": 1.2, "bbox": [72,120,210,18], "pointCount": 184, "layer": 0},
    {"ref": "item:D/P/T9P2", "kind": "text", "bbox": [72,300,400,60], "text": "Kinematics — SUVAT", "layer": 0}
  ],
  "counts": {"stroke": 412, "text": 3}, "cursor": "200", "truncated": true }
```

### 7.3 Other queries

- **`query.find {in, kinds?, layer?, bbox?, where?, text?}`.** `where` is shallow field equality on the item JSON, for example `{"tool":"highlighter"}`.
- **`recognize.pageText {page}`** returns blocks `{text, alternatives, bbox, source: ink|typed|pdf|scan, itemIDs}`. They are cached per page version.
- **`render.page {page, scale?, region?, marks?, layers?, background?}`** (owner F004) returns `{asset: "tmp:<name>", pxPerPt, region, marks?}`: a temporary PNG whose long edge is at most 1568 px. With `marks: true` it also returns a map from mark number to ref, for vision models. `nib_render`, `nib.query.render`, `selection.screenshot` and math recognition all go through it.

### 7.4 Limits

- **Size cap.** Responses are capped at `NibLimits.aiToolResultBytes` (20 KB). Anything larger returns a `cursor`.
- **Locked documents.** For non-user principals a locked document shows only `{"ref": …, "locked": true}`, and `search.text` excludes it.

---

## 8. Ink pipeline and the PencilKit bridge

### 8.1 Wet ink and dry tiles

**Wet ink.** The canvas input half (F101, same module as F006) puts one transparent `PKCanvasView` on the active page, plus a second one with a multiply blend for the highlighter. Its `zoomScale` equals the document zoom, so canvas coordinates are page points. It shows only the strokes of the current burst.

**Dry ink.** All committed content is rendered as tiles by the renderer (F004), from the model. A stroke is removed from the wet canvas only after its dry tiles are on screen, so nothing flickers. Stroke cost does not grow with the page's total stroke count.

### 8.2 What happens when a stroke is drawn

1. `canvasViewDrawingDidChange` produces a `PKStroke`.
2. `PKBridge.stroke(from:style:rolls:)` converts it into a `Stroke`. Pencil Pro roll values come from the canvas's own touch recogniser, `TouchTap`.
3. The canvas calls `CanvasTool.strokeFinished`. The default implementation calls `CanvasHost.commitStroke`.
4. `commitStroke` runs `app.content.strokeProcessors` in order: stabilisation, straight highlighter, ruler projection.
5. `commitStroke` then calls `ink.addStrokes`.

### 8.3 Stroke model

- The model keeps the size and opacity PencilKit actually rendered, so reloading a stroke draws it identically.
- Points created by AI, plugins, ink synthesis or imports leave size and opacity out. PencilKit treats stroke points as the control points of a uniform cubic B-spline, so a sparse polyline would render with rounded, pulled-in corners that no longer match what the eraser, lasso and recognisers see. `InkModel.prepare` therefore densifies every all-zero-width stroke (≤ 1.5 pt spacing, each end point tripled to clamp the spline) and then derives sizes with `InkModel.fillSizes`. `ink.addStrokes`, `ink.setPoints`, stroke patches via `item.update`/`node.set`, and `PKBridge.pkStroke` all call it.
- Ink type mapping: fountain → `.fountainPen`, ball → `.monoline`, brush → `.pen`, pencil → `.pencil`, highlighter → `.marker`, tape → vector (not PencilKit).

### 8.4 Input modes and tools

A tool declares one of three `CanvasInputMode`s:

| Mode | Behaviour |
|---|---|
| `.pencilKit` | The canvas captures wet ink. |
| `.samples` | The tool gets raw samples and draws its own preview into `overlayLayer` (the active tool's transient layer). Used by the eraser, lasso, tape, laser, dashed pens and plugin stroke tools. |
| `.taps` | Taps only. |

- **Draw-and-Hold.** When the pen rests at the end of a stroke, the canvas calls `strokeHeld`. If the tool returns `true`, the wet stroke is cancelled and the rest of that touch is delivered as samples, so the tool can live-adjust the snapped shape.
- **Long-press.** A touch held still for 0.5 s calls `longPress`. Circle-to-Lasso and page menus use it.

### 8.5 Touch routing: attachments, tap handlers, tools

Everything on the canvas that is not the active tool plugs in through two registries (F101's `GestureRouter` applies them; there is no fixed tap chain):

1. **`ui.canvasAttachments`** (`CanvasAttachment`): persistent overlays with their own layer/view, `canvasDidChange` on scroll/zoom/commit, and `hitTest` to claim a touch before anything else. Examples: selection handles and drag-to-move (F012), selection outline (F011), shape control points (F031), connector bends and quick-diagram dots (F032), spellcheck underlines (F104), Math Assist glow (F106), presence cursors (F108), minimap (F044), ruler (F039), zoom box (F038), answer-zone widgets (F099), and `canvas.decorate` DisplayList overlays (F006; plugins via `nib.canvas.decorate`).
2. **`content.tapHandlers`** (`TapHandlerDescriptor`): finger tap, double-tap and long-press are offered to commands in `order`, filtered by the topmost item's kind / drawKey and by read-only mode. Each command gets `{page, point, ref?, gesture}` and returns `{"handled": Bool}`; the first `true` wins. Built-ins: `tape.tapAt` 100, `comment.tapAt` 200, `link.tapAt` 300, `selection.tapAt` 400; features add `text.tapAt`, `sticky.tapAt`, `spellcheck.tapAt`, `mathassist.tapAt`, `replay.tapAt` and custom-item edit (double-tap); plugins add `contributes.tapHandlers`.
3. Otherwise the touch goes to the **active tool**.

### 8.6 Apple Pencil hardware

`UIPencilInteraction` taps and squeezes, and `UIHoverGestureRecognizer`, are forwarded to `ui.pencilHandler` (F043). Every iOS 17.5+ symbol is guarded at the 17.0 deployment target: `pencilInteraction(_:didReceiveSqueeze:)` and `UIPencilInteraction.Tap` handling carry `@available(iOS 17.5, *)` on the method, and `UITouch.rollAngle` / `UICanvasFeedbackGenerator` are used behind `if #available(iOS 17.5, *)`. Users can bind double-tap/squeeze to any `PencilActionDescriptor` in `content.pencilActions`.

### 8.7 Palm rejection and finger drawing

Palm rejection and finger drawing are settings read by the canvas: `NibSettings.stylusMode`, `palmSensitivity` and `writingPosture`. Software palm rejection uses the touch's `majorRadius`.

---

## 9. Rendering

- **Scope.** `PageRenderer` (F004) renders tiles, thumbnails, previews and exports. Other features use it through `services.renderer`.
- **Tiles.** Each tile is 512 px, at a scale bucket equal to the next power of two of zoom × screen scale. Tiles live in an `NSCache` capped at min(192 MB, RAM/16). When `Changeset.dirtyRect` fires, only the dirty tiles are invalidated.
- **Order within a tile:**
  1. Background: the template `DisplayList`, a PDF page drawn with `CGContextDrawPDFPage` using one `CGPDFDocument` per worker, an image, or a colour.
  2. Items in z order, as bands:
     - Runs of solid pen/pencil strokes are drawn as one `PKDrawing.image`, under a light trait collection.
     - Highlighter runs use a multiply blend, switching to normal at 55% on dark paper.
     - Everything else goes through `ItemDrawer`s, looked up by `Item.drawKey`. Owners register them: `shape` (F031), `connector` (F032), `text` (F026), `image` (F034), `sticky` (F036), `math` (F060), `comment` (F037), `stroke.tape` (F033). Dashed strokes (`InkOutline`) and `custom` DisplayLists (`DisplayList.draw`) are drawn by F004 with the shared drawing code in `NibContracts/UI/Drawing.swift`, which export (F066), template thumbnails (F045), custom blocks and decorations reuse.
- **Drawer requirements.** Drawers must be thread-safe and pure: no main-actor access (never `NibApp`, `NibServices` or `LibraryService`) and no model reads beyond the item they are given; assets come from `DrawContext.assets`.
- **Templates** are parametric (`TemplateDefinition.render(params, size, scale)`). A blank page therefore costs a few hundred bytes, and whiteboard dot grids adapt to zoom.
- **Note Replay.** `RenderRequest.replay` / `DrawContext.replay` apply the spotlight, reveal and static modes by comparing each stroke's `t0` and point times with the replay time.
- **Memory.** On a memory warning, `purgeCaches()` runs and `Workspace.evictPages` drops cached pages that are not visible (F100).

---

## 10. Sync, backup and collaboration

| Need | Mechanism | Features |
|---|---|---|
| Same library on several devices | User-chosen folder in any Files provider; per-device files; watcher plus `remoteChanges` | F001, F002, F025 |
| Server of your own | WebDAV three-way mirror of the library folder | F069 |
| Status, errors, repair | Cloud & Backup panel, badges, repair tools | F070 |
| Backups | Manual zip; automatic to a second folder or WebDAV, as Nib and/or PDF | F068 |
| Live co-editing | `CollabTransport`: Multipeer on the local network (≤ 8 peers) or a self-hosted WebSocket relay (≤ 50) | F072, F092 |
| Offline | Always. The library is local-first; sync layers merge later. | — |

No path needs CloudKit, an App Group, APNs or a Nib server. An App Group is a **progressive enhancement** only (`AppGroup.containerURL`: AltStore/SideStore register groups even for free Apple IDs and rewrite the ids into Info.plist `ALTAppGroups`): when present, the share extension's inbox, the favourites widget and favourites.json use it; otherwise they fall back (pasteboard hand-off, static widget, dynamic quick actions). Live sessions stop when iOS suspends the app (~30 s after backgrounding); peers auto-rejoin on return. The limits of this approach (for example, no public web viewer) are listed in FEATURES.md.

---

## 11. Plugin runtime (summary; full API in PLUGIN_API.md)

**Package.** A plugin is a `<id>.nibplugin` zip or a folder: `manifest.json`, one bundled JS entry, and optional HTML panels and assets.

**Runtime (F077).** Each plugin gets its own `JSVirtualMachine` on its own queue. A ~200-line `prelude.js` builds `nib.*` on top of a single native bridge, `__nib_call`, that passes JSON strings. Every call becomes `bus.execute(Invocation(principal: .plugin(id), group: <call group>, readOnly: <caller's>, inheritedPolicy: <caller's>))`. `nib.storage` lives in `.nib-library/plugin-data/<id>/`, outside the hashed plugin folder.

**Host (F078).** The host maps manifest contributions to the same registries that native features use: commands, menus, toolbar, canvas tools and their option bars, panels, templates and covers, key bindings, settings, AI actions, AI instructions, importers, exporters, custom item types (with inspector and searchable text), tap handlers, text-document blocks, stroke processors, Pencil actions, command hooks, and content packs (elements, tape patterns, board templates).

**Trust (F079).** Plugins are installed from Files, a URL, a gallery index, or by the AI. The user consents to them. Their grant is device-local and bound to the sha256 of the installed package folder (sorted paths + contents; plugin data is outside it), so a plugin that arrives through a synced folder needs review before it runs, and `nib.storage` writes never invalidate the grant. Plugins can register new commands, and those commands become AI tools as well.

**Panels (F081).** HTML panels are WKWebViews served from `nib-plugin://<id>/…`, with the same API injected. They have no network access unless the plugin was granted it.

---

## 12. AI layer, MCP bridge and deep links (summary; full detail in AI.md)

**Providers (F083).** Nib speaks three wire protocols:

1. Anthropic Messages.
2. OpenAI-compatible Chat Completions: OpenAI, OpenRouter, Ollama, LM Studio, vLLM and others.
3. The Nib Agent Protocol over HTTP, for custom endpoints.

Keys are stored in the Keychain.

**Agent (F084).** The agent implements `AIService`. It exposes a fixed set of meta-tools (`nib_context`, `nib_get`, `nib_find`, `nib_search`, `nib_page_text`, `nib_render`, `nib_commands`, `nib_command_schema`, `nib_run`) plus configurable direct tools — built by `ToolCatalog` in NibContracts, which the bridge uses too — and loops until the model stops. Ask mode is `Invocation.readOnly`.

**Safety.** Every AI turn is one undo group; confirmations go through `Gateway`; provenance is recorded in `createdBy`. The chat UI lives in F085, and the parity AI features (F087–F089) are prompts and commands built on top of the agent.

**Bridge (F090, priority 1).** An `NWListener` serves MCP Streamable HTTP (JSON mode) plus a REST fallback. Callers present a bearer token and must connect from the LAN or Tailscale. Tool calls use the same `ToolCatalog`, with principal `.bridge(client)`; `tmp:` assets in results are served as `/api/v1/assets/<token>`. The bridge runs only while the app is in the foreground. It ships in wave 1 (with F003 and `render.page`) because it is the only way to inspect the sideloaded build without a Mac: `tools/smoke/*.json` scripts run through it.

**Deep links (F074):**

```
nib://open/<doc>[/<page>]          open a document / page (also the link format of internal text links)
nib://audio/<doc>/<clip>?t=<s>     play a clip at a time (audio links)
nib://quicknote                    new QuickNote
nib://new?kind=notebook|whiteboard|textDocument|studySet
nib://search?q=<text>
nib://plugin/install?url=<https url>   (always confirmed)
nib://bridge/pair?host=…&token=…   (shows the pairing sheet; never auto-enables)
nib://import?from=pasteboard       (share-extension hand-off when no App Group exists)
```

---

## 13. DI, registries and UI extension points

`NibApp` (one per process, `NibApp.shared`) is the composition root. Every feature receives it in `register`.

| Member | What it is |
|---|---|
| `app.commands` | `CommandRegistry` |
| `app.bus` | `CommandBus` (undo with rebasing and linked groups, commit observers, applyRemote, `hooks`: before-command hooks, as a hook command or (contracts-v2) a closure `handler`) |
| `app.gateway` | permissions, confirmation presenter, lock check |
| `app.workspace` | open documents; persistence is swappable |
| `app.events` | `EventBus` |
| `app.settings` | `SettingsStore` (typed `SettingKey`s, synced or device) |
| `app.services` | `NibServices`: library, assets, renderer, recognizer, pdf, ai, lock, sessions, `packages` (thread-safe PackageLocator), plus `set/get(ServiceKeys…)` |
| `app.content` | non-UI registries: templates, drawers, importers, exporters, aiActions, strokeProcessors, keyCommands, backgroundTasks, tapHandlers, boardTemplates, tapePatterns, elementCollections, blockKinds, customItemTypes, pencilActions, textLayouts (contracts-v2). Commands reach it as `ctx.content` |
| `app.ui` | UI registries and hooks (`ctx.ui` in commands; nil in headless runs) |

**UI extension points** (each is a `Registry<Descriptor>` keyed by id; re-registering an id replaces it; `unregister(owner:)` removes all of a plugin's or feature's entries):

| Extension point | Where it appears | Filled by (examples) |
|---|---|---|
| `ui.toolbar` (ToolbarItemDescriptor) | Document toolbar: lasso / tools / accessories / nav bar groups | pen F007, eraser F010, ruler F039, audio F052, plugins |
| `ui.toolMenus` (ToolMenuDescriptor) | Active-tool options bar | presets F008 for pen, pencil, highlighter, tape, shape |
| `ui.canvasTools` (CanvasToolDescriptor) | Tools selectable via `tool.select` | pen, pencil, highlighter, eraser, lasso, shape, drawShape, text, image, sticky, tape, laser, elements, plugin tools |
| `ui.menus` (MenuItemDescriptor, MenuLocation) | Object menu, page long-press, More, title, Add Page, Share & Export, library item/new/selection, app menu, sidebar page/selection, text selection, audio clip, block, card, board, outline entry, comment, transcript line, tab | every feature that has actions |
| `ui.panels` (PanelDescriptor) | Sidebar tabs, floating panels, sheets, library tabs | pages F023, outline F046, audio F052, layers F041, AI chat F085, gallery F080, calendar F075 |
| `ui.settingsPages` | Settings sections | nearly every feature |
| `ui.inspectors` (InspectorDescriptor) | Style editor for selected item kinds (optionally custom types via `drawKeys`) | text F026, shapes F031, plugin item types |
| `ui.editors` (DocumentEditorDescriptor) | Editor per document kind | canvas F006 (notebook, whiteboard), text doc F047, study set F049 |
| `ui.blockViews` | Text-document block kinds rendered by other features | tables F048, plugin custom blocks |
| `ui.canvasAttachments` (CanvasAttachmentDescriptor) | Persistent canvas overlays that can claim touches | handles F012, underlines F104, glow F106, presence F108, minimap F044, ruler F039, zoom box F038 |
| `ui.chromeOverlays` (ChromeOverlayDescriptor, contracts-v2) | Floating HUDs, bars, pills, panels and popovers. The document chrome renders them inside the window's one droplet container at a `ChromePlacement` (or `.anchored` to a page rect), in `order`. It fades them while the Pencil is down when `recedesWhileWriting` is set | recording HUD and playback bar F052, return-to-page pill F029, zoom pane F038, ruler angle F039, time keeper F062, presenter HUD F063, text popovers F026 |
| `content.textLayouts` (TextLayoutDescriptor, contracts-v2) | Where an item's text is laid out (container frame, base attributes), for link hit-testing and editors | text boxes F026, stickies F036, shape labels F031 |
| `content.tapHandlers` (TapHandlerDescriptor) | Finger tap / double-tap / long-press routed to commands before the tool | tape F033, comments F037, links F029, selection F011, plugins |
| `content.backgroundTasks` (BackgroundTaskDescriptor) | BGTaskScheduler work, registered by the shell at launch | index F055, backup F068, WebDAV F069 |
| `content.blockKinds`, `content.boardTemplates`, `content.tapePatterns`, `content.elementCollections`, `content.customItemTypes`, `content.pencilActions` | Slash/Turn Into menu, whiteboard frameworks, tape patterns, sticker packs, custom item metadata, Pencil bindings | F047/F048, F044, F033, F035, F078 (plugins and content packs) |
| `ui.screens` | libraryRoot, documentContainer, settingsRoot, onboarding, toolbarView (SwiftUI, hosted in the chrome's container; `toolbar` is superseded) | F019, F017, F027, F093, F016 |
| `ui.sceneHooks`, `ui.pencilHandler`, `ui.externalDisplay`, `ui.openGate` | Single hooks | F018, F043, F063, F071 |
| `content.keyCommands` | UIKeyCommands built by the shell (scopes global / library / document / canvas) | F073, owners of individual shortcuts |

**Live descriptor state** (contracts-v2). Descriptors are registered once and evaluated live by their host, so features never re-register to change a title or a checkmark:
- Toolbar items have `isEnabled`, `isOn`, `sessionParams`, `sessionTitle`, `sessionIcon` and `showsInCompactWidth`.
- Menu items have `isChecked`, `contextTitle` and a display-only `shortcut`. `MenuContext` carries `folder` and `textRange`.
- Key commands have `docKinds` and `sessionParams`.
- Panels get `PanelContext.params` (the `panel.open` params minus `id`) and `presentation`, and declare `providesHeader`.
- Settings pages declare `keywords`.

Hosts call `resolvedParams`, `resolvedTitle` and `resolvedIcon`. Well-known panel ids are in `PanelIDs`.

**Signals** (contracts-v2):
- A `Registry` counts changes in `generation` and posts `.nibRegistryDidChange` with `RegistryChange` userInfo (ids, owner, kind).
- `EditorSession.inking` (`InkingSignal`) is the one Pencil-down state per window. The canvas writes it; chrome, HUDs and attachments observe it. It replaces every `"chrome.inking.<session>"` key and `NibHaptics.isInking` poll.
- `EditorSession` also publishes `openPanels`, `temporaryReturnTool` (`selectTemporarily` / `finishToolUse(sticky:)`) and `editingTextRef` / `editingTextRange`.
- Events without an owner-specific schema have typed payloads (`NibEventPayload`: `SyncStatusPayload`, `IndexProgressPayload`, `AudioPlaybackPayload`, …), emitted with `events.emit(payload)` and read with `event.decode(_:)`.

**Shell fallbacks.** The shell falls back to minimal built-in screens whenever a provider is missing, so the app runs with any subset of features. That is what makes the CI green baseline possible.

---

## 14. Concurrency

- **Swift 5 language mode** with minimal strict-concurrency checking. Do not add `Sendable` conformances or `nonisolated(unsafe)`.
- **Main actor.** `NibApp`, `Workspace`, `CommandBus`, `CommandRegistry`, `DocTransaction`, `CommandContext`, `EditorSession`, `NibServices`, all `NibCommand`s and `NibFeature`s, all UI registries, and the `@MainActor` protocols (`DocumentPersistence`, `LibraryService`, `LockService`, `AIService`, canvas and plugin protocols) are main-actor isolated. Document state changes only on the main actor; that is the single-writer rule.
- **Background work.** Rendering, recognition, PDF work, file I/O, export, network and AI streaming run off the main actor:
  - Capture value snapshots on the main actor.
  - Do the work in a detached `Task` or on a dedicated queue.
  - Hop back with `await MainActor.run` or by calling a main-actor method, and commit through a command.
- **Thread-safe types.** `ItemDrawer`s, template `render` closures, `AssetStore`, `PDFService`, `PageRenderer`, `TextRecognizer`, `EventBus`, `SettingsStore`, `PackageLocator` and `Registry` must be thread-safe. Registries use a lock.
- **Off-main code never touches main-actor types.** Drawers, template closures, `AssetStore`, persistence I/O queues and renderers must not reach `NibApp`, `NibServices`, `LibraryService` or any other `@MainActor` type (a synchronous call from a nonisolated context is a compile error). Capture what they need at registration — e.g. `app.services.packages` for package URLs.
- **Commands must not block the main actor for more than 16 ms.** `mutate` bodies are synchronous and short. Move heavy computation before them.
- **Test classes** that touch `NibApp` or `Harness` are marked `@MainActor`. They must not override `setUp`; build a `Harness()` in each test. One `NibApp` per test is fine; sessions carry their own event bus (`EditorSession.events`), so two apps (two-device tests with `Harness(deviceID:)`) never cross-talk.

---

## 15. Rules for feature agents (what "done" means)

1. **Own only your files.** Write only the files listed for your feature in `forge-spec.json`. The scaffold creates stubs for your entry file, test file and declared resources, and you overwrite them. Any other shared change must go through a contract request (§16). Never edit `NibContracts`, the app shell or another feature's files.
2. **One public entry type.** Expose `public enum <EntryType>: NibFeature` with `static let id = "<key>"` from §3 (`<Module>Feature`, or the second entry type of a split feature). Keep everything else `internal`, unless a type must be public for SwiftUI previews (it rarely needs to be). The first half of a split feature never references the second half's types.
3. **Every user action is a command** that you own or that another feature owns.
   - UI code calls `app.perform` or `bus.run`, never `DocTransaction`.
   - Every command has a one-line summary written for an LLM, a flat schema, at least one example using `Fixtures` ids (all four fixture documents exist — see `Fixtures`), the correct `effect`, and `destructive`/`userPresence`/`sensitive`/`undoable` where they apply.
   - `.edit` commands must pass the conformance undo round trip; creating commands take `id?`/`ids?` (§6.1).
   - Register exactly the command ids §6.5 lists for your feature.
   - Writes of settings, Keychain entries and files under `.nib-library/` happen inside command handlers (lint warns otherwise), so the AI and plugins can do the same.
4. **Register, don't reach.**
   - Use menus, toolbar items, panels, settings pages, drawers, templates and key commands through the registries.
   - Use other features through command ids (`CommandIDs.*` or catalogue strings) or `services`.
   - Registries must not be read or services resolved inside `register`.
   - Anything on the canvas that is not your active tool is a `CanvasAttachment` (`ui.canvasAttachments`); taps you need to intercept are `TapHandlerDescriptor`s (`content.tapHandlers`) (§8.5).
5. **Settings** use `SettingKey`: `NibSettings.*` for shared settings, `"<key>.<name>"` for your own. Declare every one of your keys in `register` (`app.settings.declare(key, summary:, owner:, schema:)`, or `declarePrefix` for per-entry families) — conformance fails on undeclared keys. Use `synced: true` for user preferences that should follow the library, and device-local for hardware or UI state. A collection (list, map) is one key per entry, never one array. Only F097 reads `UserDefaults.standard` directly.
6. **Errors** are always `NibError` with a stable `code`, a human message, and, for parameter errors, a `path` and a `hint` saying what to call next. Never `fatalError` on user data. Log with `os.Logger(subsystem: "app.nib", category: "<key>")`.
7. **Undo** follows §6.1. **Provenance** is automatic and cannot be forged (`DocTransaction.put` stamps `createdBy` from the principal).
8. **Locked documents.** Check `services.lock?.isLocked(doc)` before exporting, sharing, backing up, mirroring (WebDAV), collaborating on or indexing a document. The gateway already blocks non-user principals.
9. **UI:**
   - Support iPad and iPhone size classes, Dynamic Type in panels, dark mode (paper is never inverted) and pointer hover.
   - Icon-only buttons need an `accessibilityLabel`.
   - User-visible strings use `String(localized:)`.
   - Take tokens, components and glass from `NibDesign` (§22). `Scripts/lint.py` rejects raw colours, fonts, radii, shadows, springs, materials and glass in UI modules.
10. **Tests.** Put pure logic in separate internal types and give it XCTest coverage in your test target. Use `Harness` for command tests (`@MainActor` test classes) and NibTesting's fakes for other features' services. Tests run hostless on the iOS simulator in CI (no app bundle, Info.plist, entitlements, microphone or camera); you cannot run them locally, so mirror existing patterns exactly and keep APIs to what CONTRACTS.md defines. Acceptance checks must be CI-assertable: time budgets are `XCTAssertLessThan(elapsed, budget × 4)` (never an unbaselined `measure {}`), and anything that needs a device is a `tools/smoke/*.json` script (F111), not a PR checklist. Cross-feature acceptance belongs in IntegrationTests (F111).
11. **Stay within contracts.** Do not invent contract APIs. If something you need is missing, file `docs/contract-requests/<Fxxx>-<slug>.md` describing the need, and ship a local workaround or `NibError.unsupported`.
12. **Before finishing, verify:**
    - `python Scripts/lint.py --feature Fxxx` exits 0. It checks only your feature's module, plus the spec and the docs.
    - The CI run on your branch `feat/Fxxx` is green (§19: your test target(s) only, plus the app build when you own app-target files). ConformanceTests and IntegrationTests run only on `main`, so also call `CommandConformance.check(features: [YourFeature.self])` in your own tests.
    - Every inventory item listed for your feature is either implemented, or reported in your final summary with the reason.
13. **System services and background work.**
    - Never call `BGTaskScheduler` directly: register a `BackgroundTaskDescriptor` in `content.backgroundTasks` (its id must be in project.yml `BGTaskSchedulerPermittedIdentifiers`) and schedule with `app.scheduleBackgroundTask`. The shell registers every identifier synchronously before `didFinishLaunching` returns (registering later throws `NSInternalInconsistencyException`).
    - Anything that may prompt for permission or touch `UNUserNotificationCenter`, `BGTaskScheduler`, Speech, microphone, camera, EventKit or Photos is either `userPresence: true` or checks `authorizationStatus` first and throws `unavailable`; it also returns `unavailable` when `NibApp.isHostlessTest` (these singletons crash in hostless tests).
    - Put such services (notifications, audio input, EventKit, Speech, WKWebView, Keychain) behind a small internal protocol your feature injects, so tests use an in-memory fake; secrets go through `Keychain` (Harness swaps in `InMemorySecretStore`).
14. **Platform notes (iOS 17.0 target, iOS 26 SDK).**
    - Liquid Glass (`glassEffect`, `GlassEffectContainer`, `.glass` button styles, `UIGlassEffect`) belongs to `NibDesign`, which guards it and falls back on iOS 17; features use `.droplet` / `nibGlass`. Guard every other iOS 26 symbol with `if #available(iOS 26, *)` / `@available(iOS 26, *)` and an iOS 17 fallback. Stay in Swift 5 language mode.
    - Bookmarks: `bookmarkData(options: [])` and `URL(resolvingBookmarkData:options: [], …)` with `startAccessingSecurityScopedResource()`/`stop…`; `.withSecurityScope` does not exist on iOS.
    - Guard every iOS 17.5+/18 symbol: `@available(iOS 17.5, *)` on `pencilInteraction(_:didReceiveSqueeze:)` and `UIPencilInteraction.Tap` handlers; `if #available(iOS 17.5, *)` around `UITouch.rollAngle` and `UICanvasFeedbackGenerator`; `#if canImport(ImagePlayground)` + `@available(iOS 18.1, *)`.
    - An App Intent `perform()` that touches `NibApp.shared` is `@MainActor`.
    - Shell: `UIKeyCommand.inputDelete` for Delete; `activateSceneSession(for:)` for new windows.

---

## 16. Contract change protocol

- `contracts-v1` is frozen once the scaffold is green. Only the architect or core owner may change `NibContracts`, and only between build waves.
- Changes must be **additive**: new types, new optional or defaulted fields, protocol requirements with default implementations in an extension, new enum cases only where every switch has a `default`. New stored fields in persisted model types must be Optional, or must have decode defaults, so older files still decode.
- Every change updates `CONTRACTS.md`, adds or updates a `NibContractsTests` case (and a line in `NameLookupCanaryTests` for every new public type), and bumps the tag (`contracts-v1.1`, …).
- Before `contracts-v1` is tagged, the name-lookup canary must compile: it uses every public contract name unqualified next to SwiftUI, Combine, Vision, PDFKit, PencilKit, WebKit, JavaScriptCore, Network, Speech, AVFoundation, EventKit, MultipeerConnectivity, NaturalLanguage, AppIntents, Charts and the rest. Names that clashed with SDK types were renamed up front (`NoResult`, `DocTransaction`, `ShapeItemStyle`, `TextRecognition`, the `Output` associated type); if `Point`/`Rect` ever clash, rename them to `PagePoint`/`PageRect` before the tag.
- Breaking changes are not allowed during fan-out. If one is unavoidable, keep the old signature and forward it to the new one.

---

## 17. Error conventions

`NibError` is the only cross-boundary error. The table lists each code and when to use it.

| Code | Use |
|---|---|
| `invalid_params` | Schema or decoding failure. Include `path`, plus a `hint` ("call commands.describe …"). |
| `not_found` | Unknown ref, command, page or asset. |
| `permission_denied` | Missing scope or exposure, a security command, or a plugin managing plugins. |
| `user_denied` | The user declined a confirmation. |
| `locked` | Password-locked document, non-user principal. |
| `conflict` | Stale write the caller should re-read, such as `plugin.install` of an older version. |
| `invariant_violation` | Payload doesn't match the kind, or an attachment or anchor is missing. The transaction rolls back. |
| `timeout` | Plugin handler, AI step or bridge confirmation took too long. |
| `unavailable` | A required service isn't installed or configured (no AI provider, feature disabled). |
| `unsupported` | Platform or format limits: newer document format, no image endpoint. |
| `internal` | Bugs. Log them. |

Errors travel to JS as rejected Promises (`err.code`, `err.message`, `err.path`, `err.hint`). To AI models they travel as tool results with `isError`, and to MCP clients as `isError: true` content.

---

## 18. Testing

| Layer | How |
|---|---|
| Contracts | `NibContractsTests`: fractional keys, revisions (incl. far-future distrust), the stroke codec, densify, lenient decoding of minimal JSON for every record and payload, transaction rollback, undo/redo, selective revert, last-writer-wins merge, gateway permissions, read-only enforcement, provenance, settings declarations, schema validation. `NameLookupCanaryTests`: every contract name compiles unqualified next to every SDK framework. |
| Every command | `ConformanceTests`: `CommandConformance.check(features: AllFeatures.list)` covers descriptor hygiene, feature ownership, duplicates, declared settings, caller-chosen ids, and runs every example of every `.edit` command with an undo round trip over all fixture documents: notebook `FIXTUREDOC01` (pages `FIXTUREPG001` with one item of every kind, `FIXTUREPG002`, PDF-backed `FIXTUREPG003`; outline `FIXTUREOUT01`; audio clip `FIXTUREAUD01` with transcript), text document `FIXTUREDOC02` (blocks `FIXTUREBLK01–03`, comment `FIXTURECMB01`), study set `FIXTUREDOC03` (cards `FIXTURECRD01/02`) and whiteboard `FIXTUREDOC04` (board `FIXTUREBRD01`). `undoable: false` commands must leave every undo stack unchanged; `unavailable`/`unsupported` results are skipped. |
| Feature logic | `<Module>Tests`: geometry, parsers, layout, schedulers, codecs, with Harness for command tests and NibTesting fakes (`FakeRenderer`, `FakeRecognizer`, `FakeAIService`, `FakePDFService`, `FakeLockService`, `InMemorySecretStore`, `FakeCanvasHost`, `InMemoryCollabTransport`) for other features' services. Module test targets link only their own module. |
| Cross-feature | `IntegrationTests` (F111, linked against every module): named scenarios for every acceptance line that spans features. |
| Plugins | `ExamplePluginsTests` (linked against every module, `FakeAIService` for `nib.ai`) runs the example plugins through the real runtime and host. |
| AI | Provider SSE fixtures replayed through a `URLProtocol` stub; the agent loop driven by a scripted fake provider. |
| Bridge | Golden JSON-RPC files through the transport-free `MCPHandler`. |
| On device | `tools/smoke/*.json` scripts (F111) run by Claude Code through the bridge (`node tools/smoke/run.mjs`, F090): Pencil latency, palm rejection, handwriting recognition, PencilKit cancellation (Draw-and-Hold), multiply blend, scrolling, rotation, AirPlay and Files-provider sync — they inspect the sideloaded build with `nib_context`, `nib_render` and `nib_run`. |
| Environment | Hostless `xcodebuild test` on the iOS simulator only (`swift test` on macOS/Linux is unsupported because NibContracts imports UIKit/PencilKit/SwiftUI); parallel testing off. |

---

## 19. CI and distribution

**Workflow** (`.github/workflows/ios.yml`, verbatim in CONTRACTS Part D). Every job runs on `macos-26` with `/Applications/Xcode_26.6.app` pinned through `sudo xcode-select`; the job fails with a clear message if the image no longer has it. Xcode 26.6 brings the iOS 26 SDK, which the locked UI needs for Liquid Glass. The deployment target stays iOS 17.0 and Swift stays in Swift 5 language mode, so every iOS 26+ API sits behind `#available`.

On `main`, on pull requests and on `workflow_dispatch`, two parallel jobs run:

- **test:** `brew install xcodegen` → `Scripts/make_icons.swift` → `Scripts/lint.py` (code rules + docs lint) → `xcodegen generate` → relay self-test when `tools/relay/relay.mjs` exists → pick a simulator whose runtime is not newer than the selected SDK → `xcodebuild test -scheme NibKit-Package -parallel-testing-enabled NO` in `NibKit/` → upload logs and the xcresult.
- **ipa** (independent, so an IPA is produced even when tests fail): xcodegen → `xcodebuild archive` (Release, `generic/platform=iOS`, `CODE_SIGNING_ALLOWED=NO`; the archive compiles the app, so there is no separate simulator build) → ad-hoc sign with the entitlements files (App Group, for sideloading tools that honour it) → `Nib-unsigned.ipa` (checks `Payload/Nib.app/PlugIns/NibWidgets.appex` exists) and `Nib-unsigned-noextensions.ipa` (widget and share extensions removed) → upload.

**Feature branches.** Each feature agent pushes `feat/<FeatureID>` (for example `feat/F012`). Those pushes run only the quick **feature** job, which gives a compile-and-test result for that one feature in minutes:

1. A small Python step looks up the branch's feature in `docs/forge-spec.json`. Its test targets are the `NibKit/Tests/<Target>/` folders of its `tests[]`. The step writes a `NibFeature` package scheme (`NibKit/.swiftpm/xcode/xcshareddata/xcschemes/`, git-ignored) that builds only those test targets and their dependencies: its own module, `NibContracts`, `NibTesting` and `NibDesign`.
2. `python3 Scripts/lint.py --feature <id>` checks that feature's module, the spec and the docs. Other modules are not linted.
3. `xcodebuild build-for-testing` and then `test-without-building` run with `-scheme NibFeature -only-testing:<Target>` on the picked simulator. If Xcode does not list the generated scheme, the job warns and falls back to `NibKit-Package`, which builds everything and is slower.
4. The app is built (`xcodegen` → `xcodebuild build -scheme Nib`, `generic/platform=iOS`, unsigned) only when the feature owns files under `Nib/`, `NibWidgets/` or `NibShare/`.
5. There is no ConformanceTests, IntegrationTests or ExamplePluginsTests run and no IPA; those run on `main` after the merge. The exception is F111 and F082, whose own test targets are IntegrationTests and ExamplePluginsTests and link every module.

**Caches.** SwiftPM checkouts (`build/SourcePackages`) are keyed on `Package.swift`. DerivedData (`build/DerivedData`) is keyed on the Xcode version plus a hash of `NibKit/`. Only the `main` test job saves DerivedData. Feature jobs restore main's latest copy read-only, so 111 branches cannot evict it from the 10 GB cache, and they compile only what differs from main. `Scripts/restore_mtimes.py` sets each file's mtime to its last commit time, and `IgnoreFileSystemDeviceInodeChanges` is set, so a fresh checkout does not invalidate the restored build. (ponytail: if this proves flaky, Xcode 26's `COMPILATION_CACHE_ENABLE_CACHING` is the content-addressed upgrade.)

**Triggers.** The workflow runs on pushes to `main` and `feat/**`, on every pull request, and on `workflow_dispatch`. Concurrency is one run per ref, and a new push cancels the one in progress.

**Sideloading.** The user sideloads the IPA with AltStore, SideStore or Sideloadly using a free Apple ID. That means 7-day re-signing, at most 3 sideloaded apps, and each extension counting as an extra App ID (use the no-extensions IPA when App IDs run short). Nothing relies on paid entitlements (no iCloud, no push); an App Group is used only when the sideloading tool provides one (§10). `BGTaskScheduler`, background audio, the local network, the camera, the microphone, speech, calendars, Face ID, the Keychain, App Intents and WidgetKit all work without paid entitlements. Re-signing with another team changes the Keychain access group: secrets then read as missing and features ask the user to re-enter them; the device id survives (Application Support).

**Minutes budget.** Keep the repo public (free macOS minutes), or restrict full runs to `main`.

---

## 20. Performance budgets

These are measured with `os_signpost` on a device; pure-code budgets are also asserted in CI with `XCTAssertLessThan(elapsed, budget × 4)` (F100 and the owning features — never an unbaselined `measure {}`, which cannot fail).

| Operation | Budget |
|---|---|
| Stroke finalize on main (bridge, processors, commit) | ≤ 2 ms p95 |
| Tile composite (512 px, ~150 strokes), off main | ≤ 8 ms |
| Page open to first paint (preview) / sharp | < 150 ms / < 400 ms |
| Lasso hit test over 5k strokes | < 16 ms |
| Decode and merge a 1k-stroke page | < 50 ms |
| Library listing of 5,000 documents (catalog) | < 300 ms |
| Resident memory with a 1,000-page PDF open | < 400 MB |

---

## 21. Top risks and mitigations

| Risk | Mitigation |
|---|---|
| Contracts are uncompilable (no Mac to check before CI) | The scaffold's first job is a green CI run with stubs. Contracts are frozen only after that, and fixes are made there before any fan-out. |
| PencilKit behaviour: cancelling a stroke mid-draw for Draw-and-Hold, `PKDrawing.image` off the main thread, the multiply `compositingFilter` on a wet canvas | On-device spikes in F006 and F007 first. Fallbacks: route held strokes through `.samples` mode; a single serial render thread; wet highlighter at 50% alpha. |
| ~110 features make CI slow | Feature branches build and test only their own target (generated `NibFeature` scheme) on top of main's cached DerivedData. The full suite and the IPA run on `main` as separate parallel jobs. SourcePackages are cached, the redundant simulator app build is gone, and parallel testing is off (the 7 GB runner cannot clone simulators). |
| Contract names clash with SDK types in client modules | Renamed up front (`NoResult`, `DocTransaction`, `ShapeItemStyle`, `TextRecognition`, `Output`); the name-lookup canary compiles every contract name next to every framework before `contracts-v1`. |
| `.nib` clashes with the Interface Builder UTI | Resolved: the package extension is `.nibnote` from day one (legacy `.nib` folders are imported). |
| Sideloaded reinstall deletes the app container | Onboarding puts the library outside the container; a banner warns while it is inside; the device id lives in Application Support. |
| File-provider latency and eviction (OneDrive, Dropbox) | Per-device files never conflict. Polling plus `NSFilePresenter`, pending-download badges, repair tools. |
| AI tool use on small local models | A fixed set of 9 meta-tools, flat schemas, examples, errors that carry hints, and a batch tool. |
| Features that cannot be done natively (personalised handwriting, math OCR, Wolfram-grade CAS) | Explicit substitutes: font-skeleton ink, AI vision, an on-device evaluator plus AI. Listed as partial in FEATURES.md. |
| Sideloading limits: 7-day signing, 3 apps, App IDs | Documented. CI also ships a no-extensions IPA; the widget and share extension are optional and can be removed from `project.yml` without code changes. |
| A plugin hangs JavaScriptCore | Watchdog plus Safe Mode. JavaScriptCore has no public interrupt; a hung thread leaks until relaunch. |

---

## 22. UI rules

- **Every UI feature imports `NibDesign`** and composes only its tokens (`NibColor`/`NibUIColor`, `NibFont`/`NibUIFont`, `NibSpacing`, `NibRadius`, `NibMetrics`, `NibMotion`, `NibHaptics`, `NibSymbol`), its components (`Nib*`) and its liquid modifiers (`.droplet`, `.budsFrom`, `.nibBudAnchor`, `nibGlass`, `nibCard`, `nibElevation`, `nibSheet`, `nibToast`, `nibBackdrop`). The list is DESIGN.md §15.
- **No hard-coded colours, fonts, radii, shadows, springs or durations**, no materials or glass, no SF Symbol strings, no emoji. `Scripts/lint.py` fails CI on them in every module with a ui/fullstack feature (DESIGN_SYSTEM.md §4); NibDesign itself is exempt. A missing token or component is a contract request (§16), never a local one "for now".
- **Follow DESIGN.md's per-screen specs (§14)** and pass its **Slop checklist (§16)** before review: one `NibDropletContainer` per window above the canvas, glass only on the floating layer, 44 pt targets, Reduce Motion / Reduce Transparency / Increase Contrast / Liquid Off, British English copy.
- **Check it on the gallery.** Settings › Advanced › Developer (`DesignGallery`) shows every token, component and droplet interaction in light and dark on a device.

# Nib — Contracts (shared source of truth)

This file holds the **exact** source that the scaffold agent creates **verbatim, byte for byte**, before any feature work starts. Every parallel feature agent compiles against it. It targets Swift 5 language mode, iOS 17.0 (deployment target), Xcode 26.6 and the iOS 26 SDK; every API newer than iOS 17.0 sits behind `#available`.

| Part | Contents | Owner after scaffold |
|---|---|---|
| **A** | `NibContracts` module (Model, Core, UI), `NibTesting` module, contract tests | Architect only (ARCHITECTURE.md §16) |
| **B** | `Package.swift`, generated feature lists, conformance tests | Regenerated from `forge-spec.json` |
| **C** | App shell (`AppDelegate.swift`, `ShellViewController.swift`) | Architect only |
| **D** | `project.yml`, CI workflow, `pick_sim.py`, `lint.py` | Architect only |

16,510 lines across 55 files. Every file starts with its repository path as a heading.

## How to use this file

- **Scaffold agent.** Create every file below at the given path, exactly as written. Then create the module stubs listed in `forge-spec.json` → `scaffold[2]` (one per feature entry type, including the second entry types of split features). Push, and do not start features until CI is green — including `NameLookupCanaryTests`, which proves no contract name clashes with an SDK type.
- **Feature agents.** Import `NibContracts` (and `NibTesting` in tests: Harness, Fixtures, fakes) and use only the API below. If something is missing, file `docs/contract-requests/<Fxxx>-<slug>.md`; do not edit these files.
- **Concurrency.** Everything marked `@MainActor` must be used from the main actor. Test classes that use `Harness` or `NibApp` are `@MainActor`.
- **contracts-v2.** The sources below are contracts-v2 (plus the additive contracts-v2.1 follow-up), an additive revision over contracts-v1. The "contracts-v2 changelog" section lists every new API by gap group, with the workaround in each feature that it replaces.

## contracts-v2 changelog

**contracts-v2.1** (branch `v2/contracts2`, additive). `CommandIDs` gains a constant for each of the 313 ARCHITECTURE.md §6.5 catalogue ids that had none (among them `settingsOpen`, `shapeTapAt`, `imagePick`, `pdfTapAt`, `pencilGesture`, `pencilPalette`, `pencilActions`, `layerExportOptions`, `outlineList`, `clipboardCopyText`, `toolbarDock` and `libraryReorder`). Each name is the id in camel case: `ai.chat.delete` → `aiChatDelete`. `PanelIDs` now matches the §13 panel id list: it gains `studySmartLearn = "studysession.smartLearn"`, which is the id F049 opens. `studyLearn` is superseded by it. It shipped as "studysession.learn", which no feature registers, and now holds the Smart Learn id. `PanelIDs` also gains `movePages = "pages.movePages"`, F022's Move Pages sheet. F023 opens it with `panel.open {id, pages}`. Adopt: F022's `MovePagesSheet` moves the refs in `PanelContext.params["pages"]` and falls back to the open page when there are none. The new `NibContractsTests/CommandCatalogueTests.swift` reads docs/ARCHITECTURE.md and fails when a §6.5 row has no `CommandIDs` constant, when a constant names an id that is not in the catalogue, or when `PanelIDs` differs from the §13 list. A spec change that adds a catalogue row or a panel id must add the constant in the same change.

contracts-v2 (branch `v2/contracts`) resolves the contract gaps the first 48 features reported (`tools/fleet/contract-gaps.md`, where every gap line now ends with `[v2: G<n> …]`, `[v2: rejected - …]` or `[v2: deferred - …]`). It is **additive over contracts-v1**: no public API was renamed, removed or re-signed; every new protocol requirement has a default implementation; new stored fields are optional or defaulted and decode leniently; superseded APIs keep working and carry a "Superseded in contracts-v2 by X" doc comment. Two behaviour changes are bug fixes: `DocTransaction.revert` (G4) and `CommandContext.inputFile` (G6); plus `Frame.applying` for rotated frames under non-uniform scale (G24). The sources in Part A below are the v2 sources; `NibContractsTests/ContractsV2Tests.swift` covers every fix and every new API.

Totals for the 368 gap lines: **220 resolved, 67 rejected, 81 deferred** (33 NibDesign, 12 catalogue rows in forge-spec, 11 app shell, 25 other owners or later design). 21 more gaps reported by fix agents and the design pass during the pass: 19 resolved, 2 deferred.

**How fix agents use this list.** For your feature, find its id below, delete the named workaround and call the v2 API instead; then re-run your tests (and `CommandConformance.check`). "Adopt" lines name owners that must implement a new hook (the default keeps today's behaviour until they do). Rejected and deferred gaps need no action from features.

### G1 — Commands reach the app and its registries

Gap: `CommandContext` exposed no `NibApp`, so commands could not read `content` / `ui` registries or the window; features published registries under untyped service keys or read `NibApp.shared`.

```swift
// CommandContext
public var app: NibApp? { get }
public var content: ContentRegistries { get }
public var ui: UIRegistries? { get }
public var navigator: SceneNavigator? { get }            // most recently active window
// CommandBus
public internal(set) weak var app: NibApp?
public internal(set) var content: ContentRegistries
// SceneNavigator (default: opens a new tab, i.e. shows it; the shell adopts the non-showing version)
func addTab(_ doc: DocumentID)
```

Replaces:
- F003 `NibKit/Sources/FeatQuery/QueryShapes.swift` `NibApp.shared` guarded by `app.bus === ctx.bus` → `ctx.app`, `ctx.navigator?.openDocuments`, `ctx.content.customItemTypes`.
- F005 `NibTemplates/TemplateCommands.swift` `TemplateCommands.registryKey` ("templates.registry") + `NibTemplatesFeature.swift` `services.set(app.content.templates, …)` → `ctx.content.templates`.
- F008 `FeatPresets/PresetCommands.swift` `PresetSetSwatch.tapePatterns` (NSMapTable CommandBus → Registry) and the `NibApp.shared?.content.tapePatterns` check → `ctx.content.tapePatterns`.
- F016 `FeatToolbar/FeatToolbarFeature.swift` `ToolbarRuntime.serviceKey` ("toolbar.runtime") + `ToolbarCommands.swift` `CommandContext.toolbarRuntime()` → `ctx.ui?.toolbar` / `ctx.app` (keep ToolbarRuntime only for window state).
- F022 `FeatPages/PageCommands.swift` `NibApp.shared?.content.template(ref)?.isCover` → `ctx.content.template(ref)?.isCover`.
- F033 `FeatTape/TapeCommands.swift` `TapeStore.serviceKey` ("tape.store") lookups of `content.tapePatterns` → `ctx.content.tapePatterns` (TapeStore stays for custom tiles and history).
- F038 `FeatZoomWindow/FeatZoomWindowFeature.swift` + `ZoomCommands.swift` `ZoomStore(templates: app.content.templates)` → `ctx.content.templates`.
- F018 `FeatWindows/SceneHooksImpl.swift` `maxRestoredTabs = 8` → `navigator.addTab(_:)` once the shell implements it (shell adoption: `ShellViewController.addTab` appends without building an editor).

### G2 — Read-only documents

Gap: the store published read-only documents as an untyped `NSMutableSet` under "store.readOnly".

```swift
// DocumentPersistence (default false)
func isReadOnly(_ doc: DocumentID) -> Bool
// Workspace / CommandContext / NibApp
public func isReadOnly(_ doc: DocumentID) -> Bool     // Workspace: persistence only; ctx and app also honour the legacy set
// ServiceKeys (legacy name of the NSSet, kept working)
public static let storeReadOnly = "store.readOnly"
```

Replaces: F001 `NibStore/NibStoreFeature.swift` `readOnlyKey` publication → implement `PackagePersistence.isReadOnly(_:)` (adopt), keep publishing the set until consumers move; F014 `FeatClipboard/ClipboardCommands.swift` `isReadOnly(_ ctx:)`, F042 and F070 `services.get("store.readOnly", as: NSSet.self)` → `ctx.isReadOnly(doc)` / `app.isReadOnly(doc)`.

### G3 — Event types and typed payloads

Gap: several events had no constant or payload schema (sync.status, index.progress, audio.*, shape.snapped, elements.changed, bridge.status), window switches and layer changes emitted nothing, and the library-changed rule was implicit.

```swift
public protocol NibEventPayload: Codable { static var eventType: String { get } }
public extension EventBus { @discardableResult func emit<P: NibEventPayload>(_ payload: P, principal: Principal? = nil, doc: DocumentID? = nil) -> NibEvent }
public extension NibEvent { func decode<P: NibEventPayload>(_ type: P.Type) -> P? }

public struct SyncStatusPayload: NibEventPayload, Equatable      // state, source, reason?, message?, files?
public struct IndexProgressPayload: NibEventPayload, Equatable   // running, done, total, pending
public struct LaserMovedPayload: NibEventPayload, Equatable      // page, point?, mode, color?, session?
public struct AudioPlaybackPayload: NibEventPayload, Equatable   // clip, t, playing, rate, at
public struct AudioRecordingPayload: NibEventPayload, Equatable  // clip, state, duration
public struct ShapeSnappedPayload: NibEventPayload, Equatable    // page, shape, point?, session?
public struct PencilHapticPayload: NibEventPayload, Equatable    // kind, page?, point?, session?

// NibEventType
public static let sessionActivated = "session.activated"   // SessionRegistry.add / activate / remove when `active` changes
public static let layersChanged = "session.layers"          // EditorSession.activeLayer / hiddenLayers didSet
public static let toolFinished = "tool.finished"            // EditorSession.finishToolUse
public static let indexProgress = "index.progress"
public static let audioPlayback = "audio.playback"
public static let audioRecording = "audio.recording"
public static let shapeSnapped = "shape.snapped"
public static let pencilHaptic = "pencil.haptic"            // anyone asks F043 for a Pencil Pro haptic
public static let elementsChanged = "elements.changed"
public static let bridgeStatus = "bridge.status"
```
`LibraryService` doc: implementations emit `library.changed` after every catalog change.

Replaces:
- F001 `NibStore/PackagePersistence.swift` `StoreStatus.payload(...)` JSON → `events.emit(SyncStatusPayload(...), doc:)`; F025/F070 decode with `event.decode(SyncStatusPayload.self)`.
- F055 `NibIndex/Indexer.swift` `IndexKeys.progressEvent` + `emitProgress` JSON → `IndexProgressPayload`; F056 subscribes to `NibEventType.indexProgress`.
- F040 `FeatLaser/FeatLaserFeature.swift` hand-built `payload` → `LaserMovedPayload`.
- F052 `FeatAudio/Player.swift` `emit("audio.playback", …)`, `Recorder.swift` `emit("audio.recording", …)` → the payload types; F053 reads them.
- F030 `FeatShapeRecognition/DrawShapeTool.swift` `ShapeRecognitionEvents.snapped` → `NibEventType.shapeSnapped` + `ShapeSnappedPayload`; F043 `FeatPencilHardware/PencilHandler.swift` `shapeSnapped` literal → the constant; F039 (ruler) and F012 (guides) emit `PencilHapticPayload` instead of `NibHaptics.play(.detent)` stand-ins.
- F035 `FeatElements/ElementCommands.swift` `ElementEvents.changed` → `NibEventType.elementsChanged`.
- F090 `NibBridge/NibBridgeFeature.swift` `BridgeController.statusEvent` → `NibEventType.bridgeStatus`.
- F015 `FeatUndoUI/UndoButtons.swift` `UIWindow.didBecomeKeyNotification` observer, F063 `FeatPresentation/FeatPresentationFeature.swift` `UIScene.didActivateNotification` re-reads → `NibEventType.sessionActivated`.
- F041 (canvas redraw on layer visibility) → `NibEventType.layersChanged`.

### G4 — Undo: revert rebasing and linked undo across documents

Gap (the F031 blocker, also F005, F026, F028, F029, F034, F036, F044, F049): `DocTransaction.revert` only reverted a record whose current revision equalled the stored after-revision, but reverting writes a fresh revision. So (a) a record written twice in one undo group (move then attach, debounced text commits, two meta writes) was only reverted to the middle state, and (b) the older of two consecutive undo entries on one record was silently skipped. Also, a change across two documents (page.moveTo) was two undo steps.

Fix: a revert pass remembers "the value that had revision r now lives at revision r'" per record (`RevRebase`, internal) and accepts r' for older mutations of that record; after every undo, redo and selective revert the bus rewrites the after-revisions stored in the remaining undo and redo entries the same way. Selective revert still skips records changed later by anyone else (`testSelectiveRevertStillSkipsRecordsChangedLater`). Non-undoable writes (`mutate(undoable: false)`) still count as later changes (F033's tape reveal, rejected).

```swift
// CommandContext: make this command's undo group one step across every document it changes
public func linkUndoAcrossDocuments()
// UndoEntry
public var linked: Bool
// UndoHistory
public func isLinked(_ group: String) -> Bool
// CommandBus.undo / redo: a linked entry also undoes (redoes) the same group in every other document where it is the latest step
```

Regression tests: `ContractsV2Tests.testAttachAfterMoveInTheSameGroupUndoesTheMoveToo` (F031's exact flow: commit observer attaches with `item.update` in the move's group), `testRecordWrittenTwiceInOneGroupIsFullyReverted` (item, page record and meta, F028/F005), `testConsecutiveUndosOnOneItem` (undo ×3, redo, interleaved), `testInsertCropFlipThenThreeUndosRemovesTheImage` (F034), `testLinkedUndoAcrossDocuments` (F022).

Replaces:
- F005 `NibTemplates/TemplateCommands.swift` `MetaChange` / `apply` (write each page and meta once per command) → write as needed.
- F026 `FeatTextBox` de-duplicated refs and one group per editing commit → plain writes; F036 `FeatSticky` draft-until-typing-ends sticky creation and once-per-session saves → allowed to autosave; F044 `FeatWhiteboard` write-once rule (board template re-centring can come back).
- F031 `FeatShapesTests.testDroppingAnItemIntoAShapeAttachesItInTheSameUndoStep` passes unchanged; F036 can restore its drop-to-attach criterion.
- F029 `FeatLinksTests.swift` (note about consecutive undo), F034, F036 and F049 tests that check one undo step at a time → may stack undos again.
- F022 `FeatPages` `page.moveTo`: call `ctx.linkUndoAcrossDocuments()` so one undo restores both documents (update its test, which today undoes each document separately).

### G5 — Writes: provenance-keeping moves, batch writes, fast paths

Gap: moving an item by a non-user principal re-stamped `createdBy`; per-item puts were O(page size) (scan + array copy), so page-wide edits and imports were quadratic; stroke points decoded through JSONDecoder.

```swift
// DocTransaction
@discardableResult public func put(_ item: Item, doc: DocumentID, page: PageID, keepingProvenanceFrom sourcePage: PageID, in sourceDoc: DocumentID? = nil) throws -> Item
@discardableResult public func move(item id: ElementID, doc: DocumentID, from source: PageID, to target: PageID, transform: Affine? = nil, z: String = "") throws -> Item
@discardableResult public func put(_ items: [Item], doc: DocumentID, page: PageID) throws -> [Item]
public func delete(items ids: [ElementID], doc: DocumentID, page: PageID) throws
@discardableResult public func put(_ blocks: [TextBlock], doc: DocumentID) throws -> [TextBlock]
@discardableResult public func put(_ cards: [StudyCard], doc: DocumentID) throws -> [StudyCard]
@discardableResult public func put(_ pages: [PageRecord], doc: DocumentID) throws -> [PageRecord]   // validates all first
@discardableResult public func put(_ entries: [OutlineEntry], doc: DocumentID) throws -> [OutlineEntry]
@discardableResult public func put(_ clips: [AudioClip], doc: DocumentID) throws -> [AudioClip]
// Stroke
public static func unpackFull(_ v: [Float]) -> [StrokePoint]
public static func unpackCompact(_ data: Data) -> [StrokePoint]
```
Workspace now keeps an id → index table per cached page (O(1) item lookups and in-place replacement) and writes records in place, so single puts no longer copy the page. Batch puts give records with an empty `order` (and items with an empty `z`) keys after the current last one, in array order, using balanced keys (`FractionalIndex.balanced`), so 10,000 appended cards get keys a few characters long. Undo, redo and rollback of a batch are linear too: consecutive record writes of one kind are reverted (or restored) in one pass (`testLargeCardImportUndoesRedoesAndRollsBackInOnePass`: 10,000 cards imported, re-edited in the same group, undone, redone, and a failed import rolled back).

Replaces:
- F003 `FeatQuery/NodeCommands.swift` node.move (ponytail "a non-user cross-page move stamps the mover as createdBy") → `tx.move(item:doc:from:to:)` (or `put(_:doc:page:keepingProvenanceFrom:in:)` across documents).
- F012 `FeatTransform` item.moveToPage re-put → `tx.move(item:doc:from:to:transform:)`; the drag commit over many items → one `tx.put(items, …)` (the 5,000-stroke nudge).
- F010 `FeatEraser/EraseCommands.swift` `EraseSupport.remove` → `tx.delete(items:doc:page:)` and `tx.put(items, …)` for the cut pieces.
- F051 `FeatStudyIO/StudyImporter.swift` appending into an existing set, and its `rows × (existing + rows) ≤ 25M` append cap → `tx.put(cards, doc:)` (drop the cap).
- F019/F020 PDF and image import (one `put(page)` per page, each re-sorting `livePages`) → `tx.put(pages, doc:)`; outline importers → `tx.put(entries, doc:)`.
- F001 `NibStore` PageReader's own points decoder → `Stroke.unpackCompact(_:)`.

### G6 — `CommandContext.inputFile` security fix and import naming

Gap: `case "https", "http" where principal.isUser` bound the `where` only to "http", so any plugin, AI or bridge caller could make https downloads with no network-scope check and no size limit; `tmp:` names were not validated; downloads were renamed `<UUID>-name`, and importers had no display name or caller-chosen ids.

Fix: non-user principals may download only `https`, only with the `network` scope, and plugins whose manifest the plugin host knows only from `network.hosts`; plain `http` is user-only; every download is capped at `NibLimits.maxDownloadBytes` (200 MB, 60 s timeout) and lands as `<tmp>/nib-downloads/<UUID>/<original name>`; `tmp:` names must be plain file names (no `/`, `\`, leading `.`).

```swift
public static let maxDownloadBytes = 200 * 1_048_576          // NibLimits
// ImportTarget
public var displayName: String?
public var ids: [NibID]?
public init(folder: FolderID? = nil, document: DocumentID? = nil, position: PagePosition = .end, anchorPage: PageID? = nil, displayName: String? = nil, ids: [NibID]? = nil)
```
Test: `ContractsV2Tests.testInputFileSecurity`.

Replaces: F003 `FeatQuery/AssetCommands.swift` `AssetBytes.load` checks (plugin network, `maxInputBytes`, tmp names) → rely on `ctx.inputFile`; F024 `NibPDF/PDFImporter.swift` and F051 `FeatStudyIO/StudyImporter.swift` "<UUID>-" prefix stripping → no longer needed (keep reading `lastPathComponent`, or `target.displayName`). Adopt: F064 `import.files` fills `ImportTarget.displayName` (original name without extension) and `ids`.

### G7 — Templates: region rendering, metrics, boards

Gap: templates rendered whole pages only, published no grid spacing, margins or repeat period, and the board size semantics were unstated.

```swift
public struct PageInsets: Codable, Hashable { public var top, left, bottom, right: Double }
public struct TemplateMetrics: Equatable { public var spacing: Double?; public var margins: PageInsets?; public var repeatPeriod: PageSize? }
// TemplateDefinition
public var renderRegion: ((_ params: [String: JSONValue], _ size: PageSize, _ scale: Double, _ region: Rect) -> TemplateRender)?
public var metricsProvider: ((_ params: [String: JSONValue], _ size: PageSize?) -> TemplateMetrics)?
public func renderOps(_ params: [String: JSONValue], size: PageSize, scale: Double, region: Rect?) -> TemplateRender
public func metrics(for params: [String: JSONValue], size: PageSize?) -> TemplateMetrics
public enum TemplateIDs { blank, dots, grid, graph, isometric, ruled, ruledNarrow, ruledWide, cornell, legalPad, whiteboardDots, whiteboardGrid, whiteboardLines }   // "builtin.<name>"
public enum TemplateParamNames { paper, line, spacing, margin, color }                     // static let String constants
```
Patterns are anchored at the page origin; boards call `renderRegion` with each tile's world rect (else `render` with the tile size, tiles aligned to `repeatPeriod`, 240 pt when nil). Without a provider, `metrics` reads the "spacing" and "margin" params.

Replaces: F004 `NibRender/DisplayListRenderer.swift` `boardPeriod = 240` → `metrics(...).repeatPeriod` and `renderOps(..., region:)`; F005 `NibTemplates/WhiteboardGrids.swift` `fineDotBudget` → set `renderRegion` (and `metricsProvider`) on its templates; F012 `FeatTransform` GuideEngine grid read from the DisplayList → `metrics(for:size:).spacing`; F028 `FeatPageText/PageTextCommands.swift` page-proportional margins → `metrics(...).margins`. F044 `FeatWhiteboard/WhiteboardCreateSheet.swift` `BoardPattern.candidates` and `WhiteboardCommands.swift` `Whiteboard.dotsTemplate` literals, and the "paper" / "line" param names (`MinimapView.swift` paper colour) → `TemplateIDs` / `TemplateParamNames`; F005 `NibTemplates/PaperTemplates.swift` param names → the same constants.

### G8 — DisplayOp text alignment and weight

```swift
public var align: ParagraphAlignment?          // DisplayOp
public var weight: DisplayFontWeight?          // DisplayOp (system font only)
public enum DisplayFontWeight: String, Codable, CaseIterable { case light, regular, medium, semibold, bold, heavy }
```
`DisplayList.draw` honours both. Replaces: F005 planner headings, weekday names and day numbers drawn left-aligned regular → set `align` / `weight`.

### G9 — Per-page content revision

```swift
func contentRevision(_ doc: DocumentID, page: PageID) -> Rev?        // DocumentPersistence, default nil
public func contentRevision(_ doc: DocumentID, page: PageID) -> Rev? // Workspace: cached page max rev, else persistence
```
Replaces: F004 thumbnail key that loads a page's items to compute the max rev → `workspace.contentRevision(doc, page:)` (falls back to loading when nil). Adopt: F001 implements `PackagePersistence.contentRevision` from its page files.

### G10 — Workspace cache accessors

```swift
public func isPageCached(_ doc: DocumentID, page: PageID) -> Bool
public func cachedPages(_ doc: DocumentID) -> Set<PageID>
public func peekContent(_ doc: DocumentID) throws -> DocumentContent   // no caching, no doc.opened
```
Replaces: F005 `NibTemplates/TemplateCommands.swift` `evictPages(t.doc, keeping: all pages minus that one)` → evict only pages that were not in `cachedPages` before; F020 `FeatLibraryOrganize` heads cache (bookmarked and trashed pages of documents never opened) → `peekContent` per document.

### G11 — Registry change signals

```swift
public var generation: UInt64                  // Registry
public enum RegistryChange {                   // userInfo of .nibRegistryDidChange posted by a Registry
    public static let idsKey, ownerKey, kindKey, generationKey: String
    public static let registered, replaced, unregistered: String
    public static func ids(_ note: Notification) -> [String]
}
public private(set) var isStarted: Bool         // NibApp, true after start(_:)
```
Replaces: F004 `NibRender` "drop every tile on any drawer/template registration" → drop only pages whose background template id or item draw keys are in `RegistryChange.ids(note)`, and ignore changes before `app.isStarted` for disk thumbnails.

### G12 — Chrome overlays (floating HUDs), the inking signal, the SwiftUI toolbar

Gap (blocked F052; worked around by F029, F038, F039, F044, F062, F063, F016, F017, F026, F008, F037): no chrome extension point for floating HUDs, bars or popovers, no hand-off of the Pencil-down state, and the toolbar was a UIView in a second droplet container.

```swift
public enum ChromePlacement: String, Codable, CaseIterable { case topLeading, top, topTrailing, leading, trailing, center, bottomLeading, bottom, bottomTrailing, anchored }
public enum ChromeSurface: String, Codable, CaseIterable { case hud, bar, pill, panel, popover, none }
public enum ChromeAnchor: Equatable { case page(PageID, Rect); case window(CGRect) }
public struct ChromeContext { public var app: NibApp; public var session: EditorSession; public var navigator: SceneNavigator?; public var kind: DocumentKind?; public var isCompact: Bool }
public struct ChromeOverlayDescriptor: Registrable {
    public init(id: String, owner: String, placement: ChromePlacement, surface: ChromeSurface = .hud, order: Int = 0,
                recedesWhileWriting: Bool = true, isInteractive: Bool = true, docKinds: Set<DocumentKind>? = nil,
                isVisible: @escaping @MainActor (ChromeContext) -> Bool = { _ in true },
                anchor: (@MainActor (ChromeContext) -> ChromeAnchor?)? = nil,
                makeView: @escaping @MainActor (ChromeContext) -> AnyView)
}
// UIRegistries
public let chromeOverlays: Registry<ChromeOverlayDescriptor>
public func visibleChromeOverlays(_ context: ChromeContext) -> [ChromeOverlayDescriptor]   // bottom-most first
public func setNeedsChromeUpdate(_ session: EditorSession? = nil)                        // posts .nibChromeNeedsUpdate
// EditorSession (not @Published, so Pencil down never re-evaluates SwiftUI bodies)
public let inking: InkingSignal
@MainActor public final class InkingSignal {
    public private(set) var isInking: Bool; public private(set) var strokeBounds: CGRect?   // window coordinates
    public func begin(strokeBounds: CGRect? = nil); public func update(strokeBounds: CGRect); public func end()
    @discardableResult public func observe(_ handler: @escaping @MainActor (InkingSignal) -> Void) -> EventSubscription
}
// ScreenRegistry (the chrome prefers it; `toolbar` is superseded)
public var toolbarView: (@MainActor (EditorSession, NibApp) -> AnyView)?
// The window's floating host (NibDesign's NibFloatingHost behind a protocol): popovers, HUDs and toasts from UIKit
// code and canvas attachments, INSIDE the window's droplet container
@MainActor public protocol FloatingHosting: AnyObject {
    func present(_ id: String, content: AnyView); func dismiss(_ id: String); func isPresenting(_ id: String) -> Bool
    @discardableResult func setAnchor(_ id: String, rect: CGRect, in view: UIView) -> Bool; func removeAnchor(_ id: String)
    func containerRect(_ rect: CGRect, from view: UIView) -> CGRect?
    func postToast(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?)
}
public extension FloatingHosting { func present<Content: View>(_ id: String, @ViewBuilder content: () -> Content); func postToast(_ message: String) }
public weak var floatingHost: FloatingHosting?          // EditorSession, set by the container's owner (F017, F019)
var floatingHost: FloatingHosting? { get }               // SceneNavigator (default session.floatingHost)
@MainActor public var floatingHost: FloatingHosting?     // ChromeContext (session.floatingHost)
// ToolMenuDescriptor: the options bar's own popover, handed to NibDesign's NibToolOptions(bar:popover:)
public var makePopover: (@MainActor (EditorSession) -> ToolMenuPopover?)?
public struct ToolMenuPopover { public var source: String; public var isPresented: Binding<Bool>; public var title: String; public var subtitle: String?; public var content: AnyView }
```
NibDesign's `NibFloatingHost` already has every `FloatingHosting` member except `present(_:content: AnyView)` and `postToast`. So NibDesign (or F017, in an adapter) conforms it in two lines. `ToolMenuPopover` mirrors `NibToolOptionsPopover` field for field.
The document chrome (F017) renders every visible overlay inside the window's one `NibDropletContainer`, in `order` (z-order), at its placement (an `.anchored` overlay follows its page rect through the canvas, or a window rect), with the NibDesign surface for its `surface`, receding to the recede opacity while `session.inking.isInking` when `recedesWhileWriting`. It re-evaluates `isVisible` on registry changes, session changes and `.nibChromeNeedsUpdate`.

Adopt: F017 (render `ui.chromeOverlays`, mirror `session.inking` into its `NibInkingState`, host `screens.toolbarView` in its container, place a `NibFloatingLayer` and set `session.floatingHost`); F019 (the same host for the library window); F016 (pass `makePopover` to the palette as `NibToolOptions.popover`); F006/F101 canvas (write `session.inking` begin/update/end).

Replaces:
- F052 `FeatAudio/AudioPanel.swift` `RecorderView` + playback bar living in the sidebar tab → a `.top` `.hud` overlay (recording) and a `.bottom` `.bar` overlay (playback).
- F029 `FeatLinks/LinkNavigator.swift` `ReturnToPageAttachment` (standalone `.droplet(style: .hud)` on the canvas) → `.bottom` `.pill` overlay.
- F038 `FeatZoomWindow` pane (static `nibGlass(.deep)` in `canvasView.superview`) → `.bottom` `.panel` overlay (the zoom box stays a CanvasAttachment).
- F039 `FeatRuler/RulerView.swift` angle HUD in a UIHostingController on the canvas → `.top` `.hud` overlay.
- F062 `FeatTimeKeeper/TimeKeeperView.swift` `TimeKeeperBarAttachment` → `.bottom` `.bar` overlay; its `NibHaptics.isInking` polling → `session.inking.observe`.
- F063 `FeatPresentation/FeatPresentationFeature.swift` `PresenterHUDAttachment` → overlay; mirror pausing → `session.inking`.
- F044 `FeatWhiteboard` minimap fade, F058 `FeatSmartInk/FeatSmartInkFeature.swift` `NibHaptics.isInking` → `session.inking`.
- F016 `FeatToolbar/FeatToolbarFeature.swift` `screens.toolbar = { ToolbarHostView(...) }` and `ToolbarView.swift` `inkingKey` ("chrome.inking.<session>") → `screens.toolbarView`; F017 `FeatDocChrome/ChromeCommands.swift` `ChromeStateStore.inkingKey` publication → `session.inking`.
- F026 `FeatTextBox` UIKit popovers (More, font picker) and F037 `FeatComments` thread panel opened through `panel.open` → `session.floatingHost` (`setAnchor(_:rect:in:)` + `present`), or `.anchored` `.popover` overlays.
- F008 `FeatPresets` inline options-bar modes (thickness slider, colour editor inside the bar) → `ToolMenuDescriptor.makePopover`.
- F020 and other library tabs announcing results to VoiceOver instead of toasting → `navigator.floatingHost?.postToast(_:)`.

### G13 — Shared settings keys

```swift
// NibSettings (declared by NibApp.init; the owning feature may re-declare the same name)
public static let liquidMode = SettingKey("appearance.liquid", default: "full")                 // full | calm | off
public static let defaultTextStyle = SettingKey("text.defaultStyle", default: TextBoxStyle(), synced: true)
public static let drawAndHold = SettingKey("shapes.drawAndHold", default: true, synced: true)
public static let eraserMode = SettingKey("eraser.mode", default: "standard", synced: true)      // precision | standard | stroke
public static let eraserSize = SettingKey("eraser.size", default: 14.0, synced: true)           // screen points
public static func eraserFilter(_ tool: InkTool) -> SettingKey<Bool>                            // "eraser.filter.<tool>"
public static let penReactsToRoll = SettingKey("pen.reactToRoll", default: true, synced: true)
public static let toolbarLayout = SettingKey<ToolbarLayoutSetting?>("toolbar.layout", default: nil, synced: true)
public struct ToolbarLayoutSetting: Codable, Equatable { public var order: [String]; public var hidden: [String] }
// writingPosture doc pinned: value = hand × 4 + wrist (hand 0 right, 1 left; wrist 0 below, 1 angled, 2 level, 3 hooked)
// TextBoxStyle
public var align: ParagraphAlignment?
public var lineSpacing: Double?
public static let maxErasePathPoints = 20_000                                                   // NibLimits
```
Replaces: F014 `FeatClipboard/ClipboardCommands.swift` `defaultStyleSettings` ("text.defaultStyle", "text.styles.default") → `NibSettings.defaultTextStyle`; F026 `FeatTextBox/TextCommands.swift` `SavedTextStyle` align/lineSpacing side keys → `TextBoxStyle.align` / `lineSpacing` (same JSON keys, so stored styles still decode); F016 hard-coded Liquid `.full` → `NibSettings.liquidMode`; F009 `FeatHighlighter` and F030 `FeatShapeRecognition` → read `NibSettings.drawAndHold` without declaring it; F038 `FeatZoomWindow/AutoAdvance.swift` untyped eraser keys and point limit, F043 `toolOptions["eraser"]` guess → the eraser keys and `NibLimits.maxErasePathPoints` (F010 `EraserGeometry.maxPathPoints` → the constant); F043 `FeatPencilHardware/FeatPencilHardwareFeature.swift` `PencilSettings.reactToRoll` literal → `NibSettings.penReactsToRoll`; F043 lenient `toolbar.layout` read → `NibSettings.toolbarLayout`; F027 writing posture → the pinned layout.

### G14 — Canvas and drawing contracts

```swift
// CanvasHost (defaults in an extension; the canvas F006/F101 overrides)
func afterNextRender(page: PageID, _ body: @escaping @MainActor () -> Void)     // default: after 150 ms
func pageTransform(_ page: PageID) -> CGAffineTransform?                         // page → canvasView
func convert(_ point: Point, from source: PageID, to target: PageID) -> Point?
var fixedOverlayView: UIView { get }                                             // default canvasView.superview
func finishToolUse(_ tool: CanvasTool)
func commitStroke(_ stroke: Stroke, page: PageID, completion: @escaping @MainActor (Result<ElementID?, NibError>) -> Void)
// CanvasAttachment (defaults)
func hitTest(_ viewPoint: CGPoint, isPencil: Bool, host: CanvasHost) -> Bool     // canvas calls this; default → hitTest(_:host:)
func hover(_ sample: CanvasSample?, host: CanvasHost)
func gesture(_ gesture: CanvasGesture, at sample: CanvasSample, host: CanvasHost) -> Bool   // false = pass on to tap handlers
// CanvasSample
public var touchID: Int                                                          // init(..., touchID: Int = 0)
// DocumentEditing (default: reveal(page: block, …))
func reveal(block: NibID, animated: Bool)
// ItemDrawer (defaults nil)
func hitBounds(_ item: Item) -> Rect?
func paintBounds(_ item: Item) -> Rect?
// ContentRegistries
public let textLayouts: Registry<TextLayoutDescriptor>
public func textLayout(for item: Item) -> TextLayoutInfo?
public func hitBounds(for item: Item) -> Rect
public func paintBounds(for item: Item) -> Rect        // default Item.bounds grown by NibLimits.drawerMargin
public struct TextLayoutInfo: Equatable { public static let lineFragmentPadding: Double; public var container: Frame; public var base: TextAttributes; public var centredVertically: Bool }
public struct TextLayoutDescriptor: Registrable { public init(key: String, owner: String, order: Int = 0, layout: @escaping (Item) -> TextLayoutInfo?) }
// DrawContext (init gains purpose: .screen, annotations: true, paper: nil)
public let purpose: DrawPurpose; public let annotations: Bool; public let paper: RGBA?
public enum DrawPurpose: String, Codable, CaseIterable { case screen, thumbnail, export, query }
public var purpose: DrawPurpose                          // RenderRequest
public static let drawerMargin: Double = 12             // NibLimits
```
Doc clarifications: `canvasView` is the scroll view and `viewPoint`/`pageFrame` use its bounds coordinates; `cancelWetStroke` is idempotent and may be called from `strokeFinished`; a touch claimed by an attachment never pans, zooms or inks; the canvas owns `UIPencilInteraction` and forwards through `ui.pencilHandler` (squeeze locations in `canvasView` coordinates); a bound Pencil action gets `{gesture, doc, page?, at?}` with its own params merged over.

Adopt: F006/F101 (implement the CanvasHost hooks precisely, call `hitTest(_:isPencil:host:)`, `hover`, `gesture`, fill `touchID`); F004 (culling/invalidation with `paintBounds(for:)`, pass `purpose`/`annotations`/`paper`); F026, F036, F031 register `TextLayoutDescriptor`s for text, sticky and shape labels.

Replaces:
- F010 `FeatEraser/EraserTool.swift` ~150 ms preview hold, F012 `FeatTransform/DragController.swift` `settleNanoseconds` (120 ms), F030 `FeatShapeRecognition/DrawShapeTool.swift` `previewHandOff` (300 ms), F033 `FeatTape/TapeTool.swift` `dryHandoff` (0.25 s) → `host.afterNextRender(page:) { … }`.
- F012 `FeatTransform/DragController.swift` `extension CanvasHost { func pageToView(_:) }` → `host.pageTransform(_:)`; F010 dropping samples on other pages → `host.convert(_:from:to:)`.
- F012 invisible hover view with UIPointerInteraction, F032 `FeatDiagrams/ConnectorEditor.swift` UIHoverGestureRecognizer → `CanvasAttachment.hover`.
- F012 `FeatTransform/SelectionHandles.swift` `forwardTap`, F031 taps on selected shapes → return false from `gesture(_:at:host:)`.
- F039 `FeatRuler/RulerView.swift` `RulerGesture` nearest-finger matching → `CanvasSample.touchID`; `RulerProcessor.swift` 6 pt Pencil band → `hitTest(_:isPencil:host:)`.
- F038 and F062 `canvasView.superview` hosting → `host.fixedOverlayView`.
- F033 history recorded even when `ink.addStrokes` fails → `commitStroke(_:page:completion:)`.
- F047 `FeatTextDoc/TextDocViewController.swift` block id passed as a page id → its `reveal(block:animated:)` now satisfies the requirement; callers use `editor.reveal(block:animated:)`.
- F036 collapsed-note hit area → `StickyDrawer.hitBounds`; F031 `FeatShapes/ShapeDrawer.swift` reliance on F004's undocumented 12 pt margin and F032 `FeatDiagrams/ConnectorDrawer.swift` 6 pt stub limit → `NibLimits.drawerMargin` / `paintBounds` (labels, arrowheads, curve bulges); F032 label knock-out colour → `context.paper`.
- F036 (`collapsed` flag as export flag) and F037 (pins drawn in every render) → `context.purpose == .export` / `context.annotations`.
- F029 `FeatLinks/LinkNavigator.swift` assumed insets (`TextBoxStyle.padding`, lineFragmentPadding 0, 6 pt tolerance) → `ctx.content.textLayout(for: item)`.
- F028 full-page boxes: F026's drawer can return the laid-out text from `hitBounds` so the lasso stops catching the page-sized box.

### G15 — Session state: temporary tools, finished tools, open panels, text focus

```swift
// EditorSession
@Published public var openPanels: Set<String>
@Published public private(set) var temporaryReturnTool: String?
public var editingTextRef: String?          // item/block/card being edited while isEditingText
public var editingTextRange: [Int]?         // [start, length] in plain-text units
public func selectTemporarily(_ tool: String)
public func endTemporaryTool()
public func selectTool(_ tool: String)      // what tool.select does: clears a pending temporary return
public func finishToolUse(sticky: Bool)     // back to temporaryReturnTool, else previousTool when not sticky; emits tool.finished
// tool.select gains {temporary?: Bool}
```
Replaces: F011 `FeatLasso/SelectionCommands.swift` `toolOptions["lasso"]["returnTool"]` (`returnToolKey`) → `selectTemporarily` / `endTemporaryTool` (or `tool.select {tool, temporary: true}`); F010 `EraserTool.swift` auto-deselect `tool.select(previousTool)`, F034 `FeatImages/ImageTool.swift` manual return, F016 "hand back after one commit" → `host.finishToolUse(self)`; F017 `FeatDocChrome/ChromeCommands.swift` "chrome.state" open-panel store (for query.context) → `session.openPanels`; F029 `FeatLinks/LinkEditorSheet.swift` first-responder `selectedRange` probing → `session.editingTextRef` / `editingTextRange` (text editors F026, F036, F031, F047, F049 set them, adopt).

### G16 — Live descriptor state and command conventions

```swift
// ToolbarItemDescriptor (vars, set after init)
public var isEnabled: (@MainActor (EditorSession) -> Bool)?
public var isOn: (@MainActor (EditorSession) -> Bool)?
public var sessionParams: (@MainActor (EditorSession) -> JSONValue)?
public var sessionTitle: (@MainActor (EditorSession) -> String)?
public var sessionIcon: (@MainActor (EditorSession) -> String)?
public var showsInCompactWidth: Bool
public func resolvedParams(for session: EditorSession) -> JSONValue
public func resolvedTitle(for session: EditorSession) -> String
public func resolvedIcon(for session: EditorSession) -> String
// MenuItemDescriptor (vars)
public var isChecked: (@MainActor (MenuContext) -> Bool)?
public var contextTitle: (@MainActor (MenuContext) -> String)?
public var shortcut: KeyShortcut?                                     // display only
public func resolvedTitle(for context: MenuContext) -> String
// MenuContext (init gains folder:, textRange:)
public var folder: FolderID?
public var textRange: [Int]?
// KeyCommandDescriptor (vars; the shell adopts: filter by docKinds, pass resolvedParams(for: session))
public var docKinds: Set<DocumentKind>?
public var sessionParams: (@MainActor (EditorSession) -> JSONValue)?
public func resolvedParams(for session: EditorSession?) -> JSONValue
// PanelContext / PanelDescriptor / SettingsPageDescriptor
public var params: JSONValue                                          // panel.open params minus id
public var presentation: PanelPresentation?
public enum PanelPresentation: String, Codable, CaseIterable { case sidebar, window, floating, sheet, fullScreen, libraryTab }
public var providesHeader: Bool
public var keywords: [String]
// CommandContext session defaults (user callers may omit doc / page / refs)
public func documentOrSession(_ ref: String?, field: String = "doc") throws -> DocumentID
public func pageOrSession(_ ref: String?, field: String = "page") throws -> (doc: DocumentID, page: PageID)
public func refsOrSelection(_ refs: [String]?) -> [String]
```
`edit.undo` / `edit.redo`: `doc` may be omitted by the user (the invoking window's document); the schema still requires it for the AI, plugins and the bridge. §6.1 now pins the param conventions (session defaults, `position`/`anchor`, `[width, height]` sizes, frames with an optional 5th rotation value, TemplateRef JSON, page-point deltas, seconds for media time, `panel.open {id, params?}`, `ai.ask` → AIResponse JSON).

Adopt: F016/F017 (evaluate the toolbar live state, pass `PanelContext.params`/`presentation`, honour `providesHeader`), the menu hosts (checkmarks, `contextTitle`, shortcut labels), the app shell (key command `docKinds` and `resolvedParams`), text editors (fill `MenuContext.textRange`), F027 search (`keywords`).

Replaces:
- F015 `FeatUndoUI/UndoButtons.swift` `UndoChrome` re-registering toolbar items and key commands with `{doc}` and "Undo <label>" titles → one registration with `sessionParams`, `sessionTitle`, `isEnabled`; `edit.undo {}` works from key commands.
- F046 `FeatOutline` no bookmark toolbar item → a nav item with `isOn`, `sessionParams` and `sessionIcon`; `OutlineCommands.swift` `PageSetBookmarked.Params` optional decode → `ctx.pageOrSession`.
- F038, F042, F062 on/active state → `isOn`; F015 compact width → `showsInCompactWidth`.
- F012, F014 (`clipboard.copy`/`cut`/`paste`, `item.duplicate`), F046, F042 optional-refs defaults → `ctx.refsOrSelection` / `ctx.pageOrSession`.
- F017 `FeatDocChrome/FeatDocChromeFeature.swift` "Scroll Horizontally/Vertically" opposite-only entry, F022 Before/After/Last submenus, F032 route submenu, F063 `FeatPresentation/FeatPresentationFeature.swift` paired checked/unchecked entries → one entry with `isChecked`.
- F041 `FeatLayers/FeatLayersFeature.swift` re-registering Move to Layer titles, F028 `FeatPageText/FeatPageTextFeature.swift` "pagetext.start"/"pagetext.edit" pair → `contextTitle`.
- F047 `FeatTextDoc/FeatTextDocFeature.swift` "textdoc.new" key command registered for the shortcut label → `MenuItemDescriptor.shortcut`; its `nib://new` deep-link workaround → `sessionParams` with a fresh id (after shell adoption).
- F049 `FeatStudyEditor/StudySetViewController.swift` UIKeyCommands → `KeyCommandDescriptor.docKinds` (after shell adoption).
- F020 `FeatLibraryOrganize/FeatLibraryOrganizeFeature.swift` per-folder panel ids (`organize.folder.new.<parent>`) and current folder from `ctx.nodes`, F022 `FeatPages` `MovePagesStash`, F037 `FeatComments/FeatCommentsFeature.swift` `CommentsState` target slot, F062 `{instant: true}` → `PanelContext.params` / `MenuContext.folder`.
- F017 panel header by owner guess and window-mode width → `PanelDescriptor.providesHeader` / `PanelContext.presentation`.
- F027 `FeatSettings/FeatSettingsFeature.swift` `keywords(_:)` table → `SettingsPageDescriptor.keywords` on each page.
- F029 `FeatLinks/LinkEditorSheet.swift` selected range → `MenuContext.textRange`.

### G17 — Selection outline

```swift
public var outline: [Point]?        // Selection; init(..., outline: [Point]? = nil)
```
Replaces: F011 `FeatLasso` `SelectionOutlines.bySession` → `session.selection.outline`; F012 transforms it with the items so a rotated selection keeps its outline.

### G18 — Well-known ids

```swift
// CommandIDs
public static let selectionClear = "selection.clear", textSetText = "text.setText", libraryRename = "library.rename"
public static let clipboardCut = "clipboard.cut", itemRecolor = "item.recolor", itemDuplicate = "item.duplicate"
public static let viewReveal = "view.reveal", viewSetReadOnly = "view.setReadOnly", panelClose = "panel.close", audioPlay = "audio.play"
public static let windowShowLibrary = "window.showLibrary"      // NEW contracts command {folder?} (session)
// PanelIDs
public static let assistant = "aichat.panel", trash = "organize.trash", favourites = "organize.favourites"
public static let templates = "templateui.manage", cloudBackup = "syncui.panel", about = "about.panel"
public static let gallery = "pluginmanager.gallery", studyPractice = "studysession.practice"
public static let studySmartLearn = "studysession.smartLearn"   // v2.1; v2's studyLearn now holds this id too
public static let movePages = "pages.movePages"                 // v2.1; F022 sheet, panel.open {id, pages?}
```
Replaces: F014 `FeatClipboard/ClipboardCommands.swift` `"selection.clear"`, F028 `PageTextEditor.setTextCommand`, F047 `TextDocViewController.swift` `"library.rename"`, F058 `FeatSmartInk/EditHandwritingMode.swift` `"item.recolor"` / `"clipboard.cut"` literals → the constants; F017 `DocumentContainerViewController.swift` Back button and F018 `FeatWindows/TabStripView.swift` `showLibrary()` / `WindowCommands.swift` direct `navigator.showLibrary` → `app.perform(CommandIDs.windowShowLibrary, …)`; F017 assistant found by owner "aichat", F027 app-menu places guessed by owner, F035 gallery by owner "pluginmanager", F049 `FeatStudyEditor/CardEditorView.swift` practice/learn by owner → `PanelIDs`. Adopt: F085, F045, F070, F098, F080, F050 register their panels under these ids.

### G19 — Device identity

```swift
public var deviceHex: String       // HLCClock and NibApp: 8 lowercase hex characters
```
Replaces: F001 `NibStore/NibStoreFeature.swift` `String(format: "%08x", app.clock.device)` → `app.deviceHex`.

### G20 — NibTesting

```swift
public init(features: [NibFeature.Type] = [], fixtures: Bool = true, deviceID: UInt32 = 7, keepFeatureServices: Bool = false)   // Harness
@discardableResult public func insert(_ items: [Item], page: PageID = Fixtures.page1, doc: DocumentID = Fixtures.docID) async throws -> [Item]
// FakeCanvasHost: afterNextRender runs at once and records renderWaits; FakePDFService: words for word(_:page:at:)
@MainActor public enum NibSnapshot {                  // offscreen SwiftUI snapshots (ImageRenderer)
    public enum Variant: String, CaseIterable { case light, dark, largeText }   // largeText = AX3
    public static func image<V: View>(_ view: V, size: CGSize, variant: Variant = .light, scale: CGFloat = 2) -> UIImage?
    public static func images<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2) -> [Variant: UIImage]
    public static func fittingSize<V: View>(_ view: V, width: CGFloat, variant: Variant = .light) -> CGSize
    public static func pixel(_ image: UIImage, at point: CGPoint) -> RGBA?
}
```
Replaces: F001/F025 re-registering `NibStoreFeature` after Harness init → `Harness(features:, keepFeatureServices: true)`; F058 tests writing synthetic strokes into `InMemoryPersistence.pageItems` and stand-in `ink.addStrokes` → `h.insert(_:page:doc:)`; F037 `FeatComments` tests that render both panels through `UIHostingController.sizeThatFits` in every state → `NibSnapshot` (Light, Dark, AX3); Reduce Transparency and Increase Contrast stay F111 smoke scripts.

### G21 — Query paging

`ToolCatalog.metaTools` `nib_get` gains `cursor`; §6.1 makes `cursor` + `truncated` the paging rule for every read result over 20 KB. Replaces: nothing to remove; F003's additive `cursor` on query.get / query.tree is the sanctioned form.

### G22 — PDF, backgrounds and recognition

```swift
// PageRecord.rotation pinned: turns only a PDF/image background clockwise, aspect-fitted and centred into size; items never rotate
public func backgroundTransform(sourceSize: PageSize) -> Affine
public static func backgroundTransform(sourceSize: PageSize, rotation: Int, pageSize: PageSize?) -> Affine
public static let scanTextExtKey = "nib.scanText"
// PDFService (default nil)
func word(_ url: URL, page: Int, at point: Point) -> (text: String, rect: Rect)?
// TextRecognition and TextRecognitionWord (decoding is now lenient: only text is required)
public var words: [TextRecognitionWord]?
public struct TextRecognitionWord: Codable, Equatable { public var text: String; public var bbox: Rect; public var itemIDs: [ElementID] }
```
Replaces: F024 `NibPDF/PDFCommands.swift` link placement, F042 `FeatReadOnly/ReadOnlyCommands.swift` `PDFPlacement`, F004 `NibRender/PDFRenderPool.swift` rotation → `PageRecord.backgroundTransform`; F042 whole-line long-press → `pdf.word(_:page:at:)` (adopt: F024 implements it in NibPDF); F055 `NibIndex/VisionRecognizer.swift` `recognizer as? VisionRecognizer` cast → `TextRecognition.words` (adopt: NibIndex's recognizer fills them); F055 `NibIndex/Indexer.swift` `IndexKeys.scanText` and F065 `FeatScan/ScanCommands.swift` `extKey` → `PageRecord.scanTextExtKey`.

### G23 — Model additions

```swift
public var flipX: Bool?; public var flipY: Bool?                      // ImageItem
public struct NibFragment: Equatable, Codable                         // "nib-fragment/1": make, expand, instantiated, mapAssets, assetRefs, union, decode, encoded
public static func balanced(count: Int, after a: String? = nil, before b: String? = nil) -> [String]   // FractionalIndex
public static func tapePatternRef(id: String) -> AssetRef             // PresetSwatch: "<id>.png"
public static func tapePatternID(_ ref: AssetRef) -> String
public static let highlighterAlpha: UInt8 = 0x80                      // RGBA
// ToolPresets decodes leniently (patterns and selections default; swatches and widths required)
```
Replaces: F034 `FeatImages/ImageDrawer.swift` `Item.ext["images"]` flipX/flipY → `ImageItem.flipX/flipY` (read the ext as a fallback for existing items); F035 `FeatElements/ElementStore.swift` `ElementFragment` and F014 `FeatClipboard/Fragment.swift` `Fragment` → `NibFragment`; F051 `FeatStudyIO/StudyImporter.swift` `orderKeys` → `FractionalIndex.balanced`; F008 `FeatPresets/PresetCommands.swift` swatch pattern ids and F033 `FeatTape/TapePatterns.swift` `TapePatternRef` → `PresetSwatch.tapePatternRef(id:)` / `tapePatternID(_:)`; F009 highlighter alpha literal → `RGBA.highlighterAlpha`; F008 normalising of partial presets that failed to decode → keep the clamping, decoding now succeeds.

### G24 — Geometry

```swift
public init?(array a: [Double])                  // Frame: [x, y, w, h] or [x, y, w, h, rotation]
public var array: [Double]                        // Frame
public var inverted: Affine?                      // Affine
public static func quadraticControl(through start: Point, _ mid: Point, _ end: Point) -> [Point]   // ShapeItem
// ShapeItem.points pinned: control points. .curve: 2 straight, 3 quadratic, 4 cubic, 5+ clamped B-spline.
//   .arc: [start, control, end], control = tangent intersection for sweeps < 170°; wider sweeps / parabolas as quadratic.
// Frame.applying fixed: non-uniform scale of a rotated frame is measured along the frame's own axes.
```
Replaces: F012 `FeatTransform/TransformCommands.swift` `TransformMath.frame(_:applying:)` overwrite → `Item.transformed(by:)` alone; F031 `FeatShapes/ShapeCommands.swift` frame array parsing, F009 and F030 frame building → `Frame(array:)` / `.array`; F009 and F030 through-point curves → `ShapeItem.quadraticControl(through:_:_:)`; F031 curve/arc semantics note → the pinned rule.

### G25 — Rich text round trip

```swift
public extension NSAttributedString.Key { static let nibModelFont: Self; static let nibModelTraits: Self }
// RichTextBridge.attributes writes them; textAttributes keeps a model family that is not installed here and a model
// bold/italic the rendered family has no face for.
```
Replaces: F026 `FeatTextBox/TextBoxDrawer.swift` `modelFontKey` / `modelTraitsKey` ("nib.text.modelFont" / "nib.text.modelTraits") → the bridge's keys.

### G26 — Export options and closure hooks

```swift
public enum ExportOptionKeys { public static let visibleLayersOnly, visibleLayers, annotations, background: String }
public var docKinds: Set<DocumentKind>?          // ExporterDescriptor
public var handler: (@MainActor (_ command: String, _ params: JSONValue) async throws -> JSONValue?)?   // CommandHookDescriptor
public init(id: String, owner: String, commands: [String], order: Int = 0, handler: @escaping @MainActor (_ command: String, _ params: JSONValue) async throws -> JSONValue?)
public var contextHandler: (@MainActor (_ command: String, _ params: JSONValue, _ ctx: CommandContext) async throws -> JSONValue?)?
public static func guarding(id: String, owner: String, commands: [String], order: Int = 0,
                            _ body: @escaping @MainActor (_ command: String, _ params: JSONValue, _ ctx: CommandContext) async throws -> JSONValue?) -> CommandHookDescriptor
```
Closure hooks run before validation and authorization, for every principal and for typed `bus.run` calls. They return replacement params, return nil to let the call through, or throw to veto it. A guard (`contextHandler`) also gets a read-only `CommandContext` of the call: the principal, the session (`ctx.pageOrSession(_:)` resolves session defaults), and `ctx.app` / `ctx.content`. `ctx.mutate` throws inside a guard. Test: `testGuardHookSeesTheCallAndVetoesForEveryPrincipal`.
Replaces: F041 `FeatLayers/LayerCommands.swift` `layer.exportOptions` hook command (extra id, lint warning) + `FeatLayersFeature.swift` hook registration → a closure hook on `export.run` writing `ExportOptionKeys.visibleLayersOnly` / `visibleLayers` (F066 reads them); F044 board item limit enforced only in its own commands → a `CommandHookDescriptor.guarding` hook on item-creating commands (`ink.addStrokes`, `shape.create`, `clipboard.paste`, …) that counts the target board's items; F051 `FeatStudyIO/StudyExporter.swift` "study.csv" throwing for other kinds → `docKinds: [.studySet]`.

### G27 — Gateway and bridge

```swift
public var kind: String                                   // Principal: user, plugin, ai, bridge, sync
public func setPresenter(_ presenter: ConfirmationPresenter?, forPrincipalKind kind: String)   // Gateway
public func setPolicy(forPrincipalKind kind: String, _ policy: ((Principal) -> ConfirmationPolicy)?)
public func confirmationPresenter(for principal: Principal) -> ConfirmationPresenter?
public enum BridgeNames { enabledSetting, portSetting, networksSetting, originsSetting, tokenService, tokenAccount, statusEvent }
public static let aiDirectToolsName = "ai.directTools"; public static let defaultAIDirectTools: [String]   // NibSettings
```
Replaces: F090 `NibBridge/NibBridgeFeature.swift` wrapping `gateway.presenter` (BridgeConfirmer) and chaining `gateway.policy` → `setPresenter(_:forPrincipalKind: "bridge")` / `setPolicy(forPrincipalKind: "bridge")`; F090 `BridgeCommands.swift` / `BridgeAuth.swift` literals shared with F091 → `BridgeNames`; F090 `MCPHandler.swift` `defaultDirectTools` → `NibSettings.defaultAIDirectTools`. Adopt: F085 registers its sheet for "ai" and F084 its policy.

### Rejected and deferred (summary)

- **NibDesign (33 lines, deferred):** NibSymbol glyphs, tokens (metrics, radii, motion), NibBadge principal kind, NibToolPalette bindings and popover API, NibPenSwatch pattern, progress bar tint, canvas-anchored droplets. The design-system passes own them.
- **Catalogue rows (12, deferred):** extra ids already registered by F027 (settings.open), F031 (shape.tapAt), F034 (image.pick), F041 (layer.exportOptions, superseded by G26), F042 (pdf.tapAt), F043 (pencil.gesture, pencil.palette, pencil.actions), pdf.outline; the spec owner adds the rows to docs/forge-spec.json.
- **App shell (11, deferred):** status-bar forwarding, tab model and band layout, openGate result, settings page forwarding, paste responder, editing-interaction configuration, key routing while editing text; plus shell adoption of `KeyCommandDescriptor.docKinds`/`sessionParams` and `SceneNavigator.addTab`.
- **Other deferred (25):** later owners or design: F007 stabiliser rule, F045 covers, F054 transcripts, F055 recognition inputs, F073 shortcuts, F074 deep links, F019 library tabs, F101 spatial index and stroke preview, F004 hiding items attached to a collapsed note, per-message comment merge (F025/F108), item groups, system font designs, pen type in shapes, connector normals.
- **Rejected (67):** by design (optional dependencies, provenance, non-undoable writes, locked codes, feature-internal seams), already in the contract, additive params the catalogue allows, platform or language limits, and observations. Recorded conventions: F025's NSFilePresenters use a background `presentedItemOperationQueue`; `tab.select` is 0-based with -1 = last tab (F018, F073 follows); `shape.recognize` returns `{shape: ShapeItem?, mergeWith?: [ref]}`; deep links `nib://open/<doc>/<page>?comment=<itemID>` route to `comment.tapAt`.

## Quick reference: a complete feature module (example, do not create)

```swift
// NibKit/Sources/FeatExample/FeatExampleFeature.swift
import SwiftUI
import NibContracts

public enum FeatExampleFeature: NibFeature {
    public static let id = "example"

    public static func register(_ app: NibApp) {
        app.commands.register(ExampleStamp.self)                                    // a command (owner stamped = "example")
        app.settings.declare(ExampleSettings.loud, summary: "Stamp in bold red.", owner: id, schema: .bool())
        app.ui.toolbar.register(ToolbarItemDescriptor(                              // a toolbar button → command
            id: "example.stamp", title: "Stamp", icon: "seal", group: .accessories, order: 500, owner: id,
            command: "example.stamp"))
        app.ui.menus.register(MenuItemDescriptor(                                   // an object-menu entry → command
            id: "example.stamp.menu", title: "Stamp here", icon: "seal", location: .pageLongPress, order: 900,
            owner: id, command: "example.stamp",
            params: { ctx in ["page": .string(NodeRef.page(ctx.doc!, ctx.page!).description),
                              "at": .array([.number(ctx.point?.x ?? 72), .number(ctx.point?.y ?? 72)])] },
            isVisible: { ctx in ctx.doc != nil && ctx.page != nil }))
        app.ui.settingsPages.register(SettingsPageDescriptor(                       // a settings page
            id: "example.settings", title: "Example", icon: "seal", section: .advanced, order: 900, owner: id,
            makeView: { app in AnyView(Toggle("Loud stamps", isOn: .constant(app.settings.get(ExampleSettings.loud)))) }))
    }
}

enum ExampleSettings {
    static let loud = SettingKey("example.loud", default: false, synced: true)
}

struct ExampleStamp: NibCommand {
    struct Params: Codable { var page: String; var at: [Double]?; var id: String? }
    struct Output: Codable { var ref: String }
    static let descriptor = CommandDescriptor(
        id: "example.stamp", title: "Stamp",
        summary: "Put a 'Checked' text box on a page at a point (optional caller-chosen id).",
        params: .obj(["page": .ref, "at": .point, "id": .str("your own id, [A-Za-z0-9_-]{1,64}")], required: ["page"]),
        examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001", "at": [100, 100]]],
        effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard case let .page(doc, page)? = NodeRef(p.page) else { throw NibError.invalid("expected a page ref", path: "$.page") }
        if let id = p.id, !NibID.isValid(id) { throw NibError.invalid("id must be 1–64 of [A-Za-z0-9_-]", path: "$.id") }
        let at = p.at ?? [72, 72]
        let layer = ctx.activeSession?.activeLayer ?? 0
        let item = try ctx.mutate { tx in
            var it = Item.makeText(TextBoxItem(frame: Frame(x: at[0], y: at[1], w: 120, h: 32),
                                               text: RichText(plain: "Checked ✓")), layer: layer)
            if let id = p.id { it.id = NibID(id) }
            return try tx.put(it, doc: doc, page: page)
        }
        return Output(ref: NodeRef.item(doc, page, item.id).description)
    }
}
```

## Part A — `NibContracts`, `NibTesting` and contract tests

The frozen, shared layer. Model = value types and the JSON wire format (lenient decoding everywhere). Core = commands, bus, transactions, undo, events, permissions, settings, services, registries and the AI tool catalogue. UI = PencilKit and TextKit bridges, shared drawing (DisplayList, InkOutline), UI registries, canvas protocols (tools, attachments) and the `NibApp` composition root.

### `NibKit/Sources/NibContracts/Model/JSONValue.swift`

```swift
import Foundation

/// Dynamically typed JSON. Used on every untyped boundary: plugins, AI tools, the MCP bridge, settings, `ext` data.
public enum JSONValue: Codable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

public extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var intValue: Int? {
        if case .number(let n) = self, n == n.rounded(), abs(n) < 9.0e15 { return Int(n) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var isNull: Bool { self == .null }

    /// Encodes any `Encodable` into a `JSONValue`.
    static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes this value into `T`.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func parse(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    func jsonString(pretty: Bool = false) -> String {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        guard let d = try? e.encode(self) else { return "null" }
        return String(decoding: d, as: UTF8.self)
    }

    /// Deep-merges `other` over this value. Objects merge key by key; anything else is replaced.
    func merging(_ other: JSONValue) -> JSONValue {
        guard case .object(var base) = self, case .object(let over) = other else { return other }
        for (k, v) in over { base[k] = (base[k] ?? .null).merging(v) }
        return .object(base)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var o: [String: JSONValue] = [:]
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
}
```

### `NibKit/Sources/NibContracts/Model/Primitives.swift`

```swift
import Foundation

// MARK: - Format constants

public enum NibFormat {
    /// Major on-disk format version. Readers refuse to write packages with a newer major version.
    public static let version = 1
    /// Document package extension. The ONLY place it is spelled (plus project.yml). "nibnote", not "nib":
    /// `.nib` is the system-declared Interface Builder type. Folders named `*.nib` that contain `doc.*.json`
    /// are still accepted as a legacy import (F002, F064).
    public static let packageExtension = "nibnote"
    public static let legacyPackageExtension = "nib"
    public static let packageUTType = "app.nib.document"
    public static let pluginExtension = "nibplugin"
    public static let pluginUTType = "app.nib.plugin"
    /// Hidden folder at the library root holding trash, plugins, elements, templates, prefs, AI chats.
    public static let libraryDirectory = ".nib-library"
    public static let urlScheme = "nib"
}

public enum NibLimits {
    public static let layerCount = 5
    public static let maxNesting = 16
    public static let boardItemLimit = 100_000
    public static let aiToolResultBytes = 20_000
    public static let undoDepth = 200
    /// contracts-v2: largest file `CommandContext.inputFile` downloads (200 MB).
    public static let maxDownloadBytes = 200 * 1_048_576
    /// contracts-v2: how far an `ItemDrawer` may paint outside `Item.bounds` (arrowheads, nib width, connector labels,
    /// text overflow). The renderer pads culling and tile invalidation by it.
    public static let drawerMargin: Double = 12
    /// contracts-v2: most points one `ink.erase` path may carry.
    public static let maxErasePathPoints = 20_000
}

// MARK: - Identifiers

/// Identifier for every persisted record (documents, folders, pages, items, blocks, cards, clips).
/// Generated IDs are 12 Crockford-base32 characters. AI agents and plugins may supply their own
/// IDs (see `isValid`) so they can link records created in one batch.
public struct NibID: Hashable, Comparable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let raw: String

    public init(_ raw: String) { self.raw = raw }
    public init(stringLiteral value: String) { self.raw = value }

    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    public var description: String { raw }
    public static func < (a: NibID, b: NibID) -> Bool { a.raw < b.raw }

    private static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

    public static func make() -> NibID {
        var rng = SystemRandomNumberGenerator()
        var chars: [Character] = []
        chars.reserveCapacity(12)
        for _ in 0..<12 {
            let v: UInt64 = rng.next()
            chars.append(NibID.alphabet[Int(v % 32)])
        }
        return NibID(String(chars))
    }

    /// 1–64 characters of [A-Za-z0-9_-].
    public static func isValid(_ s: String) -> Bool {
        guard (1...64).contains(s.count) else { return false }
        return s.unicodeScalars.allSatisfy { NibID.allowed.contains($0) }
    }
}

public typealias DocumentID = NibID
public typealias PageID = NibID
public typealias ElementID = NibID
public typealias FolderID = NibID

// MARK: - Revisions (hybrid logical clock)

/// Last-writer-wins revision. Ordered by (wall ms, counter, device); encoded as a sortable hex string.
public struct Rev: Hashable, Comparable, Codable, CustomStringConvertible {
    public var wallMs: UInt64
    public var counter: UInt32
    public var device: UInt32

    public init(wallMs: UInt64, counter: UInt32, device: UInt32) {
        self.wallMs = wallMs
        self.counter = counter
        self.device = device
    }

    public static let zero = Rev(wallMs: 0, counter: 0, device: 0)

    public static func < (a: Rev, b: Rev) -> Bool {
        if a.wallMs != b.wallMs { return a.wallMs < b.wallMs }
        if a.counter != b.counter { return a.counter < b.counter }
        return a.device < b.device
    }

    public var description: String { String(format: "%012llx.%08x.%08x", wallMs, counter, device) }

    /// Revisions stamped more than 24 h in the future come from a device whose clock is wrong: they compare as if
    /// written at time 0, so every correctly-clocked edit beats them (they still merge when nothing else exists)
    /// until real time catches up. Used by `LWW.merge` and `Workspace.merge`; F025 reports such files in sync.status.
    public func effective(now: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) -> Rev {
        wallMs > now + 86_400_000 ? Rev(wallMs: 0, counter: counter, device: device) : self
    }

    public init?(string: String) {
        let parts = string.split(separator: ".")
        guard parts.count == 3,
              let w = UInt64(parts[0], radix: 16),
              let c = UInt32(parts[1], radix: 16),
              let d = UInt32(parts[2], radix: 16) else { return nil }
        self.init(wallMs: w, counter: c, device: d)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let r = Rev(string: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid rev '\(s)'")
        }
        self = r
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// Hybrid logical clock. One per app process (`NibApp.clock`). Thread-safe.
public final class HLCClock {
    public let device: UInt32
    private var last = Rev.zero
    private let lock = NSLock()

    public init(device: UInt32) { self.device = device }

    /// contracts-v2: `device` as 8 lowercase hex characters (per-device file names).
    public var deviceHex: String { String(format: "%08x", device) }

    public func tick() -> Rev {
        lock.lock()
        defer { lock.unlock() }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        if now > last.wallMs {
            last = Rev(wallMs: now, counter: 0, device: device)
        } else {
            last = Rev(wallMs: last.wallMs, counter: last.counter &+ 1, device: device)
        }
        return last
    }

    /// Advances the clock past a remote revision (remote wall time is capped at now + 24 h).
    public func observe(_ remote: Rev) {
        lock.lock()
        defer { lock.unlock() }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let wall = min(remote.wallMs, now + 86_400_000)
        if wall > last.wallMs || (wall == last.wallMs && remote.counter > last.counter) {
            last = Rev(wallMs: wall, counter: remote.counter, device: device)
        }
    }
}

// MARK: - Fractional ordering keys

/// Base-62 fractional index used for z-order, page order, block/card/outline order.
/// Keys never end in "0", so a key can always be generated between any two keys.
public enum FractionalIndex {
    private static let digits: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    private static func value(_ c: Character) -> Int { digits.firstIndex(of: c) ?? 0 }

    /// A key strictly between `a` and `b` (nil = unbounded). Precondition: a < b when both are given.
    public static func between(_ a: String?, _ b: String?) -> String {
        String(mid(Array(a ?? ""), b.map { Array($0) }))
    }

    /// contracts-v2: `count` increasing keys strictly between `a` and `b` (nil = unbounded), built by bisection so they
    /// stay short: about log62(count) + 1 characters (10,000 keys ≤ 4 characters), where `sequence` grows by one
    /// character every few keys. For imports and batch inserts. Precondition: a < b when both are given.
    public static func balanced(count: Int, after a: String? = nil, before b: String? = nil) -> [String] {
        guard count > 0 else { return [] }
        var out = [String](repeating: "", count: count)
        func fill(_ lo: Int, _ hi: Int, _ left: String?, _ right: String?) {
            guard lo <= hi else { return }
            let mid = (lo + hi) / 2
            let key = between(left, right)
            out[mid] = key
            fill(lo, mid - 1, left, key)
            fill(mid + 1, hi, key, right)
        }
        fill(0, count - 1, a, b)
        return out
    }

    /// `count` increasing keys after `a`.
    public static func sequence(after a: String?, count: Int) -> [String] {
        var out: [String] = []
        var last = a
        for _ in 0..<max(0, count) {
            let k = between(last, nil)
            out.append(k)
            last = k
        }
        return out
    }

    private static func mid(_ a: [Character], _ b: [Character]?) -> [Character] {
        if let b = b {
            var n = 0
            while n < b.count && (n < a.count ? a[n] : "0") == b[n] { n += 1 }
            if n > 0 {
                return Array(b[0..<n]) + mid(Array(a.dropFirst(n)), Array(b.dropFirst(n)))
            }
        }
        let da = a.isEmpty ? 0 : value(a[0])
        let db = b.map { $0.isEmpty ? 62 : value($0[0]) } ?? 62
        if db - da > 1 { return [digits[(da + db) / 2]] }
        if let b = b, b.count > 1 { return [b[0]] }
        return [digits[da]] + mid(Array(a.dropFirst()), nil)
    }
}

// MARK: - Colors and assets

/// sRGB color with alpha. Encoded as "#RRGGBBAA".
public struct RGBA: Hashable, Codable, CustomStringConvertible {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Accepts "#RRGGBB" or "#RRGGBBAA" (the "#" is optional).
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF), 255)
        } else {
            self.init(UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
        }
    }

    public var hex: String { String(format: "#%02X%02X%02X%02X", r, g, b, a) }
    public var description: String { hex }
    public var alpha: Double { Double(a) / 255 }

    public func withAlpha(_ alpha: Double) -> RGBA {
        RGBA(r, g, b, UInt8(max(0, min(255, (alpha * 255).rounded()))))
    }

    /// contracts-v2: alpha a highlighter colour is stored with (the renderer blends it per paper, see `NibHighlighter`).
    public static let highlighterAlpha: UInt8 = 0x80

    public static let black = RGBA(0x1A, 0x1A, 0x1A)
    public static let white = RGBA(0xFF, 0xFF, 0xFF)
    public static let clear = RGBA(0, 0, 0, 0)
    public static let highlighterYellow = RGBA(0xFF, 0xE0, 0x3D, 0x80)
    public static let paperYellow = RGBA(0xFD, 0xF6, 0xDC)
    public static let paperDark = RGBA(0x24, 0x24, 0x26)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let v = RGBA(hex: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid color '\(s)', expected #RRGGBB or #RRGGBBAA")
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}

/// Content-addressed file inside a document package: "assets/<sha256 hex>.<ext>". Immutable.
public struct AssetRef: Hashable, Codable, CustomStringConvertible {
    public var name: String

    public init(_ name: String) { self.name = name }

    public var ext: String { (name as NSString).pathExtension.lowercased() }
    public var description: String { name }

    public init(from decoder: Decoder) throws {
        name = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }
}
```

### `NibKit/Sources/NibContracts/Model/Geometry.swift`

```swift
import Foundation

/// A point in page coordinates: PDF points (1/72 in), origin at the page's top-left, y grows downward.
/// Encoded as `[x, y]`.
public struct Point: Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(0, 0)

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
    }

    public func distance(to p: Point) -> Double { hypot(p.x - x, p.y - y) }

    public static func + (a: Point, b: Point) -> Point { Point(a.x + b.x, a.y + b.y) }
    public static func - (a: Point, b: Point) -> Point { Point(a.x - b.x, a.y - b.y) }
    public static func * (a: Point, s: Double) -> Point { Point(a.x * s, a.y * s) }
}

/// Axis-aligned rectangle in page coordinates. Encoded as `[x, y, width, height]`.
public struct Rect: Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
        width = try c.decode(Double.self)
        height = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
        try c.encode(width)
        try c.encode(height)
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var center: Point { Point(midX, midY) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func union(_ r: Rect) -> Rect {
        let nx = min(x, r.x), ny = min(y, r.y)
        return Rect(x: nx, y: ny, width: max(maxX, r.maxX) - nx, height: max(maxY, r.maxY) - ny)
    }

    public func intersects(_ r: Rect) -> Bool {
        x <= r.maxX && r.x <= maxX && y <= r.maxY && r.y <= maxY
    }

    public func contains(_ p: Point) -> Bool {
        p.x >= x && p.x <= maxX && p.y >= y && p.y <= maxY
    }

    public func contains(_ r: Rect) -> Bool {
        r.x >= x && r.maxX <= maxX && r.y >= y && r.maxY <= maxY
    }

    /// Positive `d` shrinks, negative grows.
    public func insetBy(_ d: Double) -> Rect {
        Rect(x: x + d, y: y + d, width: max(0, width - 2 * d), height: max(0, height - 2 * d))
    }

    public static func bounding(_ points: [Point]) -> Rect? {
        guard let first = points.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// A possibly rotated box: position/size of the unrotated box plus rotation (radians, clockwise on screen)
/// about its center. Used by shapes, text boxes, images, sticky notes, math and custom items.
public struct Frame: Hashable, Codable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var rotation: Double

    public init(x: Double, y: Double, w: Double, h: Double, rotation: Double = 0) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.rotation = rotation
    }

    public init(_ r: Rect, rotation: Double = 0) {
        self.init(x: r.x, y: r.y, w: r.width, h: r.height, rotation: rotation)
    }

    enum CodingKeys: String, CodingKey { case x, y, w, h, rotation }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        w = try c.decode(Double.self, forKey: .w)
        h = try c.decode(Double.self, forKey: .h)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
    }

    public var rect: Rect { Rect(x: x, y: y, width: w, height: h) }
    public var center: Point { Point(x + w / 2, y + h / 2) }

    /// Corners (top-left, top-right, bottom-right, bottom-left) after rotation.
    public var corners: [Point] {
        let c = center
        let hw = w / 2, hh = h / 2
        let cs = cos(rotation), sn = sin(rotation)
        let offsets: [(Double, Double)] = [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)]
        return offsets.map { d in Point(c.x + d.0 * cs - d.1 * sn, c.y + d.0 * sn + d.1 * cs) }
    }

    /// Axis-aligned bounds of the rotated box.
    public var bounds: Rect {
        if rotation == 0 { return rect }
        return Rect.bounding(corners) ?? rect
    }

    /// Applies an affine transform (translation, uniform/non-uniform scale, rotation; shear is ignored).
    /// contracts-v2 fix: a non-uniform scale of a ROTATED frame is measured along the frame's own axes (it used to be
    /// measured along the page axes, which skewed rotated boxes). Similarity transforms and unrotated frames are
    /// computed exactly as before.
    public func applying(_ t: Affine) -> Frame {
        let c = t.apply(center)
        let sx = hypot(t.a, t.b), sy = hypot(t.c, t.d)
        let scale = max(sx, sy, 1)
        let similarity = abs(sx - sy) <= 1e-9 * scale && abs(t.a * t.c + t.b * t.d) <= 1e-9 * scale * scale
        if rotation == 0 || similarity {
            let nw = w * sx, nh = h * sy
            return Frame(x: c.x - nw / 2, y: c.y - nh / 2, w: nw, h: nh, rotation: rotation + atan2(t.b, t.a))
        }
        let cs = cos(rotation), sn = sin(rotation)
        let ux = t.a * cs + t.c * sn, uy = t.b * cs + t.d * sn
        let vx = -t.a * sn + t.c * cs, vy = -t.b * sn + t.d * cs
        let nw = w * hypot(ux, uy), nh = h * hypot(vx, vy)
        let turn = atan2(cs * uy - sn * ux, cs * ux + sn * uy)
        return Frame(x: c.x - nw / 2, y: c.y - nh / 2, w: nw, h: nh, rotation: rotation + turn)
    }

    /// contracts-v2: the array form command params use: `[x, y, w, h]` or `[x, y, w, h, rotation]` (radians). nil when
    /// the array has another length.
    public init?(array a: [Double]) {
        guard a.count == 4 || a.count == 5 else { return nil }
        self.init(x: a[0], y: a[1], w: a[2], h: a[3], rotation: a.count == 5 ? a[4] : 0)
    }

    /// contracts-v2: `[x, y, w, h]`, plus the rotation as a 5th value when it is not 0.
    public var array: [Double] { rotation == 0 ? [x, y, w, h] : [x, y, w, h, rotation] }
}

/// 2-D affine transform in CoreGraphics convention: x' = a·x + c·y + tx, y' = b·x + d·y + ty.
/// Encoded as `[a, b, c, d, tx, ty]`.
public struct Affine: Hashable, Codable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public static let identity = Affine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public static func translation(_ dx: Double, _ dy: Double) -> Affine {
        Affine(a: 1, b: 0, c: 0, d: 1, tx: dx, ty: dy)
    }

    public static func scale(_ sx: Double, _ sy: Double, about p: Point = .zero) -> Affine {
        translation(-p.x, -p.y)
            .concatenating(Affine(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0))
            .concatenating(translation(p.x, p.y))
    }

    public static func rotation(_ radians: Double, about p: Point = .zero) -> Affine {
        let cs = cos(radians), sn = sin(radians)
        return translation(-p.x, -p.y)
            .concatenating(Affine(a: cs, b: sn, c: -sn, d: cs, tx: 0, ty: 0))
            .concatenating(translation(p.x, p.y))
    }

    /// `self` first, then `t`.
    public func concatenating(_ t: Affine) -> Affine {
        Affine(a: a * t.a + b * t.c,
               b: a * t.b + b * t.d,
               c: c * t.a + d * t.c,
               d: c * t.b + d * t.d,
               tx: tx * t.a + ty * t.c + t.tx,
               ty: tx * t.b + ty * t.d + t.ty)
    }

    public func apply(_ p: Point) -> Point {
        Point(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty)
    }

    public var determinant: Double { a * d - b * c }

    /// contracts-v2: the inverse transform; nil when it is not invertible.
    public var inverted: Affine? {
        let det = determinant
        guard det != 0, det.isFinite else { return nil }
        return Affine(a: d / det, b: -b / det, c: -c / det, d: a / det,
                      tx: (c * ty - d * tx) / det, ty: (b * tx - a * ty) / det)
    }

    public init(from decoder: Decoder) throws {
        var u = try decoder.unkeyedContainer()
        a = try u.decode(Double.self)
        b = try u.decode(Double.self)
        c = try u.decode(Double.self)
        d = try u.decode(Double.self)
        tx = try u.decode(Double.self)
        ty = try u.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var u = encoder.unkeyedContainer()
        try u.encode(a)
        try u.encode(b)
        try u.encode(c)
        try u.encode(d)
        try u.encode(tx)
        try u.encode(ty)
    }
}

/// Shared geometry helpers (hit testing, lasso, eraser, recognition).
public enum Geo {
    public static func distance(_ p: Point, toSegment a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return p.distance(to: Point(a.x + t * dx, a.y + t * dy))
    }

    /// Even-odd point-in-polygon test.
    public static func polygonContains(_ polygon: [Point], _ p: Point) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i], pj = polygon[j]
            if (pi.y > p.y) != (pj.y > p.y) {
                let xCross = (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x
                if p.x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    public static func segmentsIntersect(_ p1: Point, _ p2: Point, _ q1: Point, _ q2: Point) -> Bool {
        func orient(_ a: Point, _ b: Point, _ c: Point) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        let d1 = orient(q1, q2, p1), d2 = orient(q1, q2, p2)
        let d3 = orient(p1, p2, q1), d4 = orient(p1, p2, q2)
        return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))
    }

    /// True when any vertex of `line` is inside `polygon` or any segment crosses its boundary.
    public static func polylineTouchesPolygon(_ line: [Point], _ polygon: [Point]) -> Bool {
        if line.contains(where: { polygonContains(polygon, $0) }) { return true }
        guard polygon.count >= 2, line.count >= 2 else { return false }
        for i in 0..<(line.count - 1) {
            for j in 0..<polygon.count {
                let k = (j + 1) % polygon.count
                if segmentsIntersect(line[i], line[i + 1], polygon[j], polygon[k]) { return true }
            }
        }
        return false
    }

    public static func pathLength(_ pts: [Point]) -> Double {
        guard pts.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<pts.count { total += pts[i - 1].distance(to: pts[i]) }
        return total
    }

    /// Resamples a polyline to `count` evenly spaced points.
    public static func resample(_ pts: [Point], count: Int) -> [Point] {
        guard pts.count > 1, count > 1 else { return pts }
        let total = pathLength(pts)
        if total == 0 { return Array(repeating: pts[0], count: count) }
        let step = total / Double(count - 1)
        var out = [pts[0]]
        var acc = 0.0
        var prev = pts[0]
        var i = 1
        while i < pts.count && out.count < count {
            let cur = pts[i]
            let d = prev.distance(to: cur)
            if d > 0 && acc + d >= step {
                let t = (step - acc) / d
                let q = Point(prev.x + t * (cur.x - prev.x), prev.y + t * (cur.y - prev.y))
                out.append(q)
                prev = q
                acc = 0
            } else {
                acc += d
                prev = cur
                i += 1
            }
        }
        while out.count < count { out.append(pts[pts.count - 1]) }
        return out
    }

    /// Douglas–Peucker simplification.
    public static func simplify(_ pts: [Point], tolerance: Double) -> [Point] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack: [(Int, Int)] = [(0, pts.count - 1)]
        while let pair = stack.popLast() {
            let s = pair.0, e = pair.1
            guard e > s + 1 else { continue }
            var maxD = 0.0
            var idx = -1
            for i in (s + 1)..<e {
                let d = distance(pts[i], toSegment: pts[s], pts[e])
                if d > maxD {
                    maxD = d
                    idx = i
                }
            }
            if idx >= 0 && maxD > tolerance {
                keep[idx] = true
                stack.append((s, idx))
                stack.append((idx, e))
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }
}
```

### `NibKit/Sources/NibContracts/Model/Ink.swift`

```swift
import Foundation

public enum InkTool: String, Codable, CaseIterable { case pen, pencil, highlighter, tape }
public enum PenStyle: String, Codable, CaseIterable { case fountain, ball, brush }
public enum StrokePattern: String, Codable, CaseIterable { case solid, dashed, dotted }

/// How a stroke looks. Every field is optional in JSON (missing fields take the defaults below).
public struct InkStyle: Codable, Hashable {
    public var tool: InkTool
    /// Pen tool only.
    public var pen: PenStyle?
    public var color: RGBA
    /// Nominal preset width in points.
    public var width: Double
    public var pattern: StrokePattern
    /// 0 = round … 1 = sharp (fountain pen).
    public var tipSharpness: Double
    /// 0 … 1 (fountain, brush).
    public var pressureSensitivity: Double
    /// 0 … 1 (fountain).
    public var tipFlatness: Double
    /// Apple Pencil Pro barrel roll shapes the nib (fountain).
    public var reactsToRoll: Bool
    /// Tape only: tiled pattern image; nil = solid color.
    public var tapePattern: AssetRef?
    /// Tape only: pattern follows stroke direction instead of staying horizontal.
    public var tapeFollowsDirection: Bool

    public init(tool: InkTool = .pen, pen: PenStyle? = .fountain, color: RGBA = .black, width: Double = 1.2,
                pattern: StrokePattern = .solid, tipSharpness: Double = 0.5, pressureSensitivity: Double = 0.5,
                tipFlatness: Double = 0, reactsToRoll: Bool = false, tapePattern: AssetRef? = nil,
                tapeFollowsDirection: Bool = false) {
        self.tool = tool
        self.pen = pen
        self.color = color
        self.width = width
        self.pattern = pattern
        self.tipSharpness = tipSharpness
        self.pressureSensitivity = pressureSensitivity
        self.tipFlatness = tipFlatness
        self.reactsToRoll = reactsToRoll
        self.tapePattern = tapePattern
        self.tapeFollowsDirection = tapeFollowsDirection
    }

    enum CodingKeys: String, CodingKey {
        case tool, pen, color, width, pattern, tipSharpness, pressureSensitivity, tipFlatness, reactsToRoll,
             tapePattern, tapeFollowsDirection
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = InkStyle()
        tool = try c.decodeIfPresent(InkTool.self, forKey: .tool) ?? d.tool
        pen = try c.decodeIfPresent(PenStyle.self, forKey: .pen) ?? (tool == .pen ? .fountain : nil)
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? d.color
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? d.width
        pattern = try c.decodeIfPresent(StrokePattern.self, forKey: .pattern) ?? d.pattern
        tipSharpness = try c.decodeIfPresent(Double.self, forKey: .tipSharpness) ?? d.tipSharpness
        pressureSensitivity = try c.decodeIfPresent(Double.self, forKey: .pressureSensitivity) ?? d.pressureSensitivity
        tipFlatness = try c.decodeIfPresent(Double.self, forKey: .tipFlatness) ?? d.tipFlatness
        reactsToRoll = try c.decodeIfPresent(Bool.self, forKey: .reactsToRoll) ?? d.reactsToRoll
        tapePattern = try c.decodeIfPresent(AssetRef.self, forKey: .tapePattern)
        tapeFollowsDirection = try c.decodeIfPresent(Bool.self, forKey: .tapeFollowsDirection) ?? d.tapeFollowsDirection
    }

    public static let defaultPen = InkStyle()
    public static let defaultPencil = InkStyle(tool: .pencil, pen: nil, color: RGBA(0x3A, 0x3A, 0x3C), width: 1.6)
    public static let defaultHighlighter = InkStyle(tool: .highlighter, pen: nil, color: .highlighterYellow, width: 12)
    public static let defaultTape = InkStyle(tool: .tape, pen: nil, color: RGBA(0xF4, 0xC4, 0x30), width: 18)
}

/// One captured sample. Page coordinates; `t` seconds since the stroke's `t0`; angles in radians.
/// `width`/`height`/`opacity` are what PencilKit rendered (0 = derive from style with `InkModel.fillSizes`).
public struct StrokePoint: Hashable {
    public var x: Float
    public var y: Float
    public var t: Float
    public var force: Float
    public var azimuth: Float
    public var altitude: Float
    public var roll: Float
    public var width: Float
    public var height: Float
    public var opacity: Float

    public init(x: Float, y: Float, t: Float = 0, force: Float = 0.5, azimuth: Float = 0,
                altitude: Float = 1.5707964, roll: Float = 0, width: Float = 0, height: Float = 0, opacity: Float = 1) {
        self.x = x
        self.y = y
        self.t = t
        self.force = force
        self.azimuth = azimuth
        self.altitude = altitude
        self.roll = roll
        self.width = width
        self.height = height
        self.opacity = opacity
    }

    public var location: Point { Point(Double(x), Double(y)) }

    /// Field order of the canonical "full" format.
    public static let fullFormat = ["x", "y", "t", "force", "azimuth", "altitude", "roll", "width", "height", "opacity"]
    public static let fullStride = 10

    /// Accepted `fmt` values for the flat `pts` array (plugins/AI usually send "xy").
    public static let formats: [String: [String]] = [
        "xy": ["x", "y"],
        "xyt": ["x", "y", "t"],
        "xytf": ["x", "y", "t", "force"],
        "xytfaa": ["x", "y", "t", "force", "azimuth", "altitude"],
        "xytfaar": ["x", "y", "t", "force", "azimuth", "altitude", "roll"],
        "full": StrokePoint.fullFormat
    ]

    var packed: [Float] { [x, y, t, force, azimuth, altitude, roll, width, height, opacity] }

    /// Linear interpolation of every field (used by `InkModel.densify`).
    public static func lerp(_ a: StrokePoint, _ b: StrokePoint, _ t: Float) -> StrokePoint {
        func m(_ u: Float, _ v: Float) -> Float { u + (v - u) * t }
        return StrokePoint(x: m(a.x, b.x), y: m(a.y, b.y), t: m(a.t, b.t), force: m(a.force, b.force),
                           azimuth: m(a.azimuth, b.azimuth), altitude: m(a.altitude, b.altitude), roll: m(a.roll, b.roll),
                           width: m(a.width, b.width), height: m(a.height, b.height), opacity: m(a.opacity, b.opacity))
    }

    mutating func set(_ field: String, _ v: Float) {
        switch field {
        case "x": x = v
        case "y": y = v
        case "t": t = v
        case "force": force = v
        case "azimuth": azimuth = v
        case "altitude": altitude = v
        case "roll": roll = v
        case "width": width = v
        case "height": height = v
        case "opacity": opacity = v
        default: break
        }
    }
}

/// A freehand stroke (pen, pencil, highlighter or tape) with the transform baked into its points.
public struct Stroke: Equatable {
    public var style: InkStyle
    public var points: [StrokePoint]
    /// Unix seconds of the first sample (links ink to audio for Note Replay).
    public var t0: Double
    /// Tape only: false = opaque (content hidden), true = revealed.
    public var tapeRevealed: Bool

    public init(style: InkStyle, points: [StrokePoint], t0: Double = Date().timeIntervalSince1970, tapeRevealed: Bool = false) {
        self.style = style
        self.points = points
        self.t0 = t0
        self.tapeRevealed = tapeRevealed
    }

    public var polyline: [Point] { points.map { $0.location } }

    /// Bounds including half the nib width.
    public var bounds: Rect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        var maxW: Float = 0
        for p in points {
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
            maxW = max(maxW, max(p.width, p.height))
        }
        let pad = Double(max(maxW, Float(style.width))) / 2 + 1
        return Rect(x: Double(minX) - pad, y: Double(minY) - pad,
                    width: Double(maxX - minX) + 2 * pad, height: Double(maxY - minY) + 2 * pad)
    }

    public func transformed(by t: Affine) -> Stroke {
        var s = self
        let k = Float(sqrt(abs(t.determinant)))
        for i in s.points.indices {
            let p = t.apply(s.points[i].location)
            s.points[i].x = Float(p.x)
            s.points[i].y = Float(p.y)
            s.points[i].width *= k
            s.points[i].height *= k
        }
        s.style.width *= Double(k)
        return s
    }
}

public extension CodingUserInfoKey {
    /// Set to `true` in an encoder's `userInfo` to write stroke points as base64 little-endian Float32
    /// (`ptsB64`, used inside document packages). Otherwise points are written as a flat number array (`pts`).
    static let nibCompactPoints = CodingUserInfoKey(rawValue: "nib.compactPoints")!
}

extension Stroke: Codable {
    enum CodingKeys: String, CodingKey { case style, pts, ptsB64, fmt, t0, tapeRevealed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decodeIfPresent(InkStyle.self, forKey: .style) ?? InkStyle()
        t0 = try c.decodeIfPresent(Double.self, forKey: .t0) ?? Date().timeIntervalSince1970
        tapeRevealed = try c.decodeIfPresent(Bool.self, forKey: .tapeRevealed) ?? false
        if let b64 = try c.decodeIfPresent(String.self, forKey: .ptsB64) {
            guard let data = Data(base64Encoded: b64) else {
                throw DecodingError.dataCorruptedError(forKey: .ptsB64, in: c, debugDescription: "invalid base64 points")
            }
            points = Stroke.unpackCompact(data)
        } else {
            let fmt = try c.decodeIfPresent(String.self, forKey: .fmt) ?? "xy"
            guard let fields = StrokePoint.formats[fmt] else {
                throw DecodingError.dataCorruptedError(forKey: .fmt, in: c,
                    debugDescription: "unknown point format '\(fmt)'; use one of \(StrokePoint.formats.keys.sorted())")
            }
            let raw = try c.decodeIfPresent([Double].self, forKey: .pts) ?? []
            points = Stroke.unpack(raw.map { Float($0) }, fields: fields)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(style, forKey: .style)
        try c.encode(t0, forKey: .t0)
        if tapeRevealed { try c.encode(true, forKey: .tapeRevealed) }
        var flat: [Float] = []
        flat.reserveCapacity(points.count * StrokePoint.fullStride)
        for p in points { flat.append(contentsOf: p.packed) }
        if encoder.userInfo[.nibCompactPoints] as? Bool == true {
            let data = flat.withUnsafeBufferPointer { Data(buffer: $0) }
            try c.encode(data.base64EncodedString(), forKey: .ptsB64)
        } else {
            try c.encode("full", forKey: .fmt)
            try c.encode(flat.map { (Double($0) * 1000).rounded() / 1000 }, forKey: .pts)
        }
    }

    /// contracts-v2: points from the compact package form (`ptsB64`: little-endian Float32 in `StrokePoint.fullFormat`
    /// order), without JSON: page readers decode strokes straight from the file bytes.
    public static func unpackCompact(_ data: Data) -> [StrokePoint] {
        var floats = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBufferPointer { data.copyBytes(to: $0) }
        return unpackFull(floats)
    }

    /// contracts-v2: points from a flat array in exactly the encoder's `StrokePoint.fullFormat` order (the fast path
    /// of every "full" and compact decode: no per-field name lookups).
    public static func unpackFull(_ v: [Float]) -> [StrokePoint] {
        let s = StrokePoint.fullStride
        let n = v.count / s
        var out: [StrokePoint] = []
        out.reserveCapacity(n)
        v.withUnsafeBufferPointer { b in
            for k in 0..<n {
                let i = k * s
                out.append(StrokePoint(x: b[i], y: b[i + 1], t: b[i + 2], force: b[i + 3], azimuth: b[i + 4],
                                       altitude: b[i + 5], roll: b[i + 6], width: b[i + 7], height: b[i + 8],
                                       opacity: b[i + 9]))
            }
        }
        return out
    }

    static func unpack(_ v: [Float], fields: [String]) -> [StrokePoint] {
        let stride = fields.count
        guard stride > 0 else { return [] }
        if fields == StrokePoint.fullFormat { return unpackFull(v) }
        var out: [StrokePoint] = []
        out.reserveCapacity(v.count / stride)
        var i = 0
        var n = 0
        while i + stride <= v.count {
            var p = StrokePoint(x: 0, y: 0, t: Float(n) * 0.008)
            for (k, f) in fields.enumerated() { p.set(f, v[i + k]) }
            out.append(p)
            i += stride
            n += 1
        }
        return out
    }
}

public enum InkModel {
    /// Fills zero `width`/`height` (and zero opacity) from the style — for points created by AI, plugins,
    /// ink synthesis or SVG import that carry no rendered nib size.
    public static func fillSizes(_ points: inout [StrokePoint], style: InkStyle) {
        let w = Float(style.width)
        for i in points.indices where points[i].width <= 0 || points[i].height <= 0 {
            var f: Float = 1
            switch style.tool {
            case .pen:
                if style.pen != .ball {
                    f = 1 + (points[i].force - 0.5) * Float(style.pressureSensitivity) * 1.2
                }
            case .pencil:
                f = 0.8 + points[i].force * 0.4
            case .highlighter, .tape:
                f = 1
            }
            let size = max(0.1, w * f)
            points[i].width = size
            points[i].height = size
            if points[i].opacity <= 0 { points[i].opacity = 1 }
        }
    }

    /// Resamples so consecutive points are at most `maxSpacing` points apart (every field interpolated) and
    /// repeats each end point so it appears 3 times. PencilKit treats stroke points as control points of a
    /// uniform cubic B-spline; sparse AI/plugin polylines would otherwise render with rounded, pulled-in corners
    /// that no longer match the polyline used by the eraser, lasso, hit testing and recognition.
    public static func densify(_ points: [StrokePoint], maxSpacing: Float = 1.5) -> [StrokePoint] {
        guard points.count >= 2, let first = points.first, let last = points.last else { return points }
        let spacing = max(maxSpacing, 0.1)
        var out: [StrokePoint] = [first, first]
        out.reserveCapacity(points.count * 4)
        for i in points.indices {
            let p = points[i]
            if i > 0 {
                let a = points[i - 1]
                let d = ((p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y)).squareRoot()
                let n = max(1, Int((d / spacing).rounded(.up)))
                for k in 1..<n { out.append(StrokePoint.lerp(a, p, Float(k) / Float(n))) }
            }
            out.append(p)
        }
        out.append(last)
        out.append(last)
        return out
    }

    /// Normalises a stroke that did not come from PencilKit (AI, plugins, ink synthesis, SVG import, patched
    /// points): when EVERY point has zero width it is densified and its nib sizes are derived from the style.
    /// Captured PencilKit strokes (non-zero widths) are untouched. `ink.addStrokes`, `ink.setPoints`,
    /// `item.update`/`node.set` of stroke points and `PKBridge.pkStroke` all call this before storing/drawing.
    public static func prepare(_ stroke: inout Stroke) {
        guard !stroke.points.isEmpty, stroke.points.allSatisfy({ $0.width <= 0 }) else { return }
        stroke.points = densify(stroke.points)
        fillSizes(&stroke.points, style: stroke.style)
    }
}
```

### `NibKit/Sources/NibContracts/Model/RichText.swift`

```swift
import Foundation

/// A link target on typed text: a web URL, a page of any document, or an audio timestamp.
public struct TextLink: Codable, Hashable {
    public var url: String?
    public var document: DocumentID?
    public var page: PageID?
    public var audioClip: NibID?
    public var audioTime: Double?

    public init(url: String? = nil, document: DocumentID? = nil, page: PageID? = nil,
                audioClip: NibID? = nil, audioTime: Double? = nil) {
        self.url = url
        self.document = document
        self.page = page
        self.audioClip = audioClip
        self.audioTime = audioTime
    }
}

/// Character attributes. nil = inherit (text box default style, then app default).
public struct TextAttributes: Codable, Hashable {
    public var font: String?
    public var size: Double?
    public var color: RGBA?
    public var highlight: RGBA?
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strikethrough: Bool?
    public var code: Bool?
    /// -1 = subscript, 1 = superscript.
    public var baseline: Int?
    public var link: TextLink?
    /// Inline image glyph (system stickers / adaptive image glyphs).
    public var attachment: AssetRef?

    public init(font: String? = nil, size: Double? = nil, color: RGBA? = nil, highlight: RGBA? = nil,
                bold: Bool? = nil, italic: Bool? = nil, underline: Bool? = nil, strikethrough: Bool? = nil,
                code: Bool? = nil, baseline: Int? = nil, link: TextLink? = nil, attachment: AssetRef? = nil) {
        self.font = font
        self.size = size
        self.color = color
        self.highlight = highlight
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.code = code
        self.baseline = baseline
        self.link = link
        self.attachment = attachment
    }
}

public struct TextRun: Codable, Hashable {
    public var text: String
    public var attrs: TextAttributes

    public init(_ text: String, _ attrs: TextAttributes = TextAttributes()) {
        self.text = text
        self.attrs = attrs
    }

    enum CodingKeys: String, CodingKey { case text, attrs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        attrs = try c.decodeIfPresent(TextAttributes.self, forKey: .attrs) ?? TextAttributes()
    }
}

public enum ParagraphAlignment: String, Codable, CaseIterable { case natural, left, center, right, justified }
public enum ListKind: String, Codable, CaseIterable { case plain, bullet, number, numberParen, todo }

public struct Paragraph: Codable, Hashable {
    public var runs: [TextRun]
    public var align: ParagraphAlignment
    public var list: ListKind
    /// Nesting level for lists / indentation (0 = none).
    public var indent: Int
    /// Todo lists only.
    public var checked: Bool
    /// nil = automatic line spacing.
    public var lineSpacing: Double?
    /// Style preset name for full-page text ("title", "heading", "body", "caption").
    public var style: String?

    public init(runs: [TextRun] = [], align: ParagraphAlignment = .natural, list: ListKind = .plain, indent: Int = 0,
                checked: Bool = false, lineSpacing: Double? = nil, style: String? = nil) {
        self.runs = runs
        self.align = align
        self.list = list
        self.indent = indent
        self.checked = checked
        self.lineSpacing = lineSpacing
        self.style = style
    }

    enum CodingKeys: String, CodingKey { case runs, align, list, indent, checked, lineSpacing, style }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runs = try c.decodeIfPresent([TextRun].self, forKey: .runs) ?? []
        align = try c.decodeIfPresent(ParagraphAlignment.self, forKey: .align) ?? .natural
        list = try c.decodeIfPresent(ListKind.self, forKey: .list) ?? .plain
        indent = try c.decodeIfPresent(Int.self, forKey: .indent) ?? 0
        checked = try c.decodeIfPresent(Bool.self, forKey: .checked) ?? false
        lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing)
        style = try c.decodeIfPresent(String.self, forKey: .style)
    }

    public var plainText: String { runs.map { $0.text }.joined() }
}

/// Rich text used by text boxes, shapes, sticky notes, connectors labels, text-document blocks and cards.
/// In JSON it may also be given as a plain string (one paragraph per line).
public struct RichText: Codable, Hashable {
    public var paragraphs: [Paragraph]

    public init(paragraphs: [Paragraph]) { self.paragraphs = paragraphs }

    public init(plain: String, attrs: TextAttributes = TextAttributes()) {
        paragraphs = plain.components(separatedBy: "\n").map { line in
            Paragraph(runs: line.isEmpty ? [] : [TextRun(line, attrs)])
        }
    }

    public static let empty = RichText(paragraphs: [Paragraph()])

    public var plainText: String { paragraphs.map { $0.plainText }.joined(separator: "\n") }
    public var isEmpty: Bool { plainText.isEmpty }

    enum CodingKeys: String, CodingKey { case paragraphs }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self = RichText(plain: s)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paragraphs = try c.decode([Paragraph].self, forKey: .paragraphs)
    }
}
```

### `NibKit/Sources/NibContracts/Model/Items.swift`

```swift
import Foundation

public enum ItemKind: String, Codable, CaseIterable {
    case stroke, shape, connector, text, image, sticky, math, comment, custom
}

// MARK: - Shapes and connectors

public enum ShapeKind: String, Codable, CaseIterable {
    case line, polyline, polygon, rectangle, roundedRectangle, ellipse, triangle, diamond, arc, curve, arrow
}

public struct ShapeItemStyle: Codable, Hashable {
    /// nil = no outline (fill-only shape).
    public var strokeColor: RGBA?
    public var strokeWidth: Double
    /// nil = no fill.
    public var fillColor: RGBA?
    public var cornerRadius: Double
    public var pattern: StrokePattern
    /// Shapes snapped from Draw-and-Hold keep the look of the tool that drew them.
    public var drawnWith: InkTool?
    public var arrowStart: Bool
    public var arrowEnd: Bool

    public init(strokeColor: RGBA? = .black, strokeWidth: Double = 1.5, fillColor: RGBA? = nil, cornerRadius: Double = 6,
                pattern: StrokePattern = .solid, drawnWith: InkTool? = nil, arrowStart: Bool = false, arrowEnd: Bool = false) {
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.fillColor = fillColor
        self.cornerRadius = cornerRadius
        self.pattern = pattern
        self.drawnWith = drawnWith
        self.arrowStart = arrowStart
        self.arrowEnd = arrowEnd
    }

    enum CodingKeys: String, CodingKey {
        case strokeColor, strokeWidth, fillColor, cornerRadius, pattern, drawnWith, arrowStart, arrowEnd
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strokeColor = try c.decodeIfPresent(RGBA.self, forKey: .strokeColor)
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 1.5
        fillColor = try c.decodeIfPresent(RGBA.self, forKey: .fillColor)
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 6
        pattern = try c.decodeIfPresent(StrokePattern.self, forKey: .pattern) ?? .solid
        drawnWith = try c.decodeIfPresent(InkTool.self, forKey: .drawnWith)
        arrowStart = try c.decodeIfPresent(Bool.self, forKey: .arrowStart) ?? false
        arrowEnd = try c.decodeIfPresent(Bool.self, forKey: .arrowEnd) ?? false
    }
}

public struct ShapeItem: Codable, Equatable {
    public var shape: ShapeKind
    public var frame: Frame
    /// Vertices / control points in page coordinates (line, polyline, polygon, arc, curve, arrow).
    /// Empty for box shapes, which are defined by `frame` alone.
    /// contracts-v2 (pinned): points are CONTROL points, never points the curve passes through, so the shape stays inside
    /// the points' bounds and `Item.bounds` is right.
    /// - `.curve`: Bézier control points: 2 = straight, 3 = quadratic, 4 = cubic, 5+ = clamped uniform B-spline.
    /// - `.arc`: [start, control, end]. For sweeps under 170° `control` is where the tangents at start and end meet
    ///   (a conic arc, circular when |control − start| = |control − end|); wider sweeps and parabolas are sent as a
    ///   quadratic start / control / end. Convert three through-points with `ShapeItem.quadraticControl(through:_:_:)`.
    public var points: [Point]
    public var style: ShapeItemStyle
    public var text: RichText?

    public init(shape: ShapeKind, frame: Frame, points: [Point] = [], style: ShapeItemStyle = ShapeItemStyle(), text: RichText? = nil) {
        self.shape = shape
        self.frame = frame
        self.points = points
        self.style = style
        self.text = text
    }

    /// contracts-v2: the quadratic Bézier control points [start, control, end] of the curve through `start`, `mid` (at
    /// t = 0.5) and `end`: control = 2·mid − (start + end) / 2.
    public static func quadraticControl(through start: Point, _ mid: Point, _ end: Point) -> [Point] {
        [start, Point(2 * mid.x - (start.x + end.x) / 2, 2 * mid.y - (start.y + end.y) / 2), end]
    }

    enum CodingKeys: String, CodingKey { case shape, frame, points, style, text }

    /// Lenient (AI / plugin JSON): only `shape` is required; `frame` defaults to the bounds of `points`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shape = try c.decode(ShapeKind.self, forKey: .shape)
        points = try c.decodeIfPresent([Point].self, forKey: .points) ?? []
        frame = try c.decodeIfPresent(Frame.self, forKey: .frame)
            ?? Rect.bounding(points).map { Frame($0) } ?? Frame(x: 0, y: 0, w: 0, h: 0)
        style = try c.decodeIfPresent(ShapeItemStyle.self, forKey: .style) ?? ShapeItemStyle()
        text = try c.decodeIfPresent(RichText.self, forKey: .text)
    }
}

public struct ConnectorEnd: Codable, Hashable {
    /// Current end point in page coordinates (kept in sync with the anchored item).
    public var point: Point
    /// Anchored shape/item, if any.
    public var item: ElementID?
    /// 0 top, 1 right, 2 bottom, 3 left.
    public var side: Int?
    /// 0…1 along the side.
    public var t: Double?

    public init(point: Point, item: ElementID? = nil, side: Int? = nil, t: Double? = nil) {
        self.point = point
        self.item = item
        self.side = side
        self.t = t
    }

    enum CodingKeys: String, CodingKey { case point, item, side, t }

    /// Lenient: `point` defaults to (0, 0) (anchored ends are recomputed from `item`/`side`/`t` by the commands).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        point = try c.decodeIfPresent(Point.self, forKey: .point) ?? .zero
        item = try c.decodeIfPresent(ElementID.self, forKey: .item)
        side = try c.decodeIfPresent(Int.self, forKey: .side)
        t = try c.decodeIfPresent(Double.self, forKey: .t)
    }
}

public enum ConnectorRoute: String, Codable, CaseIterable { case straight, elbow, curved }

public struct ConnectorItem: Codable, Equatable {
    public var from: ConnectorEnd
    public var to: ConnectorEnd
    public var route: ConnectorRoute
    /// User-added bend / control points.
    public var bends: [Point]
    public var style: ShapeItemStyle
    public var label: RichText?

    public init(from: ConnectorEnd, to: ConnectorEnd, route: ConnectorRoute = .straight, bends: [Point] = [],
                style: ShapeItemStyle = ShapeItemStyle(arrowEnd: true), label: RichText? = nil) {
        self.from = from
        self.to = to
        self.route = route
        self.bends = bends
        self.style = style
        self.label = label
    }

    enum CodingKeys: String, CodingKey { case from, to, route, bends, style, label }

    /// Lenient: only `from` and `to` are required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(ConnectorEnd.self, forKey: .from)
        to = try c.decode(ConnectorEnd.self, forKey: .to)
        route = try c.decodeIfPresent(ConnectorRoute.self, forKey: .route) ?? .straight
        bends = try c.decodeIfPresent([Point].self, forKey: .bends) ?? []
        style = try c.decodeIfPresent(ShapeItemStyle.self, forKey: .style) ?? ShapeItemStyle(arrowEnd: true)
        label = try c.decodeIfPresent(RichText.self, forKey: .label)
    }
}

// MARK: - Boxes

public struct TextBoxStyle: Codable, Hashable {
    public var background: RGBA?
    public var borderColor: RGBA?
    public var borderWidth: Double
    public var cornerRadius: Double
    public var padding: Double
    public var shadow: Bool
    /// Grow height to fit content.
    public var autoGrow: Bool
    /// Full-page ("body") text: page-sized box at the bottom of the z-order.
    public var fullPage: Bool
    /// Default character attributes for runs that leave fields nil.
    public var defaults: TextAttributes
    /// contracts-v2: paragraph defaults of a saved or default style (applied to new paragraphs); nil = natural / none.
    public var align: ParagraphAlignment?
    public var lineSpacing: Double?

    public init(background: RGBA? = nil, borderColor: RGBA? = nil, borderWidth: Double = 0, cornerRadius: Double = 0,
                padding: Double = 4, shadow: Bool = false, autoGrow: Bool = true, fullPage: Bool = false,
                defaults: TextAttributes = TextAttributes(), align: ParagraphAlignment? = nil, lineSpacing: Double? = nil) {
        self.background = background
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.shadow = shadow
        self.autoGrow = autoGrow
        self.fullPage = fullPage
        self.defaults = defaults
        self.align = align
        self.lineSpacing = lineSpacing
    }

    enum CodingKeys: String, CodingKey {
        case background, borderColor, borderWidth, cornerRadius, padding, shadow, autoGrow, fullPage, defaults
        case align, lineSpacing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        background = try c.decodeIfPresent(RGBA.self, forKey: .background)
        borderColor = try c.decodeIfPresent(RGBA.self, forKey: .borderColor)
        borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 0
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? 4
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? false
        autoGrow = try c.decodeIfPresent(Bool.self, forKey: .autoGrow) ?? true
        fullPage = try c.decodeIfPresent(Bool.self, forKey: .fullPage) ?? false
        defaults = try c.decodeIfPresent(TextAttributes.self, forKey: .defaults) ?? TextAttributes()
        align = (try? c.decodeIfPresent(ParagraphAlignment.self, forKey: .align)) ?? nil
        lineSpacing = (try? c.decodeIfPresent(Double.self, forKey: .lineSpacing)) ?? nil
    }
}

public struct TextBoxItem: Codable, Equatable {
    public var frame: Frame
    public var text: RichText
    public var style: TextBoxStyle

    public init(frame: Frame, text: RichText, style: TextBoxStyle = TextBoxStyle()) {
        self.frame = frame
        self.text = text
        self.style = style
    }

    enum CodingKeys: String, CodingKey { case frame, text, style }

    /// Lenient: only `frame` is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = try c.decode(Frame.self, forKey: .frame)
        text = try c.decodeIfPresent(RichText.self, forKey: .text) ?? .empty
        style = try c.decodeIfPresent(TextBoxStyle.self, forKey: .style) ?? TextBoxStyle()
    }
}

public struct ImageItem: Codable, Equatable {
    public var frame: Frame
    public var asset: AssetRef
    /// Rectangular crop, normalized 0…1 in image space.
    public var crop: Rect?
    /// Freehand crop outline, normalized 0…1 in image space.
    public var mask: [Point]?
    /// Animated GIF: tiles show the first frame, a live view animates it while visible.
    public var animated: Bool
    public var altText: String?
    /// contracts-v2: mirrored horizontally / vertically inside the frame (after `crop`); nil = not flipped. Every
    /// drawer, live view and export honours them.
    public var flipX: Bool?
    public var flipY: Bool?

    public init(frame: Frame, asset: AssetRef, crop: Rect? = nil, mask: [Point]? = nil, animated: Bool = false, altText: String? = nil) {
        self.frame = frame
        self.asset = asset
        self.crop = crop
        self.mask = mask
        self.animated = animated
        self.altText = altText
    }

    enum CodingKeys: String, CodingKey { case frame, asset, crop, mask, animated, altText, flipX, flipY }

    /// Lenient: `frame` and `asset` are required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = try c.decode(Frame.self, forKey: .frame)
        asset = try c.decode(AssetRef.self, forKey: .asset)
        crop = try c.decodeIfPresent(Rect.self, forKey: .crop)
        mask = try c.decodeIfPresent([Point].self, forKey: .mask)
        animated = try c.decodeIfPresent(Bool.self, forKey: .animated) ?? false
        altText = try c.decodeIfPresent(String.self, forKey: .altText)
        flipX = try c.decodeIfPresent(Bool.self, forKey: .flipX)
        flipY = try c.decodeIfPresent(Bool.self, forKey: .flipY)
    }
}

public struct StickyItem: Codable, Equatable {
    public var frame: Frame
    public var color: RGBA
    public var text: RichText
    public var collapsed: Bool
    public var author: String?
    public var resolved: Bool

    public init(frame: Frame, color: RGBA = RGBA(0xFF, 0xE8, 0x7C), text: RichText = .empty, collapsed: Bool = false,
                author: String? = nil, resolved: Bool = false) {
        self.frame = frame
        self.color = color
        self.text = text
        self.collapsed = collapsed
        self.author = author
        self.resolved = resolved
    }

    enum CodingKeys: String, CodingKey { case frame, color, text, collapsed, author, resolved }

    /// Lenient: only `frame` is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = try c.decode(Frame.self, forKey: .frame)
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? RGBA(0xFF, 0xE8, 0x7C)
        text = try c.decodeIfPresent(RichText.self, forKey: .text) ?? .empty
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        author = try c.decodeIfPresent(String.self, forKey: .author)
        resolved = try c.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
    }
}

public struct MathItem: Codable, Equatable {
    public var frame: Frame
    /// One LaTeX string per line.
    public var latex: [String]
    public var color: RGBA
    /// The handwriting it was converted from ("Copy Handwriting").
    public var sourceInk: [Stroke]?

    public init(frame: Frame, latex: [String], color: RGBA = .black, sourceInk: [Stroke]? = nil) {
        self.frame = frame
        self.latex = latex
        self.color = color
        self.sourceInk = sourceInk
    }

    enum CodingKeys: String, CodingKey { case frame, latex, color, sourceInk }

    /// Lenient: only `frame` is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = try c.decode(Frame.self, forKey: .frame)
        latex = try c.decodeIfPresent([String].self, forKey: .latex) ?? []
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? .black
        sourceInk = try c.decodeIfPresent([Stroke].self, forKey: .sourceInk)
    }
}

public struct CommentMessage: Codable, Equatable {
    public var id: NibID
    public var author: String
    public var text: String
    /// Unix seconds.
    public var at: Double
    public var edited: Bool

    public init(id: NibID = NibID.make(), author: String, text: String, at: Double = Date().timeIntervalSince1970, edited: Bool = false) {
        self.id = id
        self.author = author
        self.text = text
        self.at = at
        self.edited = edited
    }

    enum CodingKeys: String, CodingKey { case id, author, text, at, edited }

    /// Lenient: only `text` is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(NibID.self, forKey: .id) ?? NibID.make()
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        text = try c.decode(String.self, forKey: .text)
        at = try c.decodeIfPresent(Double.self, forKey: .at) ?? Date().timeIntervalSince1970
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
    }
}

public struct CommentItem: Codable, Equatable {
    /// Pin location. When `Item.attachedTo` is set the pin follows that item.
    public var anchor: Point
    public var messages: [CommentMessage]
    public var resolved: Bool

    public init(anchor: Point, messages: [CommentMessage], resolved: Bool = false) {
        self.anchor = anchor
        self.messages = messages
        self.resolved = resolved
    }

    enum CodingKeys: String, CodingKey { case anchor, messages, resolved }

    /// Lenient: only `anchor` is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anchor = try c.decode(Point.self, forKey: .anchor)
        messages = try c.decodeIfPresent([CommentMessage].self, forKey: .messages) ?? []
        resolved = try c.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
    }
}

// MARK: - Plugin / custom items

public enum DisplayOpKind: String, Codable, CaseIterable {
    case rect, ellipse, line, polyline, polygon, text, image, hlines, vlines, dots
}

/// One drawing instruction. Coordinates are relative to the owning frame's top-left (custom items)
/// or to the page (templates). Unused fields stay nil.
public struct DisplayOp: Codable, Equatable {
    public var op: DisplayOpKind
    public var rect: Rect?
    public var points: [Point]?
    public var stroke: RGBA?
    public var fill: RGBA?
    public var width: Double?
    public var dash: [Double]?
    public var text: String?
    public var fontSize: Double?
    public var fontName: String?
    public var asset: AssetRef?
    /// Line / dot spacing for hlines, vlines, dots.
    public var spacing: Double?
    /// Corner radius (rect) or dot radius (dots).
    public var radius: Double?
    /// contracts-v2: `text` alignment inside `rect` (nil = natural / left).
    public var align: ParagraphAlignment?
    /// contracts-v2: `text` weight of the system font (ignored with `fontName`); nil = regular.
    public var weight: DisplayFontWeight?

    public init(op: DisplayOpKind, rect: Rect? = nil, points: [Point]? = nil, stroke: RGBA? = nil, fill: RGBA? = nil,
                width: Double? = nil, dash: [Double]? = nil, text: String? = nil, fontSize: Double? = nil,
                fontName: String? = nil, asset: AssetRef? = nil, spacing: Double? = nil, radius: Double? = nil,
                align: ParagraphAlignment? = nil, weight: DisplayFontWeight? = nil) {
        self.op = op
        self.rect = rect
        self.points = points
        self.stroke = stroke
        self.fill = fill
        self.width = width
        self.dash = dash
        self.text = text
        self.fontSize = fontSize
        self.fontName = fontName
        self.asset = asset
        self.spacing = spacing
        self.radius = radius
        self.align = align
        self.weight = weight
    }
}

/// contracts-v2: font weights a `DisplayOp` text can use (template headings, planner labels).
public enum DisplayFontWeight: String, Codable, CaseIterable {
    case light, regular, medium, semibold, bold, heavy
}

/// A tiny vector format drawn by the host renderer (templates, plugin items, math graphs, AI diagrams).
public struct DisplayList: Codable, Equatable {
    public var ops: [DisplayOp]
    public init(ops: [DisplayOp] = []) { self.ops = ops }

    enum CodingKeys: String, CodingKey { case ops }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ops = try c.decodeIfPresent([DisplayOp].self, forKey: .ops) ?? []
    }
}

/// An item whose meaning is owned by a feature or plugin. It always renders from `display`,
/// so it survives the owner being disabled or uninstalled.
public struct CustomItem: Codable, Equatable {
    /// Feature or plugin id, e.g. "nib.mathgraph" or "dev.example.chart".
    public var owner: String
    public var type: String
    public var frame: Frame
    public var data: JSONValue
    public var display: DisplayList

    public init(owner: String, type: String, frame: Frame, data: JSONValue = [:], display: DisplayList = DisplayList()) {
        self.owner = owner
        self.type = type
        self.frame = frame
        self.data = data
        self.display = display
    }

    enum CodingKeys: String, CodingKey { case owner, type, frame, data, display }

    /// Lenient: `owner`, `type` and `frame` are required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decode(String.self, forKey: .owner)
        type = try c.decode(String.self, forKey: .type)
        frame = try c.decode(Frame.self, forKey: .frame)
        data = try c.decodeIfPresent(JSONValue.self, forKey: .data) ?? [:]
        display = try c.decodeIfPresent(DisplayList.self, forKey: .display) ?? DisplayList()
    }
}

// MARK: - Item

/// Every object on a page. Exactly one payload matching `kind` is non-nil.
/// JSON: {"id":"…","kind":"stroke","layer":0,"z":"V","stroke":{…}}.
public struct Item: Codable, Equatable, Identifiable, LWWRecord {
    public var id: ElementID
    public var rev: Rev
    /// Tombstone (kept for sync / undo).
    public var deleted: Bool
    public var kind: ItemKind
    /// Fractional z-order key; empty = assign on first write (top of the page).
    public var z: String
    /// 0…4.
    public var layer: Int
    public var locked: Bool
    /// Container shape / sticky note / anchored comment target.
    public var attachedTo: ElementID?
    /// Provenance: "user", "ai:<chat>", "plugin:<id>", "bridge:<client>".
    public var createdBy: String?
    /// Plugin-owned data keyed by plugin id.
    public var ext: [String: JSONValue]?

    public var stroke: Stroke?
    public var shape: ShapeItem?
    public var connector: ConnectorItem?
    public var text: TextBoxItem?
    public var image: ImageItem?
    public var sticky: StickyItem?
    public var math: MathItem?
    public var comment: CommentItem?
    public var custom: CustomItem?

    public init(id: ElementID = NibID.make(), kind: ItemKind, z: String = "", layer: Int = 0, locked: Bool = false,
                attachedTo: ElementID? = nil, createdBy: String? = nil, ext: [String: JSONValue]? = nil,
                stroke: Stroke? = nil, shape: ShapeItem? = nil, connector: ConnectorItem? = nil, text: TextBoxItem? = nil,
                image: ImageItem? = nil, sticky: StickyItem? = nil, math: MathItem? = nil, comment: CommentItem? = nil,
                custom: CustomItem? = nil) {
        self.id = id
        self.rev = .zero
        self.deleted = false
        self.kind = kind
        self.z = z
        self.layer = layer
        self.locked = locked
        self.attachedTo = attachedTo
        self.createdBy = createdBy
        self.ext = ext
        self.stroke = stroke
        self.shape = shape
        self.connector = connector
        self.text = text
        self.image = image
        self.sticky = sticky
        self.math = math
        self.comment = comment
        self.custom = custom
    }

    enum CodingKeys: String, CodingKey {
        case id, rev, deleted, kind, z, layer, locked, attachedTo, createdBy, ext
        case stroke, shape, connector, text, image, sticky, math, comment, custom
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(ElementID.self, forKey: .id) ?? NibID.make()
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        kind = try c.decode(ItemKind.self, forKey: .kind)
        z = try c.decodeIfPresent(String.self, forKey: .z) ?? ""
        layer = try c.decodeIfPresent(Int.self, forKey: .layer) ?? 0
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        attachedTo = try c.decodeIfPresent(ElementID.self, forKey: .attachedTo)
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
        ext = try c.decodeIfPresent([String: JSONValue].self, forKey: .ext)
        stroke = try c.decodeIfPresent(Stroke.self, forKey: .stroke)
        shape = try c.decodeIfPresent(ShapeItem.self, forKey: .shape)
        connector = try c.decodeIfPresent(ConnectorItem.self, forKey: .connector)
        text = try c.decodeIfPresent(TextBoxItem.self, forKey: .text)
        image = try c.decodeIfPresent(ImageItem.self, forKey: .image)
        sticky = try c.decodeIfPresent(StickyItem.self, forKey: .sticky)
        math = try c.decodeIfPresent(MathItem.self, forKey: .math)
        comment = try c.decodeIfPresent(CommentItem.self, forKey: .comment)
        custom = try c.decodeIfPresent(CustomItem.self, forKey: .custom)
    }

    // MARK: Factories

    public static func makeStroke(_ s: Stroke, layer: Int = 0) -> Item { Item(kind: .stroke, layer: layer, stroke: s) }
    public static func makeShape(_ s: ShapeItem, layer: Int = 0) -> Item { Item(kind: .shape, layer: layer, shape: s) }
    public static func makeConnector(_ c: ConnectorItem, layer: Int = 0) -> Item { Item(kind: .connector, layer: layer, connector: c) }
    public static func makeText(_ t: TextBoxItem, layer: Int = 0) -> Item { Item(kind: .text, layer: layer, text: t) }
    public static func makeImage(_ i: ImageItem, layer: Int = 0) -> Item { Item(kind: .image, layer: layer, image: i) }
    public static func makeSticky(_ s: StickyItem, layer: Int = 0) -> Item { Item(kind: .sticky, layer: layer, sticky: s) }
    public static func makeMath(_ m: MathItem, layer: Int = 0) -> Item { Item(kind: .math, layer: layer, math: m) }
    public static func makeComment(_ c: CommentItem, layer: Int = 0) -> Item { Item(kind: .comment, layer: layer, comment: c) }
    public static func makeCustom(_ c: CustomItem, layer: Int = 0) -> Item { Item(kind: .custom, layer: layer, custom: c) }

    // MARK: Derived

    /// True when exactly the payload matching `kind` is present.
    public var isValid: Bool {
        var kinds: [ItemKind] = []
        if stroke != nil { kinds.append(.stroke) }
        if shape != nil { kinds.append(.shape) }
        if connector != nil { kinds.append(.connector) }
        if text != nil { kinds.append(.text) }
        if image != nil { kinds.append(.image) }
        if sticky != nil { kinds.append(.sticky) }
        if math != nil { kinds.append(.math) }
        if comment != nil { kinds.append(.comment) }
        if custom != nil { kinds.append(.custom) }
        return kinds == [kind]
    }

    /// Key used to look up an `ItemDrawer`: "stroke.<tool>", "custom.<owner>.<type>", or the kind name.
    public var drawKey: String {
        switch kind {
        case .stroke: return "stroke." + (stroke?.style.tool.rawValue ?? InkTool.pen.rawValue)
        case .custom: return "custom." + (custom?.owner ?? "") + "." + (custom?.type ?? "")
        default: return kind.rawValue
        }
    }

    /// Frame of frame-based kinds (shape, text, image, sticky, math, custom); nil otherwise.
    public var frame: Frame? {
        get {
            switch kind {
            case .shape: return shape?.frame
            case .text: return text?.frame
            case .image: return image?.frame
            case .sticky: return sticky?.frame
            case .math: return math?.frame
            case .custom: return custom?.frame
            default: return nil
            }
        }
        set {
            guard let f = newValue else { return }
            switch kind {
            case .shape: shape?.frame = f
            case .text: text?.frame = f
            case .image: image?.frame = f
            case .sticky: sticky?.frame = f
            case .math: math?.frame = f
            case .custom: custom?.frame = f
            default: break
            }
        }
    }

    /// Axis-aligned bounds in page coordinates.
    public var bounds: Rect {
        switch kind {
        case .stroke:
            return stroke?.bounds ?? .zero
        case .shape:
            guard let s = shape else { return .zero }
            let pad = s.style.strokeWidth / 2 + 1
            if let r = Rect.bounding(s.points), !s.points.isEmpty { return r.insetBy(-pad) }
            return s.frame.bounds.insetBy(-pad)
        case .connector:
            guard let c = connector else { return .zero }
            let r = Rect.bounding([c.from.point, c.to.point] + c.bends) ?? .zero
            return r.insetBy(-(c.style.strokeWidth / 2 + 6))
        case .comment:
            guard let c = comment else { return .zero }
            return Rect(x: c.anchor.x - 12, y: c.anchor.y - 12, width: 24, height: 24)
        default:
            return frame?.bounds ?? .zero
        }
    }

    /// Point on a side of a frame-based item (0 top, 1 right, 2 bottom, 3 left; t 0…1), used by connectors.
    public func anchorPoint(side: Int, t: Double) -> Point? {
        guard let f = frame else { return nil }
        let c = f.corners
        var a = c[0]
        var b = c[1]
        switch side {
        case 1:
            a = c[1]
            b = c[2]
        case 2:
            a = c[3]
            b = c[2]
        case 3:
            a = c[0]
            b = c[3]
        default:
            break
        }
        let k = max(0, min(1, t))
        return Point(a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k)
    }

    /// Applies a transform to the geometry (points are baked; frames move/scale/rotate; stroke widths scale).
    public func transformed(by t: Affine) -> Item {
        var it = self
        switch kind {
        case .stroke:
            it.stroke = stroke?.transformed(by: t)
        case .shape:
            if var s = shape {
                s.frame = s.frame.applying(t)
                s.points = s.points.map { t.apply($0) }
                it.shape = s
            }
        case .connector:
            if var c = connector {
                c.from.point = t.apply(c.from.point)
                c.to.point = t.apply(c.to.point)
                c.bends = c.bends.map { t.apply($0) }
                it.connector = c
            }
        case .comment:
            if var c = comment {
                c.anchor = t.apply(c.anchor)
                it.comment = c
            }
        case .math:
            if var m = math {
                m.frame = m.frame.applying(t)
                m.sourceInk = m.sourceInk?.map { $0.transformed(by: t) }
                it.math = m
            }
        case .text, .image, .sticky, .custom:
            if let f = frame { it.frame = f.applying(t) }
        }
        return it
    }
}
```

### `NibKit/Sources/NibContracts/Model/Document.swift`

```swift
import Foundation

// MARK: - Last-writer-wins records

/// A synced record: merged by `id`, the higher `rev` wins; deletion is a tombstone.
public protocol LWWRecord: Codable, Equatable {
    var id: NibID { get }
    var rev: Rev { get set }
    var deleted: Bool { get set }
}

public enum LWW {
    /// Merges `incoming` into `base` by id keeping the higher rev (far-future revs are distrusted, see `Rev.effective`).
    /// Order: base order, new records appended.
    public static func merge<T: LWWRecord>(_ base: [T], _ incoming: [T]) -> [T] {
        var index: [NibID: Int] = [:]
        var out = base
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        for (i, r) in out.enumerated() { index[r.id] = i }
        for r in incoming {
            if let i = index[r.id] {
                if r.rev.effective(now: now) > out[i].rev.effective(now: now) { out[i] = r }
            } else {
                index[r.id] = out.count
                out.append(r)
            }
        }
        return out
    }
}

// MARK: - Documents

public enum DocumentKind: String, Codable, CaseIterable { case notebook, whiteboard, textDocument, studySet }
public enum ScrollDirection: String, Codable, CaseIterable { case vertical, horizontal }

public struct LayerInfo: Codable, Hashable {
    public var index: Int
    public var name: String
    public init(index: Int, name: String) {
        self.index = index
        self.name = name
    }

    enum CodingKeys: String, CodingKey { case index, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Layer \(index + 1)"
    }
}

public struct PageSize: Codable, Hashable {
    public var width: Double
    public var height: Double

    public init(_ width: Double, _ height: Double) {
        self.width = width
        self.height = height
    }

    public var isLandscape: Bool { width > height }
    public var rotated: PageSize { PageSize(height, width) }

    public static let standard = PageSize(455.04, 588.45)
    public static let standardLandscape = PageSize(650.88, 406.8)
    public static let a3 = PageSize(841.89, 1190.55)
    public static let a4 = PageSize(595.28, 841.89)
    public static let a5 = PageSize(419.53, 595.28)
    public static let a6 = PageSize(297.64, 419.53)
    public static let a7 = PageSize(209.76, 297.64)
    public static let b5 = PageSize(498.9, 708.66)
    public static let letter = PageSize(612, 792)
    public static let legal = PageSize(612, 1008)
    public static let tabloid = PageSize(792, 1224)
    public static let square = PageSize(595.28, 595.28)

    public static let presets: [(name: String, size: PageSize)] = [
        ("Standard", PageSize.standard), ("A3", PageSize.a3), ("A4", PageSize.a4), ("A5", PageSize.a5),
        ("A6", PageSize.a6), ("A7", PageSize.a7), ("B5", PageSize.b5), ("Letter", PageSize.letter),
        ("Legal", PageSize.legal), ("Tabloid", PageSize.tabloid), ("Square", PageSize.square)
    ]
}

/// Reference to a registered (parametric) template: `{"id": "builtin.ruled", "params": {"spacing": 24}}`.
public struct TemplateRef: Codable, Hashable {
    public var id: String
    public var params: [String: JSONValue]

    public init(_ id: String, params: [String: JSONValue] = [:]) {
        self.id = id
        self.params = params
    }

    enum CodingKeys: String, CodingKey { case id, params }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        params = try c.decodeIfPresent([String: JSONValue].self, forKey: .params) ?? [:]
    }
}

public enum BackgroundKind: String, Codable, CaseIterable { case template, pdf, image, color }

/// Page background. PDFs and images are referenced assets; templates are parametric.
public struct Background: Codable, Hashable {
    public var kind: BackgroundKind
    public var template: TemplateRef?
    public var asset: AssetRef?
    /// 0-based page index inside the PDF asset.
    public var pdfPage: Int?
    public var color: RGBA?

    public init(kind: BackgroundKind, template: TemplateRef? = nil, asset: AssetRef? = nil, pdfPage: Int? = nil, color: RGBA? = nil) {
        self.kind = kind
        self.template = template
        self.asset = asset
        self.pdfPage = pdfPage
        self.color = color
    }

    public static func ofTemplate(_ id: String, params: [String: JSONValue] = [:]) -> Background {
        Background(kind: .template, template: TemplateRef(id, params: params))
    }
    public static func ofPDF(_ asset: AssetRef, page: Int) -> Background { Background(kind: .pdf, asset: asset, pdfPage: page) }
    public static func ofImage(_ asset: AssetRef) -> Background { Background(kind: .image, asset: asset) }
    public static func ofColor(_ color: RGBA) -> Background { Background(kind: .color, color: color) }
}

public struct DocumentMeta: Codable, Equatable {
    public var id: DocumentID
    public var rev: Rev
    /// `NibFormat.version` that last wrote this document.
    public var format: Int
    public var kind: DocumentKind
    /// Unix seconds.
    public var createdAt: Double
    /// BCP-47 handwriting-recognition / search language.
    public var language: String
    public var scrollDirection: ScrollDirection
    public var favorite: Bool
    /// Password-locked (access gate, not encryption).
    public var locked: Bool
    public var coverEnabled: Bool
    public var layers: [LayerInfo]
    public var spellcheck: Bool
    public var mathAssist: Bool
    /// Template for "Add Page › Current template" and QuickNote pages.
    public var defaultTemplate: TemplateRef?
    /// Library-relative folder path the document was trashed from (nil when not trashed).
    public var trashedFrom: String?
    /// Security-scoped bookmark of an external source file (import-in-place, "save changes back").
    public var sourceBookmark: Data?
    public var ext: [String: JSONValue]?

    public init(id: DocumentID = NibID.make(), kind: DocumentKind, createdAt: Double = Date().timeIntervalSince1970,
                language: String = "en-US", scrollDirection: ScrollDirection = .vertical) {
        self.id = id
        self.rev = .zero
        self.format = NibFormat.version
        self.kind = kind
        self.createdAt = createdAt
        self.language = language
        self.scrollDirection = scrollDirection
        self.favorite = false
        self.locked = false
        self.coverEnabled = kind == .notebook
        self.layers = (0..<NibLimits.layerCount).map { LayerInfo(index: $0, name: "Layer \($0 + 1)") }
        self.spellcheck = false
        self.mathAssist = false
        self.defaultTemplate = nil
        self.trashedFrom = nil
        self.sourceBookmark = nil
        self.ext = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, rev, format, kind, createdAt, language, scrollDirection, favorite, locked, coverEnabled, layers,
             spellcheck, mathAssist, defaultTemplate, trashedFrom, sourceBookmark, ext
    }

    /// Lenient: every field has a decode default (`kind` defaults to notebook, `format` to 1), so heads written by
    /// older builds and hand-written JSON decode, and new fields can be added with defaults (ARCHITECTURE §16).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(DocumentKind.self, forKey: .kind) ?? .notebook
        self.init(id: try c.decodeIfPresent(DocumentID.self, forKey: .id) ?? NibID.make(), kind: kind,
                  createdAt: try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? Date().timeIntervalSince1970,
                  language: try c.decodeIfPresent(String.self, forKey: .language) ?? "en-US",
                  scrollDirection: try c.decodeIfPresent(ScrollDirection.self, forKey: .scrollDirection) ?? .vertical)
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? 1
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        coverEnabled = try c.decodeIfPresent(Bool.self, forKey: .coverEnabled) ?? (kind == .notebook)
        layers = try c.decodeIfPresent([LayerInfo].self, forKey: .layers) ?? layers
        spellcheck = try c.decodeIfPresent(Bool.self, forKey: .spellcheck) ?? false
        mathAssist = try c.decodeIfPresent(Bool.self, forKey: .mathAssist) ?? false
        defaultTemplate = try c.decodeIfPresent(TemplateRef.self, forKey: .defaultTemplate)
        trashedFrom = try c.decodeIfPresent(String.self, forKey: .trashedFrom)
        sourceBookmark = try c.decodeIfPresent(Data.self, forKey: .sourceBookmark)
        ext = try c.decodeIfPresent([String: JSONValue].self, forKey: .ext)
    }
}

/// A notebook page or whiteboard board. `deleted` + `trashedAt` = in the page Trash (recoverable);
/// `deleted` without `trashedAt` = purged tombstone.
public struct PageRecord: LWWRecord {
    public let id: PageID
    public var rev: Rev
    public var deleted: Bool
    public var trashedAt: Double?
    /// Fractional order key (see `DocumentContent.orderKey`).
    public var order: String
    /// nil = infinite whiteboard board. The page as displayed (after `rotation`).
    public var size: PageSize?
    /// 0, 90, 180 or 270, clockwise (contracts-v2, pinned): turns only a PDF or image BACKGROUND, which is then
    /// aspect-fitted and centred into `size` (`backgroundTransform(sourceSize:)`). Items are stored in page points and
    /// never rotated by it; rotating a page's content is a command that rewrites `size` and item geometry.
    public var rotation: Int
    public var background: Background
    public var bookmarked: Bool
    /// Board name or page label.
    public var title: String?
    /// Zoom Window return height override (points).
    public var zoomReturnHeight: Double?
    public var ext: [String: JSONValue]?

    public init(id: PageID = NibID.make(), order: String = "", size: PageSize? = .a4,
                background: Background = .ofTemplate("builtin.blank"), rotation: Int = 0, title: String? = nil) {
        self.id = id
        self.rev = .zero
        self.deleted = false
        self.trashedAt = nil
        self.order = order
        self.size = size
        self.rotation = rotation
        self.background = background
        self.bookmarked = false
        self.title = title
        self.zoomReturnHeight = nil
        self.ext = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, rev, deleted, trashedAt, order, size, rotation, background, bookmarked, title, zoomReturnHeight, ext
    }

    /// Lenient: every field has a default. An absent `size` means an infinite whiteboard board (nil is never
    /// encoded), so raw inserts of notebook pages must pass `size`; `page.add` fills it for you.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(PageID.self, forKey: .id) ?? NibID.make()
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        trashedAt = try c.decodeIfPresent(Double.self, forKey: .trashedAt)
        order = try c.decodeIfPresent(String.self, forKey: .order) ?? ""
        size = try c.decodeIfPresent(PageSize.self, forKey: .size)
        rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        background = try c.decodeIfPresent(Background.self, forKey: .background) ?? .ofTemplate("builtin.blank")
        bookmarked = try c.decodeIfPresent(Bool.self, forKey: .bookmarked) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title)
        zoomReturnHeight = try c.decodeIfPresent(Double.self, forKey: .zoomReturnHeight)
        ext = try c.decodeIfPresent([String: JSONValue].self, forKey: .ext)
    }
}

public extension PageRecord {
    /// contracts-v2: `ext` key of the text recognised on a scanned page (F065 writes `[TextRecognition]`, NibIndex F055
    /// and search read it).
    static let scanTextExtKey = "nib.scanText"

    /// contracts-v2: maps a background source page (PDF page or image, `sourceSize` in its own points, top-left origin)
    /// into page points: turned clockwise by `rotation`, then aspect-fitted and centred into `size`. Identity when the
    /// sizes match and rotation is 0. Boards (`size == nil`) draw the source unscaled at the origin. Renderers,
    /// PDF link and text hit-testing, and exporters all use it.
    func backgroundTransform(sourceSize: PageSize) -> Affine {
        PageRecord.backgroundTransform(sourceSize: sourceSize, rotation: rotation, pageSize: size)
    }

    static func backgroundTransform(sourceSize: PageSize, rotation: Int, pageSize: PageSize?) -> Affine {
        let w = sourceSize.width, h = sourceSize.height
        let turn: Affine
        switch ((rotation % 360) + 360) % 360 {
        case 90: turn = Affine(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case 180: turn = Affine(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 270: turn = Affine(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        default: turn = .identity
        }
        guard let page = pageSize, w > 0, h > 0 else { return turn }
        let turned = (rotation / 90) % 2 == 0 ? PageSize(w, h) : PageSize(h, w)
        let k = min(page.width / turned.width, page.height / turned.height)
        let ox = (page.width - turned.width * k) / 2, oy = (page.height - turned.height * k) / 2
        return turn.concatenating(Affine(a: k, b: 0, c: 0, d: k, tx: ox, ty: oy))
    }
}

/// A custom outline (table of contents) entry. PDF outlines are read from the PDF, not stored.
public struct OutlineEntry: LWWRecord {
    public let id: NibID
    public var rev: Rev
    public var deleted: Bool
    public var title: String
    public var page: PageID?
    /// Parent entry (max depth 3).
    public var parent: NibID?
    public var order: String

    public init(id: NibID = NibID.make(), title: String, page: PageID?, parent: NibID? = nil, order: String = "") {
        self.id = id
        self.rev = .zero
        self.deleted = false
        self.title = title
        self.page = page
        self.parent = parent
        self.order = order
    }

    enum CodingKeys: String, CodingKey { case id, rev, deleted, title, page, parent, order }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(NibID.self, forKey: .id) ?? NibID.make()
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        page = try c.decodeIfPresent(PageID.self, forKey: .page)
        parent = try c.decodeIfPresent(NibID.self, forKey: .parent)
        order = try c.decodeIfPresent(String.self, forKey: .order) ?? ""
    }
}

/// One transcript line. Transcripts are NOT document records: each device writes its own
/// `<AudioClip.transcriptFile base>.<dev>.json` (`[TranscriptSegment]`); readers merge every such file (plus a
/// legacy `<base>.json`) per `index`, the highest `rev` winning, exactly like package files (ARCHITECTURE §4.3).
public struct TranscriptSegment: Codable, Equatable {
    /// Stable position of the line in the clip's transcript.
    public var index: Int
    /// Seconds from the clip start.
    public var start: Double
    public var duration: Double
    public var text: String
    public var speaker: String?
    /// Last edit (nil = as recognised). The merge keeps the highest rev per index.
    public var rev: Rev?

    public init(index: Int = 0, start: Double, duration: Double, text: String, speaker: String? = nil, rev: Rev? = nil) {
        self.index = index
        self.start = start
        self.duration = duration
        self.text = text
        self.speaker = speaker
        self.rev = rev
    }

    enum CodingKeys: String, CodingKey { case index, start, duration, text, speaker, rev }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        text = try c.decode(String.self, forKey: .text)
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev)
    }
}

/// An audio recording. Audio bytes live at `file` inside the package; transcripts in per-device files derived from
/// `transcriptFile` (see `TranscriptSegment`).
public struct AudioClip: LWWRecord {
    public let id: NibID
    public var rev: Rev
    public var deleted: Bool
    public var name: String
    /// Package-relative path, e.g. "audio/<id>.m4a".
    public var file: String
    /// Unix seconds when recording started (ink with `t0` inside [start, start+duration] is linked).
    public var start: Double
    public var duration: Double
    /// Page where recording started.
    public var page: PageID?
    public var language: String?
    /// Package-relative base path of the transcript, e.g. "audio/<id>.transcript" (device files add ".<dev>.json").
    public var transcriptFile: String?
    public var summary: String?

    public init(id: NibID = NibID.make(), name: String, file: String, start: Double, duration: Double = 0, page: PageID? = nil) {
        self.id = id
        self.rev = .zero
        self.deleted = false
        self.name = name
        self.file = file
        self.start = start
        self.duration = duration
        self.page = page
        self.language = nil
        self.transcriptFile = nil
        self.summary = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, rev, deleted, name, file, start, duration, page, language, transcriptFile, summary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(NibID.self, forKey: .id) ?? NibID.make()
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Recording"
        file = try c.decodeIfPresent(String.self, forKey: .file) ?? "audio/\(id.raw).caf"
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        page = try c.decodeIfPresent(PageID.self, forKey: .page)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        transcriptFile = try c.decodeIfPresent(String.self, forKey: .transcriptFile)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
    }
}

// MARK: - Text documents

public enum BlockKind: String, Codable, CaseIterable {
    case paragraph, heading1, heading2, heading3, bullet, numbered, todo, quote, code, divider, table, image, video
    /// Owned by a feature or plugin (`TextBlock.custom`); always renders from its DisplayList.
    case custom
}

public struct TableCell: Codable, Equatable {
    public var text: RichText
    public var background: RGBA?
    public init(text: RichText = .empty, background: RGBA? = nil) {
        self.text = text
        self.background = background
    }

    enum CodingKeys: String, CodingKey { case text, background }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(RichText.self, forKey: .text) ?? .empty
        background = try c.decodeIfPresent(RGBA.self, forKey: .background)
    }
}

public struct TableMerge: Codable, Hashable {
    public var row: Int
    public var column: Int
    public var rowSpan: Int
    public var columnSpan: Int
    public init(row: Int, column: Int, rowSpan: Int, columnSpan: Int) {
        self.row = row
        self.column = column
        self.rowSpan = rowSpan
        self.columnSpan = columnSpan
    }

    enum CodingKeys: String, CodingKey { case row, column, rowSpan, columnSpan }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        row = try c.decode(Int.self, forKey: .row)
        column = try c.decode(Int.self, forKey: .column)
        rowSpan = try c.decodeIfPresent(Int.self, forKey: .rowSpan) ?? 1
        columnSpan = try c.decodeIfPresent(Int.self, forKey: .columnSpan) ?? 1
    }
}

public struct TableData: Codable, Equatable {
    public var rows: [[TableCell]]
    public var columnWidths: [Double]
    public var merges: [TableMerge]
    public var borders: Bool
    public init(rows: [[TableCell]], columnWidths: [Double] = [], merges: [TableMerge] = [], borders: Bool = true) {
        self.rows = rows
        self.columnWidths = columnWidths
        self.merges = merges
        self.borders = borders
    }

    enum CodingKeys: String, CodingKey { case rows, columnWidths, merges, borders }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rows = try c.decodeIfPresent([[TableCell]].self, forKey: .rows) ?? []
        columnWidths = try c.decodeIfPresent([Double].self, forKey: .columnWidths) ?? []
        merges = try c.decodeIfPresent([TableMerge].self, forKey: .merges) ?? []
        borders = try c.decodeIfPresent(Bool.self, forKey: .borders) ?? true
    }
}

/// Payload of a `BlockKind.custom` block (plugins' `contributes.blocks`, feature-owned block kinds). The editor
/// draws `display` in a full-width box `height` points tall, so the block survives its owner being removed.
public struct CustomBlock: Codable, Equatable {
    public var owner: String
    public var type: String
    public var height: Double
    public var data: JSONValue
    public var display: DisplayList

    public init(owner: String, type: String, height: Double = 120, data: JSONValue = [:], display: DisplayList = DisplayList()) {
        self.owner = owner
        self.type = type
        self.height = height
        self.data = data
        self.display = display
    }

    enum CodingKeys: String, CodingKey { case owner, type, height, data, display }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decode(String.self, forKey: .owner)
        type = try c.decode(String.self, forKey: .type)
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 120
        data = try c.decodeIfPresent(JSONValue.self, forKey: .data) ?? [:]
        display = try c.decodeIfPresent(DisplayList.self, forKey: .display) ?? DisplayList()
    }
}

public struct BlockComment: Codable, Equatable {
    public var id: NibID
    public var author: String
    public var text: String
    public var at: Double
    public var resolved: Bool
    /// UTF-16 range inside the block's plain text.
    public var rangeStart: Int
    public var rangeLength: Int
    public init(id: NibID = NibID.make(), author: String, text: String, at: Double = Date().timeIntervalSince1970,
                resolved: Bool = false, rangeStart: Int = 0, rangeLength: Int = 0) {
        self.id = id
        self.author = author
        self.text = text
        self.at = at
        self.resolved = resolved
        self.rangeStart = rangeStart
        self.rangeLength = rangeLength
    }

    enum CodingKeys: String, CodingKey { case id, author, text, at, resolved, rangeStart, rangeLength }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(NibID.self, forKey: .id) ?? NibID.make()
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        text = try c.decode(String.self, forKey: .text)
        at = try c.decodeIfPresent(Double.self, forKey: .at) ?? Date().timeIntervalSince1970
        resolved = try c.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
        rangeStart = try c.decodeIfPresent(Int.self, forKey: .rangeStart) ?? 0
        rangeLength = try c.decodeIfPresent(Int.self, forKey: .rangeLength) ?? 0
    }
}

public struct TextBlock: LWWRecord {
    public let id: NibID
    public var rev: Rev
    public var deleted: Bool
    public var order: String
    public var kind: BlockKind
    public var text: RichText
    public var checked: Bool?
    public var indent: Int?
    public var codeLanguage: String?
    public var table: TableData?
    public var asset: AssetRef?
    /// Video URL for `.video` blocks.
    public var url: String?
    public var caption: RichText?
    public var comments: [BlockComment]?
    /// `.custom` blocks only.
    public var custom: CustomBlock?

    public init(id: NibID = NibID.make(), kind: BlockKind, text: RichText = .empty, order: String = "") {
        self.id = id
        self.rev = .zero
        self.deleted = false
        self.order = order
        self.kind = kind
        self.text = text
        self.checked = nil
        self.indent = nil
        self.codeLanguage = nil
        self.table = nil
        self.asset = nil
        self.url = nil
        self.caption = nil
        self.comments = nil
        self.custom = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, rev, deleted, order, kind, text, checked, indent, codeLanguage, table, asset, url, caption, comments, custom
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(NibID.self, forKey: .id) ?? NibID.make()
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        order = try c.decodeIfPresent(String.self, forKey: .order) ?? ""
        kind = try c.decodeIfPresent(BlockKind.self, forKey: .kind) ?? .paragraph
        text = try c.decodeIfPresent(RichText.self, forKey: .text) ?? .empty
        checked = try c.decodeIfPresent(Bool.self, forKey: .checked)
        indent = try c.decodeIfPresent(Int.self, forKey: .indent)
        codeLanguage = try c.decodeIfPresent(String.self, forKey: .codeLanguage)
        table = try c.decodeIfPresent(TableData.self, forKey: .table)
        asset = try c.decodeIfPresent(AssetRef.self, forKey: .asset)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        caption = try c.decodeIfPresent(RichText.self, forKey: .caption)
        comments = try c.decodeIfPresent([BlockComment].self, forKey: .comments)
        custom = try c.decodeIfPresent(CustomBlock.self, forKey: .custom)
    }
}

// MARK: - Study sets

public enum CardFaceKind: String, Codable, CaseIterable { case text, image, ink }

public struct CardFace: Codable, Equatable {
    public var kind: CardFaceKind
    public var text: RichText?
    public var asset: AssetRef?
    public var ink: [Stroke]?
    /// Canvas size for ink faces.
    public var size: PageSize?
    public init(kind: CardFaceKind = .text, text: RichText? = nil, asset: AssetRef? = nil, ink: [Stroke]? = nil, size: PageSize? = nil) {
        self.kind = kind
        self.text = text
        self.asset = asset
        self.ink = ink
        self.size = size
    }

    enum CodingKeys: String, CodingKey { case kind, text, asset, ink, size }

    /// Lenient: a plain string is a text face; `kind` is inferred (ink > image > text) when absent.
    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self = CardFace(kind: .text, text: RichText(plain: s))
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(RichText.self, forKey: .text)
        asset = try c.decodeIfPresent(AssetRef.self, forKey: .asset)
        ink = try c.decodeIfPresent([Stroke].self, forKey: .ink)
        size = try c.decodeIfPresent(PageSize.self, forKey: .size)
        kind = try c.decodeIfPresent(CardFaceKind.self, forKey: .kind) ?? (ink != nil ? .ink : asset != nil ? .image : .text)
    }
}

/// Spaced-repetition state (Smart Learn).
public struct SRSState: Codable, Equatable {
    /// Unix seconds when the card is next due.
    public var due: Double
    /// Days.
    public var interval: Double
    public var ease: Double
    public var reps: Int
    public var lapses: Int
    public var lastReviewed: Double?
    public init(due: Double = 0, interval: Double = 0, ease: Double = 2.5, reps: Int = 0, lapses: Int = 0, lastReviewed: Double? = nil) {
        self.due = due
        self.interval = interval
        self.ease = ease
        self.reps = reps
        self.lapses = lapses
        self.lastReviewed = lastReviewed
    }

    enum CodingKeys: String, CodingKey { case due, interval, ease, reps, lapses, lastReviewed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        due = try c.decodeIfPresent(Double.self, forKey: .due) ?? 0
        interval = try c.decodeIfPresent(Double.self, forKey: .interval) ?? 0
        ease = try c.decodeIfPresent(Double.self, forKey: .ease) ?? 2.5
        reps = try c.decodeIfPresent(Int.self, forKey: .reps) ?? 0
        lapses = try c.decodeIfPresent(Int.self, forKey: .lapses) ?? 0
        lastReviewed = try c.decodeIfPresent(Double.self, forKey: .lastReviewed)
    }
}

public struct StudyCard: LWWRecord {
    public let id: NibID
    public var rev: Rev
    public var deleted: Bool
    public var order: String
    public var front: CardFace
    public var back: CardFace
    public var srs: SRSState?
    public init(id: NibID = NibID.make(), front: CardFace, back: CardFace, order: String = "") {
        self.id = id
        self.rev = .zero
        self.deleted = false
        self.order = order
        self.front = front
        self.back = back
        self.srs = nil
    }

    enum CodingKeys: String, CodingKey { case id, rev, deleted, order, front, back, srs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(NibID.self, forKey: .id) ?? NibID.make()
        rev = try c.decodeIfPresent(Rev.self, forKey: .rev) ?? .zero
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        order = try c.decodeIfPresent(String.self, forKey: .order) ?? ""
        front = try c.decodeIfPresent(CardFace.self, forKey: .front) ?? CardFace()
        back = try c.decodeIfPresent(CardFace.self, forKey: .back) ?? CardFace()
        srs = try c.decodeIfPresent(SRSState.self, forKey: .srs)
    }
}

// MARK: - Document content (the persisted document head)

public enum PagePosition: String, Codable, CaseIterable { case before, after, start, end }

/// Everything in a document except page items. Page items are loaded per page by `Workspace`.
public struct DocumentContent: Codable, Equatable {
    public var meta: DocumentMeta
    /// All pages including trashed and purged tombstones. Use `livePages` for display order.
    public var pages: [PageRecord]
    public var outline: [OutlineEntry]
    public var blocks: [TextBlock]
    public var cards: [StudyCard]
    public var audio: [AudioClip]

    public init(meta: DocumentMeta, pages: [PageRecord] = [], outline: [OutlineEntry] = [], blocks: [TextBlock] = [],
                cards: [StudyCard] = [], audio: [AudioClip] = []) {
        self.meta = meta
        self.pages = pages
        self.outline = outline
        self.blocks = blocks
        self.cards = cards
        self.audio = audio
    }

    enum CodingKeys: String, CodingKey { case meta, pages, outline, blocks, cards, audio }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try c.decode(DocumentMeta.self, forKey: .meta)
        pages = try c.decodeIfPresent([PageRecord].self, forKey: .pages) ?? []
        outline = try c.decodeIfPresent([OutlineEntry].self, forKey: .outline) ?? []
        blocks = try c.decodeIfPresent([TextBlock].self, forKey: .blocks) ?? []
        cards = try c.decodeIfPresent([StudyCard].self, forKey: .cards) ?? []
        audio = try c.decodeIfPresent([AudioClip].self, forKey: .audio) ?? []
    }

    public var livePages: [PageRecord] { pages.filter { !$0.deleted }.sorted { ($0.order, $0.id.raw) < ($1.order, $1.id.raw) } }
    public var trashedPages: [PageRecord] { pages.filter { $0.deleted && $0.trashedAt != nil } }
    public var liveOutline: [OutlineEntry] { outline.filter { !$0.deleted }.sorted { ($0.order, $0.id.raw) < ($1.order, $1.id.raw) } }
    public var liveBlocks: [TextBlock] { blocks.filter { !$0.deleted }.sorted { ($0.order, $0.id.raw) < ($1.order, $1.id.raw) } }
    public var liveCards: [StudyCard] { cards.filter { !$0.deleted }.sorted { ($0.order, $0.id.raw) < ($1.order, $1.id.raw) } }
    public var liveAudio: [AudioClip] { audio.filter { !$0.deleted }.sorted { $0.start < $1.start } }

    /// Any page record (including trashed) with this id.
    public func page(_ id: PageID) -> PageRecord? { pages.first { $0.id == id } }

    /// 0-based index among live pages.
    public func pageIndex(_ id: PageID) -> Int? { livePages.firstIndex { $0.id == id } }

    /// Order key for inserting a page at `position` relative to `anchor` (a live page).
    public func orderKey(_ position: PagePosition, relativeTo anchor: PageID?) -> String {
        let pages = livePages
        switch position {
        case .start:
            return FractionalIndex.between(nil, pages.first?.order)
        case .end:
            return FractionalIndex.between(pages.last?.order, nil)
        case .before, .after:
            guard let anchor = anchor, let i = pages.firstIndex(where: { $0.id == anchor }) else {
                return FractionalIndex.between(pages.last?.order, nil)
            }
            if position == .before {
                return FractionalIndex.between(i > 0 ? pages[i - 1].order : nil, pages[i].order)
            }
            return FractionalIndex.between(pages[i].order, i + 1 < pages.count ? pages[i + 1].order : nil)
        }
    }
}
```

### `NibKit/Sources/NibContracts/Model/Presets.swift`

```swift
import Foundation

/// One color (or tape pattern) slot of a writing tool.
public struct PresetSwatch: Codable, Hashable {
    public var color: RGBA
    /// Tape only: tiled pattern stored in `.nib-library/tape/`; copied into a document's assets on use.
    public var pattern: AssetRef?

    public init(color: RGBA, pattern: AssetRef? = nil) {
        self.color = color
        self.pattern = pattern
    }

    /// contracts-v2 (pinned): a library tape pattern is referenced as "<TapePatternDescriptor.id>.png"; the tape
    /// feature (F033) resolves it through `content.tapePatterns` and copies the tile into the document on use.
    public static func tapePatternRef(id: String) -> AssetRef { AssetRef(id + ".png") }

    /// The `TapePatternDescriptor.id` a pattern ref names (a bare id without ".png" is accepted too).
    public static func tapePatternID(_ ref: AssetRef) -> String {
        ref.name.lowercased().hasSuffix(".png") ? String(ref.name.dropLast(4)) : ref.name
    }
}

/// Per-tool presets: up to 12 color slots and exactly 3 thickness slots (each with its own line pattern).
/// Stored as the synced setting `NibSettings.presets(<toolId>)`; edited by the Tool Presets feature,
/// read by pen, pencil, highlighter, tape and shape tools.
public struct ToolPresets: Codable, Equatable {
    public static let maxSwatches = 12

    public var swatches: [PresetSwatch]
    public var widths: [Double]
    public var patterns: [StrokePattern]
    public var selectedSwatch: Int
    public var selectedWidth: Int

    public init(swatches: [PresetSwatch], widths: [Double], patterns: [StrokePattern]? = nil,
                selectedSwatch: Int = 0, selectedWidth: Int = 1) {
        self.swatches = swatches
        self.widths = widths
        self.patterns = patterns ?? widths.map { _ in StrokePattern.solid }
        self.selectedSwatch = selectedSwatch
        self.selectedWidth = selectedWidth
    }

    enum CodingKeys: String, CodingKey { case swatches, widths, patterns, selectedSwatch, selectedWidth }

    /// contracts-v2: lenient, so a partial preset written with `settings.set` still decodes: `swatches` and `widths` are
    /// required; `patterns` defaults to solid for every width, the selections to 0 and 1.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        swatches = try c.decode([PresetSwatch].self, forKey: .swatches)
        widths = try c.decode([Double].self, forKey: .widths)
        patterns = try c.decodeIfPresent([StrokePattern].self, forKey: .patterns) ?? widths.map { _ in StrokePattern.solid }
        selectedSwatch = try c.decodeIfPresent(Int.self, forKey: .selectedSwatch) ?? 0
        selectedWidth = try c.decodeIfPresent(Int.self, forKey: .selectedWidth) ?? 1
    }

    public var color: RGBA { swatches.indices.contains(selectedSwatch) ? swatches[selectedSwatch].color : .black }
    public var width: Double { widths.indices.contains(selectedWidth) ? widths[selectedWidth] : 1.2 }
    public var pattern: StrokePattern { patterns.indices.contains(selectedWidth) ? patterns[selectedWidth] : .solid }
    public var tapePattern: AssetRef? { swatches.indices.contains(selectedSwatch) ? swatches[selectedSwatch].pattern : nil }

    public static func defaults(for tool: String) -> ToolPresets {
        switch tool {
        case "highlighter":
            return ToolPresets(swatches: [PresetSwatch(color: RGBA(0xFF, 0xE0, 0x3D, 0x80)), PresetSwatch(color: RGBA(0x7C, 0xE3, 0x8B, 0x80)),
                                          PresetSwatch(color: RGBA(0xFF, 0x8F, 0xB1, 0x80))], widths: [8, 12, 18])
        case "tape":
            return ToolPresets(swatches: [PresetSwatch(color: RGBA(0xF4, 0xC4, 0x30)), PresetSwatch(color: RGBA(0x8E, 0xC5, 0xFF)),
                                          PresetSwatch(color: RGBA(0xFF, 0xA8, 0xA8))], widths: [12, 18, 26])
        case "pencil":
            return ToolPresets(swatches: [PresetSwatch(color: RGBA(0x3A, 0x3A, 0x3C)), PresetSwatch(color: RGBA(0x5B, 0x6B, 0x7F)),
                                          PresetSwatch(color: RGBA(0x8A, 0x5A, 0x3C))], widths: [1.0, 1.6, 2.4])
        case "shape":
            return ToolPresets(swatches: [PresetSwatch(color: RGBA(0x1A, 0x1A, 0x1A)), PresetSwatch(color: RGBA(0x1F, 0x5F, 0xD1)),
                                          PresetSwatch(color: RGBA(0xD1, 0x3B, 0x2F))], widths: [1.0, 1.5, 3.0])
        default:
            return ToolPresets(swatches: [PresetSwatch(color: RGBA(0x1A, 0x1A, 0x1A)), PresetSwatch(color: RGBA(0x1F, 0x5F, 0xD1)),
                                          PresetSwatch(color: RGBA(0xD1, 0x3B, 0x2F))], widths: [0.6, 1.2, 2.0])
        }
    }
}
```

### `NibKit/Sources/NibContracts/Model/Library.swift`

```swift
import Foundation

public struct FolderStyle: Codable, Hashable {
    public var color: RGBA?
    /// SF Symbol name or a single emoji.
    public var icon: String?
    public var favorite: Bool

    public init(color: RGBA? = nil, icon: String? = nil, favorite: Bool = false) {
        self.color = color
        self.icon = icon
        self.favorite = favorite
    }
}

public enum LibraryNodeKind: String, Codable, CaseIterable { case folder, document }

/// Sync state shown on library thumbnails.
public enum SyncBadge: String, Codable, CaseIterable { case synced, syncing, downloading, error, localOnly }

/// A folder or document as listed by the library catalog (derived, rebuilt from disk).
public struct LibraryNode: Codable, Hashable, Identifiable {
    /// Document id, or the folder id stored in the folder's `.nibfolder.<dev>.json` files.
    public var id: NibID
    public var kind: LibraryNodeKind
    /// Package / folder name without extension.
    public var title: String
    /// Library-relative path, "/"-separated.
    public var path: String
    /// Parent folder; nil = library root.
    public var parent: FolderID?
    public var documentKind: DocumentKind?
    /// Unix seconds.
    public var modified: Double
    public var created: Double
    public var favorite: Bool
    public var locked: Bool
    public var pageCount: Int?
    public var style: FolderStyle?
    public var sync: SyncBadge
    public var trashedAt: Double?

    public init(id: NibID, kind: LibraryNodeKind, title: String, path: String, parent: FolderID? = nil,
                documentKind: DocumentKind? = nil, modified: Double = 0, created: Double = 0, favorite: Bool = false,
                locked: Bool = false, pageCount: Int? = nil, style: FolderStyle? = nil, sync: SyncBadge = .localOnly,
                trashedAt: Double? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.path = path
        self.parent = parent
        self.documentKind = documentKind
        self.modified = modified
        self.created = created
        self.favorite = favorite
        self.locked = locked
        self.pageCount = pageCount
        self.style = style
        self.sync = sync
        self.trashedAt = trashedAt
    }
}
```

### `NibKit/Sources/NibContracts/Model/NodeRef.swift`

```swift
import Foundation

/// String address of any node, used by commands, queries, AI tools, plugins and the bridge:
/// `lib`, `folder:F`, `doc:D`, `page:D/P`, `item:D/P/I`, `block:D/B`, `card:D/C`, `audio:D/A`, `outline:D/O`.
public enum NodeRef: Hashable, Codable, CustomStringConvertible {
    case library
    case folder(FolderID)
    case document(DocumentID)
    case page(DocumentID, PageID)
    case item(DocumentID, PageID, ElementID)
    case block(DocumentID, NibID)
    case card(DocumentID, NibID)
    case audio(DocumentID, NibID)
    case outline(DocumentID, NibID)

    public init?(_ string: String) {
        if string == "lib" || string == "library" {
            self = .library
            return
        }
        guard let colon = string.firstIndex(of: ":") else { return nil }
        let kind = String(string[..<colon])
        let parts = string[string.index(after: colon)...].split(separator: "/").map { NibID(String($0)) }
        switch (kind, parts.count) {
        case ("folder", 1): self = .folder(parts[0])
        case ("doc", 1): self = .document(parts[0])
        case ("page", 2): self = .page(parts[0], parts[1])
        case ("item", 3): self = .item(parts[0], parts[1], parts[2])
        case ("block", 2): self = .block(parts[0], parts[1])
        case ("card", 2): self = .card(parts[0], parts[1])
        case ("audio", 2): self = .audio(parts[0], parts[1])
        case ("outline", 2): self = .outline(parts[0], parts[1])
        default: return nil
        }
    }

    public var description: String {
        switch self {
        case .library: return "lib"
        case .folder(let f): return "folder:\(f.raw)"
        case .document(let d): return "doc:\(d.raw)"
        case .page(let d, let p): return "page:\(d.raw)/\(p.raw)"
        case .item(let d, let p, let i): return "item:\(d.raw)/\(p.raw)/\(i.raw)"
        case .block(let d, let b): return "block:\(d.raw)/\(b.raw)"
        case .card(let d, let c): return "card:\(d.raw)/\(c.raw)"
        case .audio(let d, let a): return "audio:\(d.raw)/\(a.raw)"
        case .outline(let d, let o): return "outline:\(d.raw)/\(o.raw)"
        }
    }

    public var documentID: DocumentID? {
        switch self {
        case .library, .folder: return nil
        case .document(let d), .page(let d, _), .item(let d, _, _), .block(let d, _), .card(let d, _),
             .audio(let d, _), .outline(let d, _):
            return d
        }
    }

    public var pageID: PageID? {
        switch self {
        case .page(_, let p), .item(_, let p, _): return p
        default: return nil
        }
    }

    /// Accepts "doc:D", any ref inside a document, or a bare id.
    public static func documentID(from string: String) -> DocumentID {
        NodeRef(string)?.documentID ?? NibID(string)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let r = NodeRef(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid node ref '\(s)'")
        }
        self = r
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}
```

### `NibKit/Sources/NibContracts/Model/Fragment.swift`

```swift
import Foundation

/// contracts-v2: the clipboard, drag-and-drop, element and board-template format "nib-fragment/1" (UTI
/// `app.nib.fragment`): `{"format": "nib-fragment/1", "items": [Item], "assets": {name: base64}, "bounds": [x, y, w, h]}`.
/// Items keep their source ids, z keys and page geometry; `instantiated` re-mints ids, re-assigns z and remaps
/// `attachedTo`, connector anchors and asset names when the fragment lands on a page. Shared by clipboard (F014),
/// elements (F035), board templates (F044), content packs and plugins, so nobody keeps a byte-compatible copy.
public struct NibFragment: Equatable {
    public static let format = "nib-fragment/1"
    public static let typeIdentifier = "app.nib.fragment"

    public var items: [Item]
    /// Asset bytes keyed by the asset name the items reference.
    public var assets: [String: Data]
    public var bounds: Rect

    public init(items: [Item], assets: [String: Data] = [:], bounds: Rect? = nil) {
        self.items = items
        self.assets = assets
        self.bounds = bounds ?? NibFragment.union(items)
    }

    // MARK: Building

    /// A fragment of `items` (provenance and revisions stripped) carrying the bytes of every asset they reference.
    public static func make(items: [Item], assetData: (AssetRef) -> Data?) -> NibFragment {
        var assets: [String: Data] = [:]
        var clean: [Item] = []
        clean.reserveCapacity(items.count)
        for item in items {
            var n = item
            n.rev = .zero
            n.createdBy = nil
            n.deleted = false
            for ref in NibFragment.assetRefs(n) where assets[ref.name] == nil {
                if let data = assetData(ref) { assets[ref.name] = data }
            }
            clean.append(n)
        }
        return NibFragment(items: clean, assets: assets)
    }

    /// The live items `ids` (in that order), then every item attached to them, so a container carries its contents.
    /// Comments pinned to an item stay behind: they discuss the object, they are not part of it.
    public static func expand(_ ids: [ElementID], in pageItems: [Item]) -> [Item] {
        let live = pageItems.filter { !$0.deleted }
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chosen = Set<ElementID>()
        var out: [Item] = []
        for id in ids {
            if let item = byID[id], chosen.insert(id).inserted { out.append(item) }
        }
        var grew = !out.isEmpty
        while grew {
            grew = false
            for item in live where item.kind != .comment && !chosen.contains(item.id) {
                if let parent = item.attachedTo, chosen.contains(parent) {
                    chosen.insert(item.id)
                    out.append(item)
                    grew = true
                }
            }
        }
        return out
    }

    // MARK: Landing on a page

    /// The items ready to write: new ids (`ids` in creation order, the rest minted), z keys above `zAfter` in the
    /// fragment's own z order, geometry moved by `translate`, references remapped (`attachedTo` and connector anchors
    /// that point outside the fragment are dropped, keeping the connector end where it is), asset names mapped
    /// through `assetMap`, and `layer` applied when given. Attachment loops from untrusted JSON are broken.
    public func instantiated(translate d: Point, ids: [NibID] = [], zAfter: String?, layer: Int?,
                             assets assetMap: [String: AssetRef] = [:]) -> [Item] {
        var newIDs: [ElementID] = []
        var map: [ElementID: ElementID] = [:]
        for (i, item) in items.enumerated() {
            let fresh = i < ids.count ? ids[i] : NibID.make()
            newIDs.append(fresh)
            if map[item.id] == nil { map[item.id] = fresh }
        }
        let order = items.indices.sorted { a, b in
            (items[a].z, items[a].id.raw, a) < (items[b].z, items[b].id.raw, b)
        }
        let keys = FractionalIndex.sequence(after: zAfter, count: items.count)
        var z = [String](repeating: "", count: items.count)
        for (k, i) in order.enumerated() { z[i] = keys[k] }
        let move = Affine.translation(d.x, d.y)

        var out: [Item] = []
        out.reserveCapacity(items.count)
        for i in items.indices {
            let source = items[i]
            var n = d == .zero ? source : source.transformed(by: move)
            n.id = newIDs[i]
            n.rev = .zero
            n.deleted = false
            n.createdBy = nil
            n.z = z[i]
            n.attachedTo = source.attachedTo.flatMap { map[$0] }
            if var c = n.connector {
                c.from = NibFragment.remap(c.from, map)
                c.to = NibFragment.remap(c.to, map)
                n.connector = c
            }
            if var s = n.stroke {
                InkModel.prepare(&s)                  // synthetic (AI / plugin) ink gets nib sizes; captured ink is untouched
                n.stroke = s
            }
            if !assetMap.isEmpty { NibFragment.mapAssets(&n) { assetMap[$0.name] ?? $0 } }
            n.layer = min(max(layer ?? n.layer, 0), NibLimits.layerCount - 1)
            out.append(n)
        }
        var parent: [ElementID: ElementID] = [:]
        for n in out { if let p = n.attachedTo { parent[n.id] = p } }
        for i in out.indices {
            var seen = Set<ElementID>()
            var next = out[i].attachedTo
            while let p = next, seen.insert(p).inserted {
                if p == out[i].id {
                    out[i].attachedTo = nil
                    parent[out[i].id] = nil
                    break
                }
                next = parent[p]
            }
        }
        return out
    }

    /// A connector end anchored inside the fragment follows the copy; one anchored outside becomes a free end.
    static func remap(_ end: ConnectorEnd, _ map: [ElementID: ElementID]) -> ConnectorEnd {
        guard let target = end.item else { return end }
        guard let mapped = map[target] else { return ConnectorEnd(point: end.point) }
        var e = end
        e.item = mapped
        return e
    }

    // MARK: Assets

    /// Rewrites every asset reference an item holds: image, tape pattern, custom display ops and inline text glyphs.
    public static func mapAssets(_ item: inout Item, _ f: (AssetRef) -> AssetRef) {
        if var image = item.image {
            image.asset = f(image.asset)
            item.image = image
        }
        if var stroke = item.stroke, let pattern = stroke.style.tapePattern {
            stroke.style.tapePattern = f(pattern)
            item.stroke = stroke
        }
        if var custom = item.custom {
            for i in custom.display.ops.indices {
                if let a = custom.display.ops[i].asset { custom.display.ops[i].asset = f(a) }
            }
            item.custom = custom
        }
        if var text = item.text {
            mapRich(&text.text, f)
            item.text = text
        }
        if var sticky = item.sticky {
            mapRich(&sticky.text, f)
            item.sticky = sticky
        }
        if var shape = item.shape, var label = shape.text {
            mapRich(&label, f)
            shape.text = label
            item.shape = shape
        }
        if var connector = item.connector, var label = connector.label {
            mapRich(&label, f)
            connector.label = label
            item.connector = connector
        }
    }

    private static func mapRich(_ t: inout RichText, _ f: (AssetRef) -> AssetRef) {
        for p in t.paragraphs.indices {
            for r in t.paragraphs[p].runs.indices {
                if let a = t.paragraphs[p].runs[r].attrs.attachment { t.paragraphs[p].runs[r].attrs.attachment = f(a) }
            }
        }
    }

    /// Every asset an item references (image, tape pattern, display-op images, inline glyphs), without duplicates.
    public static func assetRefs(_ item: Item) -> [AssetRef] {
        var out: [AssetRef] = []
        var probe = item
        mapAssets(&probe) { ref in
            if !out.contains(ref) { out.append(ref) }
            return ref
        }
        return out
    }

    // MARK: Helpers

    /// Union of the items' bounds (`.zero` when empty).
    public static func union(_ items: [Item]) -> Rect {
        guard let first = items.first else { return .zero }
        return items.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
    }

    /// Decodes fragment JSON, turning errors into `invalid_params`.
    public static func decode(_ data: Data) throws -> NibFragment {
        do {
            return try JSONDecoder().decode(NibFragment.self, from: data)
        } catch {
            throw NibError(.invalidParams, "the Nib fragment could not be read (\(error.localizedDescription))",
                           hint: "copy the items again, or pass nib-fragment/1 JSON")
        }
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

extension NibFragment: Codable {
    enum CodingKeys: String, CodingKey { case format, items, assets, bounds }

    /// Lenient: `format` may be left out (elements, board templates, AI JSON); `assets` defaults to none and
    /// `bounds` to the union of the items. A different format version is refused.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let f = try c.decodeIfPresent(String.self, forKey: .format), f != NibFragment.format {
            throw DecodingError.dataCorruptedError(forKey: .format, in: c,
                                                   debugDescription: "unsupported fragment format '\(f)'; expected \(NibFragment.format)")
        }
        let items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        var assets: [String: Data] = [:]
        for (name, b64) in try c.decodeIfPresent([String: String].self, forKey: .assets) ?? [:] {
            guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                throw DecodingError.dataCorruptedError(forKey: .assets, in: c, debugDescription: "asset '\(name)' is not base64")
            }
            assets[name] = data
        }
        self.items = items
        self.assets = assets
        self.bounds = try c.decodeIfPresent(Rect.self, forKey: .bounds) ?? NibFragment.union(items)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(NibFragment.format, forKey: .format)
        try c.encode(items, forKey: .items)
        try c.encode(assets.mapValues { $0.base64EncodedString() }, forKey: .assets)
        try c.encode(bounds, forKey: .bounds)
    }
}
```

### `NibKit/Sources/NibContracts/Core/Errors.swift`

```swift
import Foundation

/// The one error type that crosses every boundary (UI, plugins, AI tools, MCP). Stable `code`s let models self-correct.
/// Wire form: {"error": {"code": "...", "message": "...", "path": "...", "hint": "..."}}.
public struct NibError: Error, Codable, Equatable, CustomStringConvertible, LocalizedError {
    public enum Code: String, Codable, CaseIterable {
        case invalidParams = "invalid_params"
        case notFound = "not_found"
        case permissionDenied = "permission_denied"
        case userDenied = "user_denied"
        case locked
        case conflict
        case invariantViolation = "invariant_violation"
        case timeout
        case unavailable
        case unsupported
        case internalError = "internal"
    }

    public var code: Code
    public var message: String
    /// JSON path of the offending parameter, e.g. "$.points[3]".
    public var path: String?
    /// What to try next, e.g. "call commands.describe {id: 'ink.addStrokes'}".
    public var hint: String?

    public init(_ code: Code, _ message: String, path: String? = nil, hint: String? = nil) {
        self.code = code
        self.message = message
        self.path = path
        self.hint = hint
    }

    public static func notFound(_ what: String) -> NibError { NibError(.notFound, "\(what) not found") }
    public static func invalid(_ message: String, path: String? = nil) -> NibError { NibError(.invalidParams, message, path: path) }
    public static func unavailable(_ what: String) -> NibError {
        NibError(.unavailable, "\(what) is not available", hint: "the feature that provides it is disabled or not configured")
    }
    public static func unsupported(_ what: String) -> NibError { NibError(.unsupported, "\(what) is not supported") }

    /// Converts any error into a NibError (non-Nib errors become `internal`).
    public static func wrap(_ error: Error) -> NibError {
        if let e = error as? NibError { return e }
        return NibError(.internalError, error.localizedDescription)
    }

    public var description: String {
        var s = "[\(code.rawValue)] \(message)"
        if let p = path { s += " at \(p)" }
        if let h = hint { s += " (hint: \(h))" }
        return s
    }

    public var errorDescription: String? { message }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["code": .string(code.rawValue), "message": .string(message)]
        if let p = path { o["path"] = .string(p) }
        if let h = hint { o["hint"] = .string(h) }
        return ["error": .object(o)]
    }
}
```

### `NibKit/Sources/NibContracts/Core/Permissions.swift`

```swift
import Foundation

/// Who is calling a command. String form: "user", "plugin:<id>", "ai:<chat>", "bridge:<client>", "sync:<device>".
public enum Principal: Hashable, Codable, CustomStringConvertible {
    case user
    case plugin(String)
    case ai(String)
    case bridge(String)
    case sync(String)

    public init(string: String) {
        let parts = string.split(separator: ":", maxSplits: 1).map { String($0) }
        let rest = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "plugin": self = .plugin(rest)
        case "ai": self = .ai(rest)
        case "bridge": self = .bridge(rest)
        case "sync": self = .sync(rest)
        default: self = .user
        }
    }

    public var description: String {
        switch self {
        case .user: return "user"
        case .plugin(let id): return "plugin:\(id)"
        case .ai(let id): return "ai:\(id)"
        case .bridge(let id): return "bridge:\(id)"
        case .sync(let id): return "sync:\(id)"
        }
    }

    public var isUser: Bool { self == .user }

    /// contracts-v2: "user", "plugin", "ai", "bridge" or "sync" (per-kind gateway policies and presenters).
    public var kind: String {
        switch self {
        case .user: return "user"
        case .plugin: return "plugin"
        case .ai: return "ai"
        case .bridge: return "bridge"
        case .sync: return "sync"
        }
    }

    /// The exposure bit a command needs for this principal to see it.
    public var exposure: Exposure {
        switch self {
        case .user: return .ui
        case .plugin: return .plugin
        case .ai: return .ai
        case .bridge: return .bridge
        case .sync: return []
        }
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self.init(string: s)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// What a command does. Drives undo, confirmation and default scopes.
public enum Effect: String, Codable, CaseIterable {
    /// No mutation.
    case read
    /// Editor/window state only (tool, selection, zoom, navigation, panels). Not undoable, not persisted in documents.
    case session
    /// Undoable document mutation through `CommandContext.mutate`.
    case edit
    /// Library/file-system change (create, move, rename, trash). Recoverable through Trash, not on the undo stack.
    case library
    /// Cannot be undone (empty trash, delete permanently, overwrite a source file). Always confirmed for non-users.
    case irreversible
}

public enum CommandTarget: String, Codable, CaseIterable { case document, library, app }

public enum Scope: String, Codable, CaseIterable, Hashable {
    case documentRead = "document:read"
    case documentWrite = "document:write"
    case libraryRead = "library:read"
    case libraryWrite = "library:write"
    case destructive
    case app
    case ai
    case network
    /// Install/enable/remove plugins. Grantable to AI and bridge (always confirmed), never to plugins.
    case pluginsManage = "plugins:manage"
    /// Security settings, secrets, grants, passwords. Never granted to any non-user principal.
    case security
}

/// Which callers may see/run a command.
public struct Exposure: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let ui = Exposure(rawValue: 1)
    public static let plugin = Exposure(rawValue: 2)
    public static let ai = Exposure(rawValue: 4)
    public static let bridge = Exposure(rawValue: 8)
    public static let all: Exposure = [.ui, .plugin, .ai, .bridge]
}
```

### `NibKit/Sources/NibContracts/Core/JSONSchema.swift`

```swift
import Foundation

/// A deliberately flat JSON Schema subset (no $ref / oneOf) that small local models can follow.
/// Unknown object keys are allowed; `null` values are treated as absent.
public indirect enum JSONSchema {
    case object([String: JSONSchema], required: [String], description: String?)
    case array(JSONSchema, description: String?)
    case string(description: String?, choices: [String]?)
    case number(description: String?, minimum: Double?, maximum: Double?)
    case integer(description: String?, minimum: Int?, maximum: Int?)
    case boolean(description: String?)
    case anyValue(description: String?)
    /// A schema supplied verbatim (plugin manifests). Only its presence is checked.
    case raw(JSONValue)

    // MARK: Builders

    public static func obj(_ properties: [String: JSONSchema], required: [String] = [], _ description: String? = nil) -> JSONSchema {
        .object(properties, required: required, description: description)
    }
    public static func str(_ description: String? = nil, choices: [String]? = nil) -> JSONSchema {
        .string(description: description, choices: choices)
    }
    public static func num(_ description: String? = nil, min: Double? = nil, max: Double? = nil) -> JSONSchema {
        .number(description: description, minimum: min, maximum: max)
    }
    public static func int(_ description: String? = nil, min: Int? = nil, max: Int? = nil) -> JSONSchema {
        .integer(description: description, minimum: min, maximum: max)
    }
    public static func bool(_ description: String? = nil) -> JSONSchema { .boolean(description: description) }
    public static func arr(_ items: JSONSchema, _ description: String? = nil) -> JSONSchema { .array(items, description: description) }
    public static func anything(_ description: String? = nil) -> JSONSchema { .anyValue(description: description) }

    public static let empty: JSONSchema = .object([:], required: [], description: nil)
    public static let ref: JSONSchema = .string(description: "node ref: doc:D, page:D/P, item:D/P/I, block:D/B, card:D/C, audio:D/A, folder:F", choices: nil)
    public static let color: JSONSchema = .string(description: "#RRGGBB or #RRGGBBAA", choices: nil)
    public static let point: JSONSchema = .array(.number(description: nil, minimum: nil, maximum: nil), description: "[x, y] in page points, origin top-left")
    public static let rect: JSONSchema = .array(.number(description: nil, minimum: nil, maximum: nil), description: "[x, y, width, height] in page points")

    /// Wraps a plugin-supplied JSON Schema.
    public static func fromJSON(_ value: JSONValue) -> JSONSchema { .raw(value) }

    // MARK: Validation

    public func validate(_ value: JSONValue, path: String = "$") -> [NibError] {
        switch self {
        case .anyValue, .raw:
            return []
        case let .object(properties, required, _):
            guard case .object(let o) = value else { return [NibError.invalid("expected an object", path: path)] }
            var errors: [NibError] = []
            for key in required where o[key] == nil || o[key] == .null {
                errors.append(NibError.invalid("missing required field '\(key)'", path: path + "." + key))
            }
            for key in o.keys.sorted() {
                guard let schema = properties[key], let v = o[key], v != .null else { continue }
                errors += schema.validate(v, path: path + "." + key)
            }
            return errors
        case let .array(items, _):
            guard case .array(let a) = value else { return [NibError.invalid("expected an array", path: path)] }
            var errors: [NibError] = []
            for (i, v) in a.enumerated() {
                errors += items.validate(v, path: "\(path)[\(i)]")
                if errors.count > 20 { break }
            }
            return errors
        case let .string(_, choices):
            guard case .string(let s) = value else { return [NibError.invalid("expected a string", path: path)] }
            if let choices = choices, !choices.contains(s) {
                return [NibError.invalid("expected one of: \(choices.joined(separator: ", "))", path: path)]
            }
            return []
        case let .number(_, lo, hi):
            guard case .number(let n) = value else { return [NibError.invalid("expected a number", path: path)] }
            if let lo = lo, n < lo { return [NibError.invalid("must be >= \(lo)", path: path)] }
            if let hi = hi, n > hi { return [NibError.invalid("must be <= \(hi)", path: path)] }
            return []
        case let .integer(_, lo, hi):
            guard case .number(let n) = value, n == n.rounded() else { return [NibError.invalid("expected an integer", path: path)] }
            if let lo = lo, n < Double(lo) { return [NibError.invalid("must be >= \(lo)", path: path)] }
            if let hi = hi, n > Double(hi) { return [NibError.invalid("must be <= \(hi)", path: path)] }
            return []
        case .boolean:
            guard case .bool = value else { return [NibError.invalid("expected true or false", path: path)] }
            return []
        }
    }

    // MARK: Export (tool definitions, MCP, commands.describe)

    public func toJSON() -> JSONValue {
        switch self {
        case .raw(let v):
            return v
        case let .object(properties, required, d):
            var o: [String: JSONValue] = ["type": "object", "properties": .object(properties.mapValues { $0.toJSON() })]
            if !required.isEmpty { o["required"] = .array(required.map { JSONValue.string($0) }) }
            return JSONSchema.described(o, d)
        case let .array(items, d):
            return JSONSchema.described(["type": "array", "items": items.toJSON()], d)
        case let .string(d, choices):
            var o: [String: JSONValue] = ["type": "string"]
            if let c = choices { o["enum"] = .array(c.map { JSONValue.string($0) }) }
            return JSONSchema.described(o, d)
        case let .number(d, lo, hi):
            var o: [String: JSONValue] = ["type": "number"]
            if let lo = lo { o["minimum"] = .number(lo) }
            if let hi = hi { o["maximum"] = .number(hi) }
            return JSONSchema.described(o, d)
        case let .integer(d, lo, hi):
            var o: [String: JSONValue] = ["type": "integer"]
            if let lo = lo { o["minimum"] = .number(Double(lo)) }
            if let hi = hi { o["maximum"] = .number(Double(hi)) }
            return JSONSchema.described(o, d)
        case let .boolean(d):
            return JSONSchema.described(["type": "boolean"], d)
        case let .anyValue(d):
            return JSONSchema.described([:], d)
        }
    }

    private static func described(_ o: [String: JSONValue], _ description: String?) -> JSONValue {
        var o = o
        if let d = description { o["description"] = .string(d) }
        return .object(o)
    }
}
```

### `NibKit/Sources/NibContracts/Core/Command.swift`

```swift
import Foundation

/// Describes a command for the UI, plugins, the AI tool catalogue and MCP.
public struct CommandDescriptor {
    /// "namespace.verb" (built-in) or "<pluginId>.<name>" (plugins). Lower camel case segments.
    public var id: String
    /// UI label, e.g. "Add Page".
    public var title: String
    /// ONE line (≤ 200 chars) written for an LLM: what it does and the key params.
    public var summary: String
    public var params: JSONSchema
    /// Example params. Required for every command exposed to AI; they must validate and should use
    /// `Fixtures` ids (FIXTUREDOC01, FIXTUREPG001, …) so the conformance test can run them.
    public var examples: [JSONValue]
    public var effect: Effect
    public var target: CommandTarget
    public var destructive: Bool
    /// Derived from effect/target/destructive plus `extraScopes`.
    public var scopes: Set<Scope>
    public var exposure: Exposure
    /// "builtin" (contracts), the feature id (stamped by `NibApp.register`) or the plugin id.
    public var owner: String
    /// Shows system UI that needs a human (camera, microphone, file picker, Face ID, print).
    public var userPresence: Bool
    /// `.edit` commands that persist through `ctx.mutate(undoable: false)` (tape reveal, study grading, view flags)
    /// set this to false: conformance then asserts the undo stack is unchanged instead of an undo round trip.
    public var undoable: Bool
    /// Sends data off the device or captures it (WebDAV/backup destinations, collaboration, microphone, calendar,
    /// Photos, AI provider endpoints). Non-user principals are ALWAYS confirmed, whatever their policy.
    public var sensitive: Bool
    /// Runs caller-supplied nested calls that are authorized one by one (`commands.batch`, `ai.ask`). Every other
    /// `read` command runs read-only: its nested calls must be `read` and `ctx.mutate` throws.
    public var forwardsCalls: Bool

    public init(id: String, title: String, summary: String, params: JSONSchema = .empty, examples: [JSONValue] = [],
                effect: Effect, target: CommandTarget = .document, destructive: Bool = false,
                extraScopes: Set<Scope> = [], exposure: Exposure = .all, owner: String = "builtin",
                userPresence: Bool = false, undoable: Bool = true, sensitive: Bool = false, forwardsCalls: Bool = false) {
        self.id = id
        self.title = title
        self.summary = summary
        self.params = params
        self.examples = examples
        self.effect = effect
        self.target = target
        self.destructive = destructive || effect == .irreversible
        self.exposure = exposure
        self.owner = owner
        self.userPresence = userPresence
        self.undoable = undoable
        self.sensitive = sensitive
        self.forwardsCalls = forwardsCalls
        var s = extraScopes
        switch (effect, target) {
        case (.read, .document): s.insert(.documentRead)
        case (.read, .library): s.insert(.libraryRead)
        case (.read, .app), (.session, _): s.insert(.app)
        case (.edit, .document), (.irreversible, .document): s.insert(.documentWrite)
        case (.edit, .library), (.library, _), (.irreversible, .library): s.insert(.libraryWrite)
        case (.edit, .app), (.irreversible, .app): s.insert(.app)
        }
        if self.destructive { s.insert(.destructive) }
        self.scopes = s
    }

    /// Tool name for LLM APIs ([a-zA-Z0-9_-]{1,64}): dots become double underscores.
    public var toolName: String { id.replacingOccurrences(of: ".", with: "__") }

    public var isMutating: Bool { effect == .edit || effect == .library || effect == .irreversible }
}

/// A native command. Conforming types are main-actor isolated. Return `NoResult()` when there is nothing to return.
/// The result associated type is `Output` (not `Result`) so `Swift.Result` stays usable inside conformers; name
/// your nested result type `Output` too. Keep `examples` literals small: annotate nested literals
/// (`let ex: JSONValue = […]`) or use `try! JSONValue.parse(#"…"#)` for anything longer than one line.
///
///     struct PageRotate: NibCommand {
///         struct Params: Codable { var page: String; var degrees: Int? }
///         static let descriptor = CommandDescriptor(id: "page.rotate", title: "Rotate Page", summary: "…",
///             params: .obj(["page": .ref, "degrees": .int(min: 90, max: 270)], required: ["page"]),
///             examples: [["page": "page:FIXTUREDOC01/FIXTUREPG001"]], effect: .edit)
///         static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult { … ctx.mutate { tx in … } … }
///     }
@MainActor
public protocol NibCommand {
    associatedtype Params: Codable
    associatedtype Output: Codable
    static var descriptor: CommandDescriptor { get }
    static func run(_ params: Params, _ ctx: CommandContext) async throws -> Output
}

/// Empty params/result. Named `NoResult` (not `Empty`) so it never clashes with `Combine.Empty`.
public struct NoResult: Codable, Equatable {
    public init() {}
}

public typealias CommandHandler = @MainActor (JSONValue, CommandContext) async throws -> JSONValue

/// All commands: built-in, feature and plugin. The command registry IS the app's API.
@MainActor
public final class CommandRegistry {
    public struct Entry {
        public let descriptor: CommandDescriptor
        public let handler: CommandHandler
    }

    private var entries: [String: Entry] = [:]
    /// Set by `NibApp.register` around each feature's `register`: descriptors that still say "builtin" are
    /// stamped with this owner, so `unregister(owner:)`, conformance filtering and provenance work per feature.
    public var defaultOwner: String?
    /// Ids registered twice while features registered (the later one replaced the earlier). Conformance fails on any.
    public private(set) var duplicateIDs: [String] = []

    public init() {}

    public func register<C: NibCommand>(_ type: C.Type) {
        register(C.descriptor) { json, ctx in
            let params = try CommandRegistry.decode(C.Params.self, from: json)
            let result = try await C.run(params, ctx)
            return try JSONValue.from(result)
        }
    }

    /// Registers a JSON-level command (plugins, generated commands).
    public func register(_ descriptor: CommandDescriptor, handler: @escaping CommandHandler) {
        var d = descriptor
        if d.owner == "builtin", let owner = defaultOwner { d.owner = owner }
        if defaultOwner != nil, entries[d.id] != nil { duplicateIDs.append(d.id) }
        entries[d.id] = Entry(descriptor: d, handler: handler)
        NotificationCenter.default.post(name: .nibRegistryDidChange, object: self)
    }

    public func unregister(id: String) {
        entries[id] = nil
        NotificationCenter.default.post(name: .nibRegistryDidChange, object: self)
    }

    public func unregister(owner: String) {
        entries = entries.filter { $0.value.descriptor.owner != owner }
        NotificationCenter.default.post(name: .nibRegistryDidChange, object: self)
    }

    public func entry(_ id: String) -> Entry? { entries[id] }
    public func descriptor(_ id: String) -> CommandDescriptor? { entries[id]?.descriptor }

    /// Sorted by id; filtered to commands exposed to `exposure` when given.
    public func all(exposedTo exposure: Exposure? = nil) -> [CommandDescriptor] {
        entries.values.map { $0.descriptor }
            .filter { d in exposure.map { d.exposure.contains($0) } ?? true }
            .sorted { $0.id < $1.id }
    }

    /// Decodes params, turning DecodingError into a readable `invalid_params` NibError with a JSON path.
    public nonisolated static func decode<T: Decodable>(_ type: T.Type, from json: JSONValue) throws -> T {
        let value: JSONValue = json == .null ? [:] : json
        do {
            return try value.decode(T.self)
        } catch let e as DecodingError {
            throw NibError.invalid(describe(e))
        }
    }

    nonisolated static func describe(_ e: DecodingError) -> String {
        func path(_ p: [CodingKey]) -> String {
            "$" + p.map { k in k.intValue.map { "[\($0)]" } ?? ".\(k.stringValue)" }.joined()
        }
        switch e {
        case .keyNotFound(let k, let c): return "missing '\(k.stringValue)' at \(path(c.codingPath))"
        case .typeMismatch(let t, let c): return "wrong type at \(path(c.codingPath)) (expected \(t))"
        case .valueNotFound(let t, let c): return "missing value at \(path(c.codingPath)) (expected \(t))"
        case .dataCorrupted(let c): return "invalid value at \(path(c.codingPath)): \(c.debugDescription)"
        @unknown default: return "invalid parameters"
        }
    }
}

public extension Notification.Name {
    /// Posted when any command or UI/content registry changes (UI refreshes toolbars/menus).
    static let nibRegistryDidChange = Notification.Name("NibRegistryDidChange")
}
```

### `NibKit/Sources/NibContracts/Core/CommandIDs.swift`

```swift
import Foundation

/// Well-known command ids that features call across module boundaries (owners: ARCHITECTURE.md §6).
/// Calling a command by id is the ONLY way one feature uses another feature's behaviour.
/// Since contracts-v2.1 every id in the §6.5 catalogue has a constant here.
public enum CommandIDs {
    // Contracts (always present)
    public static let undo = "edit.undo"
    public static let redo = "edit.redo"
    public static let historyList = "history.list"
    public static let revertGroup = "history.revertGroup"
    public static let commandsList = "commands.list"
    public static let commandsDescribe = "commands.describe"
    public static let batch = "commands.batch"
    public static let toolSelect = "tool.select"
    public static let settingsGet = "settings.get"
    public static let settingsSet = "settings.set"
    public static let settingsList = "settings.list"
    public static let settingsDescribe = "settings.describe"

    // Query / render / recognition
    public static let queryContext = "query.context"
    public static let queryGet = "query.get"
    public static let queryFind = "query.find"
    public static let queryTree = "query.tree"
    /// Owner: F004 (NibRender). {page, scale?, region?, marks?, layers?, background?} →
    /// {asset: "tmp:<name>", pxPerPt, region, marks?}; long edge capped at 1568 px.
    public static let renderPage = "render.page"
    public static let recognizePageText = "recognize.pageText"
    public static let recognizeItems = "recognize.items"
    public static let searchText = "search.text"

    // Ink, items, selection
    public static let inkAddStrokes = "ink.addStrokes"
    public static let inkErase = "ink.erase"
    public static let inkScribbleErase = "ink.scribbleErase"
    public static let inkWriteText = "ink.writeText"
    public static let inkSetPoints = "ink.setPoints"
    public static let itemCreate = "item.create"
    public static let itemUpdate = "item.update"
    public static let itemDelete = "item.delete"
    public static let itemTransform = "item.transform"
    public static let itemMoveToPage = "item.moveToPage"
    public static let selectionSet = "selection.set"
    public static let selectionFromPolygon = "selection.fromPolygon"
    public static let clipboardCopy = "clipboard.copy"
    public static let clipboardPaste = "clipboard.paste"
    public static let shapeRecognize = "shape.recognize"
    public static let shapeCreate = "shape.create"
    public static let diagramCreate = "diagram.create"
    public static let textCreateBox = "text.createBox"
    public static let assetPut = "asset.put"
    /// Stores bytes as a temporary asset ("tmp:<name>", 1 h) that url-taking commands accept.
    public static let assetUpload = "asset.upload"
    /// Owner: F006. Transient DisplayList overlays per page ({page, id, display, ttl?}); plugins: nib.canvas.decorate.
    public static let canvasDecorate = "canvas.decorate"

    // Pages, documents, library, view
    public static let pageAdd = "page.add"
    public static let pageSetTemplate = "page.setTemplate"
    public static let docCreate = "doc.create"
    /// Owner: F018. {doc, page?, mode?: replace|newTab|newWindow} — opens in the active window unless told otherwise.
    public static let docOpen = "doc.open"
    public static let viewGoToPage = "view.goToPage"
    public static let panelOpen = "panel.open"
    public static let importFiles = "import.files"
    public static let exportRun = "export.run"
    public static let appOpenURL = "app.openURL"
    public static let appQuickAction = "app.quickAction"

    // Finger taps, double-taps and long-presses are routed through `app.content.tapHandlers`
    // (TapHandlerDescriptor, lowest order first; built-ins: tape.tapAt 100, comment.tapAt 200, link.tapAt 300,
    // selection.tapAt 400), then to the active tool. There is no fixed tap-chain constant.

    // Extensibility
    public static let pluginInstall = "plugin.install"
    public static let aiAsk = "ai.ask"

    // contracts-v2: more catalogue ids features call across modules (owners: ARCHITECTURE.md §6.5)
    public static let selectionClear = "selection.clear"
    public static let textSetText = "text.setText"
    public static let libraryRename = "library.rename"
    public static let clipboardCut = "clipboard.cut"
    public static let itemRecolor = "item.recolor"
    public static let itemDuplicate = "item.duplicate"
    public static let viewReveal = "view.reveal"
    public static let viewSetReadOnly = "view.setReadOnly"
    public static let panelClose = "panel.close"
    public static let audioPlay = "audio.play"
    /// Contracts (always present): shows the library in the invoking window {folder?} (session).
    public static let windowShowLibrary = "window.showLibrary"

    // contracts-v2.1: a constant for every other id in the ARCHITECTURE.md §6.5 catalogue, by namespace in catalogue
    // order, with the owning feature. NibContractsTests/CommandCatalogueTests checks that every catalogue row has one.

    public static let a11yDescribePage = "a11y.describePage"  // F095

    public static let aiChatList = "ai.chat.list"  // F084
    public static let aiChatRename = "ai.chat.rename"  // F084
    public static let aiChatDelete = "ai.chat.delete"  // F084
    public static let aiChatFeedback = "ai.chat.feedback"  // F084
    public static let aiProviderList = "ai.provider.list"  // F086
    public static let aiProviderSave = "ai.provider.save"  // F086
    public static let aiProviderActivate = "ai.provider.activate"  // F086
    public static let aiProviderDelete = "ai.provider.delete"  // F086
    public static let aiProviderTest = "ai.provider.test"  // F086
    public static let aiQuiz = "ai.quiz"  // F087

    public static let answerZoneCreate = "answerZone.create"  // F099
    public static let answerZoneScore = "answerZone.score"  // F099
    public static let answerZoneSetHints = "answerZone.setHints"  // F099
    public static let answerZoneRevealHint = "answerZone.revealHint"  // F099

    public static let appDeleteAllData = "app.deleteAllData"  // F098

    public static let assetGet = "asset.get"  // F003

    public static let audioRecord = "audio.record"  // F052
    public static let audioPause = "audio.pause"  // F052
    public static let audioSeek = "audio.seek"  // F052
    public static let audioSetPlayback = "audio.setPlayback"  // F052
    public static let audioRename = "audio.rename"  // F052
    public static let audioDelete = "audio.delete"  // F052
    public static let audioExport = "audio.export"  // F052
    public static let audioQuickRecord = "audio.quickRecord"  // F052

    public static let backupNow = "backup.now"  // F068
    public static let backupManual = "backup.manual"  // F068
    public static let backupConfigure = "backup.configure"  // F068
    public static let backupChooseFolder = "backup.chooseFolder"  // F068
    public static let backupStatus = "backup.status"  // F068
    public static let backupClearQueue = "backup.clearQueue"  // F068

    public static let blockInsert = "block.insert"  // F047
    public static let blockUpdate = "block.update"  // F047
    public static let blockDelete = "block.delete"  // F047
    public static let blockMove = "block.move"  // F047
    public static let blockComment = "block.comment"  // F103
    public static let blockEditComment = "block.editComment"  // F103
    public static let blockDeleteComment = "block.deleteComment"  // F103
    public static let blockResolveComment = "block.resolveComment"  // F103

    public static let boardAdd = "board.add"  // F044
    public static let boardRename = "board.rename"  // F044
    public static let boardInsertTemplate = "board.insertTemplate"  // F044

    public static let bridgeSetEnabled = "bridge.setEnabled"  // F090
    public static let bridgeStatus = "bridge.status"  // F090

    public static let calendarEvents = "calendar.events"  // F075
    public static let calendarCreateNote = "calendar.createNote"  // F075
    public static let calendarOpenNote = "calendar.openNote"  // F075

    public static let canvasClearDecorations = "canvas.clearDecorations"  // F006

    public static let cardAdd = "card.add"  // F049
    public static let cardUpdate = "card.update"  // F049
    public static let cardDelete = "card.delete"  // F049
    public static let cardMove = "card.move"  // F049
    public static let cardMoveTo = "card.moveTo"  // F049

    public static let clipboardCopyText = "clipboard.copyText"  // F014

    public static let collabHost = "collab.host"  // F072
    public static let collabJoin = "collab.join"  // F072
    public static let collabLeave = "collab.leave"  // F072
    public static let collabParticipants = "collab.participants"  // F072
    public static let collabApprove = "collab.approve"  // F072
    public static let collabSetRole = "collab.setRole"  // F072
    public static let collabRevoke = "collab.revoke"  // F072
    public static let collabFollow = "collab.follow"  // F108
    public static let collabFollowMe = "collab.followMe"  // F108
    public static let collabMarkSeen = "collab.markSeen"  // F108

    public static let commentAdd = "comment.add"  // F037
    public static let commentReply = "comment.reply"  // F037
    public static let commentEdit = "comment.edit"  // F037
    public static let commentDeleteMessage = "comment.deleteMessage"  // F037
    public static let commentResolve = "comment.resolve"  // F037
    public static let commentTapAt = "comment.tapAt"  // F037

    public static let connectorCreate = "connector.create"  // F032
    public static let connectorSetPath = "connector.setPath"  // F032

    public static let diagnosticsExport = "diagnostics.export"  // F076
    public static let diagnosticsSetFeatureEnabled = "diagnostics.setFeatureEnabled"  // F076

    public static let diagramAddConnected = "diagram.addConnected"  // F032

    public static let dictionaryAdd = "dictionary.add"  // F104
    public static let dictionaryRemove = "dictionary.remove"  // F104
    public static let dictionaryList = "dictionary.list"  // F104

    public static let docSetFavorite = "doc.setFavorite"  // F002
    public static let docMerge = "doc.merge"  // F002
    public static let docSetScrollDirection = "doc.setScrollDirection"  // F017
    public static let docQuickNote = "doc.quickNote"  // F021
    public static let docConvertToWhiteboard = "doc.convertToWhiteboard"  // F044
    public static let docSetLanguage = "doc.setLanguage"  // F057
    public static let docSetWritingAids = "doc.setWritingAids"  // F104
    public static let docSetLocked = "doc.setLocked"  // F071
    public static let docUnlock = "doc.unlock"  // F071
    public static let docSuggestTitle = "doc.suggestTitle"  // F087

    public static let elementCreate = "element.create"  // F035
    public static let elementInsert = "element.insert"  // F035
    public static let elementCollectionCreate = "element.collection.create"  // F035
    public static let elementCollectionUpdate = "element.collection.update"  // F035
    public static let elementCollectionDelete = "element.collection.delete"  // F035
    public static let elementCollectionList = "element.collection.list"  // F035
    public static let elementList = "element.list"  // F035
    public static let elementRename = "element.rename"  // F035
    public static let elementDelete = "element.delete"  // F035
    public static let elementImport = "element.import"  // F035
    public static let elementExport = "element.export"  // F035

    public static let exportPresent = "export.present"  // F067
    public static let exportSaveToSource = "export.saveToSource"  // F067

    public static let folderCreate = "folder.create"  // F002
    public static let folderSetStyle = "folder.setStyle"  // F002

    public static let galleryList = "gallery.list"  // F080

    public static let gifSearch = "gif.search"  // F035

    public static let handwritingToText = "handwriting.toText"  // F057
    public static let handwritingToTextPages = "handwriting.toTextPages"  // F057
    public static let handwritingWords = "handwriting.words"  // F058
    public static let handwritingReflow = "handwriting.reflow"  // F058
    public static let handwritingStraighten = "handwriting.straighten"  // F058
    public static let handwritingAlign = "handwriting.align"  // F058
    public static let handwritingInsertSpace = "handwriting.insertSpace"  // F058
    public static let handwritingReplaceWord = "handwriting.replaceWord"  // F059
    public static let handwritingRestyle = "handwriting.restyle"  // F105

    public static let imageInsert = "image.insert"  // F034
    public static let imageCrop = "image.crop"  // F034
    public static let imageFlip = "image.flip"  // F034
    public static let imageReplace = "image.replace"  // F034
    public static let imageSaveToPhotos = "image.saveToPhotos"  // F034
    public static let imagePick = "image.pick"  // F034

    public static let importPick = "import.pick"  // F064

    public static let indexRebuild = "index.rebuild"  // F055

    public static let inkSetStyle = "ink.setStyle"  // F007

    public static let itemArrange = "item.arrange"  // F013
    public static let itemSetLocked = "item.setLocked"  // F013

    public static let laserSetMode = "laser.setMode"  // F040
    public static let laserPoint = "laser.point"  // F040

    public static let layerSetActive = "layer.setActive"  // F041
    public static let layerSetVisible = "layer.setVisible"  // F041
    public static let layerRename = "layer.rename"  // F041
    public static let layerMoveItems = "layer.moveItems"  // F041
    public static let layerExportOptions = "layer.exportOptions"  // F041

    public static let lessonCreate = "lesson.create"  // F109
    public static let lessonSetState = "lesson.setState"  // F109
    public static let lessonImportRoster = "lesson.importRoster"  // F109
    public static let lessonCollect = "lesson.collect"  // F110
    public static let lessonCluster = "lesson.cluster"  // F110
    public static let lessonSetClusters = "lesson.setClusters"  // F110

    public static let libraryList = "library.list"  // F002
    public static let libraryMove = "library.move"  // F002
    public static let libraryDuplicate = "library.duplicate"  // F002
    public static let libraryTrash = "library.trash"  // F002
    public static let librarySetView = "library.setView"  // F019
    public static let libraryReorder = "library.reorder"  // F019
    public static let libraryChooseFolder = "library.chooseFolder"  // F025
    public static let libraryRelocate = "library.relocate"  // F025
    public static let libraryLocations = "library.locations"  // F025
    public static let librarySwitch = "library.switch"  // F025
    public static let libraryRepair = "library.repair"  // F070

    public static let linkSet = "link.set"  // F029
    public static let linkRemove = "link.remove"  // F029
    public static let linkFollow = "link.follow"  // F029
    public static let linkBack = "link.back"  // F029
    public static let linkAutodetect = "link.autodetect"  // F029
    public static let linkTapAt = "link.tapAt"  // F029

    public static let lockSetup = "lock.setup"  // F071

    public static let mathRecognize = "math.recognize"  // F060
    public static let mathConvert = "math.convert"  // F060
    public static let mathSetLatex = "math.setLatex"  // F060
    public static let mathCopy = "math.copy"  // F060
    public static let mathEvaluate = "math.evaluate"  // F061
    public static let mathAssist = "math.assist"  // F106
    public static let mathGraphCreate = "math.graph.create"  // F107
    public static let mathGraphSetViewport = "math.graph.setViewport"  // F107
    public static let mathSolve = "math.solve"  // F088

    public static let mathassistTapAt = "mathassist.tapAt"  // F106

    public static let meetingSummarize = "meeting.summarize"  // F089
    public static let meetingGenerateNotes = "meeting.generateNotes"  // F089

    public static let menuShowAt = "menu.showAt"  // F013

    public static let nodeInsert = "node.insert"  // F003
    public static let nodeSet = "node.set"  // F003
    public static let nodeRemove = "node.remove"  // F003
    public static let nodeMove = "node.move"  // F003

    public static let outlineAdd = "outline.add"  // F046
    public static let outlineRename = "outline.rename"  // F046
    public static let outlineMove = "outline.move"  // F046
    public static let outlineDelete = "outline.delete"  // F046
    public static let outlineSortByPage = "outline.sortByPage"  // F046
    public static let outlineList = "outline.list"  // F046
    public static let outlineGenerate = "outline.generate"  // F087

    public static let pageSetBackground = "page.setBackground"  // F005
    public static let pageClear = "page.clear"  // F010
    public static let pageDeleteItems = "page.deleteItems"  // F010
    public static let pageDuplicate = "page.duplicate"  // F022
    public static let pageCopy = "page.copy"  // F022
    public static let pagePaste = "page.paste"  // F022
    public static let pageMoveTo = "page.moveTo"  // F022
    public static let pageReorder = "page.reorder"  // F022
    public static let pageRotate = "page.rotate"  // F022
    public static let pageTrash = "page.trash"  // F022
    public static let pageRestore = "page.restore"  // F022
    public static let pagePurge = "page.purge"  // F022
    public static let pageSetBookmarked = "page.setBookmarked"  // F046

    public static let pdfText = "pdf.text"  // F024
    public static let pdfLinks = "pdf.links"  // F024
    public static let pdfMarkSelection = "pdf.markSelection"  // F042
    public static let pdfCopyText = "pdf.copyText"  // F042
    public static let pdfTapAt = "pdf.tapAt"  // F042

    public static let pencilGesture = "pencil.gesture"  // F043
    public static let pencilPalette = "pencil.palette"  // F043
    public static let pencilActions = "pencil.actions"  // F043

    public static let pluginList = "plugin.list"  // F078
    public static let pluginEnable = "plugin.enable"  // F078
    public static let pluginReload = "plugin.reload"  // F078
    public static let pluginLogs = "plugin.logs"  // F078
    public static let pluginSdkTypes = "plugin.sdkTypes"  // F078
    public static let pluginDocs = "plugin.docs"  // F078
    public static let pluginUninstall = "plugin.uninstall"  // F079
    public static let pluginReview = "plugin.review"  // F079

    public static let presentSetMode = "present.setMode"  // F063

    public static let presetSelect = "preset.select"  // F008
    public static let presetSetSwatch = "preset.setSwatch"  // F008
    public static let presetAddSwatch = "preset.addSwatch"  // F008
    public static let presetRemoveSwatch = "preset.removeSwatch"  // F008
    public static let presetMoveSwatch = "preset.moveSwatch"  // F008
    public static let presetSetWidth = "preset.setWidth"  // F008
    public static let presetReset = "preset.reset"  // F008

    public static let printPresent = "print.present"  // F067

    public static let relayConfigure = "relay.configure"  // F092

    public static let replaySetMode = "replay.setMode"  // F053
    public static let replaySeekToItem = "replay.seekToItem"  // F053
    public static let replayTapAt = "replay.tapAt"  // F053

    public static let rulerSet = "ruler.set"  // F039

    public static let scanDocuments = "scan.documents"  // F065
    public static let scanQr = "scan.qr"  // F065

    public static let searchOpen = "search.open"  // F056
    public static let searchStep = "search.step"  // F056

    public static let selectionFromRect = "selection.fromRect"  // F011
    public static let selectionFromLoop = "selection.fromLoop"  // F011
    public static let selectionSelectAll = "selection.selectAll"  // F011
    public static let selectionTapAt = "selection.tapAt"  // F011
    public static let selectionScreenshot = "selection.screenshot"  // F013

    public static let settingsOpen = "settings.open"  // F027

    public static let shapeSetStyle = "shape.setStyle"  // F031
    public static let shapeSetKind = "shape.setKind"  // F031
    public static let shapeSetPoints = "shape.setPoints"  // F031
    public static let shapeTapAt = "shape.tapAt"  // F031

    public static let sidebarToggle = "sidebar.toggle"  // F017

    public static let spellcheckTapAt = "spellcheck.tapAt"  // F104

    public static let stickyCreate = "sticky.create"  // F036
    public static let stickySetCollapsed = "sticky.setCollapsed"  // F036
    public static let stickyResolve = "sticky.resolve"  // F036
    public static let stickySetColor = "sticky.setColor"  // F036
    public static let stickyTapAt = "sticky.tapAt"  // F036

    public static let stopwatchStart = "stopwatch.start"  // F062
    public static let stopwatchLap = "stopwatch.lap"  // F062

    public static let studyGrade = "study.grade"  // F050
    public static let studyResetProgress = "study.resetProgress"  // F050
    public static let studySetReminders = "study.setReminders"  // F050
    public static let studySetTheme = "study.setTheme"  // F050
    public static let studyImportText = "study.importText"  // F051
    public static let studyExportCSV = "study.exportCSV"  // F051

    public static let syncNow = "sync.now"  // F025

    public static let tabClose = "tab.close"  // F018
    public static let tabCloseOthers = "tab.closeOthers"  // F018
    public static let tabSelect = "tab.select"  // F018

    public static let tableEdit = "table.edit"  // F048
    public static let tableExportCSV = "table.exportCSV"  // F048

    public static let tapeTapAt = "tape.tapAt"  // F033
    public static let tapeSetRevealed = "tape.setRevealed"  // F033
    public static let tapeRemoveAll = "tape.removeAll"  // F033
    public static let tapeImportPattern = "tape.importPattern"  // F033
    public static let tapePatterns = "tape.patterns"  // F033
    public static let tapeDeletePattern = "tape.deletePattern"  // F033
    public static let tapeClearHistory = "tape.clearHistory"  // F033

    public static let templateList = "template.list"  // F005
    public static let templateChoose = "template.choose"  // F045
    public static let templateImport = "template.import"  // F045
    public static let templateListCustom = "template.listCustom"  // F045
    public static let templateGroupCreate = "template.group.create"  // F045
    public static let templateGroupRename = "template.group.rename"  // F045
    public static let templateGroupDelete = "template.group.delete"  // F045
    public static let templateDelete = "template.delete"  // F045
    public static let templateSetHidden = "template.setHidden"  // F045
    public static let templateFromPage = "template.fromPage"  // F045

    public static let textFormat = "text.format"  // F026
    public static let textSetParagraph = "text.setParagraph"  // F026
    public static let textSetBoxStyle = "text.setBoxStyle"  // F026
    public static let textSaveDefaultStyle = "text.saveDefaultStyle"  // F026
    public static let textTapAt = "text.tapAt"  // F026
    public static let textStartPageText = "text.startPageText"  // F028

    public static let timerStart = "timer.start"  // F062
    public static let timerControl = "timer.control"  // F062
    public static let timerHistory = "timer.history"  // F062
    public static let timerSaveMode = "timer.saveMode"  // F062
    public static let timerDeleteMode = "timer.deleteMode"  // F062

    public static let toolbarSetLayout = "toolbar.setLayout"  // F016
    public static let toolbarReset = "toolbar.reset"  // F016
    public static let toolbarSetVisible = "toolbar.setVisible"  // F016
    public static let toolbarLayouts = "toolbar.layouts"  // F016
    public static let toolbarSaveLayout = "toolbar.saveLayout"  // F016
    public static let toolbarApplyLayout = "toolbar.applyLayout"  // F016
    public static let toolbarDeleteLayout = "toolbar.deleteLayout"  // F016
    public static let toolbarDock = "toolbar.dock"  // F016

    public static let transcriptGet = "transcript.get"  // F054
    public static let transcriptRegenerate = "transcript.regenerate"  // F054
    public static let transcriptEditSegment = "transcript.editSegment"  // F054
    public static let transcriptInsert = "transcript.insert"  // F054

    public static let trashList = "trash.list"  // F002
    public static let trashRecover = "trash.recover"  // F002
    public static let trashDeletePermanently = "trash.deletePermanently"  // F002
    public static let trashEmpty = "trash.empty"  // F002

    public static let viewZoom = "view.zoom"  // F006
    public static let viewScrollBy = "view.scrollBy"  // F006

    public static let webdavSyncNow = "webdav.syncNow"  // F069
    public static let webdavConfigure = "webdav.configure"  // F069
    public static let webdavPut = "webdav.put"  // F069
    public static let webdavStatus = "webdav.status"  // F069

    public static let windowOpen = "window.open"  // F018

    public static let zoomToggle = "zoom.toggle"  // F038
    public static let zoomSetBox = "zoom.setBox"  // F038
    public static let zoomNewLine = "zoom.newLine"  // F038
    public static let zoomSetReturnHeight = "zoom.setReturnHeight"  // F038
}

/// contracts-v2: well-known panel ids, so a feature can open another feature's panel with `panel.open {id}` without
/// guessing by owner. Owners register their panels under exactly these ids.
public enum PanelIDs {
    /// AI chat panel (F085).
    public static let assistant = "aichat.panel"
    /// Library Trash tab (F020).
    public static let trash = "organize.trash"
    /// Library Favourites tab (F020).
    public static let favourites = "organize.favourites"
    /// Manage Templates (F045).
    public static let templates = "templateui.manage"
    /// Cloud & Backup (F070).
    public static let cloudBackup = "syncui.panel"
    /// About (F098).
    public static let about = "about.panel"
    /// Plugin and content Gallery library tab (F080).
    public static let gallery = "pluginmanager.gallery"
    /// Study set Practice panel (F050).
    public static let studyPractice = "studysession.practice"
    /// Study set Smart Learn panel (F050). contracts-v2.1: the id F049 opens and ARCHITECTURE.md §13 lists.
    public static let studySmartLearn = "studysession.smartLearn"
    /// Superseded in contracts-v2.1 by `studySmartLearn`. contracts-v2 shipped "studysession.learn", which no feature
    /// registers; this now holds the Smart Learn id so existing callers open the right panel.
    public static let studyLearn = "studysession.smartLearn"
    /// Move Pages sheet (F022). contracts-v2.1. Open it with `panel.open {id, pages?}`: the sheet moves the page refs
    /// in `PanelContext.params["pages"]`, or the open page when there are none (F023 passes the selected thumbnails).
    public static let movePages = "pages.movePages"
}
```

### `NibKit/Sources/NibContracts/Core/Mutation.swift`

```swift
import Foundation

/// Node refs touched by a change (what events carry; subscribers query for details).
public struct ChangeSummary: Codable, Equatable {
    public var created: [String]
    public var updated: [String]
    public var removed: [String]

    public init(created: [String] = [], updated: [String] = [], removed: [String] = []) {
        self.created = created
        self.updated = updated
        self.removed = removed
    }

    public var isEmpty: Bool { created.isEmpty && updated.isEmpty && removed.isEmpty }
    public var count: Int { created.count + updated.count + removed.count }
    public var all: [String] { created + updated + removed }

    public mutating func merge(_ other: ChangeSummary) {
        var seen = Set(all)
        for r in other.created where seen.insert(r).inserted { created.append(r) }
        for r in other.updated where seen.insert(r).inserted { updated.append(r) }
        for r in other.removed where seen.insert(r).inserted { removed.append(r) }
    }
}

/// One record write with its previous value (nil = inserted). The only mutation primitive.
public enum Mutation {
    case item(DocumentID, PageID, before: Item?, after: Item)
    case page(DocumentID, before: PageRecord?, after: PageRecord)
    case meta(DocumentID, before: DocumentMeta, after: DocumentMeta)
    case block(DocumentID, before: TextBlock?, after: TextBlock)
    case card(DocumentID, before: StudyCard?, after: StudyCard)
    case audio(DocumentID, before: AudioClip?, after: AudioClip)
    case outline(DocumentID, before: OutlineEntry?, after: OutlineEntry)

    public var document: DocumentID {
        switch self {
        case .item(let d, _, _, _), .page(let d, _, _), .meta(let d, _, _), .block(let d, _, _),
             .card(let d, _, _), .audio(let d, _, _), .outline(let d, _, _):
            return d
        }
    }

    /// Identity of the written record (kind, document, page for items, id): the key undo rebasing works on.
    var recordKey: RecordKey {
        switch self {
        case let .item(d, p, _, a): return RecordKey(kind: 0, doc: d, page: p, id: a.id)
        case let .page(d, _, a): return RecordKey(kind: 1, doc: d, page: nil, id: a.id)
        case let .meta(d, _, _): return RecordKey(kind: 2, doc: d, page: nil, id: d)
        case let .block(d, _, a): return RecordKey(kind: 3, doc: d, page: nil, id: a.id)
        case let .card(d, _, a): return RecordKey(kind: 4, doc: d, page: nil, id: a.id)
        case let .audio(d, _, a): return RecordKey(kind: 5, doc: d, page: nil, id: a.id)
        case let .outline(d, _, a): return RecordKey(kind: 6, doc: d, page: nil, id: a.id)
        }
    }

    /// Revision of the written value (`after.rev`).
    var afterRev: Rev {
        switch self {
        case let .item(_, _, _, a): return a.rev
        case let .page(_, _, a): return a.rev
        case let .meta(_, _, a): return a.rev
        case let .block(_, _, a): return a.rev
        case let .card(_, _, a): return a.rev
        case let .audio(_, _, a): return a.rev
        case let .outline(_, _, a): return a.rev
        }
    }

    /// The same mutation with `after.rev` replaced (undo rebasing: the value is unchanged, only its revision moved).
    func withAfterRev(_ rev: Rev) -> Mutation {
        func stamped<T: LWWRecord>(_ r: T) -> T {
            var x = r
            x.rev = rev
            return x
        }
        switch self {
        case let .item(d, p, b, a): return .item(d, p, before: b, after: stamped(a))
        case let .page(d, b, a): return .page(d, before: b, after: stamped(a))
        case let .meta(d, b, a):
            var m = a
            m.rev = rev
            return .meta(d, before: b, after: m)
        case let .block(d, b, a): return .block(d, before: b, after: stamped(a))
        case let .card(d, b, a): return .card(d, before: b, after: stamped(a))
        case let .audio(d, b, a): return .audio(d, before: b, after: stamped(a))
        case let .outline(d, b, a): return .outline(d, before: b, after: stamped(a))
        }
    }

    /// Ref of the written record and whether the write created or removed it (tombstone transitions).
    public var change: (ref: String, created: Bool, removed: Bool) {
        func classify(_ beforeDeleted: Bool?, _ afterDeleted: Bool) -> (Bool, Bool) {
            let wasLive = beforeDeleted.map { !$0 } ?? false
            return (!wasLive && !afterDeleted, wasLive && afterDeleted)
        }
        switch self {
        case let .item(d, p, b, a):
            let c = classify(b?.deleted, a.deleted)
            return (NodeRef.item(d, p, a.id).description, c.0, c.1)
        case let .page(d, b, a):
            let c = classify(b?.deleted, a.deleted)
            return (NodeRef.page(d, a.id).description, c.0, c.1)
        case let .meta(d, _, _):
            return (NodeRef.document(d).description, false, false)
        case let .block(d, b, a):
            let c = classify(b?.deleted, a.deleted)
            return (NodeRef.block(d, a.id).description, c.0, c.1)
        case let .card(d, b, a):
            let c = classify(b?.deleted, a.deleted)
            return (NodeRef.card(d, a.id).description, c.0, c.1)
        case let .audio(d, b, a):
            let c = classify(b?.deleted, a.deleted)
            return (NodeRef.audio(d, a.id).description, c.0, c.1)
        case let .outline(d, b, a):
            let c = classify(b?.deleted, a.deleted)
            return (NodeRef.outline(d, a.id).description, c.0, c.1)
        }
    }
}

/// Which record a mutation wrote: kind tag (0 item … 6 outline), document, page (items only) and id.
struct RecordKey: Hashable {
    let kind: UInt8
    let doc: DocumentID
    let page: PageID?
    let id: NibID
}

/// Revisions an undo, redo or revert moved (contracts-v2). Reverting writes a record's older value with a FRESH
/// revision; every stored mutation that still expects the record at the revision of that older value must now accept
/// the fresh one instead, or the next undo on the same record would look like a later edit and be skipped.
/// `map[key][old] = new` = "the value that had revision `old` now lives at revision `new`".
struct RevRebase {
    private(set) var map: [RecordKey: [Rev: Rev]] = [:]

    var isEmpty: Bool { map.isEmpty }
    var documents: Set<DocumentID> { Set(map.keys.map { $0.doc }) }

    mutating func record(_ key: RecordKey, old: Rev, new: Rev) {
        map[key, default: [:]][old] = new
    }

    /// The revision a record must carry now for a mutation that wrote `rev` to still be the latest write.
    func current(_ key: RecordKey, _ rev: Rev) -> Rev {
        map[key]?[rev] ?? rev
    }

    /// `m` with its after-revision moved when the record's value was re-stamped.
    func apply(_ m: Mutation) -> Mutation {
        guard let moves = map[m.recordKey], let rev = moves[m.afterRev] else { return m }
        return m.withAfterRev(rev)
    }
}

/// A committed transaction (or a merged remote patch). Observers use it to invalidate tiles, indexes, etc.
public struct Changeset {
    public let id: UUID
    /// Monotonic per app run.
    public let seq: UInt64
    public let principal: Principal
    /// Undo group: all changes of one command, one plugin call or one AI turn share a group.
    public let group: String
    public let label: String
    public let command: String
    public let mutations: [Mutation]

    public init(id: UUID = UUID(), seq: UInt64, principal: Principal, group: String, label: String, command: String, mutations: [Mutation]) {
        self.id = id
        self.seq = seq
        self.principal = principal
        self.group = group
        self.label = label
        self.command = command
        self.mutations = mutations
    }

    public static func summarize(_ mutations: [Mutation]) -> ChangeSummary {
        var s = ChangeSummary()
        var seen = Set<String>()
        for m in mutations {
            let c = m.change
            guard seen.insert(c.ref).inserted else { continue }
            if c.created {
                s.created.append(c.ref)
            } else if c.removed {
                s.removed.append(c.ref)
            } else {
                s.updated.append(c.ref)
            }
        }
        return s
    }

    public var summary: ChangeSummary { Changeset.summarize(mutations) }
    public func summary(for doc: DocumentID) -> ChangeSummary { Changeset.summarize(mutations.filter { $0.document == doc }) }
    public var documents: Set<DocumentID> { Set(mutations.map { $0.document }) }

    /// True when the document head (meta, page table, outline, blocks, cards, audio) changed.
    public func headChanged(_ doc: DocumentID) -> Bool {
        mutations.contains { m in
            if case .item = m { return false }
            return m.document == doc
        }
    }

    /// Pages whose items changed, per document.
    public var itemPages: [DocumentID: Set<PageID>] {
        var out: [DocumentID: Set<PageID>] = [:]
        for m in mutations {
            if case let .item(d, p, _, _) = m { out[d, default: []].insert(p) }
        }
        return out
    }

    /// Union of before/after bounds of items changed on a page (for tile invalidation); nil if none.
    public func dirtyRect(doc: DocumentID, page: PageID) -> Rect? {
        var r: Rect?
        for m in mutations {
            guard case let .item(d, p, b, a) = m, d == doc, p == page else { continue }
            var u = a.bounds
            if let b = b { u = u.union(b.bounds) }
            r = r.map { $0.union(u) } ?? u
        }
        return r
    }

    /// The after-values for one document, as sent to collaborators.
    public func patch(for doc: DocumentID) -> DocumentPatch {
        var p = DocumentPatch(doc: doc)
        for m in mutations where m.document == doc {
            switch m {
            case let .item(_, page, _, a): p.items[page.raw, default: []].append(a)
            case let .page(_, _, a): p.pages.append(a)
            case let .meta(_, _, a): p.meta = a
            case let .block(_, _, a): p.blocks.append(a)
            case let .card(_, _, a): p.cards.append(a)
            case let .audio(_, _, a): p.audio.append(a)
            case let .outline(_, _, a): p.outline.append(a)
            }
        }
        return p
    }
}

/// Records to merge last-writer-wins (sync, collaboration, per-device package files).
public struct DocumentPatch: Codable {
    public var doc: DocumentID
    public var meta: DocumentMeta?
    public var pages: [PageRecord]
    /// PageID raw value → items.
    public var items: [String: [Item]]
    public var outline: [OutlineEntry]
    public var blocks: [TextBlock]
    public var cards: [StudyCard]
    public var audio: [AudioClip]

    public init(doc: DocumentID, meta: DocumentMeta? = nil, pages: [PageRecord] = [], items: [String: [Item]] = [:],
                outline: [OutlineEntry] = [], blocks: [TextBlock] = [], cards: [StudyCard] = [], audio: [AudioClip] = []) {
        self.doc = doc
        self.meta = meta
        self.pages = pages
        self.items = items
        self.outline = outline
        self.blocks = blocks
        self.cards = cards
        self.audio = audio
    }

    public var isEmpty: Bool {
        meta == nil && pages.isEmpty && items.isEmpty && outline.isEmpty && blocks.isEmpty && cards.isEmpty && audio.isEmpty
    }
}
```

### `NibKit/Sources/NibContracts/Core/Workspace.swift`

```swift
import Foundation

/// Storage behind the workspace. Implemented by the NibStore feature (package files in the library folder);
/// `InMemoryPersistence` is the default and the test double. Main-actor isolated (the workspace calls it on main);
/// implementations snapshot on main and do file I/O on their own queue. Package URLs off-main come from
/// `NibServices.packages` (a thread-safe `PackageLocator`), never from `LibraryService`.
@MainActor
public protocol DocumentPersistence: AnyObject {
    /// Loads and merges the document head from every device file. Throws `not_found`.
    func loadHead(_ doc: DocumentID) throws -> DocumentContent
    /// Loads and merges all items of a page, tombstones included.
    func loadItems(_ doc: DocumentID, page: PageID) throws -> [Item]
    /// Called on the main actor after every commit/merge. `head` is nil when unchanged; `pages` holds the
    /// full item arrays (tombstones included) of changed pages. Implementations debounce and write off-main.
    func didChange(_ doc: DocumentID, head: DocumentContent?, pages: [PageID: [Item]])
    /// Writes pending changes now (page leave, background, close).
    func flush(_ doc: DocumentID)
    /// Absolute URL of a file inside the document package (audio, transcripts); creates parent folders.
    func fileURL(_ doc: DocumentID, relativePath: String) throws -> URL
    /// Records written by OTHER devices since this device last read them (folder sync). nil = nothing new.
    func remoteChanges(_ doc: DocumentID) throws -> DocumentPatch?
    /// contracts-v2: true when the document must not be written (saved by a newer format, unreadable files, read-only
    /// package). Commits still apply in memory, but nothing is persisted. Default: false.
    func isReadOnly(_ doc: DocumentID) -> Bool
    /// contracts-v2: the highest revision of a page's items (tombstones included) as stored, WITHOUT loading the items
    /// into memory (thumbnail and index validity checks). nil = unknown (the caller loads the page). Default: nil.
    func contentRevision(_ doc: DocumentID, page: PageID) -> Rev?
}

@MainActor
public extension DocumentPersistence {
    func isReadOnly(_ doc: DocumentID) -> Bool { false }
    func contentRevision(_ doc: DocumentID, page: PageID) -> Rev? { nil }
}

@MainActor
public final class InMemoryPersistence: DocumentPersistence {
    public var heads: [DocumentID: DocumentContent] = [:]
    public var pageItems: [DocumentID: [PageID: [Item]]] = [:]
    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-memory-" + UUID().uuidString, isDirectory: true)
    }

    public func loadHead(_ doc: DocumentID) throws -> DocumentContent {
        guard let h = heads[doc] else { throw NibError.notFound("document \(doc)") }
        return h
    }

    public func loadItems(_ doc: DocumentID, page: PageID) throws -> [Item] {
        pageItems[doc]?[page] ?? []
    }

    public func didChange(_ doc: DocumentID, head: DocumentContent?, pages: [PageID: [Item]]) {
        if let h = head { heads[doc] = h }
        for (p, items) in pages { pageItems[doc, default: [:]][p] = items }
    }

    public func flush(_ doc: DocumentID) {}

    public func fileURL(_ doc: DocumentID, relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(doc.raw, isDirectory: true).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    public func remoteChanges(_ doc: DocumentID) throws -> DocumentPatch? { nil }
}

/// In-memory state of open documents. Reads are public; writes happen only inside `DocTransaction`
/// (via `CommandContext.mutate`), undo/redo, and `CommandBus.applyRemote`.
@MainActor
public final class Workspace {
    public let clock: HLCClock
    /// Replace before any document is opened (the NibStore feature does this in `register`).
    public var persistence: DocumentPersistence
    public let events: EventBus
    private var heads: [DocumentID: DocumentContent] = [:]
    private var pageItems: [DocumentID: [PageID: [Item]]] = [:]
    /// id → index into `pageItems[doc][page]`, built lazily and dropped whenever that array is re-sorted or rebuilt,
    /// so replacing one item costs O(1) instead of a scan of the page (contracts-v2).
    private var itemIndex: [DocumentID: [PageID: [ElementID: Int]]] = [:]

    public init(clock: HLCClock, persistence: DocumentPersistence, events: EventBus) {
        self.clock = clock
        self.persistence = persistence
        self.events = events
    }

    // MARK: Reads

    public func content(_ doc: DocumentID) throws -> DocumentContent {
        if let h = heads[doc] { return h }
        let h = try persistence.loadHead(doc)
        clock.observe(h.meta.rev)
        heads[doc] = h
        events.emit(NibEventType.docOpened, doc: doc)
        return h
    }

    /// All items of a page including tombstones, sorted by (z, id).
    public func allItems(_ doc: DocumentID, page: PageID) throws -> [Item] {
        if let items = pageItems[doc]?[page] { return items }
        _ = try content(doc)
        let items = Workspace.sortedByZ(try persistence.loadItems(doc, page: page))
        pageItems[doc, default: [:]][page] = items
        itemIndex[doc]?[page] = nil
        return items
    }

    /// Live items of a page in z-order (bottom first).
    public func items(_ doc: DocumentID, page: PageID) throws -> [Item] {
        try allItems(doc, page: page).filter { !$0.deleted }
    }

    /// Live items whose bounds intersect `rect`.
    public func items(_ doc: DocumentID, page: PageID, in rect: Rect) throws -> [Item] {
        try items(doc, page: page).filter { $0.bounds.intersects(rect) }
    }

    public func item(_ doc: DocumentID, page: PageID, id: ElementID) throws -> Item {
        guard let it = try allItems(doc, page: page).first(where: { $0.id == id && !$0.deleted }) else {
            throw NibError.notFound("item \(id) on page \(page)")
        }
        return it
    }

    /// Finds the page holding a live item (loads pages as needed).
    public func page(ofItem id: ElementID, in doc: DocumentID) throws -> PageID? {
        for p in try content(doc).pages {
            if try allItems(doc, page: p.id).contains(where: { $0.id == id && !$0.deleted }) { return p.id }
        }
        return nil
    }

    public var loadedDocuments: [DocumentID] { Array(heads.keys) }
    public func isLoaded(_ doc: DocumentID) -> Bool { heads[doc] != nil }

    /// contracts-v2: true when the page's items are in memory (reading them costs no I/O).
    public func isPageCached(_ doc: DocumentID, page: PageID) -> Bool { pageItems[doc]?[page] != nil }

    /// contracts-v2: pages of `doc` whose items are in memory (e.g. to evict only pages you loaded yourself).
    public func cachedPages(_ doc: DocumentID) -> Set<PageID> { Set(pageItems[doc]?.keys.map { $0 } ?? []) }

    /// contracts-v2: the document head WITHOUT opening it: the loaded head when the document is open, else a fresh
    /// read from persistence that is neither cached nor announced (`doc.opened` is not emitted). For library-wide
    /// scans (favourite and trashed pages, catalogues). Throws `not_found`.
    public func peekContent(_ doc: DocumentID) throws -> DocumentContent {
        if let h = heads[doc] { return h }
        return try persistence.loadHead(doc)
    }

    /// contracts-v2: the highest revision among a page's items (tombstones included): from memory when the page is
    /// cached, else `persistence.contentRevision` (nil = unknown without loading the page). Thumbnail keys, caches.
    public func contentRevision(_ doc: DocumentID, page: PageID) -> Rev? {
        if let items = pageItems[doc]?[page] { return items.map { $0.rev }.max() ?? .zero }
        return persistence.contentRevision(doc, page: page)
    }

    /// contracts-v2: true when persistence refuses to write the document (see `DocumentPersistence.isReadOnly`).
    public func isReadOnly(_ doc: DocumentID) -> Bool { persistence.isReadOnly(doc) }

    /// Flushes and drops a document from memory.
    public func close(_ doc: DocumentID) {
        guard heads[doc] != nil else { return }
        persistence.flush(doc)
        heads[doc] = nil
        pageItems[doc] = nil
        itemIndex[doc] = nil
        events.emit(NibEventType.docClosed, doc: doc)
    }

    /// Memory pressure: drop cached pages except `keeping`.
    public func evictPages(_ doc: DocumentID, keeping: Set<PageID>) {
        persistence.flush(doc)
        guard var cache = pageItems[doc] else { return }
        for key in Array(cache.keys) where !keeping.contains(key) {
            cache[key] = nil
            itemIndex[doc]?[key] = nil
        }
        pageItems[doc] = cache
    }

    static func sortedByZ(_ items: [Item]) -> [Item] {
        items.sorted { ($0.z, $0.id.raw) < ($1.z, $1.id.raw) }
    }

    // MARK: Internal writes (DocTransaction, undo, merge)

    /// Index of `id` in the cached page array (building the page's id index on first use).
    private func position(_ id: ElementID, doc: DocumentID, page: PageID) -> Int? {
        if let i = itemIndex[doc]?[page]?[id] { return i }
        if itemIndex[doc]?[page] != nil { return nil }
        guard let list = pageItems[doc]?[page] else { return nil }
        var index: [ElementID: Int] = [:]
        index.reserveCapacity(list.count)
        for (i, it) in list.enumerated() where index[it.id] == nil { index[it.id] = i }
        itemIndex[doc, default: [:]][page] = index
        return index[id]
    }

    private func resort(_ doc: DocumentID, _ page: PageID) {
        guard let list = pageItems[doc]?[page] else { return }
        pageItems[doc]?[page] = Workspace.sortedByZ(list)
        itemIndex[doc]?[page] = nil
    }

    func currentItem(_ id: ElementID, doc: DocumentID, page: PageID) -> Item? {
        guard (try? allItems(doc, page: page)) != nil, let i = position(id, doc: doc, page: page) else { return nil }
        return pageItems[doc]?[page]?[i]
    }

    @discardableResult
    func writeItem(_ item: Item, doc: DocumentID, page: PageID) throws -> Item? {
        _ = try allItems(doc, page: page)
        if let i = position(item.id, doc: doc, page: page), let old = pageItems[doc]?[page]?[i] {
            pageItems[doc]?[page]?[i] = item
            if old.z != item.z { resort(doc, page) }
            return old
        }
        let last = pageItems[doc]?[page]?.last
        pageItems[doc]?[page]?.append(item)
        if let last = last, (last.z, last.id.raw) > (item.z, item.id.raw) {
            resort(doc, page)
        } else if itemIndex[doc]?[page] != nil, let count = pageItems[doc]?[page]?.count {
            itemIndex[doc]?[page]?[item.id] = count - 1
        }
        return nil
    }

    /// Writes several items of one page (later entries win for repeated ids); returns each write's previous value.
    func writeItems(_ items: [Item], doc: DocumentID, page: PageID) throws -> [Item?] {
        var list = try allItems(doc, page: page)
        pageItems[doc]?[page] = []                      // keep `list` uniquely referenced while it is edited
        var index: [ElementID: Int] = [:]
        index.reserveCapacity(list.count + items.count)
        for (i, it) in list.enumerated() where index[it.id] == nil { index[it.id] = i }
        var olds: [Item?] = []
        olds.reserveCapacity(items.count)
        var needsSort = false
        for item in items {
            if let i = index[item.id] {
                olds.append(list[i])
                if list[i].z != item.z { needsSort = true }
                list[i] = item
            } else {
                if let last = list.last, (last.z, last.id.raw) > (item.z, item.id.raw) { needsSort = true }
                index[item.id] = list.count
                list.append(item)
                olds.append(nil)
            }
        }
        if needsSort {
            pageItems[doc, default: [:]][page] = Workspace.sortedByZ(list)
            itemIndex[doc]?[page] = nil
        } else {
            pageItems[doc, default: [:]][page] = list
            itemIndex[doc, default: [:]][page] = index
        }
        return olds
    }

    func removeItem(_ id: ElementID, doc: DocumentID, page: PageID) {
        pageItems[doc]?[page]?.removeAll { $0.id == id }
        itemIndex[doc]?[page] = nil
    }

    @discardableResult
    func writeRecord<T: LWWRecord>(_ record: T, doc: DocumentID, at path: WritableKeyPath<DocumentContent, [T]>) throws -> T? {
        _ = try content(doc)
        guard var h = heads.removeValue(forKey: doc) else { throw NibError.notFound("document \(doc)") }
        var old: T?
        if let i = h[keyPath: path].firstIndex(where: { $0.id == record.id }) {
            old = h[keyPath: path][i]
            h[keyPath: path][i] = record
        } else {
            h[keyPath: path].append(record)
        }
        heads[doc] = h
        return old
    }

    /// Writes several records of one kind (later entries win for repeated ids); returns each write's previous value.
    func writeRecords<T: LWWRecord>(_ records: [T], doc: DocumentID, at path: WritableKeyPath<DocumentContent, [T]>) throws -> [T?] {
        _ = try content(doc)
        guard var h = heads.removeValue(forKey: doc) else { throw NibError.notFound("document \(doc)") }
        var list = h[keyPath: path]
        h[keyPath: path] = []
        var index: [NibID: Int] = [:]
        for (i, r) in list.enumerated() where index[r.id] == nil { index[r.id] = i }
        var olds: [T?] = []
        olds.reserveCapacity(records.count)
        for r in records {
            if let i = index[r.id] {
                olds.append(list[i])
                list[i] = r
            } else {
                index[r.id] = list.count
                list.append(r)
                olds.append(nil)
            }
        }
        h[keyPath: path] = list
        heads[doc] = h
        return olds
    }

    /// Rollback support: restores several records of one kind in one pass (`nil` value = remove the record; ids that
    /// are not present are appended in `order`).
    func restoreRecords<T: LWWRecord>(_ values: [NibID: T?], order: [NibID], doc: DocumentID,
                                      at path: WritableKeyPath<DocumentContent, [T]>) {
        guard !values.isEmpty, var h = heads.removeValue(forKey: doc) else { return }
        let list = h[keyPath: path]
        h[keyPath: path] = []
        var out: [T] = []
        out.reserveCapacity(list.count)
        var placed = Set<NibID>()
        for r in list {
            guard let value = values[r.id] else {
                out.append(r)
                continue
            }
            guard let restored = value else { continue }
            out.append(placed.insert(r.id).inserted ? restored : r)
        }
        for id in order where !placed.contains(id) {
            if let value = values[id], let restored = value { out.append(restored) }
        }
        h[keyPath: path] = out
        heads[doc] = h
    }

    func removeRecord<T: LWWRecord>(_ id: NibID, doc: DocumentID, at path: WritableKeyPath<DocumentContent, [T]>) {
        guard var h = heads[doc] else { return }
        h[keyPath: path].removeAll { $0.id == id }
        heads[doc] = h
    }

    func currentRecord<T: LWWRecord>(_ id: NibID, doc: DocumentID, at path: WritableKeyPath<DocumentContent, [T]>) -> T? {
        (try? content(doc))?[keyPath: path].first { $0.id == id }
    }

    @discardableResult
    func writeMeta(_ meta: DocumentMeta) throws -> DocumentMeta {
        var h = try content(meta.id)
        let old = h.meta
        h.meta = meta
        heads[meta.id] = h
        return old
    }

    /// Hands changed state to persistence.
    func persist(_ cs: Changeset) {
        let itemPages = cs.itemPages
        for doc in cs.documents {
            guard let h = heads[doc] else { continue }
            var pages: [PageID: [Item]] = [:]
            for p in itemPages[doc] ?? [] {
                if let items = pageItems[doc]?[p] { pages[p] = items }
            }
            persistence.didChange(doc, head: cs.headChanged(doc) ? h : nil, pages: pages)
        }
    }

    /// Last-writer-wins merge of a remote patch. Returns the mutations that actually changed state.
    /// Remote revs more than 24 h ahead are distrusted (`Rev.effective`).
    func merge(_ patch: DocumentPatch) throws -> [Mutation] {
        let doc = patch.doc
        var out: [Mutation] = []
        if let m = patch.meta {
            clock.observe(m.rev)
            let current = try content(doc).meta
            if m.rev.effective() > current.rev.effective() {
                let before = try writeMeta(m)
                out.append(.meta(doc, before: before, after: m))
            }
        }
        for r in patch.pages { try mergeRecord(r, doc: doc, at: \.pages, into: &out) { .page(doc, before: $0, after: $1) } }
        for r in patch.outline { try mergeRecord(r, doc: doc, at: \.outline, into: &out) { .outline(doc, before: $0, after: $1) } }
        for r in patch.blocks { try mergeRecord(r, doc: doc, at: \.blocks, into: &out) { .block(doc, before: $0, after: $1) } }
        for r in patch.cards { try mergeRecord(r, doc: doc, at: \.cards, into: &out) { .card(doc, before: $0, after: $1) } }
        for r in patch.audio { try mergeRecord(r, doc: doc, at: \.audio, into: &out) { .audio(doc, before: $0, after: $1) } }
        for (pageRaw, items) in patch.items {
            let page = PageID(pageRaw)
            guard try content(doc).page(page) != nil else { continue }
            for it in items {
                clock.observe(it.rev)
                let current = currentItem(it.id, doc: doc, page: page)
                if let current = current, current.rev.effective() >= it.rev.effective() { continue }
                let before = try writeItem(it, doc: doc, page: page)
                out.append(.item(doc, page, before: before, after: it))
            }
        }
        return out
    }

    private func mergeRecord<T: LWWRecord>(_ record: T, doc: DocumentID, at path: WritableKeyPath<DocumentContent, [T]>,
                                           into out: inout [Mutation], wrap: (T?, T) -> Mutation) throws {
        clock.observe(record.rev)
        if let current = currentRecord(record.id, doc: doc, at: path), current.rev.effective() >= record.rev.effective() { return }
        let before = try writeRecord(record, doc: doc, at: path)
        out.append(wrap(before, record))
    }
}
```

### `NibKit/Sources/NibContracts/Core/DocTransaction.swift`

```swift
import Foundation

/// The ONLY way to change documents. Obtained exclusively inside `CommandContext.mutate { tx in … }`,
/// which runs synchronously on the main actor, so a transaction is atomic. Every write gets a fresh
/// revision and is recorded with its previous value (undo, sync, collaboration, events).
/// If the body throws, or an invariant fails, everything written is rolled back.
@MainActor
public final class DocTransaction {
    public let principal: Principal
    public let group: String
    let workspace: Workspace
    private(set) var mutations: [Mutation] = []

    init(workspace: Workspace, principal: Principal, group: String) {
        self.workspace = workspace
        self.principal = principal
        self.group = group
    }

    // MARK: Reads (see this transaction's own writes)

    public func content(_ doc: DocumentID) throws -> DocumentContent { try workspace.content(doc) }
    public func items(_ doc: DocumentID, page: PageID) throws -> [Item] { try workspace.items(doc, page: page) }
    public func item(_ doc: DocumentID, page: PageID, id: ElementID) throws -> Item { try workspace.item(doc, page: page, id: id) }

    /// A z key above every item on the page.
    public func topZ(_ doc: DocumentID, page: PageID) throws -> String {
        let last = try workspace.allItems(doc, page: page).last?.z
        return FractionalIndex.between(last, nil)
    }

    /// A z key below every item on the page.
    public func bottomZ(_ doc: DocumentID, page: PageID) throws -> String {
        let first = try workspace.allItems(doc, page: page).first?.z
        return FractionalIndex.between(nil, (first?.isEmpty ?? true) ? nil : first)
    }

    // MARK: Writes

    /// Inserts or replaces an item. Empty `z` = keep the existing z, or top of page for new items.
    @discardableResult
    public func put(_ item: Item, doc: DocumentID, page: PageID) throws -> Item {
        try putItem(item, doc: doc, page: page, inherited: nil)
    }

    /// contracts-v2: inserts or replaces `item` on `page`, keeping the provenance (`createdBy`) of the STORED record with
    /// the same id on `sourcePage` (of `sourceDoc`, default `doc`; live or tombstoned) instead of stamping the principal.
    /// For moves and copies of an existing record across pages or documents (`node.move`, `item.moveToPage`,
    /// `page.moveTo`): the AI moving the user's handwriting keeps it the user's. The value is read from storage, never
    /// from params, so it cannot be forged; throws `not_found` when no such record exists. `move(item:doc:from:to:)`
    /// does a whole same-document move.
    @discardableResult
    public func put(_ item: Item, doc: DocumentID, page: PageID, keepingProvenanceFrom sourcePage: PageID,
                    in sourceDoc: DocumentID? = nil) throws -> Item {
        guard let source = workspace.currentItem(item.id, doc: sourceDoc ?? doc, page: sourcePage) else {
            throw NibError.notFound("item \(item.id) on page \(sourcePage)")
        }
        return try putItem(item, doc: doc, page: page, inherited: .some(source.createdBy))
    }

    /// contracts-v2: moves a live item to another page of the same document in one step: tombstones it on `source` and
    /// writes it on `target` with the same id and its provenance kept (see `put(_:doc:page:keepingProvenanceFrom:in:)`),
    /// optionally transformed. Empty `z` = top of the target page. `attachedTo` and connector anchors that do not
    /// resolve to a live item on the target page are dropped (connector ends keep their points), so the transaction
    /// still validates. `source == target` is a plain update. Returns the written item.
    @discardableResult
    public func move(item id: ElementID, doc: DocumentID, from source: PageID, to target: PageID,
                     transform: Affine? = nil, z: String = "") throws -> Item {
        let original = try workspace.item(doc, page: source, id: id)
        var moved = transform.map { original.transformed(by: $0) } ?? original
        if source == target {
            if !z.isEmpty { moved.z = z }
            return try put(moved, doc: doc, page: target)
        }
        guard try content(doc).page(target) != nil else { throw NibError.notFound("page \(target) in document \(doc)") }
        try delete(item: id, doc: doc, page: source)
        moved.z = z
        moved.deleted = false
        func live(_ other: ElementID?) -> Bool {
            guard let other = other else { return false }
            return workspace.currentItem(other, doc: doc, page: target)?.deleted == false
        }
        if moved.attachedTo != nil && !live(moved.attachedTo) { moved.attachedTo = nil }
        if var c = moved.connector {
            if c.from.item != nil && !live(c.from.item) { c.from = ConnectorEnd(point: c.from.point) }
            if c.to.item != nil && !live(c.to.item) { c.to = ConnectorEnd(point: c.to.point) }
            moved.connector = c
        }
        return try putItem(moved, doc: doc, page: target, inherited: .some(original.createdBy))
    }

    /// contracts-v2: inserts or replaces many items on one page in one pass (O(n) lookups, one sort), with the same
    /// rules as `put(_:doc:page:)` applied to each in order (z, provenance, validation). For page-wide edits (erase,
    /// clear, import, paste, board templates) near `NibLimits.boardItemLimit`, where per-item puts are quadratic.
    @discardableResult
    public func put(_ items: [Item], doc: DocumentID, page: PageID) throws -> [Item] {
        guard !items.isEmpty else { return [] }
        guard try content(doc).page(page) != nil else { throw NibError.notFound("page \(page) in document \(doc)") }
        let current = try workspace.allItems(doc, page: page)
        var byID: [ElementID: Item] = [:]
        for it in current { byID[it.id] = it }
        let valid = try items.map { try checked($0) }
        // Items that get a fresh z on top: empty z, first occurrence, and not already on the page with a z. Each run of
        // them takes balanced keys (short, see FractionalIndex.balanced) after the top at the run's start.
        var seen = Set<ElementID>()
        let fresh = valid.map { it -> Bool in
            let first = seen.insert(it.id).inserted
            return it.z.isEmpty && first && (byID[it.id]?.z ?? "").isEmpty
        }
        var top = current.last?.z
        var runKeys: ArraySlice<String> = []
        var prepared: [Item] = []
        prepared.reserveCapacity(items.count)
        for i in valid.indices {
            var it = valid[i]
            let existing = byID[it.id]
            if it.z.isEmpty {
                if fresh[i] {
                    if runKeys.isEmpty {
                        var j = i
                        while j < fresh.count, fresh[j] { j += 1 }
                        runKeys = FractionalIndex.balanced(count: j - i, after: top)[...]
                    }
                    it.z = runKeys.removeFirst()
                } else if let z = existing?.z, !z.isEmpty {
                    it.z = z
                } else {
                    it.z = FractionalIndex.between(top, nil)
                }
            }
            if top.map({ it.z > $0 }) ?? true { top = it.z }
            stampProvenance(&it, existing: existing, inherited: nil)
            it.rev = workspace.clock.tick()
            byID[it.id] = it
            prepared.append(it)
        }
        let befores = try workspace.writeItems(prepared, doc: doc, page: page)
        for (b, a) in zip(befores, prepared) { mutations.append(.item(doc, page, before: b, after: a)) }
        return prepared
    }

    /// contracts-v2: tombstones many live items of one page in one pass (duplicates ignored). Throws `not_found`, and
    /// writes nothing, when an id is not a live item of the page.
    public func delete(items ids: [ElementID], doc: DocumentID, page: PageID) throws {
        var byID: [ElementID: Item] = [:]
        for it in try workspace.allItems(doc, page: page) { byID[it.id] = it }
        var seen = Set<ElementID>()
        var tombstones: [Item] = []
        for id in ids where seen.insert(id).inserted {
            guard var it = byID[id], !it.deleted else { throw NibError.notFound("item \(id) on page \(page)") }
            it.deleted = true
            tombstones.append(it)
        }
        try put(tombstones, doc: doc, page: page)
    }

    private func checked(_ item: Item) throws -> Item {
        guard item.isValid else {
            throw NibError(.invariantViolation, "item \(item.id) must carry exactly the '\(item.kind.rawValue)' payload")
        }
        guard (0..<NibLimits.layerCount).contains(item.layer) else {
            throw NibError.invalid("layer must be 0...\(NibLimits.layerCount - 1)")
        }
        return item
    }

    /// Provenance cannot be forged: non-user principals always stamp themselves on create and never change it;
    /// `inherited` (a stored record's `createdBy`, for moves) wins over both.
    private func stampProvenance(_ it: inout Item, existing: Item?, inherited: String??) {
        if let kept = inherited {
            it.createdBy = kept
        } else if let existing = existing {
            if !principal.isUser { it.createdBy = existing.createdBy }
        } else if !principal.isUser || it.createdBy == nil {
            it.createdBy = principal.description
        }
    }

    private func putItem(_ item: Item, doc: DocumentID, page: PageID, inherited: String??) throws -> Item {
        var it = try checked(item)
        guard try content(doc).page(page) != nil else { throw NibError.notFound("page \(page) in document \(doc)") }
        let existing = workspace.currentItem(it.id, doc: doc, page: page)
        if it.z.isEmpty {
            if let z = existing?.z, !z.isEmpty { it.z = z } else { it.z = try topZ(doc, page: page) }
        }
        stampProvenance(&it, existing: existing, inherited: inherited)
        it.rev = workspace.clock.tick()
        let before = try workspace.writeItem(it, doc: doc, page: page)
        mutations.append(.item(doc, page, before: before, after: it))
        return it
    }

    /// Tombstones an item.
    public func delete(item id: ElementID, doc: DocumentID, page: PageID) throws {
        var it = try workspace.item(doc, page: page, id: id)
        it.deleted = true
        try put(it, doc: doc, page: page)
    }

    /// Inserts or replaces a page record. Empty `order` = append at the end.
    @discardableResult
    public func put(_ page: PageRecord, doc: DocumentID) throws -> PageRecord {
        var p = page
        if let s = p.size, !(1.0...100_000.0).contains(s.width) || !(1.0...100_000.0).contains(s.height) {
            throw NibError.invalid("page size out of range")
        }
        guard [0, 90, 180, 270].contains(p.rotation) else { throw NibError.invalid("rotation must be 0, 90, 180 or 270") }
        if p.order.isEmpty {
            let last = try content(doc).livePages.last?.order
            p.order = FractionalIndex.between(last, nil)
        }
        return try putRecord(p, doc: doc, at: \.pages) { .page(doc, before: $0, after: $1) }
    }

    public func putMeta(_ meta: DocumentMeta) throws {
        var m = meta
        m.rev = workspace.clock.tick()
        let before = try workspace.writeMeta(m)
        mutations.append(.meta(m.id, before: before, after: m))
    }

    @discardableResult
    public func put(_ block: TextBlock, doc: DocumentID) throws -> TextBlock {
        var b = block
        if b.order.isEmpty {
            let last = try content(doc).liveBlocks.last?.order
            b.order = FractionalIndex.between(last, nil)
        }
        return try putRecord(b, doc: doc, at: \.blocks) { .block(doc, before: $0, after: $1) }
    }

    @discardableResult
    public func put(_ card: StudyCard, doc: DocumentID) throws -> StudyCard {
        var c = card
        if c.order.isEmpty {
            let last = try content(doc).liveCards.last?.order
            c.order = FractionalIndex.between(last, nil)
        }
        return try putRecord(c, doc: doc, at: \.cards) { .card(doc, before: $0, after: $1) }
    }

    /// contracts-v2: inserts or replaces many blocks in one pass (empty `order` = appended in array order).
    @discardableResult
    public func put(_ blocks: [TextBlock], doc: DocumentID) throws -> [TextBlock] {
        try putOrdered(blocks, doc: doc, at: \.blocks, last: try content(doc).liveBlocks.last?.order) {
            .block(doc, before: $0, after: $1)
        }
    }

    /// contracts-v2: inserts or replaces many cards in one pass (empty `order` = appended in array order), so an
    /// importer appending thousands of cards to a set is linear, not quadratic.
    @discardableResult
    public func put(_ cards: [StudyCard], doc: DocumentID) throws -> [StudyCard] {
        try putOrdered(cards, doc: doc, at: \.cards, last: try content(doc).liveCards.last?.order) {
            .card(doc, before: $0, after: $1)
        }
    }

    /// contracts-v2: inserts or replaces many pages in one pass (empty `order` = appended in array order). Every page is
    /// validated first; nothing is written when one is invalid.
    @discardableResult
    public func put(_ pages: [PageRecord], doc: DocumentID) throws -> [PageRecord] {
        for p in pages {
            if let s = p.size, !(1.0...100_000.0).contains(s.width) || !(1.0...100_000.0).contains(s.height) {
                throw NibError.invalid("page size out of range")
            }
            guard [0, 90, 180, 270].contains(p.rotation) else { throw NibError.invalid("rotation must be 0, 90, 180 or 270") }
        }
        return try putOrdered(pages, doc: doc, at: \.pages, last: try content(doc).livePages.last?.order) {
            .page(doc, before: $0, after: $1)
        }
    }

    /// contracts-v2: inserts or replaces many outline entries in one pass (empty `order` = appended in array order).
    @discardableResult
    public func put(_ entries: [OutlineEntry], doc: DocumentID) throws -> [OutlineEntry] {
        try putOrdered(entries, doc: doc, at: \.outline, last: try content(doc).liveOutline.last?.order) {
            .outline(doc, before: $0, after: $1)
        }
    }

    /// contracts-v2: inserts or replaces many audio clips in one pass.
    @discardableResult
    public func put(_ clips: [AudioClip], doc: DocumentID) throws -> [AudioClip] {
        guard !clips.isEmpty else { return [] }
        var prepared = clips
        for i in prepared.indices { prepared[i].rev = workspace.clock.tick() }
        let befores = try workspace.writeRecords(prepared, doc: doc, at: \.audio)
        for (b, a) in zip(befores, prepared) { mutations.append(.audio(doc, before: b, after: a)) }
        return prepared
    }

    @discardableResult
    public func put(_ clip: AudioClip, doc: DocumentID) throws -> AudioClip {
        try putRecord(clip, doc: doc, at: \.audio) { .audio(doc, before: $0, after: $1) }
    }

    @discardableResult
    public func put(_ entry: OutlineEntry, doc: DocumentID) throws -> OutlineEntry {
        var e = entry
        if e.order.isEmpty {
            let last = try content(doc).liveOutline.last?.order
            e.order = FractionalIndex.between(last, nil)
        }
        return try putRecord(e, doc: doc, at: \.outline) { .outline(doc, before: $0, after: $1) }
    }

    private func putOrdered<T: OrderedRecord>(_ records: [T], doc: DocumentID, at path: WritableKeyPath<DocumentContent, [T]>,
                                              last: String?, wrap: (T?, T) -> Mutation) throws -> [T] {
        guard !records.isEmpty else { return [] }
        var top = last
        var runKeys: ArraySlice<String> = []
        var prepared: [T] = []
        prepared.reserveCapacity(records.count)
        for i in records.indices {
            var r = records[i]
            if r.order.isEmpty {
                // Each run of records without an order takes balanced keys after the top at the run's start.
                if runKeys.isEmpty {
                    var j = i
                    while j < records.count, records[j].order.isEmpty { j += 1 }
                    runKeys = FractionalIndex.balanced(count: j - i, after: top)[...]
                }
                r.order = runKeys.removeFirst()
            }
            if top.map({ r.order > $0 }) ?? true { top = r.order }
            r.rev = workspace.clock.tick()
            prepared.append(r)
        }
        let befores = try workspace.writeRecords(prepared, doc: doc, at: path)
        for (b, a) in zip(befores, prepared) { mutations.append(wrap(b, a)) }
        return prepared
    }

    private func putRecord<T: LWWRecord>(_ record: T, doc: DocumentID, at path: WritableKeyPath<DocumentContent, [T]>,
                                         wrap: (T?, T) -> Mutation) throws -> T {
        var r = record
        r.rev = workspace.clock.tick()
        let before = try workspace.writeRecord(r, doc: doc, at: path)
        mutations.append(wrap(before, r))
        return r
    }

    // MARK: Commit support (bus only)

    /// Referential invariants checked before commit.
    func validate() throws {
        for m in mutations {
            guard case let .item(doc, page, _, after) = m, !after.deleted else { continue }
            if let parent = after.attachedTo, workspace.currentItem(parent, doc: doc, page: page)?.deleted != false {
                throw NibError(.invariantViolation, "item \(after.id) is attached to missing item \(parent)")
            }
            if let c = after.connector {
                for end in [c.from, c.to] {
                    if let target = end.item, workspace.currentItem(target, doc: doc, page: page)?.deleted != false {
                        throw NibError(.invariantViolation, "connector \(after.id) points at missing item \(target)")
                    }
                }
            }
        }
    }

    /// Restores every record to its exact previous value (revisions included).
    /// contracts-v2: consecutive record writes of one kind are restored in one pass (a failed 10,000-card import rolls
    /// back in linear time).
    func rollback() {
        let ordered = Array(mutations.reversed())
        var i = 0
        while i < ordered.count {
            let m = ordered[i]
            switch m {
            case let .item(d, p, b, a):
                if let b = b { _ = try? workspace.writeItem(b, doc: d, page: p) } else { workspace.removeItem(a.id, doc: d, page: p) }
                i += 1
            case let .meta(_, b, _):
                _ = try? workspace.writeMeta(b)
                i += 1
            case let .page(d, _, _):
                let j = runEnd(ordered, from: i)
                restoreRun(ordered[i..<j], d, \DocumentContent.pages) { if case let .page(_, b, a) = $0 { return (b, a) }; return nil }
                i = j
            case let .block(d, _, _):
                let j = runEnd(ordered, from: i)
                restoreRun(ordered[i..<j], d, \DocumentContent.blocks) { if case let .block(_, b, a) = $0 { return (b, a) }; return nil }
                i = j
            case let .card(d, _, _):
                let j = runEnd(ordered, from: i)
                restoreRun(ordered[i..<j], d, \DocumentContent.cards) { if case let .card(_, b, a) = $0 { return (b, a) }; return nil }
                i = j
            case let .audio(d, _, _):
                let j = runEnd(ordered, from: i)
                restoreRun(ordered[i..<j], d, \DocumentContent.audio) { if case let .audio(_, b, a) = $0 { return (b, a) }; return nil }
                i = j
            case let .outline(d, _, _):
                let j = runEnd(ordered, from: i)
                restoreRun(ordered[i..<j], d, \DocumentContent.outline) { if case let .outline(_, b, a) = $0 { return (b, a) }; return nil }
                i = j
            }
        }
        mutations.removeAll()
    }

    /// End (exclusive) of the run of mutations starting at `start` that write the same record kind of the same document.
    private func runEnd(_ muts: [Mutation], from start: Int) -> Int {
        let first = muts[start].recordKey
        var j = start + 1
        while j < muts.count {
            let k = muts[j].recordKey
            guard k.kind == first.kind, k.doc == first.doc else { break }
            j += 1
        }
        return j
    }

    /// Rollback of one run (newest first): each record ends at the `before` of its OLDEST write in the run.
    private func restoreRun<T: LWWRecord>(_ run: ArraySlice<Mutation>, _ doc: DocumentID,
                                          _ path: WritableKeyPath<DocumentContent, [T]>,
                                          _ unwrap: (Mutation) -> (T?, T)?) {
        var finals: [NibID: T?] = [:]
        var order: [NibID] = []
        for m in run {
            guard let write = unwrap(m) else { continue }
            if finals.updateValue(write.0, forKey: write.1.id) == nil { order.append(write.1.id) }
        }
        workspace.restoreRecords(finals, order: order, doc: doc, at: path)
    }

    /// Revisions this transaction's reverts re-stamped (see `RevRebase`); the bus applies them to the undo history.
    private(set) var rebase = RevRebase()

    /// Undo/redo/revert: writes each mutation's `before` (or a tombstone when it was an insert) with a fresh
    /// revision — but only where the record still carries the reverted revision, so later edits by other
    /// devices or collaborators are never overwritten. Returns the number of skipped records.
    ///
    /// contracts-v2 fix: a record written several times in one undo group (drag then attach, debounced text commits)
    /// is reverted all the way back. Reverting the newest write re-stamps the record, and the older write of the same
    /// record now accepts that fresh revision (`RevRebase`), instead of looking changed-since and being skipped.
    /// contracts-v2: consecutive record writes of one kind (a batch `put(_ cards:)`) are reverted in one pass, so
    /// undoing a large import is linear.
    func revert(_ muts: [Mutation]) -> Int {
        var skipped = 0
        let ordered = Array(muts.reversed())
        var i = 0
        while i < ordered.count {
            let m = ordered[i]
            let key = m.recordKey
            let expected = rebase.current(key, m.afterRev)
            switch m {
            case let .item(d, p, b, a):
                i += 1
                guard let cur = workspace.currentItem(a.id, doc: d, page: p), cur.rev == expected else {
                    skipped += 1
                    continue
                }
                var target = b ?? a
                if b == nil { target.deleted = true }
                target.rev = workspace.clock.tick()
                _ = try? workspace.writeItem(target, doc: d, page: p)
                mutations.append(.item(d, p, before: cur, after: target))
                if let b = b { rebase.record(key, old: b.rev, new: target.rev) }
            case let .meta(d, b, _):
                i += 1
                guard let cur = try? workspace.content(d).meta, cur.rev == expected else {
                    skipped += 1
                    continue
                }
                var target = b
                target.rev = workspace.clock.tick()
                _ = try? workspace.writeMeta(target)
                mutations.append(.meta(d, before: cur, after: target))
                rebase.record(key, old: b.rev, new: target.rev)
            case let .page(d, _, _):
                let j = runEnd(ordered, from: i)
                skipped += revertRun(ordered[i..<j], d, \DocumentContent.pages, { if case let .page(_, b, a) = $0 { return (b, a) }; return nil },
                                     { .page(d, before: $0, after: $1) })
                i = j
            case let .block(d, _, _):
                let j = runEnd(ordered, from: i)
                skipped += revertRun(ordered[i..<j], d, \DocumentContent.blocks, { if case let .block(_, b, a) = $0 { return (b, a) }; return nil },
                                     { .block(d, before: $0, after: $1) })
                i = j
            case let .card(d, _, _):
                let j = runEnd(ordered, from: i)
                skipped += revertRun(ordered[i..<j], d, \DocumentContent.cards, { if case let .card(_, b, a) = $0 { return (b, a) }; return nil },
                                     { .card(d, before: $0, after: $1) })
                i = j
            case let .audio(d, _, _):
                let j = runEnd(ordered, from: i)
                skipped += revertRun(ordered[i..<j], d, \DocumentContent.audio, { if case let .audio(_, b, a) = $0 { return (b, a) }; return nil },
                                     { .audio(d, before: $0, after: $1) })
                i = j
            case let .outline(d, _, _):
                let j = runEnd(ordered, from: i)
                skipped += revertRun(ordered[i..<j], d, \DocumentContent.outline, { if case let .outline(_, b, a) = $0 { return (b, a) }; return nil },
                                     { .outline(d, before: $0, after: $1) })
                i = j
            }
        }
        return skipped
    }

    /// Reverts one run (newest first) of record writes of one kind and document: current values are looked up once,
    /// the run is checked in order exactly like single reverts (so double writes rebase), then written in one pass.
    private func revertRun<T: LWWRecord>(_ run: ArraySlice<Mutation>, _ doc: DocumentID,
                                         _ path: WritableKeyPath<DocumentContent, [T]>,
                                         _ unwrap: (Mutation) -> (T?, T)?, _ wrap: (T?, T) -> Mutation) -> Int {
        var current: [NibID: T] = [:]
        if let list = try? workspace.content(doc)[keyPath: path] {
            var wanted = Set<NibID>()
            for m in run { if let write = unwrap(m) { wanted.insert(write.1.id) } }
            for r in list where wanted.contains(r.id) && current[r.id] == nil { current[r.id] = r }
        }
        var skipped = 0
        var targets: [T] = []
        for m in run {
            guard let write = unwrap(m) else { continue }
            let (before, after) = write
            let key = m.recordKey
            guard let cur = current[after.id], cur.rev == rebase.current(key, m.afterRev) else {
                skipped += 1
                continue
            }
            var target = before ?? after
            if before == nil { target.deleted = true }
            target.rev = workspace.clock.tick()
            current[after.id] = target
            targets.append(target)
            mutations.append(wrap(cur, target))
            if let b = before { rebase.record(key, old: b.rev, new: target.rev) }
        }
        if !targets.isEmpty { _ = try? workspace.writeRecords(targets, doc: doc, at: path) }
        return skipped
    }
}

/// Records kept in a fractional `order` key (batch puts append in array order).
protocol OrderedRecord: LWWRecord {
    var order: String { get set }
}

extension TextBlock: OrderedRecord {}
extension StudyCard: OrderedRecord {}
extension PageRecord: OrderedRecord {}
extension OutlineEntry: OrderedRecord {}
```

### `NibKit/Sources/NibContracts/Core/Undo.swift`

```swift
import Foundation

public struct UndoEntry {
    public let group: String
    public var label: String
    public let principal: Principal
    public var mutations: [Mutation]
    public let at: Date
    /// contracts-v2: the group's entries in OTHER documents undo and redo together with this one
    /// (`CommandContext.linkUndoAcrossDocuments()`, e.g. a page moved between two documents).
    public var linked: Bool = false

    public init(group: String, label: String, principal: Principal, mutations: [Mutation], at: Date = Date()) {
        self.group = group
        self.label = label
        self.principal = principal
        self.mutations = mutations
        self.at = at
    }
}

/// Per-document undo/redo stacks. Consecutive commits with the same group merge into one entry
/// (one pen stroke, one eraser gesture, one plugin call, one AI turn). Lives from open to app quit.
@MainActor
public final class UndoHistory {
    public var limit = NibLimits.undoDepth
    private var undoStacks: [DocumentID: [UndoEntry]] = [:]
    private var redoStacks: [DocumentID: [UndoEntry]] = [:]
    /// Groups whose entries undo across documents together (bounded: oldest dropped first).
    private var linkedGroups: [String] = []

    public init() {}

    public func canUndo(_ doc: DocumentID) -> Bool { !(undoStacks[doc] ?? []).isEmpty }
    public func canRedo(_ doc: DocumentID) -> Bool { !(redoStacks[doc] ?? []).isEmpty }
    public func undoLabel(_ doc: DocumentID) -> String? { undoStacks[doc]?.last?.label }
    public func redoLabel(_ doc: DocumentID) -> String? { redoStacks[doc]?.last?.label }
    /// Oldest first.
    public func entries(_ doc: DocumentID) -> [UndoEntry] { undoStacks[doc] ?? [] }

    public func clear(_ doc: DocumentID) {
        undoStacks[doc] = nil
        redoStacks[doc] = nil
    }

    /// True when `group` was linked across documents (`CommandContext.linkUndoAcrossDocuments()`).
    public func isLinked(_ group: String) -> Bool { linkedGroups.contains(group) }

    func link(_ group: String) {
        guard !linkedGroups.contains(group) else { return }
        linkedGroups.append(group)
        if linkedGroups.count > 64 { linkedGroups.removeFirst(linkedGroups.count - 64) }
        for (doc, stack) in undoStacks {
            guard let top = stack.last, top.group == group else { continue }
            undoStacks[doc]?[stack.count - 1].linked = true
        }
    }

    func record(_ cs: Changeset) {
        let linked = linkedGroups.contains(cs.group)
        for doc in cs.documents {
            let muts = cs.mutations.filter { $0.document == doc }
            var stack = undoStacks[doc] ?? []
            if var top = stack.last, top.group == cs.group {
                top.mutations.append(contentsOf: muts)
                top.linked = top.linked || linked
                stack[stack.count - 1] = top
            } else {
                var entry = UndoEntry(group: cs.group, label: cs.label, principal: cs.principal, mutations: muts)
                entry.linked = linked
                stack.append(entry)
                if stack.count > limit { stack.removeFirst(stack.count - limit) }
            }
            undoStacks[doc] = stack
            redoStacks[doc] = []
        }
    }

    /// Moves stored after-revisions that an undo, redo or revert re-stamped (see `RevRebase`), in every stack.
    func rebase(_ r: RevRebase) {
        guard !r.isEmpty else { return }
        for doc in r.documents {
            if var stack = undoStacks[doc] {
                for i in stack.indices { stack[i].mutations = stack[i].mutations.map { r.apply($0) } }
                undoStacks[doc] = stack
            }
            if var stack = redoStacks[doc] {
                for i in stack.indices { stack[i].mutations = stack[i].mutations.map { r.apply($0) } }
                redoStacks[doc] = stack
            }
        }
    }

    /// Documents (other than `doc`) whose top undo (or redo) entry belongs to `group`.
    func linkedDocuments(_ group: String, except doc: DocumentID, redo: Bool) -> [DocumentID] {
        let stacks = redo ? redoStacks : undoStacks
        return stacks.compactMap { d, stack in d != doc && stack.last?.group == group ? d : nil }
            .sorted { $0.raw < $1.raw }
    }

    func popUndo(_ doc: DocumentID) -> UndoEntry? { undoStacks[doc]?.popLast() }
    func popRedo(_ doc: DocumentID) -> UndoEntry? { redoStacks[doc]?.popLast() }
    func pushUndo(_ e: UndoEntry, doc: DocumentID) { undoStacks[doc, default: []].append(e) }
    func pushRedo(_ e: UndoEntry, doc: DocumentID) { redoStacks[doc, default: []].append(e) }

    func removeEntry(group: String, doc: DocumentID) -> UndoEntry? {
        guard let i = undoStacks[doc]?.lastIndex(where: { $0.group == group }) else { return nil }
        return undoStacks[doc]?.remove(at: i)
    }
}
```

### `NibKit/Sources/NibContracts/Core/Events.swift`

```swift
import Foundation

public enum NibEventType {
    public static let committed = "tx.committed"
    public static let docOpened = "doc.opened"
    public static let docClosed = "doc.closed"
    public static let sessionDocument = "session.document"
    public static let pageChanged = "page.changed"
    public static let toolChanged = "tool.changed"
    public static let selectionChanged = "selection.changed"
    public static let libraryChanged = "library.changed"
    public static let aiTurnFinished = "ai.turn.finished"
    public static let pluginMessage = "plugin.message"
    /// Storage, folder sync or backup trouble or progress. Payload `SyncStatusPayload` (contracts-v2).
    public static let syncStatus = "sync.status"
    /// Laser pointer moved (F040 → presentation F063, collaboration F108). Payload {page, point: [x, y], mode:
    /// "dot" | "trail"}; a payload without `point` means the laser was lifted.
    public static let laserMoved = "laser.moved"
    /// Backup queue or last-run state changed (F068 → Cloud & Backup panel F070); query `backup.status` for details.
    public static let backupStatus = "backup.status"

    // contracts-v2 (payload types in EventPayloads.swift)

    /// `SessionRegistry.active` changed (a window became key). Payload {"session": id}.
    public static let sessionActivated = "session.activated"
    /// A session's `activeLayer` or `hiddenLayers` changed. Payload {"session": id}.
    public static let layersChanged = "session.layers"
    /// A tool finished one use (`EditorSession.finishToolUse`). Payload {"session": id, "tool": id}.
    public static let toolFinished = "tool.finished"
    /// Search indexing progress (NibIndex F055 → search UI F056). Payload `IndexProgressPayload`.
    public static let indexProgress = "index.progress"
    /// Audio playback position or state (F052 → Note Replay F053). Payload `AudioPlaybackPayload`.
    public static let audioPlayback = "audio.playback"
    /// Recording started, paused, resumed or stopped (F052). Payload `AudioRecordingPayload`.
    public static let audioRecording = "audio.recording"
    /// A Draw-and-Hold or Draw Shape stroke snapped to a shape (F009, F030 → Pencil Pro haptic F043). Payload
    /// `ShapeSnappedPayload`.
    public static let shapeSnapped = "shape.snapped"
    /// Any feature asks for an Apple Pencil Pro haptic (ruler snaps F039, alignment guides F012); F043 plays it with
    /// `UICanvasFeedbackGenerator`, the only module allowed to. Payload `PencilHapticPayload`.
    public static let pencilHaptic = "pencil.haptic"
    /// The element library changed (F035: collections, favourites, recents). Payload {"collection"?: id}.
    public static let elementsChanged = "elements.changed"
    /// MCP/HTTP bridge state changed (F090 → Bridge settings F091). Payload {"state": "off" | "starting" | "on" | …}.
    public static let bridgeStatus = "bridge.status"
}

/// Events carry refs, not payloads: subscribers query for details.
public struct NibEvent: Codable {
    public let seq: UInt64
    public let type: String
    /// Unix seconds.
    public let at: Double
    public let principal: Principal?
    public let doc: DocumentID?
    public let changes: ChangeSummary?
    public let payload: JSONValue?
}

public final class EventSubscription {
    private var onCancel: (() -> Void)?
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() {
        onCancel?()
        onCancel = nil
    }
}

/// App-wide event bus with a ring buffer (the MCP bridge long-polls it). Handlers run synchronously on the
/// emitting thread (normally main) — keep them cheap and hop queues for heavy work. Thread-safe.
public final class EventBus {
    public let capacity = 5_000
    private let lock = NSLock()
    private var seq: UInt64 = 0
    private var ring: [NibEvent] = []
    private var handlers: [UUID: (NibEvent) -> Void] = [:]

    public init() {}

    @discardableResult
    public func emit(_ type: String, principal: Principal? = nil, doc: DocumentID? = nil,
                     changes: ChangeSummary? = nil, payload: JSONValue? = nil) -> NibEvent {
        lock.lock()
        seq += 1
        let e = NibEvent(seq: seq, type: type, at: Date().timeIntervalSince1970, principal: principal, doc: doc,
                         changes: changes, payload: payload)
        ring.append(e)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        let hs = Array(handlers.values)
        lock.unlock()
        for h in hs { h(e) }
        return e
    }

    /// The handler lives until `cancel()` is called on the returned subscription.
    @discardableResult
    public func subscribe(_ handler: @escaping (NibEvent) -> Void) -> EventSubscription {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        return EventSubscription { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.handlers[id] = nil
            self.lock.unlock()
        }
    }

    public func stream(where filter: @escaping (NibEvent) -> Bool = { _ in true }) -> AsyncStream<NibEvent> {
        AsyncStream { continuation in
            let sub = self.subscribe { e in
                if filter(e) { continuation.yield(e) }
            }
            continuation.onTermination = { _ in sub.cancel() }
        }
    }

    public var lastSeq: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return seq
    }

    public func events(since: UInt64, limit: Int = 500) -> [NibEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(ring.filter { $0.seq > since }.prefix(limit))
    }

    /// Long-poll: returns as soon as events newer than `since` exist, or after `timeout` seconds.
    public func poll(since: UInt64, timeout: TimeInterval) async -> [NibEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let e = events(since: since)
            if !e.isEmpty || Date() >= deadline { return e }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}
```

### `NibKit/Sources/NibContracts/Core/EventPayloads.swift`

```swift
import Foundation

/// A typed event payload (contracts-v2). Emit with `events.emit(payload)`; read with `event.decode(P.self)`. Payloads
/// travel as JSON (`NibEvent.payload`), so plugins, the bridge and the AI see the same fields.
public protocol NibEventPayload: Codable {
    /// The `NibEventType` this payload belongs to.
    static var eventType: String { get }
}

public extension EventBus {
    /// Emits `payload` under its `eventType`.
    @discardableResult
    func emit<P: NibEventPayload>(_ payload: P, principal: Principal? = nil, doc: DocumentID? = nil) -> NibEvent {
        emit(P.eventType, principal: principal, doc: doc, payload: try? JSONValue.from(payload))
    }
}

public extension NibEvent {
    /// The payload as `P`, or nil when the event is of another type or its payload does not decode.
    func decode<P: NibEventPayload>(_ type: P.Type) -> P? {
        guard self.type == P.eventType, let p = payload else { return nil }
        return try? p.decode(P.self)
    }
}

/// `sync.status`: storage, folder sync (F025), backup (F068) or WebDAV (F069) state for the Cloud & Backup UI (F070).
/// `state` is "idle" | "syncing" | "ok" | "warning" | "error"; `source` names the emitter ("store", "sync", "backup",
/// "webdav"); `reason` is a stable code (store: "newerFormat", "futureRevision", "unreadable", "writeFailed",
/// "walFailed"). `NibEvent.doc` carries the document when there is one.
public struct SyncStatusPayload: NibEventPayload, Equatable {
    public static let eventType = NibEventType.syncStatus
    public var state: String
    public var source: String
    public var reason: String?
    public var message: String?
    /// Affected files (package-relative paths).
    public var files: [String]?

    public init(state: String, source: String, reason: String? = nil, message: String? = nil, files: [String]? = nil) {
        self.state = state
        self.source = source
        self.reason = reason
        self.message = message
        self.files = files
    }
}

/// `index.progress` (NibIndex F055): pages indexed so far in the current sweep.
public struct IndexProgressPayload: NibEventPayload, Equatable {
    public static let eventType = NibEventType.indexProgress
    public var running: Bool
    public var done: Int
    public var total: Int
    public var pending: Int

    public init(running: Bool, done: Int, total: Int, pending: Int? = nil) {
        self.running = running
        self.done = done
        self.total = total
        self.pending = pending ?? max(0, total - done)
    }
}

/// `laser.moved` (F040 → presentation F063, collaboration F108). `page` is a page ref, so the payload can be passed
/// straight back to `laser.point`; no `point` = the laser was lifted.
public struct LaserMovedPayload: NibEventPayload, Equatable {
    public static let eventType = NibEventType.laserMoved
    public var page: String
    public var point: Point?
    /// "dot" | "trail".
    public var mode: String
    public var color: RGBA?
    /// `EditorSession.id` of the window the laser is in.
    public var session: String?

    public init(page: String, point: Point?, mode: String, color: RGBA? = nil, session: String? = nil) {
        self.page = page
        self.point = point
        self.mode = mode
        self.color = color
        self.session = session
    }
}

/// `audio.playback` (F052 → Note Replay F053): emitted on play, pause, seek and re-plan.
public struct AudioPlaybackPayload: NibEventPayload, Equatable {
    public static let eventType = NibEventType.audioPlayback
    /// Clip ref "audio:D/A".
    public var clip: String
    /// Position in the clip (seconds).
    public var t: Double
    public var playing: Bool
    /// Playback speed (0 while paused).
    public var rate: Double
    /// Wall clock of the sample (unix seconds), to extrapolate `t` between events.
    public var at: Double

    public init(clip: String, t: Double, playing: Bool, rate: Double, at: Double = Date().timeIntervalSince1970) {
        self.clip = clip
        self.t = t
        self.playing = playing
        self.rate = rate
        self.at = at
    }
}

/// `audio.recording` (F052).
public struct AudioRecordingPayload: NibEventPayload, Equatable {
    public static let eventType = NibEventType.audioRecording
    public var clip: String
    /// "recording" | "paused" | "stopped".
    public var state: String
    /// Seconds recorded so far.
    public var duration: Double

    public init(clip: String, state: String, duration: Double) {
        self.clip = clip
        self.state = state
        self.duration = duration
    }
}

/// `shape.snapped` (F009, F030): a stroke snapped to a shape while the Pencil was down.
public struct ShapeSnappedPayload: NibEventPayload, Equatable {
    public static let eventType = NibEventType.shapeSnapped
    /// Page ref "page:D/P".
    public var page: String
    /// `ShapeKind` raw value.
    public var shape: String
    /// Where the snap happened (page points), for the haptic's location.
    public var point: Point?
    public var session: String?

    public init(page: String, shape: String, point: Point? = nil, session: String? = nil) {
        self.page = page
        self.shape = shape
        self.point = point
        self.session = session
    }
}

/// `pencil.haptic`: ask the Pencil Hardware feature (F043) for an Apple Pencil Pro haptic.
public struct PencilHapticPayload: NibEventPayload, Equatable {
    public static let eventType = NibEventType.pencilHaptic
    /// "alignment" (snapped to a guide, angle or grid) | "levelChange" | "generic".
    public var kind: String
    /// Page ref and page point of the feedback, when known.
    public var page: String?
    public var point: Point?
    public var session: String?

    public init(kind: String = "alignment", page: String? = nil, point: Point? = nil, session: String? = nil) {
        self.kind = kind
        self.page = page
        self.point = point
        self.session = session
    }
}
```

### `NibKit/Sources/NibContracts/Core/Bus.swift`

```swift
import Foundation

/// A JSON-level command call (plugins, AI, MCP bridge, key commands, menus).
public struct Invocation {
    public var command: String
    public var params: JSONValue
    public var principal: Principal
    public var session: EditorSession?
    /// Undo group; nil = a fresh group. Pass the same group to make several calls one undo step.
    public var group: String?
    /// Run, collect the change summary, then roll back. Nothing is persisted, recorded or emitted.
    public var dryRun: Bool
    public var depth: Int
    /// Ask mode: this call and everything it calls (nested commands, plugin handlers, batches) must be `read`.
    public var readOnly: Bool
    /// Confirmation policy inherited from an outer non-user caller (e.g. the AI running a plugin command whose
    /// handler calls more commands); the stricter of this and the principal's own policy applies.
    public var inheritedPolicy: ConfirmationPolicy?
    /// Set when running a command hook, so hooks never trigger hooks.
    public var skipHooks: Bool

    public init(command: String, params: JSONValue = [:], principal: Principal = .user, session: EditorSession? = nil,
                group: String? = nil, dryRun: Bool = false, depth: Int = 0, readOnly: Bool = false,
                inheritedPolicy: ConfirmationPolicy? = nil, skipHooks: Bool = false) {
        self.command = command
        self.params = params
        self.principal = principal
        self.session = session
        self.group = group
        self.dryRun = dryRun
        self.depth = depth
        self.readOnly = readOnly
        self.inheritedPolicy = inheritedPolicy
        self.skipHooks = skipHooks
    }
}

/// A before-command hook (plugins' `contributes.commandHooks`, features). The hook command must be `read`; it gets
/// {"command": id, "params": …} and returns {"params": …} to transform the call, `{}` to let it pass, or throws to
/// veto it. Registered in `app.bus.hooks`.
public struct CommandHookDescriptor: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    /// Exact command ids or namespace wildcards ("page.*").
    public var commands: [String]
    /// The hook command to run.
    public var command: String
    /// Principal the hook runs as (`.plugin(id)` for plugins).
    public var principal: Principal
    /// contracts-v2: a native hook (features only) runs this closure instead of a command: it gets the command id and
    /// params and returns replacement params, nil to let the call pass, or throws to veto it. It must not change
    /// documents. Lets a feature hook `export.run` (layers) or item-creating commands (board limit) without
    /// registering an extra command id. `command` is ignored when set.
    public var handler: (@MainActor (_ command: String, _ params: JSONValue) async throws -> JSONValue?)?
    /// contracts-v2: a native guard that also sees the call: a READ-ONLY `CommandContext` with the caller's principal,
    /// session and group (`ctx.pageOrSession(_:)` resolves session defaults, `ctx.app` / `ctx.content` reach the app;
    /// `ctx.mutate` throws). Same contract as `handler` (replacement params, nil, or throw to veto) and preferred over it.
    /// Runs for every principal and for typed `bus.run` calls. Build with `CommandHookDescriptor.guarding(...)`.
    public var contextHandler: (@MainActor (_ command: String, _ params: JSONValue, _ ctx: CommandContext) async throws -> JSONValue?)?

    /// contracts-v2: a native guard hook with the call's context (see `contextHandler`), e.g. a board item limit that
    /// vetoes item-creating commands from any principal.
    public static func guarding(id: String, owner: String, commands: [String], order: Int = 0,
                                _ body: @escaping @MainActor (_ command: String, _ params: JSONValue, _ ctx: CommandContext) async throws -> JSONValue?)
        -> CommandHookDescriptor {
        var d = CommandHookDescriptor(id: id, owner: owner, commands: commands, command: "", order: order)
        d.contextHandler = body
        return d
    }

    public init(id: String, owner: String, commands: [String], command: String, principal: Principal = .user, order: Int = 0) {
        self.id = id
        self.order = order
        self.owner = owner
        self.commands = commands
        self.command = command
        self.principal = principal
        self.handler = nil
    }

    /// contracts-v2: a native closure hook (see `handler`).
    public init(id: String, owner: String, commands: [String], order: Int = 0,
                handler: @escaping @MainActor (_ command: String, _ params: JSONValue) async throws -> JSONValue?) {
        self.id = id
        self.order = order
        self.owner = owner
        self.commands = commands
        self.command = ""
        self.principal = .user
        self.handler = handler
    }

    public func matches(_ commandID: String) -> Bool {
        commands.contains { $0 == commandID || ($0.hasSuffix(".*") && commandID.hasPrefix(String($0.dropLast(1)))) }
    }
}

public struct InvocationResult: Codable {
    public var value: JSONValue
    public var changes: ChangeSummary
    public var group: String

    public init(value: JSONValue, changes: ChangeSummary, group: String) {
        self.value = value
        self.changes = changes
        self.group = group
    }
}

/// Handed to every command run. The only source of `DocTransaction`s.
@MainActor
public final class CommandContext {
    public let bus: CommandBus
    public let principal: Principal
    public let group: String
    public let depth: Int
    public let dryRun: Bool
    /// The invoking window's session (nil for bridge/background callers; see `activeSession`).
    public let session: EditorSession?
    public let commandID: String
    public let title: String
    /// True in ask mode and inside `read` commands (unless the descriptor `forwardsCalls`): nested calls must be
    /// `read` and `mutate` throws `permission_denied`. Plugin runtimes copy it into the Invocations they build.
    public let readOnly: Bool
    /// Passed on to nested calls (see `Invocation.inheritedPolicy`).
    public let inheritedPolicy: ConfirmationPolicy?
    public private(set) var summary = ChangeSummary()

    init(bus: CommandBus, principal: Principal, group: String, depth: Int, dryRun: Bool, session: EditorSession?,
         commandID: String, title: String, readOnly: Bool = false, inheritedPolicy: ConfirmationPolicy? = nil) {
        self.bus = bus
        self.principal = principal
        self.group = group
        self.depth = depth
        self.dryRun = dryRun
        self.session = session
        self.commandID = commandID
        self.title = title
        self.readOnly = readOnly
        self.inheritedPolicy = inheritedPolicy
    }

    public var workspace: Workspace { bus.workspace }
    public var services: NibServices { bus.services }
    public var events: EventBus { bus.events }
    /// The invoking session, else the most recently active window's session.
    public var activeSession: EditorSession? { session ?? bus.services.sessions.active }

    // MARK: contracts-v2: typed access to the app

    /// The app this command runs in (nil only for a `CommandBus` built outside `NibApp`). Prefer the typed accessors
    /// below; never reach `NibApp.shared` from a command.
    public var app: NibApp? { bus.app }
    /// Non-UI registries: templates, drawers, importers, exporters, tape patterns, custom item types, key commands…
    public var content: ContentRegistries { bus.content }
    /// UI registries (toolbar, menus, panels, chrome overlays, canvas tools…); nil without an app.
    public var ui: UIRegistries? { bus.app?.ui }
    /// Navigator of the most recently active window (open tabs, show library, present modals); nil when headless.
    public var navigator: SceneNavigator? { bus.app?.ui.activeNavigator }

    /// True when the document must not be written: persistence refuses it (`DocumentPersistence.isReadOnly`, e.g. saved
    /// by a newer Nib) or it is listed in the legacy `ServiceKeys.storeReadOnly` set.
    public func isReadOnly(_ doc: DocumentID) -> Bool {
        if workspace.isReadOnly(doc) { return true }
        return services.get(ServiceKeys.storeReadOnly, as: NSSet.self)?.contains(doc.raw) ?? false
    }

    /// Makes this command's undo group ONE step across documents: undoing (or redoing) it in any of the documents it
    /// changed also undoes it in the others, as long as it is still their latest step (`page.moveTo` between
    /// documents, an AI turn that edits two notebooks).
    public func linkUndoAcrossDocuments() {
        bus.history.link(group)
    }

    // MARK: contracts-v2: session defaults (§6.1)

    /// `ref` as a document id; when it is nil or empty, the invoking session's document (key commands, toolbar
    /// buttons and menus run with static params). Throws `invalid_params` with a hint when neither exists.
    public func documentOrSession(_ ref: String?, field: String = "doc") throws -> DocumentID {
        if let r = ref, !r.isEmpty { return NodeRef.documentID(from: r) }
        guard let doc = activeSession?.document else {
            throw NibError.invalid("missing '\(field)' and no document is open", path: "$." + field)
        }
        return doc
    }

    /// `ref` as a page ("page:D/P"); when it is nil or empty, the invoking session's current page.
    public func pageOrSession(_ ref: String?, field: String = "page") throws -> (doc: DocumentID, page: PageID) {
        if let r = ref, !r.isEmpty {
            guard case let .page(d, p)? = NodeRef(r) else {
                throw NibError.invalid("'\(field)' must be a page ref like page:D/P", path: "$." + field)
            }
            return (d, p)
        }
        guard let s = activeSession, let d = s.document, let p = s.page else {
            throw NibError.invalid("missing '\(field)' and no page is open", path: "$." + field)
        }
        return (d, p)
    }

    /// `refs` when given and non-empty, else the invoking session's selection refs ([] when nothing is selected).
    public func refsOrSelection(_ refs: [String]?) -> [String] {
        if let r = refs, !r.isEmpty { return r }
        return activeSession?.selection.refs ?? []
    }

    /// Runs synchronous writes atomically. Throwing (or an invariant failure) rolls everything back.
    /// All `mutate` calls in one command (and nested commands) share the undo group.
    /// `undoable: false` = persisted but not undoable (tape reveal, study grading, per-document view state).
    @discardableResult
    public func mutate<T>(_ label: String? = nil, undoable: Bool = true, _ body: (DocTransaction) throws -> T) throws -> T {
        if readOnly {
            throw NibError(.permissionDenied, "'\(commandID)' runs read-only and cannot change documents",
                           hint: "switch to Edit mode (AI), or declare the command with a mutating effect")
        }
        let tx = DocTransaction(workspace: bus.workspace, principal: principal, group: group)
        let result: T
        do {
            result = try body(tx)
            try tx.validate()
        } catch {
            tx.rollback()
            throw error
        }
        if dryRun {
            summary.merge(Changeset.summarize(tx.mutations))
            tx.rollback()
        } else if !tx.mutations.isEmpty {
            let cs = bus.commit(tx, label: label ?? title, command: commandID, record: undoable)
            summary.merge(cs.summary)
        }
        return result
    }

    /// Calls another command as the same principal, in the same undo group, inheriting read-only mode and the
    /// confirmation policy. Permission checks apply. An unknown nested command throws `unavailable`.
    public func execute(_ command: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        let inv = Invocation(command: command, params: params, principal: principal, session: session,
                             group: group, dryRun: dryRun, depth: depth + 1, readOnly: readOnly,
                             inheritedPolicy: inheritedPolicy)
        let r = try await bus.execute(inv)
        summary.merge(r.changes)
        return r.value
    }

    /// Typed nested call (goes through the registry like any other call).
    public func execute<C: NibCommand>(_ type: C.Type, _ params: C.Params) async throws -> C.Output {
        let json = try JSONValue.from(params)
        let value = try await execute(C.descriptor.id, json)
        return try CommandRegistry.decode(C.Output.self, from: value)
    }

    /// Resolves a url-typed parameter to a local file this command may read. Accepted:
    /// "tmp:<name>" (from `asset.upload`, renders, exports), "https://…" (downloaded to a temp file), and
    /// "file://…" only for the user principal or inside this app's tmp / Documents/Inbox folders — so the AI,
    /// plugins and the bridge can never read arbitrary sandbox paths (e.g. a locked document's package).
    ///
    /// contracts-v2 (security fix): downloads by non-user principals need `https`, the `network` scope, and — for plugins
    /// whose manifest is known — a host listed in `network.hosts`; plain `http` is user-only. Every download is capped
    /// at `NibLimits.maxDownloadBytes` and lands as `<tmp>/nib-downloads/<UUID>/<original file name>`, so importers can
    /// title documents from `lastPathComponent`. `tmp:` names must be plain file names.
    public func inputFile(_ string: String) async throws -> URL {
        let fm = FileManager.default
        if string.hasPrefix("tmp:") {
            let name = String(string.dropFirst(4))
            guard CommandContext.isPlainFileName(name) else {
                throw NibError(.invalidParams, "invalid temporary asset name '\(name)'",
                               hint: "pass the tmp: ref exactly as asset.upload returned it")
            }
            guard let url = services.assets?.temporaryURL(AssetRef(name)) else {
                throw NibError.notFound("temporary asset \(string)")
            }
            return url
        }
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else {
            throw NibError.invalid("not a URL: \(string)")
        }
        switch scheme {
        case "https", "http":
            try authorizeDownload(url, scheme: scheme)
            return try await CommandContext.download(url)
        case "file":
            if principal.isUser { return url }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let allowed = [fm.temporaryDirectory,
                           fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Inbox")]
                .map { $0.resolvingSymlinksInPath().path + "/" }
            guard allowed.contains(where: { path.hasPrefix($0) }) else {
                throw NibError(.permissionDenied, "file URLs are only accepted from the user",
                               hint: "upload the bytes with asset.upload and pass the returned tmp: ref")
            }
            return url
        default:
            throw NibError.invalid("unsupported URL '\(string)'; use a tmp: ref from asset.upload or an https URL")
        }
    }

    /// Who may download what (see `inputFile`).
    func authorizeDownload(_ url: URL, scheme: String) throws {
        if principal.isUser { return }
        guard scheme == "https" else {
            throw NibError(.permissionDenied, "only https URLs are accepted from \(principal)",
                           hint: "use an https URL, or upload the bytes with asset.upload and pass the tmp: ref")
        }
        guard bus.gateway.grants(principal).contains(.network) else {
            throw NibError(.permissionDenied, "downloading \(url.host ?? "a URL") needs the 'network' permission",
                           hint: "upload the bytes with asset.upload and pass the tmp: ref")
        }
        if case let .plugin(id) = principal,
           let manifest = services.get(ServiceKeys.pluginHost, as: PluginHosting.self)?.handle(id)?.manifest {
            let host = (url.host ?? "").lowercased()
            let hosts = (manifest.network?.hosts ?? []).map { $0.lowercased() }
            guard hosts.contains(host) else {
                throw NibError(.permissionDenied, "'\(host)' is not in the plugin's network.hosts",
                               hint: "add the host to manifest network.hosts")
            }
        }
    }

    static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 255 && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
            && !name.contains("\0")
    }

    /// Downloads `url` (60 s timeout, `NibLimits.maxDownloadBytes` cap) into a fresh temporary folder, keeping its name.
    static func download(_ url: URL) async throws -> URL {
        let fm = FileManager.default
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (tmp, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? fm.removeItem(at: tmp)
            throw NibError(.unavailable, "download failed: \(url.absoluteString)")
        }
        let limit = Int64(NibLimits.maxDownloadBytes)
        let size = ((try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard response.expectedContentLength <= limit, size <= limit else {
            try? fm.removeItem(at: tmp)
            throw NibError(.invalidParams, "the file at \(url.absoluteString) is larger than \(limit / 1_048_576) MB")
        }
        let folder = fm.temporaryDirectory.appendingPathComponent("nib-downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = url.lastPathComponent
        let dest = folder.appendingPathComponent(isPlainFileName(name) ? name : "download")
        try fm.moveItem(at: tmp, to: dest)
        return dest
    }
}

/// Executes commands, commits transactions, drives undo/redo and merges remote changes.
@MainActor
public final class CommandBus {
    public let registry: CommandRegistry
    public let workspace: Workspace
    public let gateway: Gateway
    public let services: NibServices
    public let events: EventBus
    public let history: UndoHistory
    /// Before-command hooks (plugins' `contributes.commandHooks`, features). Run for every JSON and typed call.
    public let hooks = Registry<CommandHookDescriptor>()
    /// contracts-v2: the owning app (set by `NibApp.init`; `CommandContext.app`).
    public internal(set) weak var app: NibApp?
    /// contracts-v2: the app's non-UI registries (`CommandContext.content`); an empty set for a bare bus.
    public internal(set) var content = ContentRegistries()
    private var seq: UInt64 = 0
    private var observers: [UUID: (Changeset) -> Void] = [:]

    public init(registry: CommandRegistry, workspace: Workspace, gateway: Gateway, services: NibServices, events: EventBus) {
        self.registry = registry
        self.workspace = workspace
        self.gateway = gateway
        self.services = services
        self.events = events
        self.history = UndoHistory()
    }

    // MARK: Execution

    /// Typed fast path for native UI code (no JSON). Non-user principals are still authorized. Commands with
    /// registered hooks go through the JSON path so hooks see (and may transform) the call.
    @discardableResult
    public func run<C: NibCommand>(_ type: C.Type, _ params: C.Params, principal: Principal = .user,
                                   session: EditorSession? = nil, group: String? = nil) async throws -> C.Output {
        let d = C.descriptor
        let g = group ?? NibID.make().raw
        if hooks.all.contains(where: { $0.matches(d.id) }) {
            let r = try await execute(Invocation(command: d.id, params: try JSONValue.from(params), principal: principal,
                                                 session: session, group: g))
            return try CommandRegistry.decode(C.Output.self, from: r.value)
        }
        if !principal.isUser {
            let json = try JSONValue.from(params)
            try await gateway.authorize(d, params: json, principal: principal, group: g)
        }
        let ctx = CommandContext(bus: self, principal: principal, group: g, depth: 0, dryRun: false,
                                 session: session, commandID: d.id, title: d.title,
                                 readOnly: d.effect == .read && !d.forwardsCalls,
                                 inheritedPolicy: principal.isUser ? nil : gateway.policy(principal))
        return try await C.run(params, ctx)
    }

    /// JSON path used by plugins, AI, the bridge, menus and key commands.
    public func execute(_ inv: Invocation) async throws -> InvocationResult {
        guard inv.depth <= NibLimits.maxNesting else {
            throw NibError.invalid("command nesting deeper than \(NibLimits.maxNesting)")
        }
        guard let entry = registry.entry(inv.command) else {
            if inv.depth > 0 {
                // Nested call into a feature that is disabled or still a stub (fan-out): an optional dependency.
                throw NibError(.unavailable, "command '\(inv.command)' is not installed",
                               hint: "the feature that provides it is disabled or not built yet")
            }
            throw NibError(.notFound, "unknown command '\(inv.command)'", hint: "call commands.list to see available commands")
        }
        let d = entry.descriptor
        if inv.readOnly && d.effect != .read {
            throw NibError(.permissionDenied, "'\(d.id)' changes content but this call is read-only",
                           hint: "ask mode and read commands can only run read commands; switch to Edit mode")
        }
        var params: JSONValue = inv.params == .null ? [:] : inv.params
        let group = inv.group ?? NibID.make().raw
        if !inv.skipHooks {
            for hook in hooks.all where hook.matches(d.id) {
                if let guardBody = hook.contextHandler {
                    let hookContext = CommandContext(bus: self, principal: inv.principal, group: group, depth: inv.depth,
                                                     dryRun: inv.dryRun, session: inv.session, commandID: d.id,
                                                     title: d.title, readOnly: true, inheritedPolicy: inv.inheritedPolicy)
                    if let replaced = try await guardBody(d.id, params, hookContext), replaced != .null { params = replaced }
                    continue
                }
                if let handler = hook.handler {
                    if let replaced = try await handler(d.id, params), replaced != .null { params = replaced }
                    continue
                }
                let r = try await execute(Invocation(command: hook.command, params: ["command": .string(d.id), "params": params],
                                                     principal: hook.principal, session: inv.session, group: group,
                                                     dryRun: inv.dryRun, depth: inv.depth + 1, readOnly: true, skipHooks: true))
                if let replaced = r.value["params"], replaced != .null { params = replaced }
            }
        }
        if !inv.principal.isUser, let error = d.params.validate(params).first {
            throw NibError(error.code, error.message, path: error.path,
                           hint: "call commands.describe {\"id\": \"\(inv.command)\"} for the schema and examples")
        }
        try await gateway.authorize(d, params: params, principal: inv.principal, group: group,
                                    inheritedPolicy: inv.inheritedPolicy)
        let inherited = inv.principal.isUser
            ? inv.inheritedPolicy
            : ConfirmationPolicy.stricter(inv.inheritedPolicy, gateway.policy(inv.principal))
        let ctx = CommandContext(bus: self, principal: inv.principal, group: group, depth: inv.depth, dryRun: inv.dryRun,
                                 session: inv.session, commandID: d.id, title: d.title,
                                 readOnly: inv.readOnly || (d.effect == .read && !d.forwardsCalls),
                                 inheritedPolicy: inherited)
        let value = try await entry.handler(params, ctx)
        return InvocationResult(value: value, changes: ctx.summary, group: group)
    }

    /// Convenience JSON call returning only the value.
    @discardableResult
    public func execute(_ command: String, _ params: JSONValue = [:], principal: Principal = .user,
                        session: EditorSession? = nil) async throws -> JSONValue {
        try await execute(Invocation(command: command, params: params, principal: principal, session: session)).value
    }

    // MARK: Commit + observers

    @discardableResult
    func commit(_ tx: DocTransaction, label: String, command: String, record: Bool) -> Changeset {
        seq += 1
        let cs = Changeset(seq: seq, principal: tx.principal, group: tx.group, label: label, command: command, mutations: tx.mutations)
        if record && !cs.principal.isSync { history.record(cs) }
        finish(cs)
        return cs
    }

    private func finish(_ cs: Changeset) {
        workspace.persist(cs)
        for o in Array(observers.values) { o(cs) }
        for doc in cs.documents {
            events.emit(NibEventType.committed, principal: cs.principal, doc: doc, changes: cs.summary(for: doc))
        }
    }

    /// Synchronous callback for every commit, undo and remote merge (tile invalidation, indexing, collaboration).
    @discardableResult
    public func observeCommits(_ handler: @escaping (Changeset) -> Void) -> EventSubscription {
        let id = UUID()
        observers[id] = handler
        return EventSubscription { [weak self] in
            Task { @MainActor in self?.observers[id] = nil }
        }
    }

    // MARK: Undo / redo / selective revert

    /// Undoes the latest step of `doc` (and, for a group linked across documents, the same group's latest step in
    /// every other document where it is still the latest). Returns false when there is nothing to undo.
    @discardableResult
    public func undo(_ doc: DocumentID) -> Bool {
        guard let entry = history.popUndo(doc) else { return false }
        var entries = [(doc, entry)]
        if entry.linked {
            for other in history.linkedDocuments(entry.group, except: doc, redo: false) {
                if let e = history.popUndo(other) { entries.append((other, e)) }
            }
        }
        let tx = DocTransaction(workspace: workspace, principal: .user, group: "undo:" + entry.group)
        for (_, e) in entries { _ = tx.revert(e.mutations) }
        history.rebase(tx.rebase)
        for (d, e) in entries {
            var r = UndoEntry(group: e.group, label: e.label, principal: e.principal,
                              mutations: tx.mutations.filter { $0.document == d })
            r.linked = e.linked
            history.pushRedo(r, doc: d)
        }
        finishUnrecorded(tx, label: "Undo " + entry.label, command: CommandIDs.undo)
        return true
    }

    @discardableResult
    public func redo(_ doc: DocumentID) -> Bool {
        guard let entry = history.popRedo(doc) else { return false }
        var entries = [(doc, entry)]
        if entry.linked {
            for other in history.linkedDocuments(entry.group, except: doc, redo: true) {
                if let e = history.popRedo(other) { entries.append((other, e)) }
            }
        }
        let tx = DocTransaction(workspace: workspace, principal: .user, group: "redo:" + entry.group)
        for (_, e) in entries { _ = tx.revert(e.mutations) }
        history.rebase(tx.rebase)
        for (d, e) in entries {
            var r = UndoEntry(group: e.group, label: e.label, principal: e.principal,
                              mutations: tx.mutations.filter { $0.document == d })
            r.linked = e.linked
            history.pushUndo(r, doc: d)
        }
        finishUnrecorded(tx, label: "Redo " + entry.label, command: CommandIDs.redo)
        return true
    }

    /// Reverts one undo group (e.g. an AI turn) even after later edits; records the revert as a new undo step.
    /// Returns nil when the group is not in the history.
    public func revert(group: String, doc: DocumentID, principal: Principal = .user) -> (reverted: Int, skipped: Int)? {
        guard let entry = history.removeEntry(group: group, doc: doc) else { return nil }
        let tx = DocTransaction(workspace: workspace, principal: principal, group: NibID.make().raw)
        let skipped = tx.revert(entry.mutations)
        history.rebase(tx.rebase)
        let n = tx.mutations.count
        if n > 0 { commit(tx, label: "Revert " + entry.label, command: CommandIDs.revertGroup, record: true) }
        return (n, skipped)
    }

    private func finishUnrecorded(_ tx: DocTransaction, label: String, command: String) {
        guard !tx.mutations.isEmpty else { return }
        seq += 1
        finish(Changeset(seq: seq, principal: tx.principal, group: tx.group, label: label, command: command, mutations: tx.mutations))
    }

    // MARK: Remote changes (sync + collaboration only)

    /// Merges records from another device (folder sync) or a collaborator. Not recorded for undo.
    /// The document must be loaded; unloaded documents merge from disk when opened.
    @discardableResult
    public func applyRemote(_ patch: DocumentPatch, origin: String) -> ChangeSummary {
        guard workspace.isLoaded(patch.doc) else { return ChangeSummary() }
        guard let muts = try? workspace.merge(patch), !muts.isEmpty else { return ChangeSummary() }
        seq += 1
        let cs = Changeset(seq: seq, principal: .sync(origin), group: "sync", label: "Sync", command: "sync.merge", mutations: muts)
        finish(cs)
        return cs.summary
    }
}

extension Principal {
    var isSync: Bool {
        if case .sync = self { return true }
        return false
    }
}
```

### `NibKit/Sources/NibContracts/Core/Gateway.swift`

```swift
import Foundation

public enum ConfirmationPolicy: String, Codable, CaseIterable {
    /// Confirm every mutating command.
    case always
    /// Confirm destructive commands (default).
    case destructive
    /// Never confirm (irreversible, sensitive and plugin-management commands are still confirmed).
    case never

    private var rank: Int {
        switch self {
        case .always: return 2
        case .destructive: return 1
        case .never: return 0
        }
    }

    /// The stricter of two policies (nil = no constraint).
    public static func stricter(_ a: ConfirmationPolicy?, _ b: ConfirmationPolicy?) -> ConfirmationPolicy? {
        guard let a = a else { return b }
        guard let b = b else { return a }
        return a.rank >= b.rank ? a : b
    }
}

public struct ConfirmationRequest {
    public let principal: Principal
    public let command: CommandDescriptor
    public let params: JSONValue

    public init(principal: Principal, command: CommandDescriptor, params: JSONValue) {
        self.principal = principal
        self.command = command
        self.params = params
    }
}

public enum ConfirmationDecision { case allow, allowRestOfGroup, deny }

/// Shows the confirmation sheet. The app shell installs a minimal alert-based presenter at launch (so plugins and
/// the bridge work without the AI chat feature); F085 wraps it with its richer sheet for AI turns.
@MainActor
public protocol ConfirmationPresenter: AnyObject {
    func confirm(_ request: ConfirmationRequest) async -> ConfirmationDecision
}

/// Permission, lock and confirmation checks for every non-user call.
@MainActor
public final class Gateway {
    /// Granted scopes per principal. The plugin host replaces this to answer for `.plugin(id)`.
    public var grants: (Principal) -> Set<Scope>
    /// Confirmation policy per principal (AI / bridge settings).
    public var policy: (Principal) -> ConfirmationPolicy
    /// True when a document is locked for non-user principals (Password Lock feature).
    public var isLocked: (DocumentID) -> Bool
    public weak var presenter: ConfirmationPresenter?
    private var allowedGroups = Set<String>()
    private var kindPresenters: [String: WeakPresenter] = [:]
    private var kindPolicies: [String: (Principal) -> ConfirmationPolicy] = [:]

    public init() {
        grants = { p in Gateway.defaultGrants(p) }
        policy = { _ in .destructive }
        isLocked = { _ in false }
        // Default policy: the principal kind's policy (`setPolicy`), else destructive.
        policy = { [weak self] p in self?.kindPolicies[p.kind]?(p) ?? .destructive }
    }

    /// contracts-v2: the confirmation UI for one principal kind ("ai" → the AI chat's sheet F085, "bridge" → the bridge's
    /// deadline-bound presenter F090), consulted before `presenter`. Kept weakly, like `presenter`. nil removes it.
    /// No feature needs to wrap or replace another feature's presenter any more.
    public func setPresenter(_ presenter: ConfirmationPresenter?, forPrincipalKind kind: String) {
        kindPresenters[kind] = presenter.map { WeakPresenter($0) }
    }

    /// contracts-v2: the confirmation policy for one principal kind (read from that kind's security setting). The
    /// default `policy` closure consults these; a feature that replaced `policy` wholesale bypasses them.
    public func setPolicy(forPrincipalKind kind: String, _ policy: ((Principal) -> ConfirmationPolicy)?) {
        kindPolicies[kind] = policy
    }

    /// The presenter that confirms for `principal`: its kind's presenter, else `presenter`.
    public func confirmationPresenter(for principal: Principal) -> ConfirmationPresenter? {
        kindPresenters[principal.kind]?.value ?? presenter
    }

    public nonisolated static func defaultGrants(_ p: Principal) -> Set<Scope> {
        switch p {
        case .user: return Set(Scope.allCases)
        case .ai, .bridge: return Set(Scope.allCases).subtracting([.security])
        case .plugin, .sync: return []
        }
    }

    public func authorize(_ d: CommandDescriptor, params: JSONValue, principal: Principal, group: String,
                          inheritedPolicy: ConfirmationPolicy? = nil) async throws {
        if principal.isUser { return }
        if case .sync = principal { throw NibError(.permissionDenied, "sync cannot run commands") }
        guard d.exposure.contains(principal.exposure) else {
            throw NibError(.permissionDenied, "'\(d.id)' is not available to \(principal)")
        }
        if d.scopes.contains(.security) {
            throw NibError(.permissionDenied, "'\(d.id)' can only be run by the user")
        }
        let missing = d.scopes.subtracting(grants(principal))
        guard missing.isEmpty else {
            throw NibError(.permissionDenied, "missing permission(s): " + missing.map { $0.rawValue }.sorted().joined(separator: ", "),
                           hint: "the user must grant these permissions")
        }
        for doc in Gateway.referencedDocuments(params) where isLocked(doc) {
            throw NibError(.locked, "document \(doc) is locked", hint: "ask the user to unlock it first")
        }
        guard needsConfirmation(d, principal: principal, inheritedPolicy: inheritedPolicy),
              !allowedGroups.contains(group) else { return }
        guard let presenter = confirmationPresenter(for: principal) else {
            throw NibError(.userDenied, "'\(d.title)' needs confirmation but no confirmation UI is available")
        }
        switch await presenter.confirm(ConfirmationRequest(principal: principal, command: d, params: params)) {
        case .allow: return
        case .allowRestOfGroup: allowedGroups.insert(group)
        case .deny: throw NibError(.userDenied, "the user declined '\(d.title)'")
        }
    }

    public func needsConfirmation(_ d: CommandDescriptor, principal: Principal,
                                  inheritedPolicy: ConfirmationPolicy? = nil) -> Bool {
        if principal.isUser { return false }
        if d.effect == .irreversible || d.sensitive || d.scopes.contains(.pluginsManage) { return true }
        switch ConfirmationPolicy.stricter(policy(principal), inheritedPolicy) ?? .destructive {
        case .always: return d.isMutating
        case .destructive: return d.destructive
        case .never: return false
        }
    }

    /// Documents referenced by ref strings anywhere in `params`, or by bare ids under doc/document/docId keys.
    public nonisolated static func referencedDocuments(_ params: JSONValue) -> Set<DocumentID> {
        var out = Set<DocumentID>()
        func walk(_ v: JSONValue, key: String?) {
            switch v {
            case .string(let s):
                if let ref = NodeRef(s), let d = ref.documentID {
                    out.insert(d)
                } else if let k = key, ["doc", "document", "docId", "documentId"].contains(k), NibID.isValid(s) {
                    out.insert(NibID(s))
                }
            case .array(let a):
                for x in a { walk(x, key: key) }
            case .object(let o):
                for (k, x) in o { walk(x, key: k) }
            default:
                break
            }
        }
        walk(params, key: nil)
        return out
    }
}

/// Weak box for per-kind presenters.
private final class WeakPresenter {
    weak var value: ConfirmationPresenter?
    init(_ value: ConfirmationPresenter) { self.value = value }
}
```

### `NibKit/Sources/NibContracts/Core/Session.swift`

```swift
import Foundation
import Combine
import CoreGraphics

public struct Selection: Equatable {
    public var doc: DocumentID?
    public var page: PageID?
    public var items: [ElementID]
    /// Page-coordinate bounds of the selection (lasso polygon bounds or item union).
    public var bounds: Rect?
    /// contracts-v2: the lasso outline (page coordinates) when the selection came from a lasso; the transform feature
    /// (F012) moves, scales and rotates it with the items, so everyone draws the same outline. nil = bounds only.
    public var outline: [Point]?

    public init(doc: DocumentID? = nil, page: PageID? = nil, items: [ElementID] = [], bounds: Rect? = nil,
                outline: [Point]? = nil) {
        self.doc = doc
        self.page = page
        self.items = items
        self.bounds = bounds
        self.outline = outline
    }

    public var isEmpty: Bool { items.isEmpty }

    public var refs: [String] {
        guard let d = doc, let p = page else { return [] }
        return items.map { NodeRef.item(d, p, $0).description }
    }
}

public enum ReplayMode: String, Codable, CaseIterable {
    /// Ink ahead of the playhead is faded.
    case spotlight
    /// Ink appears progressively as it was written.
    case reveal
    /// Everything visible, no animation ("Static").
    case showAll = "static"
}

/// Note Replay state: wall-clock time (unix seconds) being played back.
public struct ReplayState: Equatable {
    public var time: Double
    public var mode: ReplayMode
    public init(time: Double, mode: ReplayMode) {
        self.time = time
        self.mode = mode
    }
}

public enum StylusMode: String, Codable, CaseIterable {
    /// Apple Pencil draws, fingers scroll/select.
    case pencilOnly
    /// Fingers, mouse and passive styluses draw ("Disconnect Apple Pencil").
    case anyInput
}

/// Per-window editor state (not persisted in documents). Changed by `.session` commands and editor UI.
@MainActor
public final class EditorSession: ObservableObject {
    /// The event bus of the app this session belongs to (set by `SessionRegistry.add`); changes are emitted there.
    /// Per session, not static, so two `NibApp`s in one process (two-device tests) never cross-talk.
    public weak var events: EventBus?

    public let id: NibID
    @Published public var document: DocumentID? = nil {
        didSet { if oldValue != document { notify(NibEventType.sessionDocument) } }
    }
    @Published public var page: PageID? = nil {
        didSet { if oldValue != page { notify(NibEventType.pageChanged) } }
    }
    /// Active canvas tool id ("pen", "lasso", "eraser", plugin tool ids…).
    @Published public var tool: String = "pen" {
        didSet {
            if oldValue != tool {
                previousTool = oldValue
                notify(NibEventType.toolChanged)
            }
        }
    }
    @Published public var previousTool: String? = nil
    @Published public var selection = Selection() {
        didSet { if oldValue != selection { notify(NibEventType.selectionChanged) } }
    }
    @Published public var zoom: Double = 1
    /// Visible part of the current page in page coordinates.
    @Published public var visibleRect: Rect? = nil
    @Published public var readOnly = false
    @Published public var activeLayer = 0 {
        didSet { if oldValue != activeLayer { notify(NibEventType.layersChanged) } }
    }
    /// Per-device layer visibility.
    @Published public var hiddenLayers: Set<Int> = [] {
        didSet { if oldValue != hiddenLayers { notify(NibEventType.layersChanged) } }
    }
    /// Note Replay in progress (the canvas passes it to the renderer).
    @Published public var replay: ReplayState? = nil
    /// True while a text view (text box, block, card field) is first responder; single-key shortcuts are off.
    public var isEditingText = false
    /// contracts-v2: what is being edited while `isEditingText` (item, block or card ref) and the selected range
    /// [start, length] in plain-text units (UTF-16, list markers excluded). Set by the editing feature, cleared when
    /// editing ends; read by link (F029), spellcheck and the AI's context.
    public var editingTextRef: String?
    public var editingTextRange: [Int]?
    /// contracts-v2: this window's floating host (see `FloatingHosting`), set by the container's owner (the document
    /// chrome F017, the library F019); nil until the window's container is on screen, and in headless runs.
    public weak var floatingHost: FloatingHosting?
    /// Transient per-tool options (current preset slot, eraser size…), keyed by tool id.
    public var toolOptions: [String: JSONValue] = [:]
    /// The editor view controller showing `document` (set by the editor).
    public weak var editor: DocumentEditing?

    /// contracts-v2: Pencil-down state of this window. The canvas (F006/F101) writes it; the document chrome mirrors it
    /// into its droplet container (recede while writing, DESIGN.md §10.8); attachments, HUDs and palettes observe it.
    /// Deliberately NOT `@Published`: a Pencil down must never re-evaluate SwiftUI bodies that observe the session.
    public let inking: InkingSignal
    /// contracts-v2: ids of the panels open in this window (sidebar tab, floating panels, sheets), kept by the chrome
    /// host (F017) so `query.context` and other features can report and toggle them.
    @Published public var openPanels: Set<String> = []
    /// contracts-v2: the tool to return to after a temporary tool (quick lasso, Circle to Lasso, Edit Handwriting,
    /// eyedropper). Set by `selectTemporarily`; cleared by `endTemporaryTool` and by any regular tool switch.
    @Published public private(set) var temporaryReturnTool: String? = nil

    public init(id: NibID = NibID.make()) {
        self.id = id
        self.inking = InkingSignal()
    }

    /// contracts-v2: switches to `tool` until `endTemporaryTool()` (or `finishToolUse`), remembering the current tool.
    /// Nested temporary switches keep the first return tool.
    public func selectTemporarily(_ tool: String) {
        let back = temporaryReturnTool ?? self.tool
        self.tool = tool
        temporaryReturnTool = back
    }

    /// contracts-v2: returns from a temporary tool; no-op when none is active.
    public func endTemporaryTool() {
        guard let back = temporaryReturnTool else { return }
        temporaryReturnTool = nil
        tool = back
    }

    /// contracts-v2: a regular tool switch (`tool.select`): drops any pending temporary return.
    public func selectTool(_ tool: String) {
        temporaryReturnTool = nil
        self.tool = tool
    }

    /// contracts-v2: a tool finished one use (an insert, a lasso, an erase). Returns to the temporary return tool when one
    /// is set, else to `previousTool` when the tool is not `sticky`; emits `tool.finished` either way. Canvas tools call
    /// it through `CanvasHost.finishToolUse(_:)`.
    public func finishToolUse(sticky: Bool) {
        let finished = tool
        if temporaryReturnTool != nil {
            endTemporaryTool()
        } else if !sticky, let back = previousTool, back != tool {
            tool = back
        }
        events?.emit(NibEventType.toolFinished, doc: document,
                     payload: ["session": .string(id.raw), "tool": .string(finished)])
    }

    private func notify(_ kind: String) {
        events?.emit(kind, doc: document, payload: ["session": .string(id.raw)])
    }
}

/// contracts-v2: whether the Pencil (or a drawing finger) is down in one window, and the stroke's bounds. Written by the
/// canvas, read by chrome, HUDs and attachments that recede or pause while the user writes. Main actor only.
@MainActor
public final class InkingSignal {
    public private(set) var isInking = false
    /// Bounds of the current stroke in WINDOW coordinates (nil between strokes).
    public private(set) var strokeBounds: CGRect?
    private var observers: [UUID: @MainActor (InkingSignal) -> Void] = [:]

    public init() {}

    /// The stroke started (canvas only).
    public func begin(strokeBounds: CGRect? = nil) {
        isInking = true
        self.strokeBounds = strokeBounds
        notify()
    }

    /// The stroke grew (canvas only). Cheap: observers are called synchronously.
    public func update(strokeBounds: CGRect) {
        guard isInking else { return }
        self.strokeBounds = strokeBounds
        notify()
    }

    /// The stroke ended or was cancelled (canvas only).
    public func end() {
        guard isInking || strokeBounds != nil else { return }
        isInking = false
        strokeBounds = nil
        notify()
    }

    /// Calls `handler` on every change until the subscription is cancelled.
    @discardableResult
    public func observe(_ handler: @escaping @MainActor (InkingSignal) -> Void) -> EventSubscription {
        let id = UUID()
        observers[id] = handler
        return EventSubscription { [weak self] in
            Task { @MainActor in self?.observers[id] = nil }
        }
    }

    private func notify() {
        for o in Array(observers.values) { o(self) }
    }
}

@MainActor
public final class SessionRegistry {
    public private(set) var sessions: [EditorSession] = []
    public private(set) weak var active: EditorSession?
    /// Set by `NibApp.init`; handed to every added session.
    public weak var events: EventBus?

    public init() {}

    public func add(_ s: EditorSession) {
        if !sessions.contains(where: { $0 === s }) { sessions.append(s) }
        s.events = events
        setActive(s)
    }

    public func remove(_ s: EditorSession) {
        sessions.removeAll { $0 === s }
        if active === s { setActive(sessions.last) }
    }

    /// Makes `s` the active session; emits `session.activated` when it changes (contracts-v2).
    public func activate(_ s: EditorSession) { setActive(s) }

    private func setActive(_ s: EditorSession?) {
        let changed = active !== s
        active = s
        if changed, let s = s {
            events?.emit(NibEventType.sessionActivated, doc: s.document, payload: ["session": .string(s.id.raw)])
        }
    }

    public func session(_ id: NibID) -> EditorSession? { sessions.first { $0.id == id } }
}
```

### `NibKit/Sources/NibContracts/Core/Services.swift`

```swift
import Foundation
import CoreGraphics

// MARK: - Library (implemented by the Library Store feature)

/// The library folder: folders are directories, documents are `.nib` packages, trash lives in `.nib-library/trash`.
@MainActor
public protocol LibraryService: AnyObject {
    /// Library root (security-scoped folder the user picked; default = app Documents).
    var rootURL: URL { get }
    /// `<root>/.nib-library` (trash, plugins, elements, templates, prefs, AI chats).
    var metadataURL: URL { get }
    /// All non-trashed folders and documents (cached catalog).
    func allNodes() -> [LibraryNode]
    func node(_ id: NibID) -> LibraryNode?
    /// Children of a folder (nil = root), non-trashed.
    func children(of folder: FolderID?) -> [LibraryNode]
    /// Main actor only. Off-main code (persistence I/O, AssetStore, renderers) uses `NibServices.packages`,
    /// which the implementation keeps in sync with its catalog.
    func packageURL(_ doc: DocumentID) -> URL?
    /// Writes a new package with `content` (first page(s) included) and returns its id.
    func createDocument(_ content: DocumentContent, title: String, in folder: FolderID?) throws -> DocumentID
    func createFolder(title: String, in parent: FolderID?, style: FolderStyle?) throws -> FolderID
    func rename(_ id: NibID, to title: String) throws
    /// Moves a folder or document into `folder` (nil = root).
    func move(_ id: NibID, to folder: FolderID?) throws
    func duplicate(_ id: NibID) throws -> NibID
    func setStyle(_ style: FolderStyle, folder: FolderID) throws
    func trash(_ id: NibID) throws
    func trashedNodes() -> [LibraryNode]
    /// Restores to the original location (or `folder` when given / when the original is gone).
    func restore(_ id: NibID, to folder: FolderID?) throws
    func deletePermanently(_ id: NibID) throws
    /// Copies an external `.nibnote` package (or a legacy `.nib` package, or a folder of them) into the library.
    func importPackage(at url: URL, into folder: FolderID?) throws -> DocumentID
    /// Rescans the disk (after sync, import, repair).
    /// Implementations emit `library.changed` (`NibEventType.libraryChanged`) after EVERY catalog change: create,
    /// rename, move, style, trash, restore, delete, import and refresh (title-based indexes and lists rely on it).
    func refresh()
    /// Switches the library to another folder (security-scoped URL chosen by the user).
    func setRoot(_ url: URL) throws
}

// MARK: - Package locations (thread-safe)

/// Document id → package URL, readable from any thread. The Library Store feature (F002) fills it whenever its
/// catalog changes; persistence and `AssetStore` capture it at registration (`app.services.packages`) and read it
/// off-main. Nothing that runs off-main may touch `NibApp`, `NibServices` or any other `@MainActor` type.
public final class PackageLocator {
    private var urls: [DocumentID: URL] = [:]
    private let lock = NSLock()

    public init() {}

    public func url(_ doc: DocumentID) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return urls[doc]
    }

    public func set(_ url: URL?, for doc: DocumentID) {
        lock.lock()
        urls[doc] = url
        lock.unlock()
    }

    public func replaceAll(_ all: [DocumentID: URL]) {
        lock.lock()
        urls = all
        lock.unlock()
    }
}

// MARK: - Assets (implemented by the Document Store feature)

/// Content-addressed binary storage inside document packages. Thread-safe (drawers call it from render
/// threads); implementations find packages through a captured `PackageLocator`, never through `NibServices`.
public protocol AssetStore: AnyObject {
    /// Stores bytes as `assets/<sha256>.<ext>` in the document package (deduplicated).
    func put(_ data: Data, ext: String, doc: DocumentID) throws -> AssetRef
    func url(_ ref: AssetRef, doc: DocumentID) -> URL?
    func data(_ ref: AssetRef, doc: DocumentID) throws -> Data
    /// App-level scratch asset (renders for AI/bridge, clipboard). Expires after one hour.
    func putTemporary(_ data: Data, ext: String) throws -> AssetRef
    func temporaryURL(_ ref: AssetRef) -> URL?
}

// MARK: - Rendering (implemented by the Renderer feature)

public struct RenderRequest {
    public var doc: DocumentID
    public var page: PageID
    /// Page coordinates; nil = whole page (boards: content bounds).
    public var region: Rect?
    /// Pixels per point.
    public var scale: Double
    /// nil = the session's visible layers (all layers when rendering headless).
    public var layers: Set<Int>?
    public var background: Bool
    public var annotations: Bool
    public var hidden: Set<ElementID>
    /// Draw numbered boxes over items (Set-of-Mark prompting for vision models).
    public var marks: Bool
    public var replay: ReplayState?
    /// contracts-v2: what the render is for; handed to drawers as `DrawContext.purpose`.
    public var purpose: DrawPurpose = .screen

    public init(doc: DocumentID, page: PageID, region: Rect? = nil, scale: Double = 2, layers: Set<Int>? = nil,
                background: Bool = true, annotations: Bool = true, hidden: Set<ElementID> = [], marks: Bool = false,
                replay: ReplayState? = nil) {
        self.doc = doc
        self.page = page
        self.region = region
        self.scale = scale
        self.layers = layers
        self.background = background
        self.annotations = annotations
        self.hidden = hidden
        self.marks = marks
        self.replay = replay
    }
}

public struct RenderResult {
    public var image: CGImage
    /// Page region actually rendered.
    public var region: Rect
    public var scale: Double
    /// Mark number → item ref (when `marks` was requested).
    public var marks: [String: String]

    public init(image: CGImage, region: Rect, scale: Double, marks: [String: String] = [:]) {
        self.image = image
        self.region = region
        self.scale = scale
        self.marks = marks
    }
}

public protocol PageRenderer: AnyObject {
    func render(_ request: RenderRequest) async throws -> RenderResult
    func thumbnail(doc: DocumentID, page: PageID, maxPixelSize: Int) async -> CGImage?
    /// Drop cached tiles/thumbnails for a page region (nil = whole page).
    func invalidate(doc: DocumentID, page: PageID, rect: Rect?)
    /// Memory pressure: drop every cache that can be rebuilt.
    func purgeCaches()
}

// MARK: - Recognition (implemented by the Search Index feature)

/// One recognised text block (named `TextRecognition`, not `RecognizedText`, to avoid the iOS 18 Vision type).
public struct TextRecognition: Codable, Equatable {
    public var text: String
    public var alternatives: [String]
    /// Page coordinates (image pixel coordinates for `recognize(image:)`).
    public var bbox: Rect
    /// Stroke/text items the text came from.
    public var itemIDs: [ElementID]
    /// "ink", "typed", "pdf", "scan", "image", "transcript".
    public var source: String
    public var confidence: Double
    /// contracts-v2: word boxes when the recognizer has them (Vision); nil = line only. `recognize.items` needs them.
    public var words: [TextRecognitionWord]?

    public init(text: String, alternatives: [String] = [], bbox: Rect, itemIDs: [ElementID] = [], source: String, confidence: Double = 1) {
        self.text = text
        self.alternatives = alternatives
        self.bbox = bbox
        self.itemIDs = itemIDs
        self.source = source
        self.confidence = confidence
    }

    /// contracts-v2: lenient (only `text` is required), so feature JSON such as a page's "nib.scanText" ext decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        alternatives = try c.decodeIfPresent([String].self, forKey: .alternatives) ?? []
        bbox = try c.decodeIfPresent(Rect.self, forKey: .bbox) ?? .zero
        itemIDs = try c.decodeIfPresent([ElementID].self, forKey: .itemIDs) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "unknown"
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1
        words = try c.decodeIfPresent([TextRecognitionWord].self, forKey: .words)
    }

    enum CodingKeys: String, CodingKey { case text, alternatives, bbox, itemIDs, source, confidence, words }
}

/// contracts-v2: one recognised word with its box (page coordinates) and the items it came from.
public struct TextRecognitionWord: Codable, Equatable {
    public var text: String
    public var bbox: Rect
    public var itemIDs: [ElementID]

    public init(text: String, bbox: Rect, itemIDs: [ElementID] = []) {
        self.text = text
        self.bbox = bbox
        self.itemIDs = itemIDs
    }

    /// Lenient: `itemIDs` may be omitted (image and PDF words have none).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        bbox = try c.decodeIfPresent(Rect.self, forKey: .bbox) ?? .zero
        itemIDs = try c.decodeIfPresent([ElementID].self, forKey: .itemIDs) ?? []
    }

    enum CodingKeys: String, CodingKey { case text, bbox, itemIDs }
}

public protocol TextRecognizer: AnyObject {
    /// Line-level recognition of stroke items (Vision on an ink-only render). Word boxes map back to stroke ids.
    func recognize(strokes: [Item], language: String) async throws -> [TextRecognition]
    func recognize(image: CGImage, language: String) async throws -> [TextRecognition]
}

// MARK: - PDF (implemented by the PDF Engine feature)

public struct PDFLinkInfo: Codable, Equatable {
    /// Page coordinates (top-left origin).
    public var rect: Rect
    public var url: String?
    /// Internal destination (0-based page index in the same PDF).
    public var pageIndex: Int?
    public init(rect: Rect, url: String? = nil, pageIndex: Int? = nil) {
        self.rect = rect
        self.url = url
        self.pageIndex = pageIndex
    }
}

public struct PDFOutlineNode: Codable, Equatable {
    public var title: String
    public var pageIndex: Int?
    public var children: [PDFOutlineNode]
    public init(title: String, pageIndex: Int?, children: [PDFOutlineNode] = []) {
        self.title = title
        self.pageIndex = pageIndex
        self.children = children
    }
}

/// PDF text, links and outline (PDFKit). Coordinates are converted to page points with a top-left origin.
public protocol PDFService: AnyObject {
    func pageCount(_ url: URL) -> Int
    func pageSize(_ url: URL, page: Int) -> PageSize?
    func text(_ url: URL, page: Int) -> String?
    func textBlocks(_ url: URL, page: Int) -> [TextRecognition]
    func links(_ url: URL, page: Int) -> [PDFLinkInfo]
    func outline(_ url: URL) -> [PDFOutlineNode]
    /// Text and line rects of a drag selection between two page points.
    func selection(_ url: URL, page: Int, from: Point, to: Point) -> (text: String, rects: [Rect])
    /// contracts-v2: the word under a page point (long-press selection in read-only mode); nil = none or unsupported.
    /// Default: nil.
    func word(_ url: URL, page: Int, at point: Point) -> (text: String, rect: Rect)?
}

public extension PDFService {
    func word(_ url: URL, page: Int, at point: Point) -> (text: String, rect: Rect)? { nil }
}

// MARK: - Password lock (implemented by the Password Lock feature)

@MainActor
public protocol LockService: AnyObject {
    /// Locked and not unlocked in this app session.
    func isLocked(_ doc: DocumentID) -> Bool
    /// Prompts (Face ID / password). True when unlocked.
    func unlock(_ doc: DocumentID) async -> Bool
}

// MARK: - Container

/// Service locator filled by features in `register`. Never resolve services during `register`; resolve at use time.
@MainActor
public final class NibServices {
    public let settings: SettingsStore
    public let sessions: SessionRegistry
    /// Thread-safe package URLs (filled by the Library Store feature; see `PackageLocator`).
    public let packages = PackageLocator()
    public var library: LibraryService?
    public var assets: AssetStore?
    public var renderer: PageRenderer?
    public var recognizer: TextRecognizer?
    public var pdf: PDFService?
    public var ai: AIService?
    public var lock: LockService?
    private var extras: [String: AnyObject] = [:]

    public init(settings: SettingsStore) {
        self.settings = settings
        self.sessions = SessionRegistry()
    }

    /// Escape hatch for feature-to-feature services not in the contracts (key = "<featureId>.<name>").
    public func set(_ service: AnyObject?, for key: String) { extras[key] = service }
    public func get<T>(_ key: String, as type: T.Type = T.self) -> T? { extras[key] as? T }

    /// Unwraps an optional service or throws `unavailable`.
    public func require<T>(_ service: T?, _ name: String) throws -> T {
        guard let s = service else { throw NibError.unavailable(name) }
        return s
    }
}
```

### `NibKit/Sources/NibContracts/Core/AIService.swift`

```swift
import Foundation

/// Ask = read-only tools ("Create mode off"); edit = all tools ("Create mode on").
public enum AIMode: String, Codable, CaseIterable { case ask, edit }

public enum AIScopeKind: String, Codable, CaseIterable { case selection, page, document, library, block }

public struct AIScope: Codable, Equatable {
    public var kind: AIScopeKind
    public var doc: DocumentID?
    public var page: PageID?
    /// Selected item / block refs.
    public var refs: [String]

    public init(kind: AIScopeKind, doc: DocumentID? = nil, page: PageID? = nil, refs: [String] = []) {
        self.kind = kind
        self.doc = doc
        self.page = page
        self.refs = refs
    }
}

public struct AIMessage: Codable, Equatable {
    /// "user" | "assistant".
    public var role: String
    public var text: String
    /// Images stored with `AssetStore.putTemporary` or in the document.
    public var images: [AssetRef]?

    public init(role: String, text: String, images: [AssetRef]? = nil) {
        self.role = role
        self.text = text
        self.images = images
    }
}

public struct AIRequest {
    /// Continue a stored conversation (nil = new chat).
    public var chatID: String?
    /// Extra system instructions appended to Nib's system prompt.
    public var system: String?
    public var messages: [AIMessage]
    /// Command ids the model may call directly as tools; nil = the default catalogue for `mode`; [] = no tools.
    public var tools: [String]?
    public var mode: AIMode
    public var scope: AIScope?
    /// Tool calls run as this principal (plugins calling `nib.ai.complete` stay `.plugin(id)`).
    public var principal: Principal
    /// Undo group for everything the turn changes (nil = one fresh group per turn).
    public var group: String?
    public var maxSteps: Int
    /// Ask for a JSON-only answer (feature-internal prompts).
    public var jsonOutput: Bool

    public init(chatID: String? = nil, system: String? = nil, messages: [AIMessage], tools: [String]? = nil,
                mode: AIMode = .ask, scope: AIScope? = nil, principal: Principal = .ai("internal"), group: String? = nil,
                maxSteps: Int = 40, jsonOutput: Bool = false) {
        self.chatID = chatID
        self.system = system
        self.messages = messages
        self.tools = tools
        self.mode = mode
        self.scope = scope
        self.principal = principal
        self.group = group
        self.maxSteps = maxSteps
        self.jsonOutput = jsonOutput
    }
}

public struct AIUsage: Codable, Equatable {
    public var input: Int
    public var output: Int
    public init(input: Int = 0, output: Int = 0) {
        self.input = input
        self.output = output
    }
}

public struct AIResponse: Codable {
    public var text: String
    public var changes: ChangeSummary
    /// Undo group of the turn (for "Undo" / `history.revertGroup`).
    public var group: String?
    public var usage: AIUsage
    public var chatID: String?

    public init(text: String, changes: ChangeSummary = ChangeSummary(), group: String? = nil, usage: AIUsage = AIUsage(), chatID: String? = nil) {
        self.text = text
        self.changes = changes
        self.group = group
        self.usage = usage
        self.chatID = chatID
    }
}

public enum AIStreamEvent {
    case text(String)
    case toolStarted(name: String, arguments: JSONValue)
    case toolFinished(name: String, ok: Bool, changes: ChangeSummary?)
    case finished(AIResponse)
    case failed(NibError)
}

public struct AIChatSummary: Codable, Identifiable {
    public var id: String
    public var title: String
    public var doc: DocumentID?
    public var updated: Double
    public init(id: String, title: String, doc: DocumentID?, updated: Double) {
        self.id = id
        self.title = title
        self.doc = doc
        self.updated = updated
    }
}

/// Bring-your-own-AI service (implemented by the AI Agent feature). Every feature that needs a model
/// (summaries, math, meeting notes, title suggestions, plugins' `nib.ai.complete`) goes through this.
@MainActor
public protocol AIService: AnyObject {
    var isConfigured: Bool { get }
    var supportsVision: Bool { get }
    /// Streams a turn (text deltas, tool calls). Tool calls go through the command bus as `request.principal`.
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error>
    /// Runs a turn to completion.
    func complete(_ request: AIRequest) async throws -> AIResponse
    func cancel(chatID: String)
    func chats(doc: DocumentID?) -> [AIChatSummary]
    func messages(chatID: String) -> [AIMessage]
    func deleteChat(_ chatID: String)
    /// Cloud transcription via the provider's audio endpoint; throws `unsupported` when unavailable.
    func transcribe(audio: URL, language: String?) async throws -> [TranscriptSegment]
    /// Image generation via the provider; throws `unsupported` when unavailable.
    func generateImage(prompt: String) async throws -> Data
}

// MARK: - Tool catalogue (AI.md §4), shared by the in-app agent (F084) and the MCP bridge (F090)

@MainActor
public enum ToolCatalog {
    /// The nine meta-tools. Their set never grows; every command is reachable through `nib_run`.
    public static let metaTools: [ToolSpec] = [
        spec("nib_context", "Where the user is: document, page, visible rect, tool, selection refs/bbox, tabs.", .empty),
        spec("nib_get", "Any node (library, folder, doc, page, item, block, card) as JSON; stroke points only with points=true.",
             .obj(["ref": .ref, "depth": .int(min: 0, max: 4), "points": .bool(), "fields": .arr(.str()),
                   "cursor": .str("from the previous result when it was truncated")], required: ["ref"])),
        spec("nib_find", "Find items by kind, layer, area (bbox), field equality (where) or text inside a page or document.",
             .obj(["in": .ref, "kinds": .arr(.str()), "layer": .int(min: 0, max: 4), "bbox": .rect, "where": .anything(),
                   "text": .str(), "limit": .int(min: 1, max: 500), "cursor": .str()], required: ["in"])),
        spec("nib_search", "Full-text search over handwriting, typed text, PDFs, titles and transcripts.",
             .obj(["query": .str(), "scope": .str("doc:D or lib")], required: ["query"])),
        spec("nib_page_text", "Recognised text blocks of a page with bboxes, sources and item ids.",
             .obj(["page": .ref], required: ["page"])),
        spec("nib_render", "Render a page (or region) as an image; marks=true numbers the items and returns mark → ref.",
             .obj(["page": .ref, "region": .rect, "scale": .num(min: 0.1, max: 8), "marks": .bool()], required: ["page"])),
        spec("nib_commands", "List the commands you may call (id, one-line summary, effect), optionally for one namespace.",
             .obj(["namespace": .str()])),
        spec("nib_command_schema", "Full JSON schema and examples of one command. Read it before using an unfamiliar command.",
             .obj(["id": .str()], required: ["id"])),
        spec("nib_run", "Run one command {command, params} or several {calls:[{command, params}]} as one undo step; dry_run previews.",
             .obj(["command": .str(), "params": .anything(), "calls": .arr(.obj(["command": .str(), "params": .anything()])),
                   "dry_run": .bool()]))
    ]

    /// Meta-tools plus the direct tools (command ids) visible to `exposure`; ask mode keeps only `read` commands.
    public static func tools(_ registry: CommandRegistry, exposure: Exposure, readOnly: Bool, direct: [String]) -> [ToolSpec] {
        var out = metaTools
        for id in direct {
            guard let d = registry.descriptor(id), d.exposure.contains(exposure), !readOnly || d.effect == .read else { continue }
            out.append(ToolSpec(name: d.toolName, description: d.summary, schema: d.params.toJSON()))
        }
        return out
    }

    /// The Invocation a tool call stands for (nil = unknown tool). `nib_render` maps to `render.page`: callers turn
    /// its `asset` into an image part (or page text for models without vision). `readOnly` = ask mode.
    public static func invocation(tool: String, arguments: JSONValue, registry: CommandRegistry, principal: Principal,
                                  group: String, readOnly: Bool, session: EditorSession? = nil) -> Invocation? {
        func inv(_ command: String, _ params: JSONValue, dryRun: Bool = false) -> Invocation {
            Invocation(command: command, params: params, principal: principal, session: session, group: group,
                       dryRun: dryRun, readOnly: readOnly)
        }
        let args = arguments == .null ? [:] : arguments
        switch tool {
        case "nib_context": return inv(CommandIDs.queryContext, [:])
        case "nib_get": return inv(CommandIDs.queryGet, args)
        case "nib_find": return inv(CommandIDs.queryFind, args)
        case "nib_search": return inv(CommandIDs.searchText, args)
        case "nib_page_text": return inv(CommandIDs.recognizePageText, args)
        case "nib_render": return inv(CommandIDs.renderPage, args)
        case "nib_commands": return inv(CommandIDs.commandsList, args)
        case "nib_command_schema": return inv(CommandIDs.commandsDescribe, args)
        case "nib_run":
            let dry = args["dry_run"]?.boolValue ?? false
            if let calls = args["calls"] { return inv(CommandIDs.batch, ["calls": calls], dryRun: dry) }
            return inv(args["command"]?.stringValue ?? "", args["params"] ?? [:], dryRun: dry)
        default:
            guard let d = registry.all().first(where: { $0.toolName == tool }) else { return nil }
            return inv(d.id, args)
        }
    }

    private static func spec(_ name: String, _ description: String, _ schema: JSONSchema) -> ToolSpec {
        ToolSpec(name: name, description: description, schema: schema.toJSON())
    }
}
```

### `NibKit/Sources/NibContracts/Core/Extensibility.swift`

```swift
import Foundation

/// Keys for services shared through `NibServices.set(_:for:)` / `get(_:as:)` (typed by the protocols below).
public enum ServiceKeys {
    /// `PluginRuntimeProviding` (Plugin Runtime feature).
    public static let pluginRuntime = "plugins.runtime"
    /// `PluginHosting` (Plugin Host feature).
    public static let pluginHost = "plugins.host"
    /// `PluginPanelFactory` (Plugin Panels feature).
    public static let pluginPanels = "plugins.panels"
    /// `AIProviderStore` (AI Providers feature).
    public static let aiProviders = "ai.providers"
    /// `CollabTransport` implementations.
    public static let collabMultipeer = "collab.transport.multipeer"
    public static let collabRelay = "collab.transport.relay"
    /// contracts-v2: NSSet of `DocumentID.raw` the store refuses to write (F001's interim publication). Prefer
    /// `CommandContext.isReadOnly(_:)` / `NibApp.isReadOnly(_:)`, which also ask `DocumentPersistence.isReadOnly`.
    public static let storeReadOnly = "store.readOnly"
}

/// contracts-v2: names shared by the MCP/HTTP bridge (F090) and its settings page (F091), which cannot import each other.
/// Every setting is `security.*` (user only) and device-local; F091 reads and writes them through settings.get/set.
public enum BridgeNames {
    /// Bool, default false. Change it with `bridge.setEnabled {enabled, rotateToken?}`.
    public static let enabledSetting = "security.bridge.enabled"
    /// Int, default 7331.
    public static let portSetting = "security.bridge.port"
    /// [CIDR string]; unset = the bridge's default networks (see `settings.describe`).
    public static let networksSetting = "security.bridge.networks"
    /// [origin string], default [].
    public static let originsSetting = "security.bridge.origins"
    /// Keychain location of the bridge token (generic password, this device only).
    public static let tokenService = "app.nib.bridge"
    public static let tokenAccount = "token"
    /// Event emitted when the bridge state changes (`NibEventType.bridgeStatus`).
    public static let statusEvent = NibEventType.bridgeStatus
}

// MARK: - Plugin manifest (see docs/PLUGIN_API.md)
// These types are built by decoding manifest JSON (tests: `PluginManifest.fixture(...)` in NibTesting).

public struct PluginNetwork: Codable, Equatable {
    /// Hostnames the plugin (and its panels) may reach with the "network" permission.
    public var hosts: [String]
    public init(hosts: [String]) { self.hosts = hosts }
}

public struct PluginCommandContribution: Codable, Equatable {
    /// Must start with the plugin id: "<pluginId>.<name>".
    public var id: String
    public var title: String
    public var summary: String
    /// JSON Schema of the params (flat subset recommended).
    public var params: JSONValue?
    /// "read" | "session" | "edit" | "library" | "irreversible" (default "edit").
    public var effect: String?
    /// "document" | "library" | "app" (default "document").
    public var target: String?
    public var destructive: Bool?
    public var examples: [JSONValue]?
    /// Exposed to the in-app AI (default true) and the MCP bridge (default true).
    public var ai: Bool?
    public var bridge: Bool?
    /// Offered to the AI as its own tool instead of only via nib_run.
    public var aiDirect: Bool?
    /// Allows handlers to run up to 300 s instead of 30 s.
    public var longRunning: Bool?
}

public struct PluginWhen: Codable, Equatable {
    /// Item kinds that must all be in the selection (e.g. ["stroke"]).
    public var selectionKinds: [String]?
    public var minSelection: Int?
    public var docKinds: [String]?
}

public struct PluginMenuContribution: Codable, Equatable {
    /// A `MenuLocation` raw value, e.g. "objectMenu", "documentMore", "libraryItem".
    public var location: String
    public var command: String
    public var title: String?
    public var icon: String?
    public var when: PluginWhen?
}

public struct PluginToolbarContribution: Codable, Equatable {
    public var id: String
    public var title: String
    public var icon: String
    /// "tools" | "accessories" (default "accessories").
    public var group: String?
    public var command: String?
    /// A plugin canvas tool id (from `tools`).
    public var tool: String?
}

public struct PluginToolContribution: Codable, Equatable {
    public var id: String
    public var title: String
    public var icon: String?
    /// "stroke" (pts on lift) | "tap" (point) | "rect" (drag rectangle).
    public var input: String
    /// "ink" | "lasso" | "none" (host-drawn preview).
    public var preview: String?
    public var sticky: Bool?
    /// Command invoked with {page, pts, fmt, bbox} | {page, point} | {page, rect}.
    public var command: String
}

public struct PluginPanelContribution: Codable, Equatable {
    public var id: String
    public var title: String
    public var icon: String?
    /// Path of the HTML file inside the plugin folder.
    public var entry: String
    /// A `PanelPlacement` raw value (default "floating").
    public var placement: String?
}

public struct PluginTemplateContribution: Codable, Equatable {
    public var id: String
    public var title: String
    public var category: String?
    /// "spec" (DisplayList with $param substitution) | "pdf" (file in the plugin folder).
    public var kind: String
    public var isCover: Bool?
    /// {"name": {"type": "number|color|choice|bool", "default": …, "choices": […]}}
    public var params: JSONValue?
    /// {"paper": "#FFFFFF", "ops": [DisplayOp…]} for kind "spec".
    public var spec: JSONValue?
    public var file: String?
    public var size: PageSize?
}

public struct PluginKeybinding: Codable, Equatable {
    /// e.g. "cmd+shift+f", "alt+1".
    public var key: String
    public var command: String
    public var title: String?
}

public struct PluginAIAction: Codable, Equatable {
    public var title: String
    public var prompt: String
    /// An `AIScopeKind` raw value (default "selection").
    public var scope: String?
    /// "ask" | "edit" (default "ask").
    public var mode: String?
    public var icon: String?
}

public struct PluginAIGuidance: Codable, Equatable {
    /// ≤ 1,000 characters appended to the AI system prompt while the plugin is enabled.
    public var instructions: String?
}

public struct PluginFileHandler: Codable, Equatable {
    public var extensions: [String]
    public var command: String
    public var title: String?
}

public struct PluginItemType: Codable, Equatable {
    /// Custom item `type`; items are `custom` items with `owner` = plugin id.
    public var type: String
    public var title: String
    /// Command called with {ref} when the item is double-tapped (optional).
    public var edit: String?
    /// JSON Schema of `data` fields shown as an inspector form (writes go through `item.update`).
    public var inspector: JSONValue?
    /// Dot path inside `data` holding the item's text; indexed by search and returned by `recognize.pageText`.
    public var textPath: String?
}

/// Offers finger taps / double-taps / long-presses to a plugin command before the active tool
/// (→ `TapHandlerDescriptor`). The command gets {page, point, ref?, gesture} and returns {handled}.
public struct PluginTapHandler: Codable, Equatable {
    /// "tap" | "doubleTap" | "longPress".
    public var gesture: String
    public var command: String
    /// Only when the topmost item under the point is one of these kinds / custom types of this plugin.
    public var itemKinds: [String]?
    public var itemTypes: [String]?
}

/// An options bar for a plugin canvas tool: a form over some of the plugin's `settings` keys.
public struct PluginToolOptions: Codable, Equatable {
    public var tool: String
    public var settings: [String]
}

/// A text-document block kind (`BlockKind.custom` with `CustomBlock.type`), offered in the slash menu and Turn Into.
public struct PluginBlockContribution: Codable, Equatable {
    public var type: String
    public var title: String
    public var icon: String?
    public var height: Double?
    /// Called with {doc, after?} to insert the block, and with {ref} when the block is tapped for editing.
    public var command: String
    public var aliases: [String]?
}

/// A stroke processor: the command runs once per finished stroke with {page, stroke} and may return {stroke} or
/// {drop: true}. 50 ms budget; on timeout or error the raw stroke is kept.
public struct PluginStrokeProcessor: Codable, Equatable {
    public var id: String
    public var command: String
    /// Tool ids it applies to (default: pen, pencil, highlighter).
    public var tools: [String]?
}

/// An action users can bind to Apple Pencil double-tap or squeeze (Pencil settings).
public struct PluginPencilAction: Codable, Equatable {
    /// "doubleTap" | "squeeze".
    public var gesture: String
    public var command: String
    public var title: String
}

/// A before-command hook (→ `CommandHookDescriptor`); the hook command must have effect "read".
public struct PluginCommandHook: Codable, Equatable {
    /// Command ids or namespace wildcards ("page.*").
    public var commands: [String]
    public var command: String
}

/// A sticker/element collection: fragment JSON files (clipboard fragment format) inside the plugin folder.
public struct PluginElementCollection: Codable, Equatable {
    public var id: String
    public var title: String
    public var files: [String]
}

/// A tape pattern tile (PNG, ~100 px) inside the plugin folder.
public struct PluginTapePattern: Codable, Equatable {
    public var id: String
    public var title: String
    public var file: String
}

/// A whiteboard framework for `board.insertTemplate`: `diagram` = diagram.create params without `page`, or `file` =
/// a fragment JSON file.
public struct PluginBoardTemplate: Codable, Equatable {
    public var id: String
    public var title: String
    public var icon: String?
    public var diagram: JSONValue?
    public var file: String?
}

public struct PluginContributions: Codable, Equatable {
    public var commands: [PluginCommandContribution]?
    public var menus: [PluginMenuContribution]?
    public var toolbar: [PluginToolbarContribution]?
    public var tools: [PluginToolContribution]?
    public var toolOptions: [PluginToolOptions]?
    public var panels: [PluginPanelContribution]?
    /// Papers and covers (`isCover: true`).
    public var templates: [PluginTemplateContribution]?
    public var keybindings: [PluginKeybinding]?
    /// JSON Schema object; values stored as settings "plugin.<id>.<key>".
    public var settings: JSONValue?
    public var aiActions: [PluginAIAction]?
    public var ai: PluginAIGuidance?
    public var importers: [PluginFileHandler]?
    public var exporters: [PluginFileHandler]?
    public var itemTypes: [PluginItemType]?
    public var tapHandlers: [PluginTapHandler]?
    public var blocks: [PluginBlockContribution]?
    public var strokeProcessors: [PluginStrokeProcessor]?
    public var pencilActions: [PluginPencilAction]?
    public var commandHooks: [PluginCommandHook]?
    /// Content packs.
    public var elements: [PluginElementCollection]?
    public var tapePatterns: [PluginTapePattern]?
    public var boardTemplates: [PluginBoardTemplate]?
}

public struct PluginManifest: Codable, Equatable {
    /// Reverse-DNS id, e.g. "dev.nib.cards". [a-z0-9.-]
    public var id: String
    public var name: String
    /// Semantic version "1.2.3".
    public var version: String
    /// Plugin API version (currently 1).
    public var api: Int
    public var author: String?
    public var description: String?
    /// Single-file JS bundle, e.g. "main.js".
    public var entry: String
    /// Scope raw values: "document:read", "document:write", "library:read", "library:write", "destructive",
    /// "app", "ai", "network". ("plugins:manage" and "security" are never granted to plugins.)
    public var permissions: [String]
    public var network: PluginNetwork?
    public var contributes: PluginContributions?
    public var homepage: String?
}

public struct PluginInfo: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var version: String
    public var enabled: Bool
    /// Present on disk (e.g. synced from another device) but not yet approved on this device.
    public var needsReview: Bool
    public var permissions: [String]
    public var sha256: String
    public var source: String?

    public init(id: String, name: String, version: String, enabled: Bool, needsReview: Bool, permissions: [String],
                sha256: String, source: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.enabled = enabled
        self.needsReview = needsReview
        self.permissions = permissions
        self.sha256 = sha256
        self.source = source
    }
}

/// A running plugin (JavaScriptCore context).
@MainActor
public protocol PluginRuntimeHandle: AnyObject {
    var manifest: PluginManifest { get }
    /// Recent console output (ring buffer).
    var logs: [String] { get }
    /// Calls a command handler registered by the plugin's JS (`nib.commands.register`).
    func invoke(command: String, params: JSONValue, context: CommandContext) async throws -> JSONValue
    func deliver(_ event: NibEvent)
    /// Delivers a message to the plugin's `nib.events.on("plugin.message")` handlers.
    func postMessage(from panel: String, message: JSONValue)
    /// Developer console: evaluates JS in the plugin context and returns the result as text.
    func evaluate(_ javascript: String) async -> String
    func stop()
}

@MainActor
public protocol PluginRuntimeProviding: AnyObject {
    /// Creates the context, evaluates the prelude and the entry bundle. `folder` = the installed plugin folder.
    func start(_ manifest: PluginManifest, folder: URL) async throws -> PluginRuntimeHandle
}

@MainActor
public protocol PluginHosting: AnyObject {
    var installed: [PluginInfo] { get }
    func handle(_ id: String) -> PluginRuntimeHandle?
    func folder(_ id: String) -> URL?
    /// (Re)loads a plugin from its folder: validates, maps contributions, starts the runtime.
    func load(_ id: String) async throws
    func unload(_ id: String)
    func setEnabled(_ id: String, _ enabled: Bool) async throws
    /// `ai.instructions` of enabled plugins (appended to the AI system prompt).
    var aiInstructions: [String] { get }
}

// MARK: - AI providers (bring your own model)

public enum AIProviderKind: String, Codable, CaseIterable {
    /// Anthropic Messages API.
    case anthropic
    /// OpenAI Chat Completions and compatible servers (OpenAI, OpenRouter, Ollama, LM Studio, vLLM, Groq…).
    case openAICompatible
    /// The user's own endpoint speaking the Nib Agent Protocol (docs/AI.md §3).
    case nibHTTP
}

public struct AIProviderConfig: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: AIProviderKind
    public var baseURL: URL
    public var model: String
    /// Non-secret headers (e.g. OpenRouter HTTP-Referer / X-Title).
    public var extraHeaders: [String: String]
    public var supportsVision: Bool
    public var supportsTools: Bool
    public var contextTokens: Int?
    public var maxOutputTokens: Int
    /// Optional OpenAI-compatible audio transcription model (e.g. "whisper-1").
    public var transcriptionModel: String?
    /// Optional image generation model (e.g. "gpt-image-1").
    public var imageModel: String?

    public init(id: UUID = UUID(), name: String, kind: AIProviderKind, baseURL: URL, model: String,
                extraHeaders: [String: String] = [:], supportsVision: Bool = true, supportsTools: Bool = true,
                contextTokens: Int? = nil, maxOutputTokens: Int = 4096, transcriptionModel: String? = nil, imageModel: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.extraHeaders = extraHeaders
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
        self.contextTokens = contextTokens
        self.maxOutputTokens = maxOutputTokens
        self.transcriptionModel = transcriptionModel
        self.imageModel = imageModel
    }

    /// Keychain location of the API key: service "app.nib.ai", account = id.
    public static let keychainService = "app.nib.ai"
    public var keychainAccount: String { id.uuidString }
}

public enum ChatRole: String, Codable { case user, assistant, tool }

public enum ChatPart: Equatable {
    case text(String)
    case image(data: Data, mime: String)
    case toolCall(id: String, name: String, arguments: JSONValue)
    case toolResult(id: String, parts: [ChatPart], isError: Bool)
}

public struct ChatMessage: Equatable {
    public var role: ChatRole
    public var parts: [ChatPart]
    public init(role: ChatRole, parts: [ChatPart]) {
        self.role = role
        self.parts = parts
    }
}

public struct ToolSpec: Equatable {
    /// [a-zA-Z0-9_-]{1,64}
    public var name: String
    public var description: String
    /// JSON Schema object.
    public var schema: JSONValue
    public init(name: String, description: String, schema: JSONValue) {
        self.name = name
        self.description = description
        self.schema = schema
    }
}

public struct ChatRequest {
    public var model: String
    public var system: String
    public var messages: [ChatMessage]
    public var tools: [ToolSpec]
    public var maxTokens: Int
    public var temperature: Double?
    public init(model: String, system: String, messages: [ChatMessage], tools: [ToolSpec] = [], maxTokens: Int = 4096,
                temperature: Double? = nil) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public enum ChatEvent: Equatable {
    case textDelta(String)
    /// Emitted once the call's arguments are complete.
    case toolCall(id: String, name: String, arguments: JSONValue)
    case usage(input: Int, output: Int)
    case stop(reason: String)
}

/// One wire protocol adapter bound to a config (+ its Keychain secret).
public protocol AIProvider: AnyObject {
    var config: AIProviderConfig { get }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
    func listModels() async throws -> [String]
    /// Throws `NibError(.unsupported)` when the provider has no transcription endpoint.
    func transcribe(audio: URL, language: String?) async throws -> [TranscriptSegment]
    /// Throws `NibError(.unsupported)` when the provider has no image endpoint.
    func generateImage(prompt: String) async throws -> Data
}

@MainActor
public protocol AIProviderStore: AnyObject {
    var configs: [AIProviderConfig] { get }
    var activeID: UUID? { get set }
    /// Saves the config; a non-nil `apiKey` is written to the Keychain ("" deletes it).
    func save(_ config: AIProviderConfig, apiKey: String?) throws
    func delete(_ id: UUID)
    /// nil id = the active provider.
    func provider(_ id: UUID?) -> AIProvider?
}

// MARK: - Collaboration transports

public struct CollabPeer: Codable, Hashable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A message pipe between collaborators (Multipeer on the local network, WebSocket relay over the internet).
@MainActor
public protocol CollabTransport: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var peers: [CollabPeer] { get }
    var maxPeers: Int { get }
    var onMessage: ((CollabPeer, Data) -> Void)? { get set }
    var onPeersChanged: (([CollabPeer]) -> Void)? { get set }
    func host(code: String, displayName: String) async throws
    func join(code: String, displayName: String) async throws
    /// nil = everyone.
    func send(_ data: Data, to peers: [CollabPeer]?) throws
    func leave()
}
```

### `NibKit/Sources/NibContracts/Core/Settings.swift`

```swift
import Foundation
import Security

/// A typed setting. `synced` settings live in the library (travel with the library folder);
/// the rest are per device (UserDefaults). Names starting with "security." can only be changed by the user.
public struct SettingKey<Value: Codable> {
    public let name: String
    public let defaultValue: Value
    public let synced: Bool

    public init(_ name: String, default defaultValue: Value, synced: Bool = false) {
        self.name = name
        self.defaultValue = defaultValue
        self.synced = synced
    }
}

/// Library-level synced settings storage (implemented by the Library Store feature: `.nib-library/prefs.<device>.json`,
/// merged per key by rev). Collections are stored as ONE KEY PER ENTRY ("calendar.notes.<eventId>",
/// "writing.dictionary.<word>", "timer.history.<id>", "text.styles.<name>"; null = removed) so concurrent additions
/// on two devices never overwrite each other.
public protocol SyncedSettingsBackend: AnyObject {
    func value(_ name: String) -> JSONValue?
    func setValue(_ name: String, _ value: JSONValue?)
    /// Every stored name (for prefix enumeration).
    func names() -> [String]
}

/// Metadata of a declared setting: sync routing, `settings.list` / `settings.describe`, validation.
public struct SettingDescriptor {
    /// Full name, or a prefix ending in "." for a family of per-entry keys.
    public let name: String
    public let synced: Bool
    public let summary: String
    public let owner: String
    public let schema: JSONSchema
    public let defaultValue: JSONValue
    /// Only code writes it (e.g. "managed.*"): `settings.set` rejects it for every caller.
    public let readOnly: Bool
    public var isPrefix: Bool { name.hasSuffix(".") }
    /// "security.*": commands may read or change it only as the user.
    public var userOnly: Bool { name.hasPrefix("security.") }
}

/// Thread-safe settings store. Posts `SettingsStore.didChange` with userInfo ["name": String].
/// Every setting is DECLARED at register time (`declare` / `declarePrefix`); `NibApp.init` declares `NibSettings`.
public final class SettingsStore {
    public static let didChange = Notification.Name("NibSettingsDidChange")
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var synced: [String: Bool] = [:]
    private var declared: [String: SettingDescriptor] = [:]
    private var prefixes: [String: SettingDescriptor] = [:]
    private var undeclared = Set<String>()
    public var syncedBackend: SyncedSettingsBackend?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Declarations

    /// Declares a typed setting (call once in `register`). Declared names route to the synced backend even for
    /// untyped callers (AI, plugins, bridge), appear in `settings.list`, and `settings.set` validates against `schema`.
    public func declare<V: Codable>(_ key: SettingKey<V>, summary: String, owner: String,
                                    schema: JSONSchema = .anything(), readOnly: Bool = false) {
        let d = SettingDescriptor(name: key.name, synced: key.synced, summary: summary, owner: owner, schema: schema,
                                  defaultValue: (try? JSONValue.from(key.defaultValue)) ?? .null, readOnly: readOnly)
        lock.lock()
        declared[key.name] = d
        synced[key.name] = key.synced
        lock.unlock()
    }

    /// Declares a family of per-entry keys sharing `prefix` (must end in "."), e.g. "calendar.notes.", "plugin.<id>.".
    public func declarePrefix(_ prefix: String, synced flag: Bool, summary: String, owner: String,
                              schema: JSONSchema = .anything(), readOnly: Bool = false) {
        let d = SettingDescriptor(name: prefix, synced: flag, summary: summary, owner: owner, schema: schema,
                                  defaultValue: .null, readOnly: readOnly)
        lock.lock()
        prefixes[prefix] = d
        lock.unlock()
    }

    /// Exact declaration, else the longest declared prefix.
    public func descriptor(_ name: String) -> SettingDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        if let d = declared[name] { return d }
        return prefixes.values.filter { name.hasPrefix($0.name) }.max { $0.name.count < $1.name.count }
    }

    public var declaredSettings: [SettingDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return (Array(declared.values) + Array(prefixes.values)).sorted { $0.name < $1.name }
    }

    /// Typed keys read or written without a declaration (conformance fails on any).
    public var undeclaredNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return undeclared.sorted()
    }

    /// Stored names starting with `prefix` (synced backend and this device).
    public func names(prefix: String) -> [String] {
        var out = Set(syncedBackend?.names().filter { $0.hasPrefix(prefix) } ?? [])
        let device = "nib.setting."
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(device + prefix) {
            out.insert(String(k.dropFirst(device.count)))
        }
        return out.sorted()
    }

    // MARK: Access

    public func get<V: Codable>(_ key: SettingKey<V>) -> V {
        remember(key.name, synced: key.synced)
        guard let json = raw(key.name, synced: key.synced), let v = try? json.decode(V.self) else { return key.defaultValue }
        return v
    }

    public func set<V: Codable>(_ key: SettingKey<V>, _ value: V) {
        remember(key.name, synced: key.synced)
        guard let json = try? JSONValue.from(value) else { return }
        store(key.name, json, synced: key.synced)
    }

    /// Untyped access (settings.get / settings.set commands, plugin settings "plugin.<id>.<key>").
    public func json(_ name: String) -> JSONValue? {
        raw(name, synced: isSynced(name))
    }

    public func setJSON(_ name: String, _ value: JSONValue?) {
        store(name, value, synced: isSynced(name))
    }

    /// Names seen so far (declared or used).
    public var knownNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return synced.keys.sorted()
    }

    private func remember(_ name: String, synced flag: Bool) {
        let isDeclared = descriptor(name) != nil
        lock.lock()
        synced[name] = flag
        if !isDeclared { undeclared.insert(name) }
        lock.unlock()
    }

    private func isSynced(_ name: String) -> Bool {
        if let d = descriptor(name) { return d.synced }
        lock.lock()
        defer { lock.unlock() }
        return synced[name] ?? false
    }

    private func raw(_ name: String, synced flag: Bool) -> JSONValue? {
        if flag, let backend = syncedBackend { return backend.value(name) }
        guard let s = defaults.string(forKey: "nib.setting." + name) else { return nil }
        return try? JSONValue.parse(s)
    }

    private func store(_ name: String, _ value: JSONValue?, synced flag: Bool) {
        if flag, let backend = syncedBackend {
            backend.setValue(name, value)
        } else if let v = value {
            defaults.set(v.jsonString(), forKey: "nib.setting." + name)
        } else {
            defaults.removeObject(forKey: "nib.setting." + name)
        }
        NotificationCenter.default.post(name: SettingsStore.didChange, object: self, userInfo: ["name": name])
    }
}

/// Settings shared by several features. Feature-private settings use "<featureId>.<name>".
public enum NibSettings {
    public static let authorName = SettingKey("profile.authorName", default: "")
    public static let scrollDirection = SettingKey("editing.scrollDirection", default: ScrollDirection.vertical, synced: true)
    public static let openAsTabs = SettingKey("editing.openAsTabs", default: true, synced: true)
    public static let undoButtonsOnRight = SettingKey("editing.undoOnRight", default: false, synced: true)
    public static let objectTapSelection = SettingKey("editing.objectTapSelection", default: true, synced: true)
    public static let alignObjects = SettingKey("editing.alignObjects", default: true, synced: true)
    public static let snapToGrid = SettingKey("editing.snapToGrid", default: false, synced: true)
    public static let hideStatusBar = SettingKey("editing.hideStatusBar", default: false)
    public static let zoomAutoAdvance = SettingKey("editing.zoomAutoAdvance", default: true, synced: true)
    public static let sidebarOnRight = SettingKey("editing.sidebarOnRight", default: false, synced: true)
    public static let stylusMode = SettingKey("stylus.mode", default: StylusMode.pencilOnly)
    /// 0 = low (recommended), 1 = medium, 2 = high.
    public static let palmSensitivity = SettingKey("stylus.palmSensitivity", default: 0)
    /// 0…7: handedness × wrist angle = hand × 4 + wrist (contracts-v2, pinned). Hand: 0 right, 1 left. Wrist: 0 below
    /// the line, 1 angled, 2 level, 3 hooked. 0 (right hand, wrist below) is the default. Palm rejection (F101) and
    /// Settings (F027) share this layout.
    public static let writingPosture = SettingKey("stylus.posture", default: 0)
    public static let reduceLatency = SettingKey("pen.reduceLatency", default: true, synced: true)
    public static let defaultLanguage = SettingKey("language.default", default: "en-US", synced: true)
    public static let indexHandwriting = SettingKey("search.indexHandwriting", default: true)
    public static let spellcheckNewDocuments = SettingKey("writing.spellcheckNewDocuments", default: false, synced: true)
    public static let mathAssistSuggestions = SettingKey("writing.mathAssist", default: false, synced: true)
    /// Personal dictionary: one synced key per word ("writing.dictionary.<word>" = true; null = removed).
    public static let dictionaryPrefix = "writing.dictionary."
    public static func dictionaryWord(_ word: String) -> SettingKey<Bool> {
        SettingKey(dictionaryPrefix + word.lowercased(), default: false, synced: true)
    }
    public static let aiConfirmationPolicy = SettingKey("security.ai.confirmationPolicy", default: ConfirmationPolicy.destructive)
    public static let bridgeConfirmationPolicy = SettingKey("security.bridge.confirmationPolicy", default: ConfirmationPolicy.destructive)
    /// Expose plugin commands that opted out with `ai: false` / `bridge: false` anyway (user only).
    public static let exposeHiddenPluginCommands = SettingKey("security.plugins.exposeHiddenCommands", default: false)
    public static let pluginGalleries = SettingKey("plugins.galleries", default: [String](), synced: true)
    public static let experimental = SettingKey("advanced.experimental", default: [String: Bool]())
    public static let defaultPaper = SettingKey("templates.defaultPaper", default: TemplateRef("builtin.ruled"), synced: true)
    public static let defaultCover = SettingKey("templates.defaultCover", default: TemplateRef("cover.solid"), synced: true)
    public static let defaultPageSize = SettingKey("templates.defaultSize", default: PageSize.a4, synced: true)
    public static let coverByDefault = SettingKey("templates.coverByDefault", default: true, synced: true)

    // contracts-v2

    /// Settings › Appearance › Liquid: "full" | "calm" | "off" (NibDesign's `NibLiquidMode` raw values). Every droplet
    /// container reads it (the document chrome, the toolbar palette, the library). Device-local.
    public static let liquidMode = SettingKey("appearance.liquid", default: "full")
    /// Style of new text boxes (F026 "Save as Default"); paste-and-match-style (F014) and page text (F028) use it.
    public static let defaultTextStyle = SettingKey("text.defaultStyle", default: TextBoxStyle(), synced: true)
    /// Draw and Hold: a held pen or pencil stroke snaps to a shape (F007 reads it, F030 owns the behaviour).
    public static let drawAndHold = SettingKey("shapes.drawAndHold", default: true, synced: true)
    /// Name of the AI direct-tools setting (owned and declared by the AI Agent, F084): [command id]. Unset =
    /// `defaultAIDirectTools`. The bridge (F090) reads it untyped.
    public static let aiDirectToolsName = "ai.directTools"
    /// AI.md §4: commands offered to models as their own tools besides the meta-tools.
    public static let defaultAIDirectTools = ["ink.writeText", "ink.setPoints", "text.createBox", "item.update",
                                              "item.delete", "page.add", "shape.create", "diagram.create"]

    /// Eraser settings owned by F010, read by the Zoom Window pane (F038) and the Pencil hover preview (F043).
    /// Mode: "precision" | "standard" | "stroke".
    public static let eraserMode = SettingKey("eraser.mode", default: "standard", synced: true)
    /// Eraser diameter in SCREEN points (2…60).
    public static let eraserSize = SettingKey("eraser.size", default: 14.0, synced: true)
    /// Erase Filter: whether the eraser erases strokes drawn with `tool` (one key per ink tool).
    public static func eraserFilter(_ tool: InkTool) -> SettingKey<Bool> {
        SettingKey("eraser.filter." + tool.rawValue, default: true, synced: true)
    }

    /// Dynamic Ink: the pen reacts to Apple Pencil Pro barrel roll (F007 owns it; F043 offers the toggle).
    public static let penReactsToRoll = SettingKey("pen.reactToRoll", default: true, synced: true)
    /// The toolbar palette's layout (F016 owns it; F043's palette and plugins read it). nil = default layout.
    public static let toolbarLayout = SettingKey<ToolbarLayoutSetting?>("toolbar.layout", default: nil, synced: true)

    public static let presetTools = ["pen", "pencil", "highlighter", "tape", "shape", "drawShape"]

    /// Color / thickness presets of a writing tool (`presetTools`).
    public static func presets(_ tool: String) -> SettingKey<ToolPresets> {
        SettingKey("presets." + tool, default: ToolPresets.defaults(for: tool), synced: true)
    }

    /// Declares every shared setting (called by `NibApp.init`; owner "builtin").
    public static func declareAll(_ s: SettingsStore) {
        let bool = JSONSchema.bool()
        s.declare(authorName, summary: "Author name shown on sticky notes, comments and collaboration.", owner: "builtin", schema: .str())
        s.declare(scrollDirection, summary: "Default page scrolling for new documents.", owner: "builtin",
                  schema: .str(choices: ScrollDirection.allCases.map { $0.rawValue }))
        s.declare(openAsTabs, summary: "Open documents as tabs instead of replacing the current one.", owner: "builtin", schema: bool)
        s.declare(undoButtonsOnRight, summary: "Show undo/redo on the right of the toolbar.", owner: "builtin", schema: bool)
        s.declare(objectTapSelection, summary: "Finger tap selects objects (quick selection).", owner: "builtin", schema: bool)
        s.declare(alignObjects, summary: "Show alignment guides while moving objects.", owner: "builtin", schema: bool)
        s.declare(snapToGrid, summary: "Snap moved objects to the template grid.", owner: "builtin", schema: bool)
        s.declare(hideStatusBar, summary: "Hide the iOS status bar in documents.", owner: "builtin", schema: bool)
        s.declare(zoomAutoAdvance, summary: "Zoom Window advances automatically.", owner: "builtin", schema: bool)
        s.declare(sidebarOnRight, summary: "Show the document sidebar on the right.", owner: "builtin", schema: bool)
        s.declare(stylusMode, summary: "pencilOnly = fingers scroll; anyInput = fingers draw.", owner: "builtin",
                  schema: .str(choices: StylusMode.allCases.map { $0.rawValue }))
        s.declare(palmSensitivity, summary: "Palm rejection sensitivity 0 low, 1 medium, 2 high.", owner: "builtin", schema: .int(min: 0, max: 2))
        s.declare(writingPosture, summary: "Writing posture 0…7 (handedness × wrist angle).", owner: "builtin", schema: .int(min: 0, max: 7))
        s.declare(reduceLatency, summary: "Use predicted touches for lower ink latency.", owner: "builtin", schema: bool)
        s.declare(defaultLanguage, summary: "Default handwriting recognition language (BCP-47).", owner: "builtin", schema: .str())
        s.declare(indexHandwriting, summary: "Index handwriting for search on this device.", owner: "builtin", schema: bool)
        s.declare(spellcheckNewDocuments, summary: "Turn on handwriting spellcheck for new documents.", owner: "builtin", schema: bool)
        s.declare(mathAssistSuggestions, summary: "Offer Math Assist answers for handwritten equations.", owner: "builtin", schema: bool)
        s.declarePrefix(dictionaryPrefix, synced: true, summary: "Personal dictionary words (true = in dictionary).",
                        owner: "builtin", schema: bool)
        s.declare(aiConfirmationPolicy, summary: "When AI actions need confirmation (user only).", owner: "builtin",
                  schema: .str(choices: ConfirmationPolicy.allCases.map { $0.rawValue }))
        s.declare(bridgeConfirmationPolicy, summary: "When bridge actions need confirmation (user only).", owner: "builtin",
                  schema: .str(choices: ConfirmationPolicy.allCases.map { $0.rawValue }))
        s.declare(exposeHiddenPluginCommands, summary: "Expose plugin commands marked ai:false/bridge:false (user only).",
                  owner: "builtin", schema: bool)
        s.declare(pluginGalleries, summary: "Gallery index URLs for plugins and content packs.", owner: "builtin", schema: .arr(.str()))
        s.declare(experimental, summary: "Experimental feature toggles.", owner: "builtin")
        s.declare(defaultPaper, summary: "Default paper template {id, params}.", owner: "builtin")
        s.declare(defaultCover, summary: "Default cover template {id, params}.", owner: "builtin")
        s.declare(defaultPageSize, summary: "Default page size {width, height} in points.", owner: "builtin")
        s.declare(coverByDefault, summary: "New notebooks get a cover page.", owner: "builtin", schema: bool)
        for tool in presetTools {
            s.declare(presets(tool), summary: "Colour and thickness presets of the \(tool) tool.", owner: "builtin")
        }
        s.declarePrefix("managed.", synced: false, summary: "Managed App Configuration values (read-only).",
                        owner: "builtin", readOnly: true)
        s.declare(liquidMode, summary: "Liquid chrome: full, calm (half stretch, no necks) or off (solid, no motion).",
                  owner: "builtin", schema: .str(choices: ["full", "calm", "off"]))
        s.declare(defaultTextStyle, summary: "Style of new text boxes: TextBoxStyle fields, optionally align and lineSpacing.",
                  owner: "builtin", schema: .anything("TextBoxStyle object"))
        s.declare(drawAndHold, summary: "Hold the pen still at the end of a stroke to snap it to a shape.", owner: "builtin",
                  schema: bool)
        s.declare(eraserMode, summary: "Eraser mode: precision, standard or stroke.", owner: "builtin",
                  schema: .str(choices: ["precision", "standard", "stroke"]))
        s.declare(eraserSize, summary: "Eraser diameter in screen points.", owner: "builtin", schema: .num(min: 2, max: 60))
        s.declare(penReactsToRoll, summary: "The pen nib turns with Apple Pencil Pro barrel roll.", owner: "builtin", schema: bool)
        s.declare(toolbarLayout, summary: "Toolbar layout {order: [id], hidden: [id]} (tool or item ids); null = default.",
                  owner: "builtin", schema: .obj(["order": .arr(.str()), "hidden": .arr(.str())]))
        for tool in InkTool.allCases {
            s.declare(eraserFilter(tool), summary: "The eraser erases \(tool.rawValue) strokes.", owner: "builtin", schema: bool)
        }
    }
}

/// contracts-v2: the value of `NibSettings.toolbarLayout` (F016 writes it through `toolbar.*` commands). Ids are toolbar
/// descriptor ids or tool ids; items the layout never mentions follow the defaults.
public struct ToolbarLayoutSetting: Codable, Equatable {
    public var order: [String]
    public var hidden: [String]

    public init(order: [String] = [], hidden: [String] = []) {
        self.order = order
        self.hidden = hidden
    }

    enum CodingKeys: String, CodingKey { case order, hidden }

    /// Lenient: both lists default to empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        hidden = try c.decodeIfPresent([String].self, forKey: .hidden) ?? []
    }
}

// MARK: - Keychain

/// Where `Keychain` keeps secrets. Swappable because hostless package tests have no entitlements (SecItemAdd fails
/// with -34018); `Harness` installs NibTesting's `InMemorySecretStore`.
public protocol SecretStore: AnyObject {
    func set(_ data: Data?, service: String, account: String) -> Bool
    func get(service: String, account: String) -> Data?
}

/// The system Keychain (generic passwords, this device only).
public final class SystemKeychainStore: SecretStore {
    public init() {}

    public func set(_ data: Data?, service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard let data = data else { return true }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public func get(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}

/// Secrets (API keys, WebDAV passwords, bridge token). Device-only, never synced, never exposed to plugins or AI.
/// Re-signing with another team changes the Keychain access group: features that find a secret missing show
/// "credentials missing — re-enter" instead of failing silently.
public enum Keychain {
    public static var store: SecretStore = SystemKeychainStore()

    @discardableResult
    public static func set(_ data: Data?, service: String, account: String) -> Bool {
        store.set(data, service: service, account: account)
    }

    public static func get(service: String, account: String) -> Data? {
        store.get(service: service, account: account)
    }

    @discardableResult
    public static func setString(_ value: String?, service: String, account: String) -> Bool {
        set(value.map { Data($0.utf8) }, service: service, account: account)
    }

    public static func getString(service: String, account: String) -> String? {
        get(service: service, account: account).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Stable random per-install device id (HLC tiebreaker, per-device package files). Mirrored to
/// Application Support/Nib/device-id, which wins over the Keychain: a re-signed build (new Keychain access group)
/// or a failing Keychain keeps the same id instead of starting a new set of per-device files every launch.
public enum DeviceIdentity {
    private static var cached: UInt32?

    static var mirrorURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nib/device-id")
    }

    public static var current: UInt32 {
        if let c = cached { return c }
        func decode(_ d: Data?) -> UInt32? {
            guard let d = d, d.count == 4 else { return nil }
            return d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        let mirrored = decode(mirrorURL.flatMap { try? Data(contentsOf: $0) })
        let stored = decode(Keychain.get(service: "app.nib.device", account: "id"))
        let value = mirrored ?? stored ?? UInt32.random(in: 1...UInt32.max)
        var le = value
        let data = Data(bytes: &le, count: 4)
        if stored != value { Keychain.set(data, service: "app.nib.device", account: "id") }
        if mirrored == nil, let url = mirrorURL {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        cached = value
        return value
    }

    /// 8 lowercase hex characters, used in package file names ("doc.<hex>.json").
    public static var hex: String { String(format: "%08x", current) }
}

/// Optional App Group container — a progressive enhancement, never required. AltStore/SideStore register app
/// groups even for free Apple IDs and list the rewritten ids in Info.plist "ALTAppGroups"; "NibAppGroups" lists the
/// ids the build asked for. nil when no group is usable: callers fall back (static widgets, pasteboard hand-off).
public enum AppGroup {
    public static var containerURL: URL? {
        let info = Bundle.main.infoDictionary ?? [:]
        let ids = ((info["ALTAppGroups"] as? [String]) ?? []) + ((info["NibAppGroups"] as? [String]) ?? [])
        for id in ids {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) { return url }
        }
        return nil
    }
}
```

### `NibKit/Sources/NibContracts/Core/Registries.swift`

```swift
import Foundation
import CoreGraphics
import BackgroundTasks

/// Anything registered by a feature or plugin. `owner` = feature id or plugin id (used to unregister).
public protocol Registrable {
    var id: String { get }
    var order: Int { get }
    var owner: String { get }
}

/// Thread-safe ordered registry keyed by id (re-registering an id replaces it). Posts `.nibRegistryDidChange`.
/// contracts-v2: the notification's userInfo says what changed (`RegistryChange` keys), and `generation` counts changes,
/// so observers (tile caches, thumbnails) can drop only what an id change affects.
public final class Registry<D: Registrable> {
    private var items: [D] = []
    private var changes: UInt64 = 0
    private let lock = NSLock()

    public init() {}

    /// Sorted by (order, id).
    public var all: [D] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    /// contracts-v2: incremented on every register / unregister.
    public var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return changes
    }

    public func register(_ d: D) {
        lock.lock()
        let replaced = items.contains { $0.id == d.id }
        items.removeAll { $0.id == d.id }
        items.append(d)
        items.sort { ($0.order, $0.id) < ($1.order, $1.id) }
        changes &+= 1
        let g = changes
        lock.unlock()
        post([d.id], owner: d.owner, kind: replaced ? RegistryChange.replaced : RegistryChange.registered, generation: g)
    }

    public func unregister(id: String) {
        lock.lock()
        let owner = items.first { $0.id == id }?.owner
        items.removeAll { $0.id == id }
        changes &+= 1
        let g = changes
        lock.unlock()
        post([id], owner: owner, kind: RegistryChange.unregistered, generation: g)
    }

    public func unregister(owner: String) {
        lock.lock()
        let ids = items.filter { $0.owner == owner }.map { $0.id }
        items.removeAll { $0.owner == owner }
        changes &+= 1
        let g = changes
        lock.unlock()
        post(ids, owner: owner, kind: RegistryChange.unregistered, generation: g)
    }

    public func get(_ id: String) -> D? {
        lock.lock()
        defer { lock.unlock() }
        return items.first { $0.id == id }
    }

    private func post(_ ids: [String], owner: String?, kind: String, generation: UInt64) {
        var info: [String: Any] = [RegistryChange.idsKey: ids, RegistryChange.kindKey: kind,
                                   RegistryChange.generationKey: generation]
        if let o = owner { info[RegistryChange.ownerKey] = o }
        NotificationCenter.default.post(name: .nibRegistryDidChange, object: self, userInfo: info)
    }
}

/// contracts-v2: userInfo keys of `.nibRegistryDidChange` posted by a `Registry` (command registry posts carry none).
public enum RegistryChange {
    /// [String]: the ids registered, replaced or removed.
    public static let idsKey = "ids"
    /// String: owner of the changed entries (absent when unknown).
    public static let ownerKey = "owner"
    /// String: `registered`, `replaced` or `unregistered`.
    public static let kindKey = "change"
    /// UInt64: the registry's `generation` after the change.
    public static let generationKey = "generation"

    public static let registered = "registered"
    public static let replaced = "replaced"
    public static let unregistered = "unregistered"

    /// The ids a registry notification names ([] for posts without userInfo, e.g. the command registry).
    public static func ids(_ note: Notification) -> [String] {
        note.userInfo?[idsKey] as? [String] ?? []
    }
}

// MARK: - Templates

public struct TemplateParam: Codable, Equatable {
    public var name: String
    public var title: String
    /// "color" | "number" | "choice" | "bool".
    public var kind: String
    public var choices: [String]?
    public var minimum: Double?
    public var maximum: Double?

    public init(name: String, title: String, kind: String, choices: [String]? = nil, minimum: Double? = nil, maximum: Double? = nil) {
        self.name = name
        self.title = title
        self.kind = kind
        self.choices = choices
        self.minimum = minimum
        self.maximum = maximum
    }
}

public struct TemplateRender {
    public var paper: RGBA
    /// Page-coordinate drawing ops (lines, grids, dots, planner boxes, text).
    public var display: DisplayList

    public init(paper: RGBA, display: DisplayList = DisplayList()) {
        self.paper = paper
        self.display = display
    }
}

/// contracts-v2: insets from the page edges (points).
public struct PageInsets: Codable, Hashable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = PageInsets()
}

/// contracts-v2: layout facts a template publishes for other features: snap-to-grid (F012), the full-page text box's
/// writing area (F028), Zoom Window line height, and how its pattern repeats on infinite boards (F004).
public struct TemplateMetrics: Equatable {
    /// Distance between ruled lines, grid lines or dots (points); nil = no regular grid.
    public var spacing: Double?
    /// The writing area inside the page (margins), nil = the whole page.
    public var margins: PageInsets?
    /// The pattern repeats every `repeatPeriod` (points, anchored at page origin 0,0); boards align tiles to it.
    /// nil = not periodic (planners, covers) or unknown.
    public var repeatPeriod: PageSize?

    public init(spacing: Double? = nil, margins: PageInsets? = nil, repeatPeriod: PageSize? = nil) {
        self.spacing = spacing
        self.margins = margins
        self.repeatPeriod = repeatPeriod
    }
}

/// contracts-v2: ids of the built-in templates (the Templates feature, F005, registers them; `PageRecord` defaults to
/// `blank`). Templates are optional: check `content.templates.get(id)` and fall back (whiteboard → notebook paper →
/// blank) when one is missing.
public enum TemplateIDs {
    public static let blank = "builtin.blank"
    public static let dots = "builtin.dots"
    public static let grid = "builtin.grid"
    public static let graph = "builtin.graph"
    public static let isometric = "builtin.isometric"
    public static let ruled = "builtin.ruled"
    public static let ruledNarrow = "builtin.ruledNarrow"
    public static let ruledWide = "builtin.ruledWide"
    public static let cornell = "builtin.cornell"
    public static let legalPad = "builtin.legalPad"
    /// Zoom-adaptive infinite-board backgrounds.
    public static let whiteboardDots = "builtin.whiteboardDots"
    public static let whiteboardGrid = "builtin.whiteboardGrid"
    public static let whiteboardLines = "builtin.whiteboardLines"
}

/// contracts-v2: parameter names shared by the built-in templates (`TemplateRef.params`, `TemplateParam.name`). A
/// template declares the ones it honours in `params`; set a value only when `params` contains that name.
public enum TemplateParamNames {
    /// Paper colour, "#RRGGBB[AA]" (built-ins also accept a preset name such as "yellow").
    public static let paper = "paper"
    /// Rule, grid or dot colour, "#RRGGBB[AA]".
    public static let line = "line"
    /// Pattern pitch in points (read by `TemplateDefinition.metrics(for:size:)`).
    public static let spacing = "spacing"
    /// Writing margin in points, or `true` for 25 mm (read by `metrics(for:size:)`).
    public static let margin = "margin"
    /// Cover colour, "#RRGGBB[AA]".
    public static let color = "color"
}

/// A parametric paper or cover template. Built-ins and plugin templates use the same type.
public struct TemplateDefinition: Registrable {
    public var id: String
    public var title: String
    /// "Essentials", "Writing", "Planners", "Music", "Whiteboard", "Covers", or a plugin category.
    public var category: String
    public var isCover: Bool
    public var order: Int
    public var owner: String
    public var params: [TemplateParam]
    public var defaults: [String: JSONValue]
    public var preferredSize: PageSize?
    /// Default Zoom Window return height (points).
    public var zoomReturnHeight: Double?
    /// Pure and thread-safe (called on render threads). `scale` = pixels per point so grids can adapt to zoom.
    /// Patterns are anchored at the page origin (0, 0). Infinite boards (`PageRecord.size == nil`): the renderer calls
    /// `renderRegion` with each tile's world rect when set, else `render` with `size` = the tile size and draws the
    /// result at a tile origin aligned to `metrics(for:size:).repeatPeriod` (240 pt when nil).
    public var render: (_ params: [String: JSONValue], _ size: PageSize, _ scale: Double) -> TemplateRender
    /// contracts-v2: draws only `region` (page coordinates; world coordinates on boards), so deep zoom on a large page
    /// or board never builds ops for the whole page. Same purity rules as `render`. nil = `render` is used.
    public var renderRegion: ((_ params: [String: JSONValue], _ size: PageSize, _ scale: Double, _ region: Rect) -> TemplateRender)?
    /// contracts-v2: the template's grid spacing, margins and repeat period for `params` and `size` (nil for boards).
    /// Pure and thread-safe. nil = derived from the "spacing" / "margin" params (see `metrics(for:size:)`).
    public var metricsProvider: ((_ params: [String: JSONValue], _ size: PageSize?) -> TemplateMetrics)?

    public init(id: String, title: String, category: String, isCover: Bool = false, order: Int = 0, owner: String,
                params: [TemplateParam] = [], defaults: [String: JSONValue] = [:], preferredSize: PageSize? = nil,
                zoomReturnHeight: Double? = nil,
                render: @escaping (_ params: [String: JSONValue], _ size: PageSize, _ scale: Double) -> TemplateRender) {
        self.id = id
        self.title = title
        self.category = category
        self.isCover = isCover
        self.order = order
        self.owner = owner
        self.params = params
        self.defaults = defaults
        self.preferredSize = preferredSize
        self.zoomReturnHeight = zoomReturnHeight
        self.render = render
    }

    /// contracts-v2: `renderRegion` when the template has one (and a region is given), else `render`.
    public func renderOps(_ params: [String: JSONValue], size: PageSize, scale: Double, region: Rect?) -> TemplateRender {
        if let region = region, let f = renderRegion { return f(params, size, scale, region) }
        return render(params, size, scale)
    }

    /// contracts-v2: the template's metrics for `params` (merged over `defaults`). Without a `metricsProvider`:
    /// `spacing` from a numeric "spacing" param, `margins` from a numeric "margin" param (points on every side) or
    /// `true` (25 mm), `repeatPeriod` = spacing × spacing.
    public func metrics(for params: [String: JSONValue], size: PageSize?) -> TemplateMetrics {
        let p = defaults.merging(params) { _, new in new }
        if let f = metricsProvider { return f(p, size) }
        var m = TemplateMetrics()
        if case let .number(n)? = p[TemplateParamNames.spacing], n > 0 {
            m.spacing = n
            m.repeatPeriod = PageSize(n, n)
        }
        switch p[TemplateParamNames.margin] {
        case .number(let n)?: m.margins = PageInsets(top: n, left: n, bottom: n, right: n)
        case .bool(true)?:
            let mm25 = 25 * 72 / 25.4
            m.margins = PageInsets(top: mm25, left: mm25, bottom: mm25, right: mm25)
        default: break
        }
        return m
    }
}

// MARK: - Item drawing

/// contracts-v2: what a render is for, so drawers can leave out screen-only decorations.
public enum DrawPurpose: String, Codable, CaseIterable {
    /// Canvas tiles and live previews.
    case screen
    /// Page thumbnails (sidebar, library, previews).
    case thumbnail
    /// PDF / image / print export (F066): no pins, handles or screen-only affordances.
    case export
    /// `render.page` for the AI and plugins (marks may be drawn over it).
    case query
}

public struct DrawContext {
    /// Already scaled so that 1 unit = 1 page point; origin = page top-left.
    public let cg: CGContext
    /// Pixels per point.
    public let scale: Double
    public let doc: DocumentID
    public let page: PageID
    /// Dark paper: highlighters switch blend, drawers may lighten dark ink.
    public let darkPaper: Bool
    public let assets: AssetStore?
    /// Note Replay state; nil = draw everything normally.
    public let replay: ReplayState?
    /// contracts-v2: what the render is for (export leaves out comment pins; a collapsed sticky prints expanded when
    /// the exporter asks for it).
    public let purpose: DrawPurpose
    /// contracts-v2: false = leave annotations out (comment pins, link underlines); mirrors `RenderRequest.annotations`.
    public let annotations: Bool
    /// contracts-v2: the paper colour under the item (template paper or background colour), for knock-outs such as
    /// connector labels; nil = unknown (assume white, or black when `darkPaper`).
    public let paper: RGBA?

    public init(cg: CGContext, scale: Double, doc: DocumentID, page: PageID, darkPaper: Bool = false,
                assets: AssetStore? = nil, replay: ReplayState? = nil, purpose: DrawPurpose = .screen,
                annotations: Bool = true, paper: RGBA? = nil) {
        self.cg = cg
        self.scale = scale
        self.doc = doc
        self.page = page
        self.darkPaper = darkPaper
        self.assets = assets
        self.replay = replay
        self.purpose = purpose
        self.annotations = annotations
        self.paper = paper
    }
}

/// Draws one kind of item into a tile, a thumbnail or an export. Must be thread-safe (render threads).
public protocol ItemDrawer: AnyObject {
    func draw(_ item: Item, in context: DrawContext)
    /// contracts-v2: the area that takes taps and lasso hits (page coordinates) when it differs from `Item.bounds`,
    /// e.g. a collapsed sticky note (only its icon), a connector (its route). nil = `Item.bounds`. Default: nil.
    func hitBounds(_ item: Item) -> Rect?
    /// contracts-v2: everything the drawer paints for `item` (page coordinates) when it can reach further than
    /// `Item.bounds` + `NibLimits.drawerMargin` (connector labels and arrowheads, curve bulges, text overflow). The
    /// renderer culls and invalidates tiles with it. nil = `Item.bounds` + margin. Default: nil.
    func paintBounds(_ item: Item) -> Rect?
}

public extension ItemDrawer {
    func hitBounds(_ item: Item) -> Rect? { nil }
    func paintBounds(_ item: Item) -> Rect? { nil }
}

/// Registered under `Item.drawKey` ("shape", "text", "stroke.tape", "custom.<owner>.<type>") or a kind name.
public struct ItemDrawerEntry: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    public var drawer: ItemDrawer

    public init(key: String, owner: String, drawer: ItemDrawer, order: Int = 0) {
        self.id = key
        self.order = order
        self.owner = owner
        self.drawer = drawer
    }
}

// MARK: - Import / export

public struct ImportTarget {
    /// Destination folder for new documents (nil = root / current folder).
    public var folder: FolderID?
    /// Insert pages into this existing document instead of creating one.
    public var document: DocumentID?
    public var position: PagePosition
    public var anchorPage: PageID?
    /// contracts-v2: the file's original name without extension (a download or `tmp:` asset has a generated local name);
    /// importers title new documents from it. Filled by `import.files`.
    public var displayName: String?
    /// contracts-v2: caller-chosen ids for the records the import creates (documents or pages, in creation order;
    /// `import.files {ids}`). Importers honour them like any creating command.
    public var ids: [NibID]?

    public init(folder: FolderID? = nil, document: DocumentID? = nil, position: PagePosition = .end, anchorPage: PageID? = nil,
                displayName: String? = nil, ids: [NibID]? = nil) {
        self.folder = folder
        self.document = document
        self.position = position
        self.anchorPage = anchorPage
        self.displayName = displayName
        self.ids = ids
    }
}

public struct ImporterDescriptor: Registrable {
    public var id: String
    public var title: String
    /// Lowercased, without dot.
    public var fileExtensions: [String]
    public var utTypes: [String]
    public var order: Int
    public var owner: String
    /// Returns the created (or modified) documents.
    public var handler: @MainActor (URL, ImportTarget, CommandContext) async throws -> [DocumentID]

    public init(id: String, title: String, fileExtensions: [String], utTypes: [String] = [], order: Int = 0, owner: String,
                handler: @escaping @MainActor (URL, ImportTarget, CommandContext) async throws -> [DocumentID]) {
        self.id = id
        self.title = title
        self.fileExtensions = fileExtensions
        self.utTypes = utTypes
        self.order = order
        self.owner = owner
        self.handler = handler
    }
}

public struct ExportRequest: Codable {
    public var documents: [DocumentID]
    /// Restrict to these pages (nil = all live pages).
    public var pages: [PageID]?
    /// Exporter-specific options (PDF: {"mode":"editable|flattened","background":true,"annotations":true,...}).
    public var options: JSONValue
    public var fileName: String?

    public init(documents: [DocumentID], pages: [PageID]? = nil, options: JSONValue = [:], fileName: String? = nil) {
        self.documents = documents
        self.pages = pages
        self.options = options
        self.fileName = fileName
    }
}

/// contracts-v2: well-known `ExportRequest.options` keys shared by exporters (F066) and features that add options through a
/// command hook on `export.run` (layers F041).
public enum ExportOptionKeys {
    /// Bool: export only layers visible on this device.
    public static let visibleLayersOnly = "visibleLayersOnly"
    /// {"<documentID>": [layer index]}: the visible layers per document (set by the Layers hook).
    public static let visibleLayers = "visibleLayers"
    /// Bool: draw annotations (comment pins, link marks).
    public static let annotations = "annotations"
    /// Bool: draw page backgrounds (templates, PDFs).
    public static let background = "background"
}

public struct ExporterDescriptor: Registrable {
    public var id: String
    public var title: String
    public var fileExtension: String
    public var utType: String
    public var order: Int
    public var owner: String
    /// contracts-v2: document kinds this exporter applies to (nil = every kind), so Share & Export lists only the ones
    /// that work (e.g. "study.csv" only for study sets).
    public var docKinds: Set<DocumentKind>? = nil
    /// Writes files to a temporary folder and returns their URLs.
    public var handler: @MainActor (ExportRequest, CommandContext) async throws -> [URL]

    public init(id: String, title: String, fileExtension: String, utType: String, order: Int = 0, owner: String,
                handler: @escaping @MainActor (ExportRequest, CommandContext) async throws -> [URL]) {
        self.id = id
        self.title = title
        self.fileExtension = fileExtension
        self.utType = utType
        self.order = order
        self.owner = owner
        self.handler = handler
    }
}

// MARK: - AI quick actions

public struct AIActionDescriptor: Registrable {
    public var id: String
    public var title: String
    /// SF Symbol.
    public var icon: String
    /// Prompt sent to the agent; the scope (selection/page/document) is attached automatically.
    public var prompt: String
    public var scope: AIScopeKind
    public var mode: AIMode
    public var docKinds: Set<DocumentKind>
    public var order: Int
    public var owner: String

    public init(id: String, title: String, icon: String, prompt: String, scope: AIScopeKind, mode: AIMode,
                docKinds: Set<DocumentKind> = Set(DocumentKind.allCases), order: Int = 0, owner: String) {
        self.id = id
        self.title = title
        self.icon = icon
        self.prompt = prompt
        self.scope = scope
        self.mode = mode
        self.docKinds = docKinds
        self.order = order
        self.owner = owner
    }
}

// MARK: - Stroke processors

/// Adjusts a finished stroke before it is committed (stabilization, straight highlighter, ruler projection).
@MainActor
public protocol StrokeProcessor: AnyObject {
    /// Return false to drop the stroke (e.g. it was consumed as a gesture).
    func process(_ stroke: inout Stroke, page: PageID, session: EditorSession) -> Bool
}

public struct StrokeProcessorEntry: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    public var processor: StrokeProcessor

    public init(id: String, order: Int, owner: String, processor: StrokeProcessor) {
        self.id = id
        self.order = order
        self.owner = owner
        self.processor = processor
    }
}

// MARK: - Keyboard

public struct KeyModifiers: OptionSet, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1)
    public static let shift = KeyModifiers(rawValue: 2)
    public static let option = KeyModifiers(rawValue: 4)
    public static let control = KeyModifiers(rawValue: 8)
}

public struct KeyShortcut: Hashable, Codable {
    /// A single character ("p", "2", "["), or "up" | "down" | "left" | "right" | "escape" | "delete" | "tab" | "return" | "space".
    public var key: String
    public var modifiers: KeyModifiers

    public init(_ key: String, _ modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

public enum KeyScope: String, Codable, CaseIterable {
    case global, library, document
    /// Only while no text field is being edited (single-key tool shortcuts).
    case canvas
}

public struct KeyCommandDescriptor: Registrable {
    public var id: String
    /// Shown in the ⌘-hold discoverability overlay.
    public var title: String
    public var shortcut: KeyShortcut
    public var command: String
    public var params: JSONValue
    public var scope: KeyScope
    public var order: Int
    public var owner: String
    /// contracts-v2: only while the key window shows one of these document kinds (nil = any). Honoured by the shell.
    public var docKinds: Set<DocumentKind>? = nil
    /// contracts-v2: params computed from the key window's session when the key is pressed (selection, page, a fresh
    /// id); merged over `params`. Use `resolvedParams(for:)`.
    public var sessionParams: (@MainActor (EditorSession) -> JSONValue)? = nil

    /// contracts-v2: `params` with `sessionParams(session)` merged over them (what the shell passes to the command).
    @MainActor
    public func resolvedParams(for session: EditorSession?) -> JSONValue {
        guard let f = sessionParams, let s = session else { return params }
        return params.merging(f(s))
    }

    public init(id: String, title: String, shortcut: KeyShortcut, command: String, params: JSONValue = [:],
                scope: KeyScope = .document, order: Int = 0, owner: String) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.command = command
        self.params = params
        self.scope = scope
        self.order = order
        self.owner = owner
    }
}

// MARK: - Background tasks

public enum BackgroundTaskKind: String, Codable, CaseIterable { case refresh, processing }

/// A BGTaskScheduler task. Features ONLY fill `content.backgroundTasks` and call `NibApp.scheduleBackgroundTask`;
/// they never call `BGTaskScheduler` directly. The app shell registers every identifier listed in Info.plist
/// `BGTaskSchedulerPermittedIdentifiers` synchronously in `didFinishLaunching` (the only legal moment) and routes
/// each launch to the descriptor with that id (a task without a descriptor is completed immediately).
/// Hostless package tests never touch BGTaskScheduler.
public struct BackgroundTaskDescriptor: Registrable {
    /// The task identifier, e.g. "app.nib.backup" (must be in the Info.plist list).
    public var id: String
    public var kind: BackgroundTaskKind
    public var order: Int
    public var owner: String
    /// Does the work; return true on success. `Task.isCancelled` becomes true when the system expires the task.
    public var handler: @MainActor (BGTask) async -> Bool

    public init(id: String, kind: BackgroundTaskKind, owner: String, order: Int = 0,
                handler: @escaping @MainActor (BGTask) async -> Bool) {
        self.id = id
        self.kind = kind
        self.order = order
        self.owner = owner
        self.handler = handler
    }
}

// MARK: - Canvas gestures routed to commands

public enum CanvasGesture: String, Codable, CaseIterable { case tap, doubleTap, longPress }

/// Offers finger taps / double-taps / long-presses on the canvas to a command BEFORE the active tool (replaces the
/// old fixed tap chain). Lowest `order` first; the first handler whose command returns {"handled": true} wins.
/// The command gets {"page", "point", "ref"?, "gesture"} where `ref` is the topmost live item under the point.
/// Built-ins: tape.tapAt 100, comment.tapAt 200, link.tapAt 300, selection.tapAt 400.
public struct TapHandlerDescriptor: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    public var gesture: CanvasGesture
    /// Offered only when the topmost item under the point has one of these kinds (nil = always).
    public var itemKinds: Set<ItemKind>?
    /// Offered only when the topmost item's `Item.drawKey` is one of these (custom types: "custom.<owner>.<type>").
    public var drawKeys: Set<String>?
    /// Also offered in read-only mode.
    public var worksInReadOnly: Bool
    public var command: String

    public init(id: String, owner: String, gesture: CanvasGesture, command: String, order: Int = 500,
                itemKinds: Set<ItemKind>? = nil, drawKeys: Set<String>? = nil, worksInReadOnly: Bool = false) {
        self.id = id
        self.order = order
        self.owner = owner
        self.gesture = gesture
        self.itemKinds = itemKinds
        self.drawKeys = drawKeys
        self.worksInReadOnly = worksInReadOnly
        self.command = command
    }
}

// MARK: - Content packs, block kinds, custom item types, pencil actions

/// A whiteboard framework inserted by `board.insertTemplate` (built-ins by F044, plugins' `boardTemplates`).
public struct BoardTemplateDescriptor: Registrable {
    public var id: String
    public var title: String
    public var icon: String
    public var order: Int
    public var owner: String
    /// `diagram.create` params without `page`/`origin`, or {"fragment": <clipboard fragment JSON>}.
    public var spec: JSONValue

    public init(id: String, title: String, icon: String = "rectangle.3.group", order: Int = 0, owner: String, spec: JSONValue) {
        self.id = id
        self.title = title
        self.icon = icon
        self.order = order
        self.owner = owner
        self.spec = spec
    }
}

/// A tape pattern tile offered by the tape tool (F033 built-ins and custom images, plugins' `tapePatterns`).
public struct TapePatternDescriptor: Registrable {
    public var id: String
    public var title: String
    public var order: Int
    public var owner: String
    /// PNG tile bytes (thread-safe).
    public var load: () throws -> Data

    public init(id: String, title: String, order: Int = 0, owner: String, load: @escaping () throws -> Data) {
        self.id = id
        self.title = title
        self.order = order
        self.owner = owner
        self.load = load
    }
}

public struct ElementEntry: Codable, Equatable {
    public var id: String
    public var title: String
    /// Clipboard fragment JSON ({format: "nib-fragment/1", items, assets, bounds}).
    public var fragment: JSONValue

    public init(id: String, title: String, fragment: JSONValue) {
        self.id = id
        self.title = title
        self.fragment = fragment
    }
}

/// A read-only element collection contributed by a plugin/content pack (user collections live in F035's store).
public struct ElementCollectionDescriptor: Registrable {
    public var id: String
    public var title: String
    public var order: Int
    public var owner: String
    public var load: () throws -> [ElementEntry]

    public init(id: String, title: String, order: Int = 0, owner: String, load: @escaping () throws -> [ElementEntry]) {
        self.id = id
        self.title = title
        self.order = order
        self.owner = owner
        self.load = load
    }
}

/// One entry of the text-document slash menu and Turn Into menu. F047 registers the built-in kinds and builds both
/// menus from this registry; tables (F048) and plugins' `blocks` add theirs.
public struct BlockKindDescriptor: Registrable {
    public var id: String
    public var title: String
    public var icon: String
    public var order: Int
    public var owner: String
    /// Built-in kind, or `.custom` with `customType` = "<owner>.<type>".
    public var kind: BlockKind
    public var customType: String?
    /// Command that inserts the block ({doc, after?} merged over `params`); nil = plain `block.insert` of `kind`.
    public var command: String?
    public var params: JSONValue
    public var aliases: [String]

    public init(id: String, title: String, icon: String, kind: BlockKind, owner: String, order: Int = 0,
                customType: String? = nil, command: String? = nil, params: JSONValue = [:], aliases: [String] = []) {
        self.id = id
        self.title = title
        self.icon = icon
        self.order = order
        self.owner = owner
        self.kind = kind
        self.customType = customType
        self.command = command
        self.params = params
        self.aliases = aliases
    }
}

/// Describes a custom item type (id = "custom.<owner>.<type>", the item's `drawKey`), so search, recognition,
/// accessibility and the AI can read its text without knowing the owner.
public struct CustomItemTypeDescriptor: Registrable {
    public var id: String
    public var title: String
    public var order: Int
    public var owner: String
    /// Dot path inside `CustomItem.data` holding the item's text (e.g. "title" or "series.label").
    public var textPath: String?
    /// Command called with {ref} to edit the item (double-tap, inspector "Edit").
    public var editCommand: String?

    public init(owner: String, type: String, title: String, textPath: String? = nil, editCommand: String? = nil, order: Int = 0) {
        self.id = "custom." + owner + "." + type
        self.title = title
        self.order = order
        self.owner = owner
        self.textPath = textPath
        self.editCommand = editCommand
    }
}

/// An action users can bind to Apple Pencil double-tap or squeeze (offered by F043's settings). The bound command gets
/// {"gesture": "doubleTap"|"squeeze", "doc": "doc:D", "page"?: "page:D/P", "at"?: [x, y]} with `params` merged over it
/// (the descriptor's params win).
public struct PencilActionDescriptor: Registrable {
    public var id: String
    public var title: String
    public var order: Int
    public var owner: String
    public var gestures: Set<String>
    public var command: String
    public var params: JSONValue

    public init(id: String, title: String, owner: String, command: String, params: JSONValue = [:],
                gestures: Set<String> = ["doubleTap", "squeeze"], order: Int = 0) {
        self.id = id
        self.title = title
        self.order = order
        self.owner = owner
        self.gestures = gestures
        self.command = command
        self.params = params
    }
}

// MARK: - Text layout (contracts-v2)

/// Where an item's text lays out, so link hit-testing (F029), spellcheck (F104), search highlights (F056) and
/// recognition find the same glyphs the drawer draws. TextKit rule for every text-bearing item: `lineFragmentPadding`
/// = `TextLayoutInfo.lineFragmentPadding` (0) and no extra container inset.
public struct TextLayoutInfo: Equatable {
    public static let lineFragmentPadding: Double = 0
    /// The text container in page coordinates: an unrotated box plus rotation about its centre (like `Frame`).
    public var container: Frame
    /// Attributes runs inherit (font size, colour).
    public var base: TextAttributes
    /// True = the text block is centred vertically in the container (shape labels); false = top-aligned.
    public var centredVertically: Bool

    public init(container: Frame, base: TextAttributes = TextAttributes(), centredVertically: Bool = false) {
        self.container = container
        self.base = base
        self.centredVertically = centredVertically
    }
}

/// Published by the feature that draws an item's text (F026 text boxes, F036 sticky notes, F031 shape labels,
/// plugins' custom items), under the item's `drawKey` or kind name. `layout` is pure and thread-safe.
public struct TextLayoutDescriptor: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    public var layout: (Item) -> TextLayoutInfo?

    public init(key: String, owner: String, order: Int = 0, layout: @escaping (Item) -> TextLayoutInfo?) {
        self.id = key
        self.order = order
        self.owner = owner
        self.layout = layout
    }
}

// MARK: - Container

/// Non-UI registries (thread-safe; templates and drawers are read on render threads).
public final class ContentRegistries {
    public let templates = Registry<TemplateDefinition>()
    public let drawers = Registry<ItemDrawerEntry>()
    public let importers = Registry<ImporterDescriptor>()
    public let exporters = Registry<ExporterDescriptor>()
    public let aiActions = Registry<AIActionDescriptor>()
    public let strokeProcessors = Registry<StrokeProcessorEntry>()
    public let keyCommands = Registry<KeyCommandDescriptor>()
    public let backgroundTasks = Registry<BackgroundTaskDescriptor>()
    public let tapHandlers = Registry<TapHandlerDescriptor>()
    public let boardTemplates = Registry<BoardTemplateDescriptor>()
    public let tapePatterns = Registry<TapePatternDescriptor>()
    public let elementCollections = Registry<ElementCollectionDescriptor>()
    public let blockKinds = Registry<BlockKindDescriptor>()
    public let customItemTypes = Registry<CustomItemTypeDescriptor>()
    public let pencilActions = Registry<PencilActionDescriptor>()
    /// contracts-v2: text layout of text-bearing items (see `TextLayoutDescriptor`, `textLayout(for:)`).
    public let textLayouts = Registry<TextLayoutDescriptor>()

    public init() {}

    /// contracts-v2: where `item`'s text lays out: the registered `TextLayoutDescriptor` for its draw key or kind, else
    /// for text boxes the frame inset by `TextBoxStyle.padding` (top-aligned, `style.defaults`); nil for items
    /// without text.
    public func textLayout(for item: Item) -> TextLayoutInfo? {
        if let d = textLayouts.get(item.drawKey) ?? textLayouts.get(item.kind.rawValue) { return d.layout(item) }
        guard item.kind == .text, let t = item.text else { return nil }
        let p = t.style.padding
        let f = t.frame
        return TextLayoutInfo(container: Frame(x: f.x + p, y: f.y + p, w: max(0, f.w - 2 * p), h: max(0, f.h - 2 * p),
                                               rotation: f.rotation),
                              base: t.style.defaults)
    }

    public func drawer(for item: Item) -> ItemDrawer? {
        drawers.get(item.drawKey)?.drawer ?? drawers.get(item.kind.rawValue)?.drawer
    }

    /// contracts-v2: where `item` takes taps and lasso hits: its drawer's `hitBounds`, else `Item.bounds`.
    public func hitBounds(for item: Item) -> Rect {
        drawer(for: item)?.hitBounds(item) ?? item.bounds
    }

    /// contracts-v2: what drawing `item` can touch: its drawer's `paintBounds`, else `Item.bounds` grown by
    /// `NibLimits.drawerMargin`. Tile invalidation uses it for both the before and after value of a change.
    public func paintBounds(for item: Item) -> Rect {
        drawer(for: item)?.paintBounds(item) ?? item.bounds.insetBy(-NibLimits.drawerMargin)
    }

    public func template(_ ref: TemplateRef) -> TemplateDefinition? { templates.get(ref.id) }

    public func importer(forExtension ext: String) -> ImporterDescriptor? {
        let e = ext.lowercased()
        return importers.all.first { $0.fileExtensions.contains(e) }
    }
}
```

### `NibKit/Sources/NibContracts/Core/CoreCommands.swift`

```swift
import Foundation

/// Commands that live in the contracts layer and are registered by `NibApp.init`.
enum CoreCommands {
    @MainActor
    static func register(_ r: CommandRegistry) {
        r.register(EditUndo.self)
        r.register(EditRedo.self)
        r.register(HistoryList.self)
        r.register(HistoryRevertGroup.self)
        r.register(CommandsList.self)
        r.register(CommandsDescribe.self)
        r.register(CommandsBatch.self)
        r.register(ToolSelect.self)
        r.register(SettingsGet.self)
        r.register(SettingsSet.self)
        r.register(SettingsList.self)
        r.register(SettingsDescribe.self)
        r.register(WindowShowLibrary.self)
    }
}

struct DocParams: Codable {
    /// contracts-v2: optional for the user (key commands, toolbar buttons): nil = the invoking window's document.
    /// The schema still requires it, so the AI, plugins and the bridge always name the document.
    var doc: String?
}

struct EditUndo: NibCommand {
    struct Output: Codable {
        var done: Bool
        var label: String?
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.undo, title: "Undo",
        summary: "Undo the last change in a document (same as the Undo button). A whole AI turn or plugin call undoes as one step.",
        params: .obj(["doc": .ref], required: ["doc"]),
        examples: [["doc": "doc:FIXTUREDOC01"]], effect: .edit)

    static func run(_ p: DocParams, _ ctx: CommandContext) async throws -> Output {
        let doc = try ctx.documentOrSession(p.doc)
        let label = ctx.bus.history.undoLabel(doc)
        return Output(done: ctx.bus.undo(doc), label: label)
    }
}

struct EditRedo: NibCommand {
    struct Output: Codable {
        var done: Bool
        var label: String?
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.redo, title: "Redo",
        summary: "Redo the last undone change in a document.",
        params: .obj(["doc": .ref], required: ["doc"]),
        examples: [["doc": "doc:FIXTUREDOC01"]], effect: .edit)

    static func run(_ p: DocParams, _ ctx: CommandContext) async throws -> Output {
        let doc = try ctx.documentOrSession(p.doc)
        let label = ctx.bus.history.redoLabel(doc)
        return Output(done: ctx.bus.redo(doc), label: label)
    }
}

struct HistoryList: NibCommand {
    struct Params: Codable {
        var doc: String
        var limit: Int?
    }
    struct Row: Codable {
        var group: String
        var label: String
        var principal: String
        var changes: Int
        var at: Double
    }
    struct Output: Codable {
        var entries: [Row]
        var canRedo: Bool
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.historyList, title: "History",
        summary: "List undoable changes in a document, newest first, with their undo group ids (for history.revertGroup).",
        params: .obj(["doc": .ref, "limit": .int(min: 1, max: 200)], required: ["doc"]),
        examples: [["doc": "doc:FIXTUREDOC01", "limit": 10]], effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = NodeRef.documentID(from: p.doc)
        let rows = ctx.bus.history.entries(doc).reversed().prefix(p.limit ?? 50).map {
            Row(group: $0.group, label: $0.label, principal: $0.principal.description, changes: $0.mutations.count,
                at: $0.at.timeIntervalSince1970)
        }
        return Output(entries: Array(rows), canRedo: ctx.bus.history.canRedo(doc))
    }
}

struct HistoryRevertGroup: NibCommand {
    struct Params: Codable {
        var doc: String
        var group: String
    }
    struct Output: Codable {
        var reverted: Int
        var skipped: Int
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.revertGroup, title: "Revert Changes",
        summary: "Revert one undo group (e.g. everything an AI turn did) even after later edits; records changed since are skipped.",
        params: .obj(["doc": .ref, "group": .str("undo group id from history.list or an AI turn")], required: ["doc", "group"]),
        examples: [["doc": "doc:FIXTUREDOC01", "group": "G0"]], effect: .edit)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let doc = NodeRef.documentID(from: p.doc)
        guard let r = ctx.bus.revert(group: p.group, doc: doc, principal: ctx.principal) else {
            throw NibError.notFound("undo group '\(p.group)'")
        }
        return Output(reverted: r.reverted, skipped: r.skipped)
    }
}

struct CommandsList: NibCommand {
    struct Params: Codable {
        var namespace: String?
    }
    struct Row: Codable {
        var id: String
        var title: String
        var summary: String
        var effect: String
        var destructive: Bool
    }
    struct Output: Codable {
        var commands: [Row]
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.commandsList, title: "List Commands",
        summary: "List the commands you may call (id, one-line summary, effect). Optional namespace prefix such as 'page' or 'shape'.",
        params: .obj(["namespace": .str("namespace prefix, e.g. 'ink'")]),
        examples: [[:], ["namespace": "edit"]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let exposure = ctx.principal.exposure
        let rows = ctx.bus.registry.all().filter { d in
            let visible = ctx.principal.isUser || d.exposure.contains(exposure)
            let inNamespace = p.namespace.map { d.id == $0 || d.id.hasPrefix($0 + ".") } ?? true
            return visible && inNamespace
        }.map { Row(id: $0.id, title: $0.title, summary: $0.summary, effect: $0.effect.rawValue, destructive: $0.destructive) }
        return Output(commands: rows)
    }
}

struct CommandsDescribe: NibCommand {
    struct Params: Codable {
        var id: String
    }
    struct Output: Codable {
        var id: String
        var title: String
        var summary: String
        var params: JSONValue
        var examples: [JSONValue]
        var effect: String
        var destructive: Bool
        var scopes: [String]
        var owner: String
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.commandsDescribe, title: "Describe Command",
        summary: "Full JSON schema, examples, effect and required permissions of one command.",
        params: .obj(["id": .str("command id, e.g. 'ink.addStrokes'")], required: ["id"]),
        examples: [["id": "edit.undo"]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let d = ctx.bus.registry.descriptor(p.id),
              ctx.principal.isUser || d.exposure.contains(ctx.principal.exposure) else {
            throw NibError(.notFound, "unknown command '\(p.id)'", hint: "call commands.list")
        }
        return Output(id: d.id, title: d.title, summary: d.summary, params: d.params.toJSON(), examples: d.examples,
                      effect: d.effect.rawValue, destructive: d.destructive, scopes: d.scopes.map { $0.rawValue }.sorted(),
                      owner: d.owner)
    }
}

struct CommandsBatch: NibCommand {
    struct Call: Codable {
        var command: String
        var params: JSONValue?
    }
    struct Params: Codable {
        var calls: [Call]
        var stopOnError: Bool?
    }
    struct Outcome: Codable {
        var ok: Bool
        var value: JSONValue?
        var error: NibError?
    }
    struct Output: Codable {
        var results: [Outcome]
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.batch, title: "Batch",
        summary: "Run several commands in order as ONE undo step (each is permission-checked). Give new items your own ids to link them.",
        params: .obj(["calls": .arr(.obj(["command": .str(), "params": .obj([:])], required: ["command"])),
                      "stopOnError": .bool("default true")], required: ["calls"]),
        examples: [["calls": [["command": "commands.list", "params": ["namespace": "edit"]]]]],
        effect: .read, target: .app, forwardsCalls: true)   // effect = the calls' effects: each call is authorized,
                                                            // and in ask mode every call must be `read`

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        var out: [Outcome] = []
        for call in p.calls {
            do {
                let v = try await ctx.execute(call.command, call.params ?? [:])
                out.append(Outcome(ok: true, value: v, error: nil))
            } catch {
                out.append(Outcome(ok: false, value: nil, error: NibError.wrap(error)))
                if p.stopOnError ?? true { break }
            }
        }
        return Output(results: out)
    }
}

struct ToolSelect: NibCommand {
    struct Params: Codable {
        var tool: String
        /// contracts-v2: true = until the tool finishes one use or `EditorSession.endTemporaryTool()`, then back.
        var temporary: Bool?
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.toolSelect, title: "Select Tool",
        summary: "Activate a canvas tool in the current window: pen, pencil, highlighter, eraser, lasso, shape, text, tape, laser, or a plugin tool id.",
        params: .obj(["tool": .str("tool id"),
                      "temporary": .bool("true = return to the current tool after one use")], required: ["tool"]),
        examples: [["tool": "pen"], ["tool": "lasso", "temporary": true]], effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard let session = ctx.activeSession else { throw NibError.unavailable("an open editor window") }
        if p.temporary == true {
            session.selectTemporarily(p.tool)
        } else {
            session.selectTool(p.tool)
        }
        return NoResult()
    }
}

/// contracts-v2: shows the library in the invoking window (the document chrome's Back button, the tab strip's Library
/// button, the AI and plugins).
struct WindowShowLibrary: NibCommand {
    struct Params: Codable {
        var folder: String?
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.windowShowLibrary, title: "Show Library",
        summary: "Show the library in the current window, optionally opened at a folder ('folder:F' or a folder id).",
        params: .obj(["folder": .str("folder ref folder:F or folder id; omit for the library root")]),
        examples: [[:], ["folder": "folder:FIXTUREFLD01"]], effect: .session, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard let navigator = ctx.navigator else { throw NibError.unavailable("a window") }
        var folder: FolderID?
        if let f = p.folder, !f.isEmpty, f != "lib" {
            if case let .folder(id)? = NodeRef(f) {
                folder = id
            } else if NibID.isValid(f) {
                folder = NibID(f)
            } else {
                throw NibError.invalid("'folder' must be a folder ref like folder:F", path: "$.folder")
            }
        }
        navigator.showLibrary(folder: folder)
        return NoResult()
    }
}

struct SettingsGet: NibCommand {
    struct Params: Codable {
        var name: String
    }
    struct Output: Codable {
        var name: String
        var value: JSONValue?
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.settingsGet, title: "Get Setting",
        summary: "Read a setting by name, e.g. 'editing.scrollDirection' or 'plugin.<id>.<key>' (see settings.list).",
        params: .obj(["name": .str()], required: ["name"]),
        examples: [["name": "editing.scrollDirection"]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        if p.name.hasPrefix("security.") && !ctx.principal.isUser {
            throw NibError(.permissionDenied, "security settings can only be read by the user")
        }
        return Output(name: p.name, value: ctx.services.settings.json(p.name))
    }
}

struct SettingsSet: NibCommand {
    struct Params: Codable {
        var name: String
        var value: JSONValue?
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.settingsSet, title: "Change Setting",
        summary: "Change a declared setting (null resets it); the value is validated. 'security.*' is user-only, 'managed.*' read-only.",
        params: .obj(["name": .str(), "value": .anything("new value; null resets to default")], required: ["name"]),
        examples: [["name": "editing.scrollDirection", "value": "horizontal"]], effect: .edit, target: .app,
        undoable: false)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> NoResult {
        guard let d = ctx.services.settings.descriptor(p.name) else {
            throw NibError(.notFound, "unknown setting '\(p.name)'", hint: "call settings.list to see setting names")
        }
        if d.userOnly && !ctx.principal.isUser {
            throw NibError(.permissionDenied, "security settings can only be changed by the user")
        }
        if d.readOnly { throw NibError(.permissionDenied, "'\(p.name)' is read-only (managed configuration)") }
        if let v = p.value, v != .null, let e = d.schema.validate(v, path: "$.value").first {
            throw NibError(e.code, e.message, path: e.path, hint: "call settings.describe {\"name\": \"\(p.name)\"}")
        }
        ctx.services.settings.setJSON(p.name, p.value)
        return NoResult()
    }
}

struct SettingsList: NibCommand {
    struct Params: Codable {
        var prefix: String?
    }
    struct Row: Codable {
        var name: String
        var summary: String
        var synced: Bool
        var owner: String
    }
    struct Output: Codable {
        var settings: [Row]
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.settingsList, title: "List Settings",
        summary: "List declared settings (name, summary, synced, owner), optionally under a name prefix like 'editing.'.",
        params: .obj(["prefix": .str("name prefix, e.g. 'editing.'")]),
        examples: [[:], ["prefix": "editing."]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let rows = ctx.services.settings.declaredSettings
            .filter { p.prefix.map($0.name.hasPrefix) ?? true }
            .filter { ctx.principal.isUser || !$0.userOnly }
            .map { Row(name: $0.name, summary: $0.summary, synced: $0.synced, owner: $0.owner) }
        return Output(settings: rows)
    }
}

struct SettingsDescribe: NibCommand {
    struct Params: Codable {
        var name: String
    }
    struct Output: Codable {
        var name: String
        var summary: String
        var schema: JSONValue
        var defaultValue: JSONValue
        var synced: Bool
        var readOnly: Bool
        var userOnly: Bool
    }
    static let descriptor = CommandDescriptor(
        id: CommandIDs.settingsDescribe, title: "Describe Setting",
        summary: "Schema, default value and flags of one setting (or of the family a per-entry name belongs to).",
        params: .obj(["name": .str()], required: ["name"]),
        examples: [["name": "editing.scrollDirection"]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        guard let d = ctx.services.settings.descriptor(p.name) else {
            throw NibError(.notFound, "unknown setting '\(p.name)'", hint: "call settings.list")
        }
        return Output(name: d.name, summary: d.summary, schema: d.schema.toJSON(), defaultValue: d.defaultValue,
                      synced: d.synced, readOnly: d.readOnly, userOnly: d.userOnly)
    }
}
```

### `NibKit/Sources/NibContracts/UI/UIBridges.swift`

```swift
import UIKit
import PencilKit

// MARK: - CoreGraphics / UIKit conversions

public extension Point {
    init(_ p: CGPoint) { self.init(Double(p.x), Double(p.y)) }
    var cg: CGPoint { CGPoint(x: x, y: y) }
}

public extension Rect {
    init(_ r: CGRect) { self.init(x: Double(r.origin.x), y: Double(r.origin.y), width: Double(r.size.width), height: Double(r.size.height)) }
    var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public extension Affine {
    init(_ t: CGAffineTransform) {
        self.init(a: Double(t.a), b: Double(t.b), c: Double(t.c), d: Double(t.d), tx: Double(t.tx), ty: Double(t.ty))
    }
    var cg: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
}

public extension RGBA {
    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if !color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var white: CGFloat = 0
            _ = color.getWhite(&white, alpha: &a)
            r = white
            g = white
            b = white
        }
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(byte(r), byte(g), byte(b), byte(a))
    }

    var uiColor: UIColor {
        UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    var cgColor: CGColor { uiColor.cgColor }
}

// MARK: - PencilKit bridge

/// Converts between the platform-neutral `Stroke` model and PencilKit. Used by the canvas (wet ink capture),
/// the renderer (drawing strokes with PencilKit's ink look) and anything that needs `PKDrawing`s.
public enum PKBridge {
    public static func inkType(_ style: InkStyle) -> PKInk.InkType {
        switch style.tool {
        case .pencil: return .pencil
        case .highlighter: return .marker
        case .tape: return .monoline
        case .pen:
            switch style.pen ?? .fountain {
            case .fountain: return .fountainPen
            case .ball: return .monoline
            case .brush: return .pen
            }
        }
    }

    public static func ink(_ style: InkStyle) -> PKInk {
        PKInk(inkType(style), color: style.color.uiColor)
    }

    public static func pkStroke(_ stroke: Stroke) -> PKStroke {
        var s = stroke
        InkModel.prepare(&s)                       // densifies synthetic (zero-width) strokes; no-op for captured ink
        var pts = s.points
        InkModel.fillSizes(&pts, style: s.style)
        let controls = pts.map { p in
            PKStrokePoint(location: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)),
                          timeOffset: TimeInterval(p.t),
                          size: CGSize(width: CGFloat(p.width), height: CGFloat(p.height)),
                          opacity: CGFloat(p.opacity),
                          force: CGFloat(p.force),
                          azimuth: CGFloat(p.azimuth),
                          altitude: CGFloat(p.altitude))
        }
        let path = PKStrokePath(controlPoints: controls, creationDate: Date(timeIntervalSince1970: stroke.t0))
        return PKStroke(ink: ink(stroke.style), path: path)
    }

    public static func drawing(_ strokes: [Stroke]) -> PKDrawing {
        PKDrawing(strokes: strokes.map { pkStroke($0) })
    }

    /// Converts a captured PencilKit stroke (canvas coordinates == page coordinates) into the model.
    /// `rolls` are barrel-roll samples (time offset in seconds, radians) captured separately (Pencil Pro).
    public static func stroke(from pk: PKStroke, style: InkStyle, rolls: [(t: Double, roll: Double)] = []) -> Stroke {
        let transform = pk.transform
        var pts: [StrokePoint] = []
        pts.reserveCapacity(pk.path.count)
        for p in pk.path {
            let loc = p.location.applying(transform)
            pts.append(StrokePoint(x: Float(loc.x), y: Float(loc.y), t: Float(p.timeOffset), force: Float(p.force),
                                   azimuth: Float(p.azimuth), altitude: Float(p.altitude),
                                   roll: Float(roll(at: p.timeOffset, in: rolls)),
                                   width: Float(p.size.width), height: Float(p.size.height), opacity: Float(p.opacity)))
        }
        return Stroke(style: style, points: pts, t0: pk.path.creationDate.timeIntervalSince1970)
    }

    static func roll(at t: Double, in rolls: [(t: Double, roll: Double)]) -> Double {
        guard !rolls.isEmpty else { return 0 }
        var best = rolls[0]
        for r in rolls where abs(r.t - t) < abs(best.t - t) { best = r }
        return best.roll
    }
}

// MARK: - Rich text bridge

public extension NSAttributedString.Key {
    /// ListKind raw value on every character of a list paragraph.
    static let nibList = NSAttributedString.Key("nib.list")
    /// Marks generated bullet / number / checkbox text (stripped when converting back).
    static let nibListMarker = NSAttributedString.Key("nib.listMarker")
    static let nibChecked = NSAttributedString.Key("nib.checked")
    static let nibIndent = NSAttributedString.Key("nib.indent")
    static let nibParagraphStyle = NSAttributedString.Key("nib.paragraphStyle")
    /// contracts-v2: the model's font family (String) as stored, kept next to the rendered `.font` so a family that is
    /// not installed on this device survives a round trip through TextKit.
    static let nibModelFont = NSAttributedString.Key("nib.modelFont")
    /// contracts-v2: the model's traits (Int: 1 bold, 2 italic), kept when the rendered family has no such face.
    static let nibModelTraits = NSAttributedString.Key("nib.modelTraits")
}

/// `RichText` ⇄ `NSAttributedString` (TextKit editing and drawing). Links use `nib://` URLs for
/// page and audio targets: nib://open/<doc>/<page>, nib://audio/<doc>/<clip>?t=<seconds>.
public enum RichTextBridge {
    public static var defaultFontFamily = "Helvetica"
    public static var defaultFontSize: Double = 17
    public static let indentStep: CGFloat = 24

    public static func font(_ a: TextAttributes, base: TextAttributes = TextAttributes()) -> UIFont {
        let size = CGFloat(a.size ?? base.size ?? defaultFontSize)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if a.bold ?? base.bold ?? false { traits.insert(.traitBold) }
        if a.italic ?? base.italic ?? false { traits.insert(.traitItalic) }
        if a.code ?? base.code ?? false {
            return UIFont.monospacedSystemFont(ofSize: size, weight: traits.contains(.traitBold) ? .bold : .regular)
        }
        var desc = UIFontDescriptor(fontAttributes: [.family: a.font ?? base.font ?? defaultFontFamily])
        if !traits.isEmpty, let d = desc.withSymbolicTraits(traits) { desc = d }
        return UIFont(descriptor: desc, size: size)
    }

    public static func attributes(_ a: TextAttributes, base: TextAttributes = TextAttributes()) -> [NSAttributedString.Key: Any] {
        var d: [NSAttributedString.Key: Any] = [:]
        var sized = a
        if let b = a.baseline, b != 0 {
            let size = a.size ?? base.size ?? defaultFontSize
            sized.size = size * 0.7
            d[.baselineOffset] = CGFloat(Double(b) * size * 0.35)
        }
        d[.font] = font(sized, base: base)
        if !(a.code ?? base.code ?? false) {
            if let family = a.font ?? base.font { d[.nibModelFont] = family }
            var traits = 0
            if a.bold ?? base.bold ?? false { traits |= 1 }
            if a.italic ?? base.italic ?? false { traits |= 2 }
            if traits != 0 { d[.nibModelTraits] = traits }
        }
        d[.foregroundColor] = (a.color ?? base.color ?? .black).uiColor
        if let h = a.highlight ?? base.highlight { d[.backgroundColor] = h.uiColor }
        if a.underline ?? base.underline ?? false { d[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if a.strikethrough ?? base.strikethrough ?? false { d[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let l = a.link, let u = linkURL(l) { d[.link] = u }
        return d
    }

    public static func attributed(_ text: RichText, base: TextAttributes = TextAttributes()) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var number = 0
        for (i, p) in text.paragraphs.enumerated() {
            let ps = NSMutableParagraphStyle()
            ps.alignment = alignment(p.align)
            if let ls = p.lineSpacing { ps.lineSpacing = CGFloat(ls) }
            let indent = CGFloat(p.indent) * indentStep
            ps.firstLineHeadIndent = indent
            ps.headIndent = indent + (p.list == .plain ? 0 : 20)
            var paragraphAttrs: [NSAttributedString.Key: Any] = [.paragraphStyle: ps, .nibList: p.list.rawValue, .nibIndent: p.indent]
            if p.checked { paragraphAttrs[.nibChecked] = true }
            if let s = p.style { paragraphAttrs[.nibParagraphStyle] = s }
            number = (p.list == .number || p.list == .numberParen) ? number + 1 : 0
            if let marker = marker(p.list, number: number, checked: p.checked) {
                var a = attributes(p.runs.first?.attrs ?? TextAttributes(), base: base)
                a.merge(paragraphAttrs) { $1 }
                a[.nibListMarker] = true
                out.append(NSAttributedString(string: marker, attributes: a))
            }
            for r in p.runs {
                var a = attributes(r.attrs, base: base)
                a.merge(paragraphAttrs) { $1 }
                out.append(NSAttributedString(string: r.text, attributes: a))
            }
            if i < text.paragraphs.count - 1 {
                var a = attributes(p.runs.last?.attrs ?? TextAttributes(), base: base)
                a.merge(paragraphAttrs) { $1 }
                out.append(NSAttributedString(string: "\n", attributes: a))
            }
        }
        return out
    }

    public static func richText(_ s: NSAttributedString) -> RichText {
        let ns = s.string as NSString
        let length = ns.length
        var paragraphs: [Paragraph] = []
        var start = 0
        repeat {
            let range = ns.paragraphRange(for: NSRange(location: start, length: 0))
            var content = range
            if content.length > 0 && ns.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
            paragraphs.append(paragraph(s, content))
            start = NSMaxRange(range)
        } while start < length
        if length > 0 && ns.character(at: length - 1) == 10 { paragraphs.append(Paragraph()) }
        return RichText(paragraphs: paragraphs.isEmpty ? [Paragraph()] : paragraphs)
    }

    public static func textAttributes(_ a: [NSAttributedString.Key: Any]) -> TextAttributes {
        var t = TextAttributes()
        if let f = a[.font] as? UIFont {
            t.size = Double(f.pointSize)
            let traits = f.fontDescriptor.symbolicTraits
            if traits.contains(.traitBold) { t.bold = true }
            if traits.contains(.traitItalic) { t.italic = true }
            if traits.contains(.traitMonoSpace) {
                t.code = true
            } else if f.familyName != defaultFontFamily {
                t.font = f.familyName
            }
            if !traits.contains(.traitMonoSpace) {
                // contracts-v2: a model family that is not installed here rendered as a fallback; keep the model's.
                if let model = a[.nibModelFont] as? String, model != f.familyName, !UIFont.familyNames.contains(model) {
                    t.font = model
                }
                // A model trait the rendered family has no face for (italic in a font without italics) is kept.
                if let mt = a[.nibModelTraits] as? Int {
                    if mt & 1 != 0, !traits.contains(.traitBold), !hasFace(f.familyName, .traitBold) { t.bold = true }
                    if mt & 2 != 0, !traits.contains(.traitItalic), !hasFace(f.familyName, .traitItalic) { t.italic = true }
                }
            }
        }
        if let c = a[.foregroundColor] as? UIColor {
            let rgba = RGBA(c)
            if rgba != .black { t.color = rgba }
        }
        if let c = a[.backgroundColor] as? UIColor { t.highlight = RGBA(c) }
        if let u = a[.underlineStyle] as? Int, u != 0 { t.underline = true }
        if let u = a[.strikethroughStyle] as? Int, u != 0 { t.strikethrough = true }
        if let b = a[.baselineOffset] as? CGFloat, b != 0 {
            t.baseline = b > 0 ? 1 : -1
            if let s = t.size { t.size = (s / 0.7).rounded() }
        }
        if let url = a[.link] as? URL {
            t.link = link(from: url)
        } else if let s = a[.link] as? String, let url = URL(string: s) {
            t.link = link(from: url)
        }
        return t
    }

    public static func linkURL(_ link: TextLink) -> URL? {
        if let u = link.url { return URL(string: u) }
        guard let doc = link.document else { return nil }
        var c = URLComponents()
        c.scheme = NibFormat.urlScheme
        if let clip = link.audioClip {
            c.host = "audio"
            c.path = "/" + doc.raw + "/" + clip.raw
            c.queryItems = [URLQueryItem(name: "t", value: String(link.audioTime ?? 0))]
        } else {
            c.host = "open"
            c.path = "/" + doc.raw + (link.page.map { "/" + $0.raw } ?? "")
        }
        return c.url
    }

    public static func link(from url: URL) -> TextLink {
        guard url.scheme == NibFormat.urlScheme else { return TextLink(url: url.absoluteString) }
        let parts = url.path.split(separator: "/").map { String($0) }
        if url.host == "audio", parts.count >= 2 {
            let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "t" }?.value.flatMap { Double($0) }
            return TextLink(document: NibID(parts[0]), audioClip: NibID(parts[1]), audioTime: t)
        }
        if url.host == "open", let d = parts.first {
            return TextLink(document: NibID(d), page: parts.count > 1 ? NibID(parts[1]) : nil)
        }
        return TextLink(url: url.absoluteString)
    }

    // MARK: Private

    /// True when `family` has a face with `trait` (so a missing trait on rendered text was the user's choice).
    static func hasFace(_ family: String, _ trait: UIFontDescriptor.SymbolicTraits) -> Bool {
        guard let d = UIFontDescriptor(fontAttributes: [.family: family]).withSymbolicTraits(trait) else { return false }
        return UIFont(descriptor: d, size: 12).fontDescriptor.symbolicTraits.contains(trait)
    }

    static func alignment(_ a: ParagraphAlignment) -> NSTextAlignment {
        switch a {
        case .natural: return .natural
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case .justified: return .justified
        }
    }

    static func alignment(_ a: NSTextAlignment) -> ParagraphAlignment {
        switch a {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case .justified: return .justified
        default: return .natural
        }
    }

    static func marker(_ list: ListKind, number: Int, checked: Bool) -> String? {
        switch list {
        case .plain: return nil
        case .bullet: return "• "
        case .number: return "\(number). "
        case .numberParen: return "\(number)) "
        case .todo: return checked ? "☑ " : "☐ "
        }
    }

    static func paragraph(_ s: NSAttributedString, _ range: NSRange) -> Paragraph {
        var p = Paragraph()
        guard s.length > 0 else { return p }
        let probe = min(range.location, s.length - 1)
        let attrs = s.attributes(at: probe, effectiveRange: nil)
        if let ps = attrs[.paragraphStyle] as? NSParagraphStyle {
            p.align = alignment(ps.alignment)
            p.lineSpacing = ps.lineSpacing > 0 ? Double(ps.lineSpacing) : nil
        }
        if let indent = attrs[.nibIndent] as? Int { p.indent = indent }
        if let l = attrs[.nibList] as? String, let k = ListKind(rawValue: l) { p.list = k }
        p.checked = (attrs[.nibChecked] as? Bool) ?? false
        p.style = attrs[.nibParagraphStyle] as? String
        guard range.length > 0 else { return p }
        var runs: [TextRun] = []
        s.enumerateAttributes(in: range, options: []) { a, r, _ in
            if a[.nibListMarker] != nil { return }
            let text = (s.string as NSString).substring(with: r)
            let attrs = textAttributes(a)
            if let last = runs.last, last.attrs == attrs {
                runs[runs.count - 1].text += text
            } else {
                runs.append(TextRun(text, attrs))
            }
        }
        p.runs = runs
        return p
    }
}
```

### `NibKit/Sources/NibContracts/UI/Canvas.swift`

```swift
import UIKit

public enum CanvasInputMode {
    /// The canvas captures ink with PencilKit (wet ink) and hands the finished stroke to the tool.
    case pencilKit
    /// The tool receives raw samples and draws its own preview into `CanvasHost.overlayLayer`.
    case samples
    /// Taps only (text, sticky, image placement…).
    case taps
}

public struct CanvasSample {
    public var page: PageID
    /// Page coordinates.
    public var location: Point
    public var force: Double
    public var azimuth: Double
    public var altitude: Double
    /// Apple Pencil Pro barrel roll (radians), 0 when unavailable.
    public var roll: Double
    public var timestamp: TimeInterval
    public var isPencil: Bool
    public var isPredicted: Bool
    public var modifiers: KeyModifiers
    /// contracts-v2: stable id of the touch this sample belongs to (multi-finger gestures: two-finger ruler rotation,
    /// two-finger duplicate). 0 when unknown.
    public var touchID: Int

    public init(page: PageID, location: Point, force: Double = 0.5, azimuth: Double = 0, altitude: Double = .pi / 2,
                roll: Double = 0, timestamp: TimeInterval = 0, isPencil: Bool = true, isPredicted: Bool = false,
                modifiers: KeyModifiers = [], touchID: Int = 0) {
        self.page = page
        self.location = location
        self.force = force
        self.azimuth = azimuth
        self.altitude = altitude
        self.roll = roll
        self.timestamp = timestamp
        self.isPencil = isPencil
        self.isPredicted = isPredicted
        self.modifiers = modifiers
        self.touchID = touchID
    }
}

/// What the canvas (Canvas feature) offers to tools, gesture handlers and the Pencil handler.
@MainActor
public protocol CanvasHost: AnyObject {
    var app: NibApp { get }
    var session: EditorSession { get }
    var documentID: DocumentID { get }
    /// Current zoom (view points per page point).
    var zoomScale: Double { get }
    /// The scrolling canvas view (for presenting menus, loupes, pencil palettes). Named `canvasView` so a
    /// UIViewController (whose `view` is `UIView!`) can conform. It is the scroll view itself: `viewPoint`, `pagePoint`
    /// and `pageFrame` use its bounds coordinates, which move with scrolling and zoom; subviews added to it scroll with
    /// the pages. Things that must stay put on screen go in `fixedOverlayView` (or are chrome overlays).
    var canvasView: UIView { get }
    /// Transient drawing layer of the ACTIVE TOOL in `canvasView` coordinates (previews, lasso path). Cleared by tools.
    /// Anything persistent (selection handles, underlines, presence cursors, minimap…) is a `CanvasAttachment`.
    var overlayLayer: CALayer { get }
    func viewPoint(_ p: Point, page: PageID) -> CGPoint
    /// Page under a view point, with the point in page coordinates.
    func pagePoint(_ v: CGPoint) -> (page: PageID, point: Point)?
    /// Page frame in `view` coordinates, nil when not laid out.
    func pageFrame(_ page: PageID) -> CGRect?
    /// Temporarily hide items (drag previews); pass [] to show again.
    func setHidden(_ ids: Set<ElementID>, page: PageID)
    func invalidate(page: PageID, rect: Rect?)
    /// Commits a finished stroke through `ink.addStrokes` (applies stroke processors first).
    func commitStroke(_ stroke: Stroke, page: PageID)
    /// Cancels the in-progress PencilKit stroke (Draw-and-Hold takes over). Idempotent: after `strokeHeld` returns true
    /// the canvas has already cancelled it, and a second call is harmless. Called from `strokeFinished`, it discards
    /// the finished wet stroke (the tool commits something else instead, e.g. a recognised shape).
    func cancelWetStroke()
    /// Keeps a live view (animated GIF, video, plugin view) positioned over an item's frame; nil removes it.
    func attachLiveView(_ view: UIView?, item: ElementID, page: PageID)

    // contracts-v2 (all have default implementations below; the canvas F006/F101 overrides them)

    /// Runs `body` once the dry tiles of `page` have been redrawn after the latest commit, so a tool can drop its
    /// preview without a flicker. Default: after 150 ms.
    func afterNextRender(page: PageID, _ body: @escaping @MainActor () -> Void)
    /// Page → `canvasView` affine (zoom, page layout and page rotation included); nil when the page is not laid out.
    func pageTransform(_ page: PageID) -> CGAffineTransform?
    /// A point on `source` expressed in the coordinates of `target` (a gesture that crosses pages); nil when either
    /// page is not laid out.
    func convert(_ point: Point, from source: PageID, to target: PageID) -> Point?
    /// A view above the canvas that does NOT scroll or zoom (HUD-like attachments, panes). Default: the canvas view's
    /// superview.
    var fixedOverlayView: UIView { get }
    /// A tool finished one use: returns to the previous (or temporary-return) tool when appropriate, see
    /// `EditorSession.finishToolUse(sticky:)`.
    func finishToolUse(_ tool: CanvasTool)
    /// `commitStroke` with its outcome: the created item's id, or the error `ink.addStrokes` threw (a stroke dropped by
    /// a processor succeeds with nil). Default: commits and reports success with nil.
    func commitStroke(_ stroke: Stroke, page: PageID, completion: @escaping @MainActor (Result<ElementID?, NibError>) -> Void)
}

@MainActor
public extension CanvasHost {
    func afterNextRender(page: PageID, _ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            body()
        }
    }

    func pageTransform(_ page: PageID) -> CGAffineTransform? {
        guard pageFrame(page) != nil else { return nil }
        let o = viewPoint(.zero, page: page)
        let x = viewPoint(Point(100, 0), page: page)
        let y = viewPoint(Point(0, 100), page: page)
        return CGAffineTransform(a: (x.x - o.x) / 100, b: (x.y - o.y) / 100, c: (y.x - o.x) / 100, d: (y.y - o.y) / 100,
                                 tx: o.x, ty: o.y)
    }

    func convert(_ point: Point, from source: PageID, to target: PageID) -> Point? {
        if source == target { return point }
        guard pageFrame(source) != nil, let t = pageTransform(target) else { return nil }
        return Point(viewPoint(point, page: source).applying(t.inverted()))
    }

    var fixedOverlayView: UIView { canvasView.superview ?? canvasView }

    func finishToolUse(_ tool: CanvasTool) { session.finishToolUse(sticky: tool.isSticky) }

    func commitStroke(_ stroke: Stroke, page: PageID, completion: @escaping @MainActor (Result<ElementID?, NibError>) -> Void) {
        commitStroke(stroke, page: page)
        completion(.success(nil))
    }
}

/// A canvas tool. Registered via `UIRegistries.canvasTools`; activated by `tool.select`.
@MainActor
public protocol CanvasTool: AnyObject {
    var id: String { get }
    var inputMode: CanvasInputMode { get }
    /// Sticky tools stay active; non-sticky tools return to the previous tool after one use.
    var isSticky: Bool { get }
    /// `.pencilKit` tools: the ink to capture with.
    func inkStyle(_ host: CanvasHost) -> InkStyle?
    func activate(_ host: CanvasHost)
    func deactivate(_ host: CanvasHost)
    /// `.pencilKit`: a stroke finished (processors not yet applied). Default commits it.
    func strokeFinished(_ stroke: Stroke, page: PageID, host: CanvasHost)
    /// `.pencilKit`: the pen was held still at the end of a stroke. Return true to consume it: the wet stroke is
    /// cancelled and the rest of that touch arrives through `touchesMoved` / `touchesEnded` (Draw-and-Hold).
    func strokeHeld(_ stroke: Stroke, page: PageID, host: CanvasHost) -> Bool
    func touchesBegan(_ sample: CanvasSample, host: CanvasHost)
    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost)
    func touchesEnded(_ sample: CanvasSample, host: CanvasHost)
    func touchesCancelled(host: CanvasHost)
    func tap(_ sample: CanvasSample, host: CanvasHost)
    /// Touch held still for 0.5 s on the page (after attachments and `content.tapHandlers` declined it).
    func longPress(_ sample: CanvasSample, host: CanvasHost)
    func hover(_ sample: CanvasSample?, host: CanvasHost)
}

@MainActor
public extension CanvasTool {
    var isSticky: Bool { true }
    func inkStyle(_ host: CanvasHost) -> InkStyle? { nil }
    func activate(_ host: CanvasHost) {}
    func deactivate(_ host: CanvasHost) {}
    func strokeFinished(_ stroke: Stroke, page: PageID, host: CanvasHost) { host.commitStroke(stroke, page: page) }
    func strokeHeld(_ stroke: Stroke, page: PageID, host: CanvasHost) -> Bool { false }
    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {}
    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {}
    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {}
    func touchesCancelled(host: CanvasHost) {}
    func tap(_ sample: CanvasSample, host: CanvasHost) {}
    func longPress(_ sample: CanvasSample, host: CanvasHost) {}
    func hover(_ sample: CanvasSample?, host: CanvasHost) {}
}

/// Something that lives on the canvas independently of the active tool: selection handles (F012), shape control
/// points (F031), connector bends and quick-diagram dots (F032), spellcheck underlines (F104), Math Assist glow
/// (F106), presence cursors (F108), minimap (F044), ruler (F039), zoom box (F038), plugin decorations
/// (`canvas.decorate`), answer-zone widgets (F099). Registered through `ui.canvasAttachments`; the canvas creates
/// one instance per canvas host and gives it its own layer/view.
@MainActor
public protocol CanvasAttachment: AnyObject {
    /// Add sublayers/subviews to `host.canvasView` here; called once per canvas (document opened).
    func attach(to host: CanvasHost)
    func detach(from host: CanvasHost)
    /// Scroll, zoom, page layout, selection or a commit changed: reposition what you draw.
    func canvasDidChange(_ host: CanvasHost)
    /// True = this attachment takes the touch that starts at `viewPoint` (asked before tap handlers and the active
    /// tool, in registry order); the touch's samples then go to the touch methods below. A claimed touch never pans,
    /// zooms or inks the canvas.
    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool
    func touchesBegan(_ sample: CanvasSample, host: CanvasHost)
    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost)
    func touchesEnded(_ sample: CanvasSample, host: CanvasHost)
    func touchesCancelled(host: CanvasHost)

    // contracts-v2 (default implementations below)

    /// `hitTest` with the input kind: the canvas calls this one. Default: `hitTest(viewPoint, host:)` for both.
    func hitTest(_ viewPoint: CGPoint, isPencil: Bool, host: CanvasHost) -> Bool
    /// Pointer or Pencil hover over the canvas (nil = hover ended). Default: nothing.
    func hover(_ sample: CanvasSample?, host: CanvasHost)
    /// A claimed touch turned out to be a tap, double-tap or long-press: return true to consume it, false to pass it on
    /// to `content.tapHandlers` and then the active tool (e.g. double-tap text inside a selected shape). Default: false.
    func gesture(_ gesture: CanvasGesture, at sample: CanvasSample, host: CanvasHost) -> Bool
}

@MainActor
public extension CanvasAttachment {
    func detach(from host: CanvasHost) {}
    func canvasDidChange(_ host: CanvasHost) {}
    func hitTest(_ viewPoint: CGPoint, host: CanvasHost) -> Bool { false }
    func touchesBegan(_ sample: CanvasSample, host: CanvasHost) {}
    func touchesMoved(_ samples: [CanvasSample], host: CanvasHost) {}
    func touchesEnded(_ sample: CanvasSample, host: CanvasHost) {}
    func touchesCancelled(host: CanvasHost) {}
    func hitTest(_ viewPoint: CGPoint, isPencil: Bool, host: CanvasHost) -> Bool { hitTest(viewPoint, host: host) }
    func hover(_ sample: CanvasSample?, host: CanvasHost) {}
    func gesture(_ gesture: CanvasGesture, at sample: CanvasSample, host: CanvasHost) -> Bool { false }
}

public struct CanvasAttachmentDescriptor: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    public var docKinds: Set<DocumentKind>
    public var make: @MainActor (CanvasHost) -> CanvasAttachment

    public init(id: String, owner: String, order: Int = 0, docKinds: Set<DocumentKind> = [.notebook, .whiteboard],
                make: @escaping @MainActor (CanvasHost) -> CanvasAttachment) {
        self.id = id
        self.order = order
        self.owner = owner
        self.docKinds = docKinds
        self.make = make
    }
}

/// Apple Pencil hardware events forwarded by the canvas (Pencil Hardware feature). The canvas (F006/F101) owns the one
/// `UIPencilInteraction` and the Pencil hover recogniser per canvas and forwards through `ui.pencilHandler`; a handler
/// that also installs its own (F043 before F101 lands) must drop duplicates.
@MainActor
public protocol PencilEventHandler: AnyObject {
    func pencilDoubleTap(session: EditorSession, host: CanvasHost)
    /// `location` is in `host.canvasView` coordinates (like `CanvasHost.viewPoint`).
    func pencilSqueeze(began: Bool, location: CGPoint?, session: EditorSession, host: CanvasHost)
    func pencilHover(_ sample: CanvasSample?, session: EditorSession, host: CanvasHost)
}

/// Implemented by every document editor view controller (canvas, text document, study set).
@MainActor
public protocol DocumentEditing: AnyObject {
    var documentID: DocumentID { get }
    var session: EditorSession { get }
    /// nil for editors without a page canvas.
    var canvasHost: CanvasHost? { get }
    func reveal(page: PageID, rect: Rect?, animated: Bool)
    func reloadAll()
    /// contracts-v2: scrolls a text document to a block (outline, search, links). Default: `reveal(page: block, …)`.
    func reveal(block: NibID, animated: Bool)
}

@MainActor
public extension DocumentEditing {
    func reveal(block: NibID, animated: Bool) { reveal(page: block, rect: nil, animated: animated) }
}
```

### `NibKit/Sources/NibContracts/UI/UIRegistries.swift`

```swift
import SwiftUI
import UIKit

// MARK: - Toolbar

public enum ToolbarGroup: String, Codable, CaseIterable {
    /// Fixed first slot (Lasso).
    case lasso
    /// Writing tools (pen, pencil, highlighter, eraser, tape, shapes…).
    case tools
    /// Accessories (audio, ruler, zoom window, timer, laser…).
    case accessories
    /// Document nav bar, left side (library, sidebar, search, AI, read-only).
    case navLeading
    /// Document nav bar, right side (add page, share/export, more).
    case navTrailing
}

/// Every toolbar button is either a canvas tool (activated via `tool.select`) or a command. No other actions exist.
public struct ToolbarItemDescriptor: Registrable {
    public var id: String
    public var title: String
    /// SF Symbol name.
    public var icon: String
    public var group: ToolbarGroup
    public var order: Int
    public var owner: String
    public var toolID: String?
    public var command: String?
    public var params: JSONValue
    public var shortcut: KeyShortcut?
    /// Can be hidden in Toolbar Customization (Lasso cannot).
    public var hideable: Bool
    public var docKinds: Set<DocumentKind>
    /// Contextual options bar shown while this tool is active (presets, colors, sizes).
    public var activeToolMenu: (@MainActor (EditorSession) -> AnyView)?
    /// Settings popover shown when the already-selected tool is tapped again.
    public var settings: (@MainActor (EditorSession) -> AnyView)?

    // contracts-v2: live state. Set these after init; the toolbar and nav bar re-evaluate them on session changes,
    // commits, undo/redo and `UIRegistries.setNeedsChromeUpdate()`.

    /// Greyed out when false (Undo with nothing to undo). nil = always enabled.
    public var isEnabled: (@MainActor (EditorSession) -> Bool)? = nil
    /// Shown as on/selected when true (Zoom Window open, Read Only on, page bookmarked, timer running). nil = no state.
    public var isOn: (@MainActor (EditorSession) -> Bool)? = nil
    /// Params computed from the invoking window when tapped (the window's document, page or selection), merged over
    /// `params`. Use `resolvedParams(for:)`.
    public var sessionParams: (@MainActor (EditorSession) -> JSONValue)? = nil
    /// Title for this window ("Undo Add Page"); nil = `title`.
    public var sessionTitle: (@MainActor (EditorSession) -> String)? = nil
    /// SF Symbol for this window ("bookmark.fill" when on); nil = `icon`.
    public var sessionIcon: (@MainActor (EditorSession) -> String)? = nil
    /// Also shown on compact width (iPhone); false = regular width only.
    public var showsInCompactWidth: Bool = true

    @MainActor
    public func resolvedParams(for session: EditorSession) -> JSONValue {
        guard let f = sessionParams else { return params }
        return params.merging(f(session))
    }

    @MainActor
    public func resolvedTitle(for session: EditorSession) -> String { sessionTitle?(session) ?? title }

    @MainActor
    public func resolvedIcon(for session: EditorSession) -> String { sessionIcon?(session) ?? icon }

    public init(id: String, title: String, icon: String, group: ToolbarGroup, order: Int, owner: String,
                toolID: String? = nil, command: String? = nil, params: JSONValue = [:], shortcut: KeyShortcut? = nil,
                hideable: Bool = true, docKinds: Set<DocumentKind> = [.notebook, .whiteboard],
                activeToolMenu: (@MainActor (EditorSession) -> AnyView)? = nil,
                settings: (@MainActor (EditorSession) -> AnyView)? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.group = group
        self.order = order
        self.owner = owner
        self.toolID = toolID
        self.command = command
        self.params = params
        self.shortcut = shortcut
        self.hideable = hideable
        self.docKinds = docKinds
        self.activeToolMenu = activeToolMenu
        self.settings = settings
    }
}

// MARK: - Menus

public enum MenuLocation: String, Codable, CaseIterable {
    /// Quick-action icon row / full list above a selection.
    case objectMenu
    /// Long-press on empty page area.
    case pageLongPress
    /// Document "More (…)" menu.
    case documentMore
    /// Tap on the document title.
    case documentTitle
    /// Add Page (+) menu.
    case addPage
    /// Share & Export menu.
    case shareExport
    /// Per-item menu in the library.
    case libraryItem
    /// New (+) creation menu in the library.
    case libraryNew
    /// Actions for a multi-selection in the library.
    case librarySelection
    /// App menu (avatar / gear in the library).
    case appMenu
    /// Page thumbnail menu in the sidebar.
    case sidebarPage
    /// Actions for selected thumbnails.
    case sidebarSelection
    /// Selected typed text (text boxes, blocks).
    case textSelection
    /// Audio clip row.
    case audioClip
    /// Text-document block handle menu.
    case block
    /// Study-set card menu.
    case card
    /// Whiteboard board (Boards sidebar) menu.
    case board
    /// Outline entry menu.
    case outlineEntry
    /// Comment thread menu.
    case comment
    /// Transcript line menu.
    case transcriptSegment
    /// Document tab menu.
    case tab
}

public struct MenuContext {
    public var app: NibApp
    public var session: EditorSession?
    public var doc: DocumentID?
    public var page: PageID?
    /// Long-press location in page coordinates.
    public var point: Point?
    public var selection: Selection
    public var itemKinds: Set<ItemKind>
    /// Library selection (items, folders) or sidebar selection (pages).
    public var nodes: [NibID]
    /// The ref the menu is for (block, card, board page, outline entry, comment item, audio clip, tab document);
    /// transcript lines use "audio:D/A" plus `index`.
    public var ref: String?
    public var index: Int?
    /// contracts-v2: the library folder the menu was opened in (`libraryNew`, `libraryItem`); nil = root.
    public var folder: FolderID?
    /// contracts-v2: `textSelection` menus: the selected range [start, length] in plain-text units (UTF-16, list
    /// markers excluded) of the item or block named by `ref`.
    public var textRange: [Int]?

    /// `sidebarPage` menus: `page` is the thumbnail's page and `nodes` holds every selected page.
    public init(app: NibApp, session: EditorSession? = nil, doc: DocumentID? = nil, page: PageID? = nil, point: Point? = nil,
                selection: Selection = Selection(), itemKinds: Set<ItemKind> = [], nodes: [NibID] = [],
                ref: String? = nil, index: Int? = nil, folder: FolderID? = nil, textRange: [Int]? = nil) {
        self.app = app
        self.session = session
        self.doc = doc
        self.page = page
        self.point = point
        self.selection = selection
        self.itemKinds = itemKinds
        self.nodes = nodes
        self.ref = ref
        self.index = index
        self.folder = folder
        self.textRange = textRange
    }
}

/// A menu entry always runs a command (so plugins, AI and the bridge can do the same thing).
public struct MenuItemDescriptor: Registrable {
    public var id: String
    public var title: String
    public var icon: String?
    public var location: MenuLocation
    public var order: Int
    public var owner: String
    public var command: String
    public var params: @MainActor (MenuContext) -> JSONValue
    public var isVisible: @MainActor (MenuContext) -> Bool
    public var destructive: Bool
    /// Shown as an icon in the object menu's quick row.
    public var quick: Bool
    /// Sub-menu title this entry is grouped under (nil = top level).
    public var submenu: String?
    /// contracts-v2: shows a checkmark when true (current scroll direction, connector route, presentation mode).
    public var isChecked: (@MainActor (MenuContext) -> Bool)? = nil
    /// contracts-v2: title for this context ("Move to Layer › <name>", "Start Typing" / "Edit Text"); nil = `title`.
    public var contextTitle: (@MainActor (MenuContext) -> String)? = nil
    /// contracts-v2: shortcut shown next to the entry (display only; the key itself is a `KeyCommandDescriptor`).
    public var shortcut: KeyShortcut? = nil

    @MainActor
    public func resolvedTitle(for context: MenuContext) -> String { contextTitle?(context) ?? title }

    public init(id: String, title: String, icon: String? = nil, location: MenuLocation, order: Int, owner: String,
                command: String,
                params: @escaping @MainActor (MenuContext) -> JSONValue = { _ in [:] },
                isVisible: @escaping @MainActor (MenuContext) -> Bool = { _ in true },
                destructive: Bool = false, quick: Bool = false, submenu: String? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.location = location
        self.order = order
        self.owner = owner
        self.command = command
        self.params = params
        self.isVisible = isVisible
        self.destructive = destructive
        self.quick = quick
        self.submenu = submenu
    }
}

// MARK: - Panels, settings pages, inspectors

public enum PanelPlacement: String, Codable, CaseIterable {
    /// A tab in the document sidebar (Pages, Outline, Audio, Boards, Search, Layers…).
    case sidebarTab
    /// Draggable floating panel (AI chat, timer, plugin panels).
    case floating
    case sheet
    /// Library sidebar section (Documents, Favorites, Shared, Trash, Gallery…).
    case libraryTab
    case fullScreen
}

/// contracts-v2: how the chrome presents a panel this time (a floating panel shows as a sheet on compact width, a
/// sidebar tab in Window mode takes the full width).
public enum PanelPresentation: String, Codable, CaseIterable {
    case sidebar, window, floating, sheet, fullScreen, libraryTab
}

public struct PanelContext {
    public var app: NibApp
    public var session: EditorSession?
    public var navigator: SceneNavigator?
    public var dismiss: @MainActor () -> Void
    /// contracts-v2: the params `panel.open` was called with, minus `id` (which pages to move, which thread or folder to
    /// show, `instant: true` to skip the bud animation). `[:]` when opened without params.
    public var params: JSONValue = [:]
    /// contracts-v2: the presentation the chrome chose; nil = the descriptor's placement.
    public var presentation: PanelPresentation? = nil

    public init(app: NibApp, session: EditorSession?, navigator: SceneNavigator?, dismiss: @escaping @MainActor () -> Void) {
        self.app = app
        self.session = session
        self.navigator = navigator
        self.dismiss = dismiss
    }
}

public struct PanelDescriptor: Registrable {
    public var id: String
    public var title: String
    public var icon: String
    public var placement: PanelPlacement
    public var order: Int
    public var owner: String
    /// nil = any (library tabs ignore it).
    public var docKinds: Set<DocumentKind>?
    public var makeView: @MainActor (PanelContext) -> AnyView
    /// contracts-v2: the view draws its own header (plugin panels draw NibPluginPanelChrome); the chrome then adds none.
    public var providesHeader: Bool = false

    public init(id: String, title: String, icon: String, placement: PanelPlacement, order: Int, owner: String,
                docKinds: Set<DocumentKind>? = nil, makeView: @escaping @MainActor (PanelContext) -> AnyView) {
        self.id = id
        self.title = title
        self.icon = icon
        self.placement = placement
        self.order = order
        self.owner = owner
        self.docKinds = docKinds
        self.makeView = makeView
    }
}

public enum SettingsSection: String, Codable, CaseIterable {
    case general, editing, stylus, writing, ai, sync, plugins, bridge, advanced, about
}

public struct SettingsPageDescriptor: Registrable {
    public var id: String
    public var title: String
    public var icon: String
    public var section: SettingsSection
    public var order: Int
    public var owner: String
    public var makeView: @MainActor (NibApp) -> AnyView
    /// contracts-v2: extra words settings search matches ("palm", "handedness", "iCloud").
    public var keywords: [String] = []

    public init(id: String, title: String, icon: String, section: SettingsSection, order: Int, owner: String,
                makeView: @escaping @MainActor (NibApp) -> AnyView) {
        self.id = id
        self.title = title
        self.icon = icon
        self.section = section
        self.order = order
        self.owner = owner
        self.makeView = makeView
    }
}

public struct InspectorContext {
    public var app: NibApp
    public var session: EditorSession
    public var doc: DocumentID
    public var page: PageID
    public var items: [Item]

    public init(app: NibApp, session: EditorSession, doc: DocumentID, page: PageID, items: [Item]) {
        self.app = app
        self.session = session
        self.doc = doc
        self.page = page
        self.items = items
    }
}

/// Style editor shown for a selection of certain item kinds (text formatting, shape style, image crop…).
public struct InspectorDescriptor: Registrable {
    public var id: String
    public var title: String
    public var icon: String
    public var itemKinds: Set<ItemKind>
    /// Further restricts to these `Item.drawKey`s (custom item types: "custom.<owner>.<type>"); nil = any.
    public var drawKeys: Set<String>?
    public var order: Int
    public var owner: String
    public var makeView: @MainActor (InspectorContext) -> AnyView

    public init(id: String, title: String, icon: String, itemKinds: Set<ItemKind>, order: Int, owner: String,
                drawKeys: Set<String>? = nil, makeView: @escaping @MainActor (InspectorContext) -> AnyView) {
        self.id = id
        self.title = title
        self.icon = icon
        self.itemKinds = itemKinds
        self.drawKeys = drawKeys
        self.order = order
        self.owner = owner
        self.makeView = makeView
    }
}

/// Contextual options bar for the active tool (presets, colors, sizes). Registered under the tool id; takes
/// precedence over `ToolbarItemDescriptor.activeToolMenu` so one feature can serve several tools.
public struct ToolMenuDescriptor: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    public var makeView: @MainActor (EditorSession) -> AnyView
    /// contracts-v2: the options bar's own popover (thickness slider, colour editor), budding from a control inside
    /// the bar. The bar's droplet clips its content, so the popover cannot live in `makeView`; the toolbar (F016) hands
    /// it to the palette (NibDesign `NibToolOptions(bar:popover:)`), which places it beside the bar. nil = none.
    public var makePopover: (@MainActor (EditorSession) -> ToolMenuPopover?)? = nil

    public init(tool: String, owner: String, order: Int = 0, makeView: @escaping @MainActor (EditorSession) -> AnyView) {
        self.id = tool
        self.order = order
        self.owner = owner
        self.makeView = makeView
    }
}

/// contracts-v2: a popover that buds from the control whose bud anchor id is `source` (NibDesign `nibBudAnchor`)
/// inside a tool's options bar. One popover at a time: open it only while the tool's settings popover is closed.
/// Mirrors NibDesign's `NibToolOptionsPopover` field for field, so the toolbar converts it one to one.
public struct ToolMenuPopover {
    public var source: String
    public var isPresented: Binding<Bool>
    public var title: String
    public var subtitle: String?
    public var content: AnyView

    public init<Content: View>(source: String, isPresented: Binding<Bool>, title: String, subtitle: String? = nil,
                               @ViewBuilder content: () -> Content) {
        self.source = source
        self.isPresented = isPresented
        self.title = title
        self.subtitle = subtitle
        self.content = AnyView(content())
    }
}

public struct BlockViewContext {
    public var app: NibApp
    public var session: EditorSession
    public var doc: DocumentID
    public var block: TextBlock
    /// Call when the view's preferred height changes.
    public var heightChanged: @MainActor (CGFloat) -> Void

    public init(app: NibApp, session: EditorSession, doc: DocumentID, block: TextBlock,
                heightChanged: @escaping @MainActor (CGFloat) -> Void) {
        self.app = app
        self.session = session
        self.doc = doc
        self.block = block
        self.heightChanged = heightChanged
    }
}

/// Renders one Text Document block kind that the text document editor does not render itself (e.g. tables).
/// Custom blocks without a view are drawn by the editor from `CustomBlock.display`.
public struct BlockViewDescriptor: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    public var make: @MainActor (BlockViewContext) -> UIView

    public init(kind: BlockKind, owner: String, order: Int = 0, make: @escaping @MainActor (BlockViewContext) -> UIView) {
        self.id = kind.rawValue
        self.order = order
        self.owner = owner
        self.make = make
    }

    /// A view for one custom block type (id "custom.<owner>.<type>").
    public init(customType: String, owner: String, order: Int = 0, make: @escaping @MainActor (BlockViewContext) -> UIView) {
        self.id = "custom." + customType
        self.order = order
        self.owner = owner
        self.make = make
    }
}

/// Builds a plugin's HTML panel (Plugin Panels feature; shared via `ServiceKeys.pluginPanels`).
@MainActor
public protocol PluginPanelFactory: AnyObject {
    func makePanel(manifest: PluginManifest, folder: URL, entry: String, context: PanelContext) -> AnyView
}

// MARK: - Canvas tools and document editors

public struct CanvasToolDescriptor: Registrable {
    public var id: String
    public var title: String
    public var order: Int
    public var owner: String
    public var make: @MainActor () -> CanvasTool

    public init(id: String, title: String, order: Int = 0, owner: String, make: @escaping @MainActor () -> CanvasTool) {
        self.id = id
        self.title = title
        self.order = order
        self.owner = owner
        self.make = make
    }
}

/// Editor for one document kind (id = DocumentKind raw value). The view controller must adopt `DocumentEditing`.
public struct DocumentEditorDescriptor: Registrable {
    public var id: String
    public var order: Int
    public var owner: String
    public var make: @MainActor (DocumentID, EditorSession, NibApp) -> UIViewController

    public init(kind: DocumentKind, owner: String, order: Int = 0,
                make: @escaping @MainActor (DocumentID, EditorSession, NibApp) -> UIViewController) {
        self.id = kind.rawValue
        self.order = order
        self.owner = owner
        self.make = make
    }
}

// MARK: - Shell

public enum OpenMode { case replace, newTab, newWindow }

/// One per window scene (implemented by the app shell's root view controller).
@MainActor
public protocol SceneNavigator: AnyObject {
    var session: EditorSession { get }
    /// Open tabs, in order.
    var openDocuments: [DocumentID] { get }
    var activeDocument: DocumentID? { get }
    var rootViewController: UIViewController? { get }
    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode)
    func closeDocument(_ doc: DocumentID)
    func showLibrary(folder: FolderID?)
    func showSettings(page: String?)
    func presentModal(_ viewController: UIViewController)
    /// contracts-v2: appends a document to `openDocuments` WITHOUT showing it or building its editor (tab restore).
    /// Default (navigators that predate it): opens it as a new tab, which also shows it.
    func addTab(_ doc: DocumentID)
}

@MainActor
public extension SceneNavigator {
    func addTab(_ doc: DocumentID) { openDocument(doc, page: nil, mode: .newTab) }
    /// contracts-v2: the window's floating host (see `FloatingHosting`), also while the library shows. Default nil;
    /// the shell forwards the library's or the active editor's host.
    var floatingHost: FloatingHosting? { session.floatingHost }
}

/// Window lifecycle hooks (Tabs & Windows feature).
@MainActor
public protocol SceneHooks: AnyObject {
    func sceneDidConnect(_ scene: UIWindowScene, options: UIScene.ConnectionOptions, navigator: SceneNavigator)
    func restorationActivity(_ navigator: SceneNavigator) -> NSUserActivity?
    /// Tab strip shown above the document chrome (nil = none).
    func makeTabBar(_ navigator: SceneNavigator) -> UIView?
}

/// Screen factories filled by features. The shell falls back to minimal built-in screens when nil.
@MainActor
public final class ScreenRegistry {
    public var libraryRoot: (@MainActor (NibApp, SceneNavigator) -> UIViewController)?
    /// Wraps an editor view controller with the document chrome (nav bar, toolbar, sidebar, panels).
    public var documentContainer: (@MainActor (UIViewController, DocumentID, NibApp, SceneNavigator) -> UIViewController)?
    public var settingsRoot: (@MainActor (NibApp, SceneNavigator) -> UIViewController)?
    /// Returns nil when onboarding is complete.
    public var onboarding: (@MainActor (NibApp, SceneNavigator) -> UIViewController?)?
    /// The document toolbar view (Toolbar feature); embedded by the document chrome.
    /// Superseded in contracts-v2 by `toolbarView` (the chrome prefers it when set).
    public var toolbar: (@MainActor (EditorSession, NibApp) -> UIView)?
    /// contracts-v2: the toolbar as a SwiftUI view; the document chrome places it INSIDE its own droplet container (one
    /// container per window, so the palette merges, necks and recedes with the bars). Preferred over `toolbar`.
    public var toolbarView: (@MainActor (EditorSession, NibApp) -> AnyView)?

    public init() {}
}

@MainActor
public final class UIRegistries {
    public let toolbar = Registry<ToolbarItemDescriptor>()
    public let menus = Registry<MenuItemDescriptor>()
    public let panels = Registry<PanelDescriptor>()
    public let settingsPages = Registry<SettingsPageDescriptor>()
    public let inspectors = Registry<InspectorDescriptor>()
    public let canvasTools = Registry<CanvasToolDescriptor>()
    public let editors = Registry<DocumentEditorDescriptor>()
    public let toolMenus = Registry<ToolMenuDescriptor>()
    public let blockViews = Registry<BlockViewDescriptor>()
    /// Persistent canvas overlays and touch targets that are not the active tool (see `CanvasAttachment`).
    public let canvasAttachments = Registry<CanvasAttachmentDescriptor>()
    /// contracts-v2: floating HUDs, bars, pills and popovers rendered by the document chrome inside the window's droplet
    /// container (see `ChromeOverlayDescriptor`).
    public let chromeOverlays = Registry<ChromeOverlayDescriptor>()
    public let screens: ScreenRegistry
    public var sceneHooks: SceneHooks?
    public var pencilHandler: PencilEventHandler?
    /// Root view controller for an external display scene (Presentation feature); nil = system mirroring.
    public var externalDisplay: (@MainActor (UIWindowScene) -> UIViewController)?
    /// Awaited before a document opens (Password Lock feature); false cancels the open.
    public var openGate: (@MainActor (DocumentID) async -> Bool)?
    /// Navigator of the most recently active window.
    public weak var activeNavigator: SceneNavigator?

    public init() {
        screens = ScreenRegistry()
    }

    public func menuItems(_ location: MenuLocation, _ context: MenuContext) -> [MenuItemDescriptor] {
        menus.all.filter { $0.location == location && $0.isVisible(context) }
    }

    public func toolbarItems(for kind: DocumentKind) -> [ToolbarItemDescriptor] {
        toolbar.all.filter { $0.docKinds.contains(kind) }
    }

    /// contracts-v2: the chrome overlays to show in a window right now, bottom-most first (kind and visibility
    /// applied). The chrome host calls it whenever `setNeedsChromeUpdate` fires, the registry or the session changes.
    public func visibleChromeOverlays(_ context: ChromeContext) -> [ChromeOverlayDescriptor] {
        chromeOverlays.all.filter { d in
            (d.docKinds.map { k in context.kind.map { k.contains($0) } ?? false } ?? true) && d.isVisible(context)
        }
    }

    /// contracts-v2: asks chrome hosts, toolbars and menus to re-evaluate visibility and live state (`isVisible`,
    /// `isOn`, `isEnabled`, `sessionTitle`…) after a feature's own state changed (recording started, timer ended).
    /// nil = every window.
    public func setNeedsChromeUpdate(_ session: EditorSession? = nil) {
        let info: [AnyHashable: Any]? = session.map { ["session": $0.id.raw] }
        NotificationCenter.default.post(name: .nibChromeNeedsUpdate, object: self, userInfo: info)
    }
}

// MARK: - Chrome overlays (contracts-v2)

/// Where the document chrome places an overlay: over the canvas, under sheets, inside the safe area and clear of the
/// bars and the palette.
public enum ChromePlacement: String, Codable, CaseIterable {
    /// Budded from the nav bar.
    case topLeading, top, topTrailing
    /// Vertically centred on the leading or trailing edge.
    case leading, trailing
    case center
    /// Above the bottom edge (and above an iPhone bottom palette).
    case bottomLeading, bottom, bottomTrailing
    /// Next to `ChromeOverlayDescriptor.anchor` (a page rect or a window rect), flipping to stay on screen.
    case anchored
}

/// The surface the host gives an overlay. The host maps it to NibDesign droplets (features never build their own glass
/// for chrome); `.none` hosts the view as it is.
public enum ChromeSurface: String, Codable, CaseIterable {
    /// Clear HUD droplet (recording HUD, ruler angle, presenter HUD).
    case hud
    /// Clear bar droplet of readable width (audio playback bar, timer bar).
    case bar
    /// Small Clear pill ("Return to page", status).
    case pill
    /// Deep panel (Zoom Window pane).
    case panel
    /// Popover budded from `anchor`.
    case popover
    /// No surface: the view draws itself (still placed, stacked and receded by the host).
    case none
}

/// What an `.anchored` overlay points at.
public enum ChromeAnchor: Equatable {
    /// A rect in page coordinates of the window's document; the host follows scrolling and zoom through the canvas.
    case page(PageID, Rect)
    /// A rect in window coordinates (a button's frame, a text selection).
    case window(CGRect)
}

public struct ChromeContext {
    public var app: NibApp
    public var session: EditorSession
    public var navigator: SceneNavigator?
    /// Kind of the document the window shows (nil in the library).
    public var kind: DocumentKind?
    /// True on compact width (iPhone, narrow Split View).
    public var isCompact: Bool
    /// contracts-v2: the window's floating host, for an overlay that buds popovers of its own. Default:
    /// `session.floatingHost`.
    @MainActor
    public var floatingHost: FloatingHosting? { session.floatingHost }

    public init(app: NibApp, session: EditorSession, navigator: SceneNavigator? = nil, kind: DocumentKind? = nil,
                isCompact: Bool = false) {
        self.app = app
        self.session = session
        self.navigator = navigator
        self.kind = kind
        self.isCompact = isCompact
    }
}

/// contracts-v2: the window's floating host. It puts popovers, HUDs, droplet frames and toasts INTO the window's one
/// droplet container from code that lives outside it: a canvas attachment's popover budded from a point on the page
/// (comment thread, spelling suggestions, lasso object menu), a UIKit text editor's formatting popover, a HUD, the Zoom
/// Window's frame, a toast. NibDesign's `NibFloatingHost` does the work; the container's owner (the document chrome
/// F017, the library F019) creates one per window and sets `EditorSession.floatingHost`. Everything presented merges,
/// buds and recedes while the Pencil is down (`EditorSession.inking`) like the chrome, because it is in the same
/// container. Prefer a `ChromeOverlayDescriptor` for anything that shows in every window; use the host for transient
/// content that a gesture or a UIKit control opens.
@MainActor
public protocol FloatingHosting: AnyObject {
    /// Shows `content`, or replaces what `id` showed. The content is laid out over the whole container, in its
    /// coordinates: use a component that places itself (a bud popover from an anchor) or `.position`.
    func present(_ id: String, content: AnyView)
    func dismiss(_ id: String)
    func isPresenting(_ id: String) -> Bool
    /// A bud source at `rect` in `view`'s coordinates (a canvas view, a text view), so a popover can grow out of it.
    /// False while the host is not on screen in `view`'s window.
    @discardableResult
    func setAnchor(_ id: String, rect: CGRect, in view: UIView) -> Bool
    func removeAnchor(_ id: String)
    /// `rect` from `view`'s coordinates into the container's; nil while the host is not on screen in `view`'s window.
    func containerRect(_ rect: CGRect, from view: UIView) -> CGRect?
    /// Shows a toast (replacing the one showing). `actionTitle` + `action` add one button (usually Undo).
    func postToast(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?)
}

public extension FloatingHosting {
    /// `present(_:content:)` with a view builder.
    func present<Content: View>(_ id: String, @ViewBuilder content: () -> Content) {
        present(id, content: AnyView(content()))
    }

    func postToast(_ message: String) {
        postToast(message, actionTitle: nil, action: nil)
    }
}

/// A floating chrome element a feature contributes to every document window: the audio recording HUD and playback bar
/// (F052), the Zoom Window pane (F038), the ruler angle HUD (F039), the Return-to-page pill (F029), the timer bar
/// (F062), the presenter HUD (F063), a comment thread popover budded from its pin (F037). The document chrome (F017)
/// renders every visible overlay inside the window's one droplet container, so overlays merge, bud and recede with
/// the bars, and fade to 22 % while the Pencil is down (`EditorSession.inking`). Everything an overlay does still goes
/// through commands. Re-evaluated on registry changes, session changes and `UIRegistries.setNeedsChromeUpdate()`.
public struct ChromeOverlayDescriptor: Registrable {
    public var id: String
    /// Z-order: higher draws above lower (ties by id).
    public var order: Int
    public var owner: String
    public var placement: ChromePlacement
    public var surface: ChromeSurface
    /// Fades to the recede opacity while the Pencil is down in this window (DESIGN.md §10.8).
    public var recedesWhileWriting: Bool
    /// Takes touches inside its frame; false = display only (touches fall through to the canvas).
    public var isInteractive: Bool
    /// nil = every document kind.
    public var docKinds: Set<DocumentKind>?
    public var isVisible: @MainActor (ChromeContext) -> Bool
    /// `.anchored` only: what to point at (nil = hidden).
    public var anchor: (@MainActor (ChromeContext) -> ChromeAnchor?)?
    public var makeView: @MainActor (ChromeContext) -> AnyView

    public init(id: String, owner: String, placement: ChromePlacement, surface: ChromeSurface = .hud, order: Int = 0,
                recedesWhileWriting: Bool = true, isInteractive: Bool = true, docKinds: Set<DocumentKind>? = nil,
                isVisible: @escaping @MainActor (ChromeContext) -> Bool = { _ in true },
                anchor: (@MainActor (ChromeContext) -> ChromeAnchor?)? = nil,
                makeView: @escaping @MainActor (ChromeContext) -> AnyView) {
        self.id = id
        self.order = order
        self.owner = owner
        self.placement = placement
        self.surface = surface
        self.recedesWhileWriting = recedesWhileWriting
        self.isInteractive = isInteractive
        self.docKinds = docKinds
        self.isVisible = isVisible
        self.anchor = anchor
        self.makeView = makeView
    }
}

public extension Notification.Name {
    /// contracts-v2: posted by `UIRegistries.setNeedsChromeUpdate`; userInfo ["session": id] or nil for every window.
    static let nibChromeNeedsUpdate = Notification.Name("NibChromeNeedsUpdate")
}
```

### `NibKit/Sources/NibContracts/UI/NibApp.swift`

```swift
import Foundation
import UIKit
import BackgroundTasks

/// Every module (feature, engine, plugin host) exposes exactly one public type conforming to this,
/// named `<ModuleName>Feature`, e.g. `FeatPenFeature`. The app shell registers them all at launch.
@MainActor
public protocol NibFeature {
    /// Stable id, e.g. "pen". Used as `owner` of everything the feature registers.
    static var id: String { get }
    /// Register commands, services, drawers, templates, toolbar items, menus, panels, settings pages.
    /// Must be fast and must not resolve services or touch documents.
    static func register(_ app: NibApp)
    /// Called once after every feature registered (start watchers, restore state, load plugins).
    static func start(_ app: NibApp) async
}

@MainActor
public extension NibFeature {
    static func start(_ app: NibApp) async {}
}

/// The composition root: one per process, created by the app shell.
@MainActor
public final class NibApp {
    public private(set) static var shared: NibApp?
    /// True inside package tests (set by `Harness`): no app bundle, Info.plist or entitlements. Features must then
    /// skip system singletons that crash or prompt there — UNUserNotificationCenter, BGTaskScheduler, microphone /
    /// camera / Speech / EventKit / Photos authorization, live WKWebView — and throw `unavailable` instead.
    public static var isHostlessTest = false

    public let events: EventBus
    public let clock: HLCClock
    public let settings: SettingsStore
    public let workspace: Workspace
    public let commands: CommandRegistry
    public let gateway: Gateway
    public let services: NibServices
    public let bus: CommandBus
    public let content: ContentRegistries
    public let ui: UIRegistries
    public private(set) var featureIDs: [String] = []
    /// contracts-v2: true once `start(_:)` has run every feature's `start` (registry changes after this point are
    /// plugins, content packs or settings, not launch registration).
    public private(set) var isStarted = false

    /// contracts-v2: this app's device id as 8 lowercase hex characters (per-device package file names "doc.<hex>.json").
    /// Equals `DeviceIdentity.hex` in the app; each `Harness(deviceID:)` gets its own.
    public var deviceHex: String { clock.deviceHex }

    public init(persistence: DocumentPersistence? = nil, defaults: UserDefaults = .standard,
                deviceID: UInt32 = DeviceIdentity.current, makeShared: Bool = true) {
        let events = EventBus()
        let clock = HLCClock(device: deviceID)
        let settings = SettingsStore(defaults: defaults)
        // nil = InMemoryPersistence (created here: a main-actor init cannot be a default argument).
        let workspace = Workspace(clock: clock, persistence: persistence ?? InMemoryPersistence(), events: events)
        let commands = CommandRegistry()
        let gateway = Gateway()
        let services = NibServices(settings: settings)
        let content = ContentRegistries()
        self.events = events
        self.clock = clock
        self.settings = settings
        self.workspace = workspace
        self.commands = commands
        self.gateway = gateway
        self.services = services
        self.bus = CommandBus(registry: commands, workspace: workspace, gateway: gateway, services: services, events: events)
        self.content = content
        self.ui = UIRegistries()
        bus.content = content
        bus.app = self
        services.sessions.events = events
        CoreCommands.register(commands)
        NibSettings.declareAll(settings)
        if makeShared { NibApp.shared = self }
    }

    /// Registers features in order. Commands a feature registers with owner "builtin" are stamped with its id.
    public func register(_ features: [NibFeature.Type]) {
        for f in features {
            commands.defaultOwner = f.id
            f.register(self)
            commands.defaultOwner = nil
            featureIDs.append(f.id)
        }
    }

    /// Asks iOS to run the registered background task `id` (see `BackgroundTaskDescriptor`) no earlier than
    /// `earliestIn` seconds from now. The ONLY way features schedule BGTaskScheduler work; no-op in hostless tests.
    public func scheduleBackgroundTask(_ id: String, earliestIn: TimeInterval) {
        guard !NibApp.isHostlessTest, let d = content.backgroundTasks.get(id) else { return }
        let request: BGTaskRequest
        switch d.kind {
        case .refresh: request = BGAppRefreshTaskRequest(identifier: id)
        case .processing: request = BGProcessingTaskRequest(identifier: id)
        }
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestIn)
        try? BGTaskScheduler.shared.submit(request)
    }

    public func start(_ features: [NibFeature.Type]) async {
        for f in features { await f.start(self) }
        isStarted = true
    }

    /// contracts-v2: true when the document must not be written (see `CommandContext.isReadOnly`).
    public func isReadOnly(_ doc: DocumentID) -> Bool {
        workspace.isReadOnly(doc) || (services.get(ServiceKeys.storeReadOnly, as: NSSet.self)?.contains(doc.raw) ?? false)
    }

    /// Runs a command as the user from UI code (menus, buttons); errors are reported to the user by the shell.
    public func perform(_ command: String, _ params: JSONValue = [:], session: EditorSession? = nil) {
        Task { @MainActor in
            do {
                try await self.bus.execute(command, params, session: session ?? self.services.sessions.active)
            } catch {
                NotificationCenter.default.post(name: .nibCommandFailed, object: self,
                                                userInfo: ["command": command, "error": NibError.wrap(error)])
            }
        }
    }
}

public extension Notification.Name {
    /// userInfo: ["command": String, "error": NibError]. The shell shows a toast.
    static let nibCommandFailed = Notification.Name("NibCommandFailed")
}

/// Crash-loop protection: if two launches in a row die before `endLaunch`, the next launch is in safe mode
/// (plugins are not started, `SafeMode.disabledFeatures` are skipped).
public enum SafeMode {
    private static let crashKey = "nib.safemode.pendingLaunches"
    private static let disabledKey = "nib.safemode.disabledFeatures"

    public static var isActive: Bool { UserDefaults.standard.integer(forKey: crashKey) >= 2 }

    public static var disabledFeatures: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: disabledKey) }
    }

    public static func beginLaunch() {
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: crashKey) + 1, forKey: crashKey)
    }

    public static func endLaunch() {
        UserDefaults.standard.set(0, forKey: crashKey)
    }
}
```

### `NibKit/Sources/NibContracts/UI/Drawing.swift`

```swift
import UIKit

// Shared drawing used by the renderer (F004), export (F066), template thumbnails (F045), custom items, custom
// blocks and plugin decorations — so nobody re-implements it. Pure and thread-safe (render threads).

public extension DisplayList {
    /// Draws the ops into `cg` (1 unit = 1 page point, y down), offset by `origin` (a custom item's or block's
    /// top-left; `.zero` for templates). `image` ops read their asset from `assets` in document `doc`.
    func draw(in cg: CGContext, origin: Point = .zero, assets: AssetStore? = nil, doc: DocumentID? = nil) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.translateBy(x: CGFloat(origin.x), y: CGFloat(origin.y))
        for op in ops { DisplayList.draw(op, in: cg, assets: assets, doc: doc) }
    }

    private static func draw(_ op: DisplayOp, in cg: CGContext, assets: AssetStore?, doc: DocumentID?) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.setLineWidth(CGFloat(op.width ?? 1))
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        if let dash = op.dash, !dash.isEmpty { cg.setLineDash(phase: 0, lengths: dash.map { CGFloat($0) }) }
        if let s = op.stroke { cg.setStrokeColor(s.cgColor) }
        if let f = op.fill { cg.setFillColor(f.cgColor) }
        let r = op.rect?.cg ?? .zero
        func paint(_ path: CGPath, closed: Bool) {
            if closed && op.fill != nil {
                cg.addPath(path)
                cg.fillPath()
            }
            if op.stroke != nil {
                cg.addPath(path)
                cg.strokePath()
            }
        }
        switch op.op {
        case .rect:
            let radius = CGFloat(op.radius ?? 0)
            paint(CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2),
                         transform: nil), closed: true)
        case .ellipse:
            paint(CGPath(ellipseIn: r, transform: nil), closed: true)
        case .line, .polyline, .polygon:
            let pts = (op.points ?? []).map { $0.cg }
            guard pts.count >= 2 else { return }
            let path = CGMutablePath()
            path.addLines(between: pts)
            if op.op == .polygon { path.closeSubpath() }
            paint(path, closed: op.op == .polygon)
        case .text:
            guard let text = op.text else { return }
            let size = CGFloat(op.fontSize ?? 14)
            let font = op.fontName.flatMap { UIFont(name: $0, size: size) }
                ?? UIFont.systemFont(ofSize: size, weight: DisplayList.uiWeight(op.weight ?? .regular))
            var attributes: [NSAttributedString.Key: Any] = [.font: font,
                                                             .foregroundColor: (op.stroke ?? op.fill ?? .black).uiColor]
            if let align = op.align {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = RichTextBridge.alignment(align)
                attributes[.paragraphStyle] = paragraph
            }
            UIGraphicsPushContext(cg)
            (text as NSString).draw(in: r, withAttributes: attributes)
            UIGraphicsPopContext()
        case .image:
            guard let asset = op.asset, let doc = doc, let data = try? assets?.data(asset, doc: doc),
                  let image = UIImage(data: data)?.cgImage else { return }
            cg.translateBy(x: r.minX, y: r.maxY)
            cg.scaleBy(x: 1, y: -1)
            cg.draw(image, in: CGRect(origin: .zero, size: r.size))
        case .hlines, .vlines:
            let step = CGFloat(max(op.spacing ?? 24, 1))
            let path = CGMutablePath()
            if op.op == .hlines {
                var y = r.minY + step
                while y <= r.maxY {
                    path.move(to: CGPoint(x: r.minX, y: y))
                    path.addLine(to: CGPoint(x: r.maxX, y: y))
                    y += step
                }
            } else {
                var x = r.minX + step
                while x <= r.maxX {
                    path.move(to: CGPoint(x: x, y: r.minY))
                    path.addLine(to: CGPoint(x: x, y: r.maxY))
                    x += step
                }
            }
            if op.stroke != nil {
                cg.addPath(path)
                cg.strokePath()
            }
        case .dots:
            let step = CGFloat(max(op.spacing ?? 24, 1))
            let radius = CGFloat(op.radius ?? 1)
            if op.fill == nil, let s = op.stroke { cg.setFillColor(s.cgColor) }
            var y = r.minY + step
            while y <= r.maxY {
                var x = r.minX + step
                while x <= r.maxX {
                    cg.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
                    x += step
                }
                y += step
            }
        }
    }
}

extension DisplayList {
    static func uiWeight(_ w: DisplayFontWeight) -> UIFont.Weight {
        switch w {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }
}

/// Variable-width outline of a stroke as one closed polygon (left edge, round end cap, right edge reversed, round
/// start cap) built from each point's rendered width. Used for vector PDF export (F066), dashed strokes (F004) and
/// SVG. Synthetic strokes are prepared first (`InkModel.prepare`), so the outline matches what PencilKit draws.
public enum InkOutline {
    public static func polygon(_ stroke: Stroke, capSegments: Int = 6) -> [Point] {
        var s = stroke
        InkModel.prepare(&s)
        var raw = s.points
        InkModel.fillSizes(&raw, style: s.style)
        var p: [StrokePoint] = []
        for q in raw where p.last.map({ $0.x != q.x || $0.y != q.y }) ?? true { p.append(q) }
        guard let first = p.first else { return [] }
        if p.count == 1 { return cap(first.location, offset: Point(Double(max(first.width, 0.1)) / 2, 0), steps: 12, full: true) }
        var left: [Point] = []
        var right: [Point] = []
        var normals: [Point] = []
        for i in p.indices {
            let a = p[max(i - 1, 0)].location
            let b = p[min(i + 1, p.count - 1)].location
            let len = max(a.distance(to: b), 1e-9)
            let n = Point(-(b.y - a.y) / len, (b.x - a.x) / len)
            let r = Double(max(p[i].width, 0.1)) / 2
            let c = p[i].location
            left.append(c + n * r)
            right.append(c - n * r)
            normals.append(n * r)
        }
        let endCap = cap(p[p.count - 1].location, offset: normals[normals.count - 1], steps: capSegments, full: false)
        let startCap = cap(p[0].location, offset: normals[0] * -1, steps: capSegments, full: false)
        return left + endCap + right.reversed() + startCap
    }

    public static func path(_ stroke: Stroke) -> CGPath {
        let pts = polygon(stroke)
        let path = CGMutablePath()
        guard pts.count > 2 else { return path }
        path.addLines(between: pts.map { $0.cg })
        path.closeSubpath()
        return path
    }

    /// Points strictly between `center + offset` and `center - offset`, sweeping clockwise on screen (a full
    /// circle when `full`).
    static func cap(_ center: Point, offset: Point, steps: Int, full: Bool) -> [Point] {
        let n = max(steps, 2)
        let sweep = full ? 2 * Double.pi : Double.pi
        return (1..<(full ? n + 1 : n)).map { k in
            let th = -sweep * Double(k) / Double(n)
            return Point(center.x + offset.x * cos(th) - offset.y * sin(th), center.y + offset.x * sin(th) + offset.y * cos(th))
        }
    }
}
```

### `NibKit/Sources/NibContracts/NibPalette.swift`

Nib's colour tables (DESIGN.md §3.4–3.6) as hex plus `CGColor`, UIKit-free, so core modules (NibRender, NibExport) and NibDesign share one table; NibDesign adds `color`, `uiColor` and localised names (DESIGN_SYSTEM.md §1, item 6).

```swift
import CoreGraphics

/// Nib's colour data (DESIGN.md §3.4–3.6). UIKit-free, so core modules (NibRender, NibExport) share the one table.
/// Feature UI gets `color` / `uiColor` / `name` from the NibDesign extensions.
public protocol NibHexColour {
    var hex: UInt32 { get }
}

public extension NibHexColour {
    var cgColor: CGColor { NibPalette.cgColor(hex) }
}

public enum NibPalette {
    public static func cgColor(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// The 12 default inks. Ink is never themed: the same hex in light and dark mode.
public enum NibInk: String, CaseIterable, Sendable, NibHexColour {
    case carbon, graphite, midnight, cobalt, lagoon, moss, ochre, sienna, vermilion, crimson, plum, chalk

    public var hex: UInt32 {
        switch self {
        case .carbon: return 0x121212
        case .graphite: return 0x5B6068
        case .midnight: return 0x1B2A6B
        case .cobalt: return 0x2156D9
        case .lagoon: return 0x0B8793
        case .moss: return 0x2F7A3C
        case .ochre: return 0xB7791F
        case .sienna: return 0x9A4E2A
        case .vermilion: return 0xD9432B
        case .crimson: return 0xB0173A
        case .plum: return 0x7B3FA0
        case .chalk: return 0xF4F4F1
        }
    }

    /// Inks that vanish against the chrome get a permanent 1 pt ring in pickers: Chalk in light mode,
    /// Carbon and Midnight in dark mode.
    public func needsRing(dark: Bool) -> Bool { dark ? (self == .carbon || self == .midnight) : self == .chalk }
    /// The palette's quick slots on a fresh install.
    public static let quickSlots: [NibInk] = [.carbon, .cobalt, .vermilion]
}

/// Highlighters render beneath ink: multiply at 60 % on light paper, screen at 35 % on dark paper.
public enum NibHighlighter: String, CaseIterable, Sendable, NibHexColour {
    case lemon, apricot, mint, sky, lilac, blush

    public var hex: UInt32 {
        switch self {
        case .lemon: return 0xFFE45C
        case .apricot: return 0xFFBE6B
        case .mint: return 0x86E3AE
        case .sky: return 0x82CCFF
        case .lilac: return 0xC8A8FF
        case .blush: return 0xFFA3C7
        }
    }

    public static let lightPaperOpacity: Double = 0.60
    public static let darkPaperOpacity: Double = 0.35
}

/// Paper colours with their rule and margin-line colours.
public enum NibPaper: String, CaseIterable, Sendable, NibHexColour {
    case white, ivory, legal, grey, slate, night, board

    public var hex: UInt32 {
        switch self {
        case .white: return 0xFFFFFF
        case .ivory: return 0xFBF8F1
        case .legal: return 0xFCF3C8
        case .grey: return 0xF1F1EF
        case .slate: return 0x1E1F22
        case .night: return 0x121212
        case .board: return 0x1F2A24
        }
    }

    public var ruleHex: UInt32 {
        switch self {
        case .white: return 0xCFDBE8
        case .ivory: return 0xD9D3C5
        case .legal: return 0xB9C9DA
        case .grey: return 0xD2D4D8
        case .slate: return 0x34373D
        case .night: return 0x2A2C30
        case .board: return 0x33443A
        }
    }

    public var marginHex: UInt32? {
        switch self {
        case .white: return 0xEDB9B3
        case .ivory: return 0xE9B8A8
        case .legal: return 0xE3A49B
        case .slate: return 0x5A3A38
        case .grey, .night, .board: return nil
        }
    }

    /// Dark papers are not "light paper" for the droplets' backdrop (`nibBackdrop`).
    public var isDark: Bool { self == .slate || self == .night || self == .board }
}

/// Cover cloths: flat colour, a spine at −16 % luminance and an elastic band at −30 %.
public enum NibCoverCloth: String, CaseIterable, Sendable, NibHexColour {
    case moss, carbon, terracotta, sand, navy, oxblood, stone, paper

    public var hex: UInt32 {
        switch self {
        case .moss: return 0x2F4A3E
        case .carbon: return 0x2A2D33
        case .terracotta: return 0xA4553A
        case .sand: return 0xD5C6A8
        case .navy: return 0x23324F
        case .oxblood: return 0x5E1F24
        case .stone: return 0x8C8A84
        case .paper: return 0xF3F1EC
        }
    }

    public var isLight: Bool { self == .sand || self == .paper }
}

/// Collaborator colours; they never collide with ink.
public enum NibPresenceColour {
    public static let hexes: [UInt32] = [0xFF6B5E, 0xFFB547, 0x3DBB7A, 0x3C8DFF, 0x9C6BFF, 0xFF6FAE]
    public static func hex(_ index: Int) -> UInt32 { hexes[((index % hexes.count) + hexes.count) % hexes.count] }
}
```

### `NibKit/Sources/NibTesting/TestHarness.swift`

```swift
import Foundation
import UIKit
import NibContracts

/// Fixed ids used by command `examples` and tests. Every record kind exists, so every `.edit` example can target a
/// real record:
/// - FIXTUREDOC01 notebook — FIXTUREPG001 (A4 ruled) holds one item of EVERY kind (stroke, shape, text, sticky, tape,
///   connector shape→sticky, comment, math, image, custom); FIXTUREPG002 is empty; FIXTUREPG003's background is a
///   one-page PDF asset. Outline entry FIXTUREOUT01; audio clip FIXTUREAUD01 with a two-line transcript.
/// - FIXTUREDOC02 text document — heading FIXTUREBLK01, paragraph FIXTUREBLK02 (block comment FIXTURECMB01),
///   2×2 table FIXTUREBLK03.
/// - FIXTUREDOC03 study set — cards FIXTURECRD01 (text/text) and FIXTURECRD02 (text/image, with SRS state).
/// - FIXTUREDOC04 whiteboard — one infinite board FIXTUREBRD01 holding shape FIXTUREBSH01.
/// Every document also holds the assets `pngAsset` and `pdfAsset`.
public enum Fixtures {
    public static let docID: DocumentID = "FIXTUREDOC01"
    public static let textDocID: DocumentID = "FIXTUREDOC02"
    public static let studySetID: DocumentID = "FIXTUREDOC03"
    public static let whiteboardID: DocumentID = "FIXTUREDOC04"
    public static let allDocuments: [DocumentID] = [docID, textDocID, studySetID, whiteboardID]

    public static let page1: PageID = "FIXTUREPG001"
    public static let page2: PageID = "FIXTUREPG002"
    public static let pdfPage: PageID = "FIXTUREPG003"
    public static let boardID: PageID = "FIXTUREBRD01"

    public static let strokeID: ElementID = "FIXTURESTK01"
    public static let shapeID: ElementID = "FIXTURESHP01"
    public static let textID: ElementID = "FIXTURETXT01"
    public static let stickyID: ElementID = "FIXTURESTY01"
    public static let tapeID: ElementID = "FIXTURETAP01"
    public static let connectorID: ElementID = "FIXTURECON01"
    public static let commentID: ElementID = "FIXTURECMT01"
    public static let commentMessageID: NibID = "FIXTUREMSG01"
    public static let mathID: ElementID = "FIXTUREMTH01"
    public static let imageID: ElementID = "FIXTUREIMG01"
    public static let customID: ElementID = "FIXTURECUS01"
    public static let boardShapeID: ElementID = "FIXTUREBSH01"

    public static let outlineID: NibID = "FIXTUREOUT01"
    public static let audioID: NibID = "FIXTUREAUD01"
    public static let headingBlockID: NibID = "FIXTUREBLK01"
    public static let paragraphBlockID: NibID = "FIXTUREBLK02"
    public static let tableBlockID: NibID = "FIXTUREBLK03"
    public static let blockCommentID: NibID = "FIXTURECMB01"
    public static let card1: NibID = "FIXTURECRD01"
    public static let card2: NibID = "FIXTURECRD02"
    public static let folderID: FolderID = "FIXTUREFLD01"

    /// Installed in every fixture document under these fixed names.
    public static let pngAsset = AssetRef("fixture-image.png")
    public static let pdfAsset = AssetRef("fixture-page.pdf")
    /// A 1×1 PNG.
    public static let pngData = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    /// A one-page A4 PDF with one line of text.
    public static func pdfData() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595.28, height: 841.89)).pdfData { ctx in
            ctx.beginPage()
            ("Fixture PDF text" as NSString).draw(at: CGPoint(x: 72, y: 72),
                                                  withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
    }

    static let base = Rev(wallMs: 1, counter: 0, device: 0)

    static func stamped(_ items: [Item]) -> [Item] {
        items.map { i -> Item in
            var i = i
            i.rev = base
            return i
        }
    }

    /// The notebook FIXTUREDOC01.
    public static func sampleContent() -> (DocumentContent, [PageID: [Item]]) {
        var meta = DocumentMeta(id: docID, kind: .notebook, createdAt: 1_700_000_000)
        meta.rev = base
        var p1 = PageRecord(id: page1, order: "V", size: .a4, background: .ofTemplate("builtin.ruled"))
        var p2 = PageRecord(id: page2, order: "k", size: .a4, background: .ofTemplate("builtin.ruled"))
        var p3 = PageRecord(id: pdfPage, order: "t", size: .a4, background: .ofPDF(pdfAsset, page: 0))
        p1.rev = base
        p2.rev = base
        p3.rev = base
        var outline = OutlineEntry(id: outlineID, title: "Fixture section", page: page1, order: "V")
        outline.rev = base
        var clip = AudioClip(id: audioID, name: "Fixture recording", file: "audio/FIXTUREAUD01.caf",
                             start: 1_700_000_000, duration: 600, page: page1)
        clip.transcriptFile = "audio/FIXTUREAUD01.transcript"
        clip.rev = base
        let content = DocumentContent(meta: meta, pages: [p1, p2, p3], outline: [outline], audio: [clip])

        let z = FractionalIndex.sequence(after: nil, count: 10)
        let pts: [StrokePoint] = (0..<20).map { (i: Int) -> StrokePoint in
            let x = Float(72 + i * 4), y = Float(120 + i % 5), t = Float(i) * 0.01
            return StrokePoint(x: x, y: y, t: t)
        }
        let tapePts = [StrokePoint(x: 80, y: 600, width: 18, height: 18), StrokePoint(x: 260, y: 600, width: 18, height: 18)]
        let box = DisplayList(ops: [DisplayOp(op: .rect, rect: Rect(x: 0, y: 0, width: 100, height: 50), stroke: .black)])
        let items: [Item] = [
            Item(id: strokeID, kind: .stroke, z: z[0], stroke: Stroke(style: .defaultPen, points: pts, t0: 1_700_000_100)),
            Item(id: shapeID, kind: .shape, z: z[1],
                 shape: ShapeItem(shape: .rectangle, frame: Frame(x: 100, y: 200, w: 160, h: 90))),
            Item(id: textID, kind: .text, z: z[2],
                 text: TextBoxItem(frame: Frame(x: 72, y: 400, w: 300, h: 40), text: RichText(plain: "Hello Nib"))),
            Item(id: stickyID, kind: .sticky, z: z[3],
                 sticky: StickyItem(frame: Frame(x: 400, y: 120, w: 140, h: 140), text: RichText(plain: "Remember"))),
            Item(id: tapeID, kind: .stroke, z: z[4], stroke: Stroke(style: .defaultTape, points: tapePts, t0: 1_700_000_200)),
            Item(id: connectorID, kind: .connector, z: z[5],
                 connector: ConnectorItem(from: ConnectorEnd(point: Point(260, 245), item: shapeID, side: 1, t: 0.5),
                                          to: ConnectorEnd(point: Point(400, 190), item: stickyID, side: 3, t: 0.5))),
            Item(id: commentID, kind: .comment, z: z[6],
                 comment: CommentItem(anchor: Point(560, 400), messages: [
                     CommentMessage(id: commentMessageID, author: "Fixture", text: "Check this", at: 1_700_000_300)])),
            Item(id: mathID, kind: .math, z: z[7],
                 math: MathItem(frame: Frame(x: 72, y: 480, w: 120, h: 40), latex: ["\\frac{a}{b}"])),
            Item(id: imageID, kind: .image, z: z[8],
                 image: ImageItem(frame: Frame(x: 320, y: 480, w: 64, h: 64), asset: pngAsset)),
            Item(id: customID, kind: .custom, z: z[9],
                 custom: CustomItem(owner: "nib.fixture", type: "box", frame: Frame(x: 72, y: 700, w: 100, h: 50),
                                    data: ["title": "Fixture box"], display: box))
        ]
        return (content, [page1: stamped(items), page2: [], pdfPage: []])
    }

    /// Every fixture document with its page items and library title.
    public static func documents() -> [(content: DocumentContent, items: [PageID: [Item]], title: String)] {
        let (notebook, notebookItems) = sampleContent()

        var textMeta = DocumentMeta(id: textDocID, kind: .textDocument, createdAt: 1_700_000_000)
        textMeta.rev = base
        var heading = TextBlock(id: headingBlockID, kind: .heading1, text: RichText(plain: "Fixture Text"), order: "V")
        var paragraph = TextBlock(id: paragraphBlockID, kind: .paragraph, text: RichText(plain: "Hello blocks"), order: "k")
        paragraph.comments = [BlockComment(id: blockCommentID, author: "Fixture", text: "Nice", at: 1_700_000_300,
                                           rangeStart: 0, rangeLength: 5)]
        var table = TextBlock(id: tableBlockID, kind: .table, order: "t")
        table.table = TableData(rows: [[TableCell(text: RichText(plain: "A1")), TableCell(text: RichText(plain: "B1"))],
                                       [TableCell(text: RichText(plain: "A2")), TableCell(text: RichText(plain: "B2"))]])
        heading.rev = base
        paragraph.rev = base
        table.rev = base
        let textDoc = DocumentContent(meta: textMeta, blocks: [heading, paragraph, table])

        var studyMeta = DocumentMeta(id: studySetID, kind: .studySet, createdAt: 1_700_000_000)
        studyMeta.rev = base
        var c1 = StudyCard(id: card1, front: CardFace(text: RichText(plain: "Term")),
                           back: CardFace(text: RichText(plain: "Definition")), order: "V")
        var c2 = StudyCard(id: card2, front: CardFace(text: RichText(plain: "Picture")),
                           back: CardFace(kind: .image, asset: pngAsset), order: "k")
        c2.srs = SRSState(due: 1_700_086_400, interval: 1, reps: 1)
        c1.rev = base
        c2.rev = base
        let studySet = DocumentContent(meta: studyMeta, cards: [c1, c2])

        var boardMeta = DocumentMeta(id: whiteboardID, kind: .whiteboard, createdAt: 1_700_000_000)
        boardMeta.rev = base
        var board = PageRecord(id: boardID, order: "V", size: nil, background: .ofTemplate("builtin.whiteboardDots"),
                               title: "Board 1")
        board.rev = base
        let whiteboard = DocumentContent(meta: boardMeta, pages: [board])
        let boardItems = stamped([Item(id: boardShapeID, kind: .shape, z: "V",
                                       shape: ShapeItem(shape: .ellipse, frame: Frame(x: 0, y: 0, w: 200, h: 120)))])

        return [(notebook, notebookItems, "Fixture Notebook"),
                (textDoc, [:], "Fixture Text Document"),
                (studySet, [:], "Fixture Study Set"),
                (whiteboard, [boardID: boardItems], "Fixture Whiteboard")]
    }

    @MainActor
    public static func install(into persistence: InMemoryPersistence, library: InMemoryLibrary, assets: InMemoryAssetStore) {
        _ = try? library.createFolder(title: "Fixtures", in: nil, style: nil, id: folderID)
        let pdf = pdfData()
        for doc in documents() {
            let id = doc.content.meta.id
            _ = try? library.createDocument(doc.content, title: doc.title, in: folderID)
            for (page, list) in doc.items { persistence.pageItems[id, default: [:]][page] = list }
            assets.install(pngData, as: pngAsset, doc: id)
            assets.install(pdf, as: pdfAsset, doc: id)
        }
        let transcript = [TranscriptSegment(index: 0, start: 0, duration: 4, text: "Welcome to the fixture lecture."),
                          TranscriptSegment(index: 1, start: 4, duration: 5, text: "Velocity is displacement over time.")]
        if let url = try? persistence.fileURL(docID, relativePath: "audio/FIXTUREAUD01.transcript.json"),
           let data = try? JSONEncoder().encode(transcript) {
            try? data.write(to: url)
        }
    }
}

/// In-memory `LibraryService` for tests (and the app shell when no Library Store feature is present).
@MainActor
public final class InMemoryLibrary: LibraryService {
    public let rootURL: URL
    public var metadataURL: URL { rootURL.appendingPathComponent(NibFormat.libraryDirectory, isDirectory: true) }
    public private(set) var nodes: [NibID: LibraryNode] = [:]
    private let persistence: InMemoryPersistence
    private let locator: PackageLocator?

    /// `locator` (usually `app.services.packages`) is kept in sync, like the real Library Store does.
    public init(persistence: InMemoryPersistence, locator: PackageLocator? = nil) {
        self.persistence = persistence
        self.rootURL = persistence.root
        self.locator = locator
    }

    public func allNodes() -> [LibraryNode] {
        nodes.values.filter { $0.trashedAt == nil }.sorted { $0.title < $1.title }
    }

    public func node(_ id: NibID) -> LibraryNode? { nodes[id] }

    public func children(of folder: FolderID?) -> [LibraryNode] {
        allNodes().filter { $0.parent == folder }
    }

    public func packageURL(_ doc: DocumentID) -> URL? {
        nodes[doc] == nil ? nil : rootURL.appendingPathComponent(doc.raw + "." + NibFormat.packageExtension, isDirectory: true)
    }

    public func createDocument(_ content: DocumentContent, title: String, in folder: FolderID?) throws -> DocumentID {
        let id = content.meta.id
        persistence.heads[id] = content
        let now = Date().timeIntervalSince1970
        nodes[id] = LibraryNode(id: id, kind: .document, title: title, path: title, parent: folder,
                                documentKind: content.meta.kind, modified: now, created: now,
                                pageCount: content.livePages.count)
        locator?.set(packageURL(id), for: id)
        return id
    }

    public func createFolder(title: String, in parent: FolderID?, style: FolderStyle?) throws -> FolderID {
        try createFolder(title: title, in: parent, style: style, id: NibID.make())
    }

    public func createFolder(title: String, in parent: FolderID?, style: FolderStyle?, id: FolderID) throws -> FolderID {
        let now = Date().timeIntervalSince1970
        nodes[id] = LibraryNode(id: id, kind: .folder, title: title, path: title, parent: parent, modified: now,
                                created: now, style: style)
        return id
    }

    public func rename(_ id: NibID, to title: String) throws {
        guard var n = nodes[id] else { throw NibError.notFound("library item \(id)") }
        n.title = title
        nodes[id] = n
    }

    public func move(_ id: NibID, to folder: FolderID?) throws {
        guard var n = nodes[id] else { throw NibError.notFound("library item \(id)") }
        n.parent = folder
        nodes[id] = n
    }

    public func duplicate(_ id: NibID) throws -> NibID {
        guard let n = nodes[id] else { throw NibError.notFound("library item \(id)") }
        guard n.kind == .document, var content = persistence.heads[id] else {
            return try createFolder(title: n.title + " copy", in: n.parent, style: n.style)
        }
        let newID = NibID.make()
        content.meta.id = newID
        persistence.pageItems[newID] = persistence.pageItems[id]
        return try createDocument(content, title: n.title + " copy", in: n.parent)
    }

    public func setStyle(_ style: FolderStyle, folder: FolderID) throws {
        guard var n = nodes[folder] else { throw NibError.notFound("folder \(folder)") }
        n.style = style
        n.favorite = style.favorite
        nodes[folder] = n
    }

    public func trash(_ id: NibID) throws {
        guard var n = nodes[id] else { throw NibError.notFound("library item \(id)") }
        n.trashedAt = Date().timeIntervalSince1970
        nodes[id] = n
    }

    public func trashedNodes() -> [LibraryNode] { nodes.values.filter { $0.trashedAt != nil } }

    public func restore(_ id: NibID, to folder: FolderID?) throws {
        guard var n = nodes[id] else { throw NibError.notFound("library item \(id)") }
        n.trashedAt = nil
        if let f = folder { n.parent = f }
        nodes[id] = n
    }

    public func deletePermanently(_ id: NibID) throws {
        nodes[id] = nil
        persistence.heads[id] = nil
        persistence.pageItems[id] = nil
        locator?.set(nil, for: id)
    }

    public func importPackage(at url: URL, into folder: FolderID?) throws -> DocumentID {
        throw NibError.unsupported("package import in InMemoryLibrary")
    }

    public func refresh() {}

    public func setRoot(_ url: URL) throws {
        throw NibError.unsupported("changing the root of InMemoryLibrary")
    }
}

/// Content-addressed assets kept in memory (files are written on demand for `url`).
public final class InMemoryAssetStore: AssetStore {
    private var blobs: [String: Data] = [:]
    private let lock = NSLock()
    private let root: URL

    public init(root: URL) { self.root = root }

    public func put(_ data: Data, ext: String, doc: DocumentID) throws -> AssetRef {
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let ref = AssetRef(String(format: "%016llx", h) + "." + ext.lowercased())
        lock.lock()
        blobs[doc.raw + "/" + ref.name] = data
        lock.unlock()
        return ref
    }

    public func url(_ ref: AssetRef, doc: DocumentID) -> URL? {
        guard let data = try? self.data(ref, doc: doc) else { return nil }
        let url = root.appendingPathComponent(doc.raw, isDirectory: true).appendingPathComponent("assets/" + ref.name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
        return url
    }

    public func data(_ ref: AssetRef, doc: DocumentID) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let d = blobs[doc.raw + "/" + ref.name] else { throw NibError.notFound("asset \(ref.name)") }
        return d
    }

    /// Stores `data` under a fixed name (fixtures).
    public func install(_ data: Data, as ref: AssetRef, doc: DocumentID) {
        lock.lock()
        blobs[doc.raw + "/" + ref.name] = data
        lock.unlock()
    }

    public func putTemporary(_ data: Data, ext: String) throws -> AssetRef {
        try put(data, ext: ext, doc: NibID("_tmp"))
    }

    public func temporaryURL(_ ref: AssetRef) -> URL? { url(ref, doc: NibID("_tmp")) }
}

/// Confirms (or denies) every request and records it.
@MainActor
public final class AutoConfirm: ConfirmationPresenter {
    public var decision: ConfirmationDecision = .allow
    public private(set) var requests: [ConfirmationRequest] = []
    public init() {}
    public func confirm(_ request: ConfirmationRequest) async -> ConfirmationDecision {
        requests.append(request)
        return decision
    }
}

/// A ready-to-use app for tests: in-memory storage and secrets, every fixture document, one session, auto-confirm.
/// Marks the process as a hostless test (`NibApp.isHostlessTest`). Test classes using it must be `@MainActor`.
@MainActor
public final class Harness {
    public let app: NibApp
    public let persistence: InMemoryPersistence
    public let library: InMemoryLibrary
    public let assets: InMemoryAssetStore
    public let session: EditorSession
    public let confirmer: AutoConfirm

    /// `deviceID` lets two-device tests (sync, collaboration) give each app its own HLC device id (e.g. 7 and 8).
    /// contracts-v2: `keepFeatureServices: true` keeps the persistence, library and asset store the features installed
    /// in `register` (the real store in F001/F025 acceptance tests) instead of putting the in-memory ones back.
    public init(features: [NibFeature.Type] = [], fixtures: Bool = true, deviceID: UInt32 = 7,
                keepFeatureServices: Bool = false) {
        NibApp.isHostlessTest = true
        if !(Keychain.store is InMemorySecretStore) { Keychain.store = InMemorySecretStore() }
        let persistence = InMemoryPersistence()
        let defaults = UserDefaults(suiteName: "nib.tests." + UUID().uuidString) ?? .standard
        let app = NibApp(persistence: persistence, defaults: defaults, deviceID: deviceID)
        let library = InMemoryLibrary(persistence: persistence, locator: app.services.packages)
        let assets = InMemoryAssetStore(root: persistence.root)
        app.services.library = library
        app.services.assets = assets
        let session = EditorSession()
        app.services.sessions.add(session)
        let confirmer = AutoConfirm()
        app.gateway.presenter = confirmer
        self.app = app
        self.persistence = persistence
        self.library = library
        self.assets = assets
        self.session = session
        self.confirmer = confirmer
        if fixtures {
            Fixtures.install(into: persistence, library: library, assets: assets)
            session.document = Fixtures.docID
            session.page = Fixtures.page1
        }
        app.register(features)
        // Features may install real services in `register`; tests keep the in-memory ones unless asked not to.
        if !keepFeatureServices {
            app.workspace.persistence = persistence
            app.services.library = library
            app.services.assets = assets
            app.settings.syncedBackend = nil
        }
    }

    /// contracts-v2: writes items onto a page as the user in ONE undo step (one batch `DocTransaction.put`), without
    /// needing the features that own ink or item commands. Returns the written items (z, rev and provenance stamped).
    @discardableResult
    public func insert(_ items: [Item], page: PageID = Fixtures.page1, doc: DocumentID = Fixtures.docID) async throws -> [Item] {
        let id = "nibtesting.insert"
        var written: [Item] = []
        app.commands.register(CommandDescriptor(id: id, title: "Insert Items", summary: "NibTesting helper.",
                                                effect: .edit, exposure: .ui)) { _, ctx in
            written = try ctx.mutate { tx in try tx.put(items, doc: doc, page: page) }
            return .null
        }
        defer { app.commands.unregister(id: id) }
        try await app.bus.execute(Invocation(command: id, session: session))
        return written
    }

    /// Runs a command through the JSON path (validation, permissions, confirmation) and returns its value.
    @discardableResult
    public func run(_ command: String, _ params: JSONValue = [:], as principal: Principal = .user) async throws -> JSONValue {
        try await app.bus.execute(Invocation(command: command, params: params, principal: principal, session: session)).value
    }

    /// Undo-stack depth of a document.
    public func undoDepth(_ doc: DocumentID) -> Int { app.bus.history.entries(doc).count }

    /// Undo-stack depths of every fixture document.
    public func undoDepths() -> [DocumentID: Int] {
        Dictionary(uniqueKeysWithValues: Fixtures.allDocuments.map { ($0, undoDepth($0)) })
    }

    /// Document state without revisions and tombstones (for before/after comparisons).
    public func snapshot(_ doc: DocumentID = Fixtures.docID) throws -> JSONValue {
        var c = try app.workspace.content(doc)
        c.meta.rev = .zero
        c.pages = c.pages.filter { !$0.deleted }.map { p -> PageRecord in
            var p = p
            p.rev = .zero
            return p
        }.sorted { $0.id < $1.id }
        c.outline = c.outline.filter { !$0.deleted }.map { e -> OutlineEntry in
            var e = e
            e.rev = .zero
            return e
        }.sorted { $0.id < $1.id }
        c.blocks = c.blocks.filter { !$0.deleted }.map { b -> TextBlock in
            var b = b
            b.rev = .zero
            return b
        }.sorted { $0.id < $1.id }
        c.cards = c.cards.filter { !$0.deleted }.map { x -> StudyCard in
            var x = x
            x.rev = .zero
            return x
        }.sorted { $0.id < $1.id }
        c.audio = c.audio.filter { !$0.deleted }.map { a -> AudioClip in
            var a = a
            a.rev = .zero
            return a
        }.sorted { $0.id < $1.id }
        var pages: [String: JSONValue] = [:]
        for p in c.pages {
            let items = try app.workspace.items(doc, page: p.id).map { i -> Item in
                var i = i
                i.rev = .zero
                i.createdBy = nil
                return i
            }.sorted { $0.id < $1.id }
            pages[p.id.raw] = try JSONValue.from(items)
        }
        let contentJSON = try JSONValue.from(c)
        return ["content": contentJSON, "items": .object(pages)]
    }

    /// Snapshot of every fixture document.
    public func snapshotAll() throws -> JSONValue {
        var o: [String: JSONValue] = [:]
        for d in Fixtures.allDocuments { o[d.raw] = try snapshot(d) }
        return .object(o)
    }
}

/// Registry-wide checks run in CI (see ConformanceTests). Returns human-readable problems (empty = pass):
/// - descriptor hygiene (id pattern, one-line summary, examples that validate);
/// - every feature command is owned by its feature (not "builtin") and no id is registered twice;
/// - every example of every `.edit` command: undo of every fixture document it touched restores all of them
///   (`undoable: false` commands must instead leave every undo stack unchanged);
/// - `.edit`/`.library` commands that create records and return `ref`/`refs` declare a caller-chosen `id`/`ids`
///   param, and a given `id` is honoured;
/// - every typed setting used while running examples was declared.
/// `unavailable`/`unsupported` results (missing optional features, hostless limits) are skipped.
@MainActor
public enum CommandConformance {
    public static func check(features: [NibFeature.Type], owners: Set<String>? = nil) async -> [String] {
        var problems: [String] = []
        let core = Set(Harness(features: []).app.commands.all().map { $0.id })
        let probe = Harness(features: features)
        var undeclared = Set(probe.app.settings.undeclaredNames)
        for id in probe.app.commands.duplicateIDs {
            problems.append("\(id): registered twice (the later registration replaced the earlier one)")
        }
        let pattern = "^[a-z][a-zA-Z0-9]*(\\.[a-zA-Z0-9]+)+$"
        for d in probe.app.commands.all() where owners.map({ $0.contains(d.owner) }) ?? true {
            if d.owner == "builtin" && !core.contains(d.id) {
                problems.append("\(d.id): owner is 'builtin'; register feature commands inside the feature's register(_:)")
            }
            if d.summary.contains("\n") || d.summary.count > 200 { problems.append("\(d.id): summary must be one line of at most 200 characters") }
            if d.id.range(of: pattern, options: .regularExpression) == nil { problems.append("\(d.id): id must look like namespace.verb") }
            if d.toolName.count > 64 { problems.append("\(d.id): id too long for LLM tool names") }
            if d.examples.isEmpty && d.exposure.contains(.ai) { problems.append("\(d.id): needs at least one example") }
            for ex in d.examples {
                for e in d.params.validate(ex) { problems.append("\(d.id): example \(ex.jsonString()) fails schema: \(e)") }
            }
            // userPresence and sensitive commands (system UI, microphone, networking) are not executed here.
            guard d.effect == .edit || d.effect == .library, !d.userPresence, !d.sensitive, !core.contains(d.id) else { continue }
            for ex in d.examples {
                let h = Harness(features: features)
                do {
                    let before = try h.snapshotAll()
                    let depths = h.undoDepths()
                    let r = try await h.app.bus.execute(Invocation(command: d.id, params: ex, session: h.session))
                    undeclared.formUnion(h.app.settings.undeclaredNames)
                    if !r.changes.created.isEmpty, r.value["ref"] != nil || r.value["refs"] != nil, !declaresID(d) {
                        problems.append("\(d.id): creates records and returns refs but has no caller-chosen `id`/`ids` param")
                    }
                    guard d.effect == .edit else { continue }
                    if d.undoable {
                        for doc in Fixtures.allDocuments where h.undoDepth(doc) > (depths[doc] ?? 0) { h.app.bus.undo(doc) }
                        if try h.snapshotAll() != before {
                            problems.append("\(d.id): undo did not restore the documents for example \(ex.jsonString())")
                        }
                    } else if h.undoDepths() != depths {
                        problems.append("\(d.id): declared undoable: false but added undo entries")
                    }
                } catch let e as NibError where e.code == .unavailable || e.code == .unsupported {
                    continue
                } catch {
                    if d.effect == .edit { problems.append("\(d.id): example \(ex.jsonString()) failed: \(error)") }
                }
            }
            if declaresID(d), let ex = d.examples.first, case .object(var params) = ex {
                params["id"] = "CONFORMID0001"
                let h = Harness(features: features)
                if let r = try? await h.app.bus.execute(Invocation(command: d.id, params: .object(params), session: h.session)),
                   let ref = r.value["ref"]?.stringValue, !ref.hasSuffix("CONFORMID0001") {
                    problems.append("\(d.id): ignores the caller-chosen id (returned \(ref))")
                }
            }
        }
        for name in undeclared.sorted() {
            problems.append("setting '\(name)' is used but never declared (SettingsStore.declare in register)")
        }
        return problems
    }

    static func declaresID(_ d: CommandDescriptor) -> Bool {
        if case let .object(properties, _, _) = d.params { return properties["id"] != nil || properties["ids"] != nil }
        return false
    }
}
```

### `NibKit/Sources/NibTesting/Fakes.swift`

```swift
import Foundation
import UIKit
import NibContracts

// Service fakes shared by every feature's tests, so nobody writes their own. Install what you need:
//   let h = Harness(); let ai = FakeAIService(); h.app.services.ai = ai

/// Secrets in memory (hostless tests have no Keychain entitlement). `Harness` installs one as `Keychain.store`.
public final class InMemorySecretStore: SecretStore {
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func set(_ data: Data?, service: String, account: String) -> Bool {
        lock.lock()
        values[service + "/" + account] = data
        lock.unlock()
        return true
    }

    public func get(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[service + "/" + account]
    }
}

/// Renders blank images of the requested size; `marks` is returned verbatim when requested.
public final class FakeRenderer: PageRenderer {
    public var marks: [String: String] = [:]
    public private(set) var requests: [RenderRequest] = []
    public private(set) var invalidations: [(DocumentID, PageID, Rect?)] = []
    public var pageSize = PageSize.a4

    public init() {}

    public func render(_ request: RenderRequest) async throws -> RenderResult {
        requests.append(request)
        let region = request.region ?? Rect(x: 0, y: 0, width: pageSize.width, height: pageSize.height)
        let size = CGSize(width: max(1, region.width * request.scale), height: max(1, region.height * request.scale))
        return RenderResult(image: FakeRenderer.blank(size), region: region, scale: request.scale,
                            marks: request.marks ? marks : [:])
    }

    public func thumbnail(doc: DocumentID, page: PageID, maxPixelSize: Int) async -> CGImage? {
        FakeRenderer.blank(CGSize(width: maxPixelSize, height: maxPixelSize))
    }

    public func invalidate(doc: DocumentID, page: PageID, rect: Rect?) { invalidations.append((doc, page, rect)) }
    public func purgeCaches() {}

    public static func blank(_ size: CGSize) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }.cgImage!
    }
}

/// Returns `script` for every recognition call (set it per test); records calls.
public final class FakeRecognizer: TextRecognizer {
    public var script: [TextRecognition] = []
    public private(set) var strokeCalls = 0
    public private(set) var imageCalls = 0

    public init(_ script: [TextRecognition] = []) { self.script = script }

    public func recognize(strokes: [Item], language: String) async throws -> [TextRecognition] {
        strokeCalls += 1
        return script
    }

    public func recognize(image: CGImage, language: String) async throws -> [TextRecognition] {
        imageCalls += 1
        return script
    }
}

/// Scripted AI: each turn pops the next `responses` entry (else echoes), first running its `toolCalls` through the
/// bus as the request's principal in the turn's undo group (so "one turn = one undo step" is testable).
@MainActor
public final class FakeAIService: AIService {
    public struct Turn {
        public var text: String
        public var toolCalls: [(command: String, params: JSONValue)]
        public init(text: String, toolCalls: [(command: String, params: JSONValue)] = []) {
            self.text = text
            self.toolCalls = toolCalls
        }
    }

    public var isConfigured = true
    public var supportsVision = true
    public var responses: [Turn] = []
    public var transcript: [TranscriptSegment] = []
    public private(set) var requests: [AIRequest] = []
    /// Needed only when turns carry tool calls.
    public weak var bus: CommandBus?
    private var store: [String: [AIMessage]] = [:]

    public init(responses: [Turn] = [], bus: CommandBus? = nil) {
        self.responses = responses
        self.bus = bus
    }

    public func complete(_ request: AIRequest) async throws -> AIResponse {
        requests.append(request)
        let turn = responses.isEmpty ? Turn(text: request.messages.last?.text ?? "") : responses.removeFirst()
        let group = request.group ?? NibID.make().raw
        var changes = ChangeSummary()
        for call in turn.toolCalls {
            guard let bus = bus else { throw NibError.unavailable("FakeAIService.bus") }
            let r = try await bus.execute(Invocation(command: call.command, params: call.params, principal: request.principal,
                                                     group: group, readOnly: request.mode == .ask))
            changes.merge(r.changes)
        }
        let chat = request.chatID ?? "fake-chat"
        store[chat, default: []] += request.messages + [AIMessage(role: "assistant", text: turn.text)]
        return AIResponse(text: turn.text, changes: changes, group: group, chatID: chat)
    }

    public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    let r = try await self.complete(request)
                    continuation.yield(.text(r.text))
                    continuation.yield(.finished(r))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func cancel(chatID: String) {}
    public func chats(doc: DocumentID?) -> [AIChatSummary] {
        store.keys.sorted().map { AIChatSummary(id: $0, title: $0, doc: doc, updated: 0) }
    }
    public func messages(chatID: String) -> [AIMessage] { store[chatID] ?? [] }
    public func deleteChat(_ chatID: String) { store[chatID] = nil }
    public func transcribe(audio: URL, language: String?) async throws -> [TranscriptSegment] { transcript }
    public func generateImage(prompt: String) async throws -> Data { Fixtures.pngData }
}

/// Scripted PDF facts keyed by file name (`url.lastPathComponent`).
public final class FakePDFService: PDFService {
    public var pages: [String: Int] = [:]
    public var texts: [String: String] = [:]
    public var linkMap: [String: [PDFLinkInfo]] = [:]
    public var outlines: [String: [PDFOutlineNode]] = [:]
    /// contracts-v2: words per file name for `word(_:page:at:)` (the first whose rect contains the point).
    public var words: [String: [(text: String, rect: Rect)]] = [:]

    public init() {}

    public func pageCount(_ url: URL) -> Int { pages[url.lastPathComponent] ?? 1 }
    public func pageSize(_ url: URL, page: Int) -> PageSize? { .a4 }
    public func text(_ url: URL, page: Int) -> String? { texts[url.lastPathComponent] }
    public func textBlocks(_ url: URL, page: Int) -> [TextRecognition] {
        texts[url.lastPathComponent].map { [TextRecognition(text: $0, bbox: Rect(x: 72, y: 72, width: 400, height: 20), source: "pdf")] } ?? []
    }
    public func links(_ url: URL, page: Int) -> [PDFLinkInfo] { linkMap[url.lastPathComponent] ?? [] }
    public func outline(_ url: URL) -> [PDFOutlineNode] { outlines[url.lastPathComponent] ?? [] }
    public func selection(_ url: URL, page: Int, from: Point, to: Point) -> (text: String, rects: [Rect]) {
        (texts[url.lastPathComponent] ?? "", [Rect(x: from.x, y: from.y, width: max(1, to.x - from.x), height: 18)])
    }
    public func word(_ url: URL, page: Int, at point: Point) -> (text: String, rect: Rect)? {
        words[url.lastPathComponent]?.first { $0.rect.contains(point) }
    }
}

/// Locks the documents in `locked`; `unlock` succeeds when `unlockSucceeds`.
@MainActor
public final class FakeLockService: LockService {
    public var locked: Set<DocumentID> = []
    public var unlockSucceeds = true

    public init(locked: Set<DocumentID> = []) { self.locked = locked }

    public func isLocked(_ doc: DocumentID) -> Bool { locked.contains(doc) }
    public func unlock(_ doc: DocumentID) async -> Bool {
        if unlockSucceeds { locked.remove(doc) }
        return unlockSucceeds
    }
}

public extension PluginManifest {
    /// Builds a manifest from JSON (the manifest types have no public memberwise inits by design).
    static func fixture(id: String = "dev.test.plugin", permissions: [String] = ["document:read", "document:write"],
                        contributes: JSONValue = [:], entry: String = "main.js") throws -> PluginManifest {
        let json: JSONValue = ["id": .string(id), "name": .string(id), "version": "1.0.0", "api": 1, "entry": .string(entry),
                               "permissions": .array(permissions.map { .string($0) }), "contributes": contributes]
        return try json.decode(PluginManifest.self)
    }
}

/// A view-less canvas for tool, attachment and gesture tests: `pages` stacked top to bottom (`pageSize`, `gap`, page
/// points) and scaled by `zoomScale` into view coordinates. Records what the code under test asked of the canvas.
/// `commitStroke` only records (register a stand-in `ink.addStrokes` if a test needs the real commit path).
@MainActor
public final class FakeCanvasHost: CanvasHost {
    public let app: NibApp
    public let session: EditorSession
    public let documentID: DocumentID
    public var zoomScale: Double = 1
    public var pages: [PageID]
    public var pageSize = PageSize.a4
    public var gap: Double = 20
    public let canvasView: UIView
    public let overlayLayer = CALayer()
    public private(set) var hidden: [PageID: Set<ElementID>] = [:]
    public private(set) var invalidations: [(page: PageID, rect: Rect?)] = []
    public private(set) var committed: [(stroke: Stroke, page: PageID)] = []
    public private(set) var wetStrokeCancels = 0
    public private(set) var liveViews: [ElementID: UIView] = [:]
    /// contracts-v2: pages passed to `afterNextRender` (the fake runs the body at once).
    public private(set) var renderWaits: [PageID] = []

    public init(app: NibApp, session: EditorSession, doc: DocumentID = Fixtures.docID,
                pages: [PageID] = [Fixtures.page1, Fixtures.page2]) {
        self.app = app
        self.session = session
        self.documentID = doc
        self.pages = pages
        canvasView = UIView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        canvasView.layer.addSublayer(overlayLayer)
    }

    /// The Harness's app and session on the fixture document.
    public convenience init(_ harness: Harness) { self.init(app: harness.app, session: harness.session) }

    public func pageFrame(_ page: PageID) -> CGRect? {
        guard let i = pages.firstIndex(of: page) else { return nil }
        return CGRect(x: 0, y: Double(i) * (pageSize.height + gap) * zoomScale,
                      width: pageSize.width * zoomScale, height: pageSize.height * zoomScale)
    }

    public func viewPoint(_ p: Point, page: PageID) -> CGPoint {
        let o = pageFrame(page)?.origin ?? .zero
        return CGPoint(x: Double(o.x) + p.x * zoomScale, y: Double(o.y) + p.y * zoomScale)
    }

    public func pagePoint(_ v: CGPoint) -> (page: PageID, point: Point)? {
        for page in pages {
            if let f = pageFrame(page), f.contains(v) {
                return (page, Point(Double(v.x - f.minX) / zoomScale, Double(v.y - f.minY) / zoomScale))
            }
        }
        return nil
    }

    public func setHidden(_ ids: Set<ElementID>, page: PageID) { hidden[page] = ids.isEmpty ? nil : ids }
    public func invalidate(page: PageID, rect: Rect?) { invalidations.append((page, rect)) }
    public func commitStroke(_ stroke: Stroke, page: PageID) { committed.append((stroke, page)) }
    public func cancelWetStroke() { wetStrokeCancels += 1 }
    public func attachLiveView(_ view: UIView?, item: ElementID, page: PageID) { liveViews[item] = view }

    /// Runs `body` immediately (tests need no render delay) and records the page.
    public func afterNextRender(page: PageID, _ body: @escaping @MainActor () -> Void) {
        renderWaits.append(page)
        body()
    }
}

/// Collaboration transport inside one process: transports sharing a `Hub` that host/join the same code exchange
/// messages synchronously (two-Harness collaboration tests). `leave()` then `join` simulates suspend and rejoin.
@MainActor
public final class InMemoryCollabTransport: CollabTransport {
    /// Switchboard shared by the transports of one test: code → transports in that session.
    @MainActor
    public final class Hub {
        fileprivate var rooms: [String: [InMemoryCollabTransport]] = [:]
        public init() {}
    }

    public let id = "memory"
    public let hub: Hub
    /// This participant as the other transports see it.
    public private(set) var me: CollabPeer
    public var displayName: String { me.name }
    public var maxPeers = 8
    public var onMessage: ((CollabPeer, Data) -> Void)?
    public var onPeersChanged: (([CollabPeer]) -> Void)?
    /// Every payload this transport sent, in order.
    public private(set) var sent: [Data] = []
    private var code: String?

    public init(hub: Hub, peerID: String = NibID.make().raw) {
        self.hub = hub
        self.me = CollabPeer(id: peerID, name: "")
    }

    private var room: [InMemoryCollabTransport] { code.flatMap { hub.rooms[$0] } ?? [] }
    public var peers: [CollabPeer] { room.filter { $0 !== self }.map(\.me) }

    public func host(code: String, displayName: String) async throws { try enter(code, displayName) }

    public func join(code: String, displayName: String) async throws {
        guard hub.rooms[code]?.isEmpty == false else { throw NibError.notFound("collaboration session \(code)") }
        try enter(code, displayName)
    }

    public func send(_ data: Data, to peers: [CollabPeer]?) throws {
        guard code != nil else { throw NibError.unavailable("collaboration session") }
        sent.append(data)
        for t in room where t !== self && (peers?.contains(t.me) ?? true) { t.onMessage?(me, data) }
    }

    public func leave() {
        guard let c = code else { return }
        hub.rooms[c]?.removeAll { $0 === self }
        code = nil
        for t in hub.rooms[c] ?? [] { t.onPeersChanged?(t.peers) }
    }

    private func enter(_ code: String, _ name: String) throws {
        leave()
        guard (hub.rooms[code]?.count ?? 0) < maxPeers else { throw NibError.unavailable("collaboration session is full") }
        me.name = name
        self.code = code
        hub.rooms[code, default: []].append(self)
        for t in room { t.onPeersChanged?(t.peers) }
    }
}
```

### `NibKit/Sources/NibTesting/Snapshot.swift`

```swift
import SwiftUI
import UIKit
import NibContracts

/// contracts-v2: offscreen snapshots of SwiftUI views for hostless tests: the Light, Dark and AX3 states DESIGN.md
/// §15.7 asks for, plus pixel reads for colour assertions. Rendering uses `ImageRenderer`, so pure SwiftUI renders;
/// UIKit-backed views (UIViewRepresentable) render as placeholders. States that need a host app (Reduce Transparency,
/// Increase Contrast, live glass) belong to smoke scripts (F111).
@MainActor
public enum NibSnapshot {
    public enum Variant: String, CaseIterable {
        case light, dark
        /// Light at accessibility text size 3.
        case largeText

        public var colorScheme: ColorScheme { self == .dark ? .dark : .light }
        public var dynamicTypeSize: DynamicTypeSize { self == .largeText ? .accessibility3 : .large }
    }

    /// `view` rendered at `size` (points) in `variant`; nil when nothing renders.
    public static func image<V: View>(_ view: V, size: CGSize, variant: Variant = .light, scale: CGFloat = 2) -> UIImage? {
        let styled = view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, variant.colorScheme)
            .environment(\.dynamicTypeSize, variant.dynamicTypeSize)
        let renderer = ImageRenderer(content: styled)
        renderer.scale = scale
        return renderer.uiImage
    }

    /// `view` in every variant.
    public static func images<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2) -> [Variant: UIImage] {
        var out: [Variant: UIImage] = [:]
        for v in Variant.allCases {
            if let image = image(view, size: size, variant: v, scale: scale) { out[v] = image }
        }
        return out
    }

    /// The size `view` wants at `width` in `variant` (UIHostingController.sizeThatFits), for layout assertions such as
    /// "the panel still fits at AX3".
    public static func fittingSize<V: View>(_ view: V, width: CGFloat, variant: Variant = .light) -> CGSize {
        let styled = view
            .environment(\.colorScheme, variant.colorScheme)
            .environment(\.dynamicTypeSize, variant.dynamicTypeSize)
        let host = UIHostingController(rootView: styled)
        return host.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    }

    /// The colour of the pixel at `point` (points, top-left origin); nil outside the image.
    public static func pixel(_ image: UIImage, at point: CGPoint) -> RGBA? {
        guard let cg = image.cgImage else { return nil }
        let x = Int(point.x * image.scale)
        let y = Int(point.y * image.scale)
        guard x >= 0, y >= 0, x < cg.width, y < cg.height else { return nil }
        var px: [UInt8] = [0, 0, 0, 0]
        let drawn = px.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: -CGFloat(x), y: CGFloat(y + 1 - cg.height), width: CGFloat(cg.width),
                                    height: CGFloat(cg.height)))
            return true
        }
        return drawn ? RGBA(px[0], px[1], px[2], px[3]) : nil
    }
}
```

### `NibKit/Tests/NibContractsTests/NibContractsTests.swift`

```swift
import XCTest
import NibContracts
import NibTesting

@MainActor
final class NibContractsTests: XCTestCase {
    func testFractionalIndexOrdering() {
        var keys: [String] = []
        var last: String?
        for _ in 0..<200 {
            let k = FractionalIndex.between(last, nil)
            if let l = last { XCTAssertLessThan(l, k) }
            keys.append(k)
            last = k
        }
        for i in 0..<(keys.count - 1) {
            let m = FractionalIndex.between(keys[i], keys[i + 1])
            XCTAssertLessThan(keys[i], m)
            XCTAssertLessThan(m, keys[i + 1])
            XCTAssertFalse(m.hasSuffix("0"))
        }
        let first = FractionalIndex.between(nil, "1")
        XCTAssertLessThan(first, "1")
    }

    func testRevCodingAndOrder() throws {
        let a = Rev(wallMs: 10, counter: 1, device: 2)
        let b = Rev(wallMs: 10, counter: 2, device: 1)
        XCTAssertLessThan(a, b)
        XCTAssertEqual(Rev(string: a.description), a)
        XCTAssertLessThan(a.description, b.description)
        let data = try JSONEncoder().encode([a])
        XCTAssertEqual(try JSONDecoder().decode([Rev].self, from: data), [a])
    }

    func testStrokeCodecBothForms() throws {
        let s = Stroke(style: InkStyle(), points: [StrokePoint(x: 1, y: 2, t: 0.5, force: 0.7), StrokePoint(x: 3, y: 4)], t0: 100)
        let plain = try JSONValue.from(s)
        XCTAssertEqual(plain["fmt"], "full")
        let back = try plain.decode(Stroke.self)
        XCTAssertEqual(back.points.count, 2)
        XCTAssertEqual(back.points[0].force, 0.7, accuracy: 0.001)

        let encoder = JSONEncoder()
        encoder.userInfo[.nibCompactPoints] = true
        let compact = try JSONDecoder().decode(Stroke.self, from: try encoder.encode(s))
        XCTAssertEqual(compact.points, s.points)

        let aiStroke = try JSONValue.parse(#"{"fmt":"xy","pts":[10,10,20,20,30,15]}"#).decode(Stroke.self)
        XCTAssertEqual(aiStroke.points.count, 3)
        XCTAssertEqual(aiStroke.style.tool, .pen)
    }

    func testItemPayloadValidation() {
        var bad = Item(kind: .shape, stroke: Stroke(style: InkStyle(), points: []))
        XCTAssertFalse(bad.isValid)
        bad.kind = .stroke
        XCTAssertTrue(bad.isValid)
    }

    func testRichTextAcceptsPlainString() throws {
        let rt = try JSONValue.string("a\nb").decode(RichText.self)
        XCTAssertEqual(rt.paragraphs.count, 2)
        XCTAssertEqual(rt.plainText, "a\nb")
    }

    func testMutateCommitsAndUndoRestores() async throws {
        let h = Harness()
        let before = try h.snapshot()
        let ctx = try await probeContext(h)
        try ctx.mutate("Delete") { tx in
            try tx.delete(item: Fixtures.strokeID, doc: Fixtures.docID, page: Fixtures.page1)
        }
        XCTAssertNotEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertNotEqual(try h.snapshot(), before)
    }

    func testRollbackOnError() async throws {
        let h = Harness()
        let before = try h.snapshot()
        let ctx = try await probeContext(h)
        XCTAssertThrowsError(try ctx.mutate { tx in
            try tx.delete(item: Fixtures.shapeID, doc: Fixtures.docID, page: Fixtures.page1)
            throw NibError.invalid("boom")
        })
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testSelectiveRevertSkipsLaterEdits() async throws {
        let h = Harness()
        let ctx = try await probeContext(h)
        try ctx.mutate { tx in
            var it = try tx.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
            it.locked = true
            try tx.put(it, doc: Fixtures.docID, page: Fixtures.page1)
        }
        let group = ctx.group
        let later = try await probeContext(h)
        try later.mutate { tx in
            var it = try tx.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID)
            it.layer = 2
            try tx.put(it, doc: Fixtures.docID, page: Fixtures.page1)
        }
        let r = h.app.bus.revert(group: group, doc: Fixtures.docID)
        XCTAssertEqual(r?.skipped, 1)
        XCTAssertEqual(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.textID).layer, 2)
    }

    func testRemoteMergeIsLastWriterWins() throws {
        let h = Harness()
        var item = try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID)
        // Newer than the fixture rev but not far-future (that would be distrusted, see Rev.effective).
        item.rev = Rev(wallMs: UInt64(Date().timeIntervalSince1970 * 1000), counter: 0, device: 99)
        item.locked = true
        let patch = DocumentPatch(doc: Fixtures.docID, items: [Fixtures.page1.raw: [item]])
        XCTAssertEqual(h.app.bus.applyRemote(patch, origin: "test").updated.count, 1)
        XCTAssertTrue(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID).locked)
        item.locked = false
        item.rev = Rev(wallMs: 5, counter: 0, device: 99)
        _ = h.app.bus.applyRemote(DocumentPatch(doc: Fixtures.docID, items: [Fixtures.page1.raw: [item]]), origin: "test")
        XCTAssertTrue(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID).locked)
    }

    func testGatewayPermissions() async throws {
        let h = Harness()
        do {
            try await h.run("settings.set", ["name": "security.ai.confirmationPolicy", "value": "never"], as: .ai("t"))
            XCTFail("AI must not change security settings")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        do {
            try await h.run("edit.undo", ["doc": "doc:FIXTUREDOC01"], as: .plugin("x"))
            XCTFail("plugin without grants must be denied")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        let list = try await h.run("commands.list", ["namespace": "edit"], as: .ai("t"))
        XCTAssertEqual(list["commands"]?.arrayValue?.count, 2)
    }

    func testSchemaValidation() {
        let s = JSONSchema.obj(["page": .ref, "n": .int(min: 1)], required: ["page"])
        XCTAssertTrue(s.validate(["page": "page:A/B", "n": 2]).isEmpty)
        XCTAssertEqual(s.validate(["n": 0]).count, 2)
    }

    func testCoreCommandsConform() async {
        let problems = await CommandConformance.check(features: [])
        XCTAssertEqual(problems, [])
    }

    func testMinimalJSONDecodesForEveryRecordAndPayload() throws {
        func ok<T: Decodable>(_ type: T.Type, _ json: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertNoThrow(try JSONValue.parse(json).decode(T.self), "\(T.self) from \(json)", file: file, line: line)
        }
        ok(Item.self, #"{"kind":"shape","shape":{"shape":"rectangle","frame":{"x":1,"y":2,"w":3,"h":4}}}"#)
        ok(ShapeItem.self, #"{"shape":"line","points":[[0,0],[10,10]]}"#)
        ok(ConnectorItem.self, #"{"from":{"point":[0,0]},"to":{"item":"FIXTURESHP01","side":1}}"#)
        ok(TextBoxItem.self, #"{"frame":{"x":0,"y":0,"w":10,"h":10}}"#)
        ok(ImageItem.self, #"{"frame":{"x":0,"y":0,"w":10,"h":10},"asset":"a.png"}"#)
        ok(StickyItem.self, #"{"frame":{"x":0,"y":0,"w":10,"h":10}}"#)
        ok(MathItem.self, #"{"frame":{"x":0,"y":0,"w":10,"h":10}}"#)
        ok(CommentItem.self, #"{"anchor":[5,5]}"#)
        ok(CommentMessage.self, #"{"text":"hi"}"#)
        ok(CustomItem.self, #"{"owner":"p","type":"t","frame":{"x":0,"y":0,"w":10,"h":10}}"#)
        ok(DisplayList.self, #"{}"#)
        ok(PageRecord.self, #"{"size":{"width":595,"height":842}}"#)
        ok(OutlineEntry.self, #"{"title":"x"}"#)
        ok(AudioClip.self, #"{}"#)
        ok(TranscriptSegment.self, #"{"text":"x"}"#)
        ok(TextBlock.self, #"{"text":"plain"}"#)
        ok(CustomBlock.self, #"{"owner":"p","type":"t"}"#)
        ok(TableData.self, #"{}"#)
        ok(TableCell.self, #"{}"#)
        ok(TableMerge.self, #"{"row":0,"column":0}"#)
        ok(BlockComment.self, #"{"text":"x"}"#)
        ok(StudyCard.self, #"{"front":"Term","back":{"text":"Definition"}}"#)
        ok(CardFace.self, #""just text""#)
        ok(SRSState.self, #"{}"#)
        ok(DocumentMeta.self, #"{}"#)
        ok(LayerInfo.self, #"{"index":2}"#)
        ok(DocumentContent.self, #"{"meta":{}}"#)
        let face = try JSONValue.parse(#"{"ink":[{"fmt":"xy","pts":[0,0,5,5]}]}"#).decode(CardFace.self)
        XCTAssertEqual(face.kind, .ink)
    }

    func testDensifyClampsTheSplineEnds() {
        var s = Stroke(style: InkStyle(), points: [StrokePoint(x: 0, y: 0), StrokePoint(x: 10, y: 0), StrokePoint(x: 10, y: 10)])
        InkModel.prepare(&s)
        XCTAssertEqual(s.points.prefix(3).map { $0.x }, [0, 0, 0])
        XCTAssertEqual(s.points.suffix(3).map { $0.y }, [10, 10, 10])
        XCTAssertTrue(s.points.allSatisfy { $0.width > 0 })
        for (a, b) in zip(s.points, s.points.dropFirst()) { XCTAssertLessThanOrEqual(a.location.distance(to: b.location), 1.5 + 1e-4) }
        let captured = Stroke(style: InkStyle(), points: [StrokePoint(x: 0, y: 0, width: 2, height: 2), StrokePoint(x: 50, y: 0, width: 2, height: 2)])
        var copy = captured
        InkModel.prepare(&copy)
        XCTAssertEqual(copy, captured, "PencilKit-captured strokes are untouched")
    }

    func testFeatureCommandsAreOwnedByTheirFeature() {
        let h = Harness(features: [ProbeFeature.self])
        XCTAssertEqual(h.app.commands.descriptor("probe.stamp")?.owner, "probe")
        XCTAssertEqual(h.app.commands.descriptor("edit.undo")?.owner, "builtin")
        h.app.commands.unregister(owner: "probe")
        XCTAssertNil(h.app.commands.descriptor("probe.stamp"))
    }

    func testReadOnlyCallsCannotMutate() async throws {
        let h = Harness(features: [ProbeFeature.self])
        do {
            try await h.app.bus.execute(Invocation(command: "probe.stamp", principal: .ai("t"), readOnly: true))
            XCTFail("ask mode must refuse edit commands")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        do {
            try await h.run("probe.sneaky")
            XCTFail("a read command must not mutate")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
        do {
            try await h.run("probe.nested")
            XCTFail("unknown nested commands are unavailable")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
        }
    }

    func testProvenanceCannotBeForged() async throws {
        let h = Harness(features: [ProbeFeature.self])
        let r = try await h.run("probe.stamp", ["createdBy": "user"], as: .ai("chat1"))
        let ref = try XCTUnwrap(r["ref"]?.stringValue)
        guard case let .item(d, p, i)? = NodeRef(ref) else { return XCTFail("bad ref") }
        XCTAssertEqual(try h.app.workspace.item(d, page: p, id: i).createdBy, "ai:chat1")
    }

    func testSettingsAreDeclaredValidatedAndGuarded() async throws {
        let h = Harness()
        try await h.run("settings.set", ["name": "editing.openAsTabs", "value": false], as: .ai("t"))
        XCTAssertFalse(h.app.settings.get(NibSettings.openAsTabs))
        for (name, value, code) in [("nope.nothing", JSONValue.bool(true), NibError.Code.notFound),
                                    ("editing.openAsTabs", JSONValue.string("yes"), .invalidParams),
                                    ("managed.iCloudAllowed", JSONValue.bool(true), .permissionDenied)] {
            do {
                try await h.run("settings.set", ["name": .string(name), "value": value], as: .ai("t"))
                XCTFail("\(name) must be rejected")
            } catch let e as NibError {
                XCTAssertEqual(e.code, code, name)
            }
        }
        do {
            try await h.run("settings.get", ["name": "security.ai.confirmationPolicy"], as: .plugin("p"))
            XCTFail("security settings are user-only")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .permissionDenied)
        }
    }

    func testFarFutureRevisionsLoseToCorrectlyClockedEdits() {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        var normal = OutlineEntry(id: "OUTLINEX0001", title: "edited today", page: nil)
        normal.rev = Rev(wallMs: nowMs, counter: 0, device: 1)
        var skewed = normal
        skewed.title = "device clock 30 days ahead"
        skewed.rev = Rev(wallMs: nowMs + 30 * 86_400_000, counter: 0, device: 9)
        XCTAssertEqual(LWW.merge([normal], [skewed]).first?.title, "edited today")
        XCTAssertEqual(LWW.merge([], [skewed]).first?.title, "device clock 30 days ahead")
    }

    func testSharedCanvasAndCollabFakes() async throws {
        let h = Harness()
        let canvas = FakeCanvasHost(h)
        canvas.zoomScale = 2
        let back = try XCTUnwrap(canvas.pagePoint(canvas.viewPoint(Point(10, 20), page: Fixtures.page2)))
        XCTAssertEqual(back.page, Fixtures.page2)
        XCTAssertEqual(back.point.x, 10, accuracy: 1e-9)
        XCTAssertEqual(back.point.y, 20, accuracy: 1e-9)
        XCTAssertNil(canvas.pagePoint(CGPoint(x: -1, y: -1)))

        let hub = InMemoryCollabTransport.Hub()
        let a = InMemoryCollabTransport(hub: hub)
        let b = InMemoryCollabTransport(hub: hub)
        var received: [Data] = []
        b.onMessage = { _, data in received.append(data) }
        try await a.host(code: "ROOM01", displayName: "A")
        try await b.join(code: "ROOM01", displayName: "B")
        try a.send(Data([1]), to: nil)
        XCTAssertEqual(received, [Data([1])])
        XCTAssertEqual(a.peers.map(\.name), ["B"])
        b.leave()
        XCTAssertTrue(a.peers.isEmpty)
    }

    /// A context as a command would receive it (via a throwaway registered command).
    private func probeContext(_ h: Harness) async throws -> CommandContext {
        var captured: CommandContext?
        let d = CommandDescriptor(id: "test.probe", title: "Probe", summary: "test", effect: .edit, exposure: .ui)
        h.app.commands.register(d) { _, ctx in
            captured = ctx
            return .null
        }
        try await h.run("test.probe")
        return try XCTUnwrap(captured)
    }
}

/// A tiny feature used by the contract tests.
enum ProbeFeature: NibFeature {
    static let id = "probe"

    static func register(_ app: NibApp) {
        app.commands.register(CommandDescriptor(id: "probe.stamp", title: "Stamp", summary: "Adds a sticky note (test).",
                                                examples: [[:]], effect: .edit)) { params, ctx in
            let item = try ctx.mutate { tx -> Item in
                var it = Item.makeSticky(StickyItem(frame: Frame(x: 10, y: 10, w: 50, h: 50)))
                it.createdBy = params["createdBy"]?.stringValue
                return try tx.put(it, doc: Fixtures.docID, page: Fixtures.page1)
            }
            return ["ref": .string(NodeRef.item(Fixtures.docID, Fixtures.page1, item.id).description)]
        }
        app.commands.register(CommandDescriptor(id: "probe.sneaky", title: "Sneaky", summary: "A read command that tries to write (test).",
                                                examples: [[:]], effect: .read)) { _, ctx in
            try ctx.mutate { tx in try tx.delete(item: Fixtures.stickyID, doc: Fixtures.docID, page: Fixtures.page1) }
            return .null
        }
        app.commands.register(CommandDescriptor(id: "probe.nested", title: "Nested", summary: "Calls a missing command (test).",
                                                examples: [[:]], effect: .edit)) { _, ctx in
            try await ctx.execute("missing.command")
        }
    }
}
```

### `NibKit/Tests/NibContractsTests/NameLookupCanaryTests.swift`

```swift
// Compiles every public NibContracts name UNQUALIFIED next to every framework a feature may import. A clash such as
// Combine.Empty, SwiftUI.Transaction, SwiftUI.ShapeStyle or the iOS 18 Vision RecognizedText only shows up in a
// client module that imports both, so this file must compile before contracts-v1 is tagged (green baseline).
// If a line fails with "is ambiguous for type lookup", rename the contract type (e.g. Point/Rect → PagePoint/PageRect).
import XCTest
import SwiftUI
import UIKit
import Combine
import CoreGraphics
import Vision
import VisionKit
import PDFKit
import PencilKit
import JavaScriptCore
import WebKit
import Network
import Speech
import AVFoundation
import EventKit
import MultipeerConnectivity
import NaturalLanguage
import AppIntents
import Charts
import BackgroundTasks
import UserNotifications
import LocalAuthentication
import PhotosUI
import NibContracts
import NibTesting

enum NameLookupCanary {
    static let types: [Any.Type] = [
        JSONValue.self, NibFormat.self, NibLimits.self, NibID.self, Rev.self,
        HLCClock.self, FractionalIndex.self, RGBA.self, AssetRef.self, Point.self,
        Rect.self, Frame.self, Affine.self, Geo.self, InkTool.self,
        PenStyle.self, StrokePattern.self, InkStyle.self, StrokePoint.self, Stroke.self,
        InkModel.self, TextLink.self, TextAttributes.self, TextRun.self, ParagraphAlignment.self,
        ListKind.self, Paragraph.self, RichText.self, ItemKind.self, ShapeKind.self,
        ShapeItemStyle.self, ShapeItem.self, ConnectorEnd.self, ConnectorRoute.self, ConnectorItem.self,
        TextBoxStyle.self, TextBoxItem.self, ImageItem.self, StickyItem.self, MathItem.self,
        CommentMessage.self, CommentItem.self, DisplayOpKind.self, DisplayOp.self, DisplayList.self,
        CustomItem.self, Item.self, LWW.self, DocumentKind.self, ScrollDirection.self,
        LayerInfo.self, PageSize.self, TemplateRef.self, BackgroundKind.self, Background.self,
        DocumentMeta.self, PageRecord.self, OutlineEntry.self, TranscriptSegment.self, AudioClip.self,
        BlockKind.self, TableCell.self, TableMerge.self, TableData.self, CustomBlock.self,
        BlockComment.self, TextBlock.self, CardFaceKind.self, CardFace.self, SRSState.self,
        StudyCard.self, PagePosition.self, DocumentContent.self, PresetSwatch.self, ToolPresets.self,
        FolderStyle.self, LibraryNodeKind.self, SyncBadge.self, LibraryNode.self, NodeRef.self,
        NibError.self, Principal.self, Effect.self, CommandTarget.self, Scope.self,
        Exposure.self, JSONSchema.self, CommandDescriptor.self, NoResult.self, CommandRegistry.self,
        CommandIDs.self, ChangeSummary.self, Mutation.self, Changeset.self, DocumentPatch.self,
        DocumentPersistence.self, InMemoryPersistence.self, Workspace.self, DocTransaction.self, UndoEntry.self,
        UndoHistory.self, NibEventType.self, NibEvent.self, EventSubscription.self, EventBus.self,
        Invocation.self, CommandHookDescriptor.self, InvocationResult.self, CommandContext.self, CommandBus.self,
        ConfirmationPolicy.self, ConfirmationRequest.self, ConfirmationDecision.self, ConfirmationPresenter.self, Gateway.self,
        Selection.self, ReplayMode.self, ReplayState.self, StylusMode.self, EditorSession.self,
        SessionRegistry.self, LibraryService.self, PackageLocator.self, AssetStore.self, RenderRequest.self,
        RenderResult.self, PageRenderer.self, TextRecognition.self, TextRecognizer.self, PDFLinkInfo.self,
        PDFOutlineNode.self, PDFService.self, LockService.self, NibServices.self, AIMode.self,
        AIScopeKind.self, AIScope.self, AIMessage.self, AIRequest.self, AIUsage.self,
        AIResponse.self, AIStreamEvent.self, AIChatSummary.self, AIService.self, ToolCatalog.self,
        ServiceKeys.self, PluginNetwork.self, PluginCommandContribution.self, PluginWhen.self, PluginMenuContribution.self,
        PluginToolbarContribution.self, PluginToolContribution.self, PluginPanelContribution.self, PluginTemplateContribution.self, PluginKeybinding.self,
        PluginAIAction.self, PluginAIGuidance.self, PluginFileHandler.self, PluginItemType.self, PluginTapHandler.self,
        PluginToolOptions.self, PluginBlockContribution.self, PluginStrokeProcessor.self, PluginPencilAction.self, PluginCommandHook.self,
        PluginElementCollection.self, PluginTapePattern.self, PluginBoardTemplate.self, PluginContributions.self, PluginManifest.self,
        PluginInfo.self, PluginRuntimeHandle.self, PluginRuntimeProviding.self, PluginHosting.self, AIProviderKind.self,
        AIProviderConfig.self, ChatRole.self, ChatPart.self, ChatMessage.self, ToolSpec.self,
        ChatRequest.self, ChatEvent.self, AIProvider.self, AIProviderStore.self, CollabPeer.self,
        CollabTransport.self, SettingKey<Bool>.self, SyncedSettingsBackend.self, SettingDescriptor.self, SettingsStore.self,
        NibSettings.self, SecretStore.self, SystemKeychainStore.self, Keychain.self, DeviceIdentity.self,
        AppGroup.self, Registrable.self, Registry<TemplateDefinition>.self, TemplateParam.self, TemplateRender.self,
        TemplateDefinition.self, DrawContext.self, ItemDrawer.self, ItemDrawerEntry.self, ImportTarget.self,
        ImporterDescriptor.self, ExportRequest.self, ExporterDescriptor.self, AIActionDescriptor.self, StrokeProcessor.self,
        StrokeProcessorEntry.self, KeyModifiers.self, KeyShortcut.self, KeyScope.self, KeyCommandDescriptor.self,
        BackgroundTaskKind.self, BackgroundTaskDescriptor.self, CanvasGesture.self, TapHandlerDescriptor.self, BoardTemplateDescriptor.self,
        TapePatternDescriptor.self, ElementEntry.self, ElementCollectionDescriptor.self, BlockKindDescriptor.self, CustomItemTypeDescriptor.self,
        PencilActionDescriptor.self, ContentRegistries.self, PKBridge.self, RichTextBridge.self, CanvasInputMode.self,
        CanvasSample.self, CanvasHost.self, CanvasTool.self, CanvasAttachment.self, CanvasAttachmentDescriptor.self,
        PencilEventHandler.self, DocumentEditing.self, ToolbarGroup.self, ToolbarItemDescriptor.self, MenuLocation.self,
        MenuContext.self, MenuItemDescriptor.self, PanelPlacement.self, PanelContext.self, PanelDescriptor.self,
        SettingsSection.self, SettingsPageDescriptor.self, InspectorContext.self, InspectorDescriptor.self, ToolMenuDescriptor.self,
        BlockViewContext.self, BlockViewDescriptor.self, PluginPanelFactory.self, CanvasToolDescriptor.self, DocumentEditorDescriptor.self,
        OpenMode.self, SceneNavigator.self, SceneHooks.self, ScreenRegistry.self, UIRegistries.self,
        NibFeature.self, NibApp.self, SafeMode.self, InkOutline.self, FakeCanvasHost.self,
        InMemoryCollabTransport.self,
        // contracts-v2
        NibEventPayload.self, SyncStatusPayload.self, IndexProgressPayload.self, LaserMovedPayload.self,
        AudioPlaybackPayload.self, AudioRecordingPayload.self, ShapeSnappedPayload.self, PencilHapticPayload.self,
        InkingSignal.self, TextRecognitionWord.self, RegistryChange.self, PageInsets.self, TemplateMetrics.self,
        DrawPurpose.self, ExportOptionKeys.self, TextLayoutInfo.self, TextLayoutDescriptor.self, PanelPresentation.self,
        ChromePlacement.self, ChromeSurface.self, ChromeAnchor.self, ChromeContext.self, ChromeOverlayDescriptor.self,
        DisplayFontWeight.self, NibFragment.self, BridgeNames.self, PanelIDs.self, ToolbarLayoutSetting.self,
        TemplateIDs.self, TemplateParamNames.self, FloatingHosting.self, ToolMenuPopover.self, NibSnapshot.self
    ]

    /// Protocols with associated types / Self requirements are checked as generic constraints.
    static func constraints<C: NibCommand, R: LWWRecord>(_ command: C.Type, _ record: R.Type) {}
}

/// A SwiftUI view in the same file as commands, the way feature modules are written.
@MainActor
struct CanaryView: View {
    let app: NibApp

    var body: some View {
        Button("Undo") { app.perform(CommandIDs.undo, ["doc": "doc:FIXTUREDOC01"]) }
    }
}

@MainActor
struct CanaryCommand: NibCommand {
    struct Params: Codable { var page: String }
    struct Output: Codable { var ok: Bool }
    static let descriptor = CommandDescriptor(id: "canary.check", title: "Canary", summary: "Name lookup canary.",
                                              params: .obj(["page": .ref], required: ["page"]), effect: .read)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let r: Result<Int, Error> = .success(1)                       // Swift.Result stays usable
        _ = r
        _ = NoResult()
        return Output(ok: true)
    }
}

@MainActor
final class NameLookupCanaryTests: XCTestCase {
    func testEveryContractNameResolves() {
        XCTAssertGreaterThan(NameLookupCanary.types.count, 200)
        NameLookupCanary.constraints(CanaryCommand.self, OutlineEntry.self)
        let h = Harness()
        _ = CanaryView(app: h.app).body
    }
}
```

### `NibKit/Tests/NibContractsTests/ContractsV2Tests.swift`

```swift
import XCTest
import UIKit
import SwiftUI
import NibContracts
import NibTesting

/// contracts-v2: regression tests for the DocTransaction.revert fixes and coverage of the APIs added in the v2 pass
/// (docs/CONTRACTS.md › contracts-v2 changelog).
@MainActor
final class ContractsV2Tests: XCTestCase {
    private let doc = Fixtures.docID
    private let page1 = Fixtures.page1
    private let mathRef = "item:FIXTUREDOC01/FIXTUREPG001/FIXTUREMTH01"

    // MARK: Undo / revert regressions

    /// F031 (FeatShapesTests.testDroppingAnItemIntoAShapeAttachesItInTheSameUndoStep): a commit observer attaches the
    /// moved item with `item.update` in the move's own undo group; one undo must revert BOTH the attach and the move.
    func testAttachAfterMoveInTheSameGroupUndoesTheMoveToo() async throws {
        let h = Harness()
        registerMoveStandIns(h.app)
        var pending: Task<Void, Never>?
        let watcher = h.app.bus.observeCommits { cs in
            guard cs.principal.isUser, cs.command == CommandIDs.itemTransform else { return }
            let app = h.app, session = h.session, group = cs.group, ref = self.mathRef
            pending = Task { @MainActor in
                _ = try? await app.bus.execute(Invocation(command: CommandIDs.itemUpdate,
                                                          params: ["ref": .string(ref), "patch": ["attachedTo": "FIXTURESHP01"]],
                                                          session: session, group: group))
            }
        }
        defer { watcher.cancel() }
        // The maths item (72, 480, 120 × 40) moves inside the fixture rectangle (100, 200, 160 × 90).
        try await h.run(CommandIDs.itemTransform, ["refs": [.string(mathRef)], "translate": [48, -260]])
        await pending?.value
        let math = try h.app.workspace.item(doc, page: page1, id: Fixtures.mathID)
        XCTAssertEqual(math.attachedTo, Fixtures.shapeID)
        XCTAssertEqual(math.frame, Frame(x: 120, y: 220, w: 120, h: 40))
        XCTAssertEqual(h.undoDepth(doc), 1, "move and attach are one undo step")

        XCTAssertTrue(h.app.bus.undo(doc))
        let restored = try h.app.workspace.item(doc, page: page1, id: Fixtures.mathID)
        XCTAssertNil(restored.attachedTo)
        XCTAssertEqual(restored.frame, Frame(x: 72, y: 480, w: 120, h: 40))

        XCTAssertTrue(h.app.bus.redo(doc))
        let again = try h.app.workspace.item(doc, page: page1, id: Fixtures.mathID)
        XCTAssertEqual(again.attachedTo, Fixtures.shapeID)
        XCTAssertEqual(again.frame, Frame(x: 120, y: 220, w: 120, h: 40))
    }

    /// F005 / F028 / F036 / F044: one undo group that writes the same item, page record and document meta twice
    /// (debounced text commits, a meta change applied in two steps) undoes all the way back and redoes all the way.
    func testRecordWrittenTwiceInOneGroupIsFullyReverted() async throws {
        let h = Harness()
        let before = try h.snapshot()
        let group = "TWICE0000001"
        for text in ["One", "One two"] {
            let ctx = try await probeContext(h, group: group)
            try ctx.mutate { tx in
                var it = try tx.item(self.doc, page: self.page1, id: Fixtures.textID)
                it.text?.text = RichText(plain: text)
                try tx.put(it, doc: self.doc, page: self.page1)
                var page = try XCTUnwrap(try tx.content(self.doc).page(self.page1))
                page.title = text
                try tx.put(page, doc: self.doc)
                var meta = try tx.content(self.doc).meta
                meta.language = text == "One" ? "de-DE" : "fr-FR"
                try tx.putMeta(meta)
            }
        }
        XCTAssertEqual(h.undoDepth(doc), 1)
        let after = try h.snapshot()
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(), before, "both writes of each record are reverted")
        XCTAssertTrue(h.app.bus.redo(doc))
        XCTAssertEqual(try h.snapshot(), after)
        XCTAssertEqual(try h.app.workspace.item(doc, page: page1, id: Fixtures.textID).text?.text.plainText, "One two")
    }

    /// F026 / F029 / F034 / F036 / F049: consecutive undo entries on the SAME item all undo (each revert re-stamps the
    /// item, which used to make the next-older entry look "changed since" and be skipped), then all redo.
    func testConsecutiveUndosOnOneItem() async throws {
        let h = Harness()
        let before = try h.snapshot()
        var states: [JSONValue] = []
        for step in 0..<3 {
            let ctx = try await probeContext(h)
            try ctx.mutate { tx in
                var it = try tx.item(self.doc, page: self.page1, id: Fixtures.stickyID)
                switch step {
                case 0: it.locked = true
                case 1: it.layer = 2
                default: it.sticky?.text = RichText(plain: "edited")
                }
                try tx.put(it, doc: self.doc, page: self.page1)
            }
            states.append(try h.snapshot())
        }
        XCTAssertEqual(h.undoDepth(doc), 3)
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(), states[1])
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(), states[0])
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertTrue(h.app.bus.redo(doc))
        XCTAssertTrue(h.app.bus.redo(doc))
        XCTAssertEqual(try h.snapshot(), states[1])
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(), states[0], "undo after redo still lines up")
        XCTAssertTrue(h.app.bus.redo(doc))
        XCTAssertTrue(h.app.bus.redo(doc))
        XCTAssertEqual(try h.snapshot(), states[2])
    }

    /// F034: insert an image, crop it, flip it, then undo three times: the page is back to where it started.
    func testInsertCropFlipThenThreeUndosRemovesTheImage() async throws {
        let h = Harness()
        let before = try h.snapshot()
        let id: ElementID = "IMGV2TEST001"
        let insert = try await probeContext(h)
        try insert.mutate { tx in
            try tx.put(Item.makeImage(ImageItem(frame: Frame(x: 50, y: 50, w: 100, h: 80), asset: Fixtures.pngAsset)).with(id: id),
                       doc: self.doc, page: self.page1)
        }
        let crop = try await probeContext(h)
        try crop.mutate { tx in
            var it = try tx.item(self.doc, page: self.page1, id: id)
            it.image?.crop = Rect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            try tx.put(it, doc: self.doc, page: self.page1)
        }
        let flip = try await probeContext(h)
        try flip.mutate { tx in
            var it = try tx.item(self.doc, page: self.page1, id: id)
            it.image?.flipX = true
            try tx.put(it, doc: self.doc, page: self.page1)
        }
        XCTAssertEqual(try h.app.workspace.item(doc, page: page1, id: id).image?.flipX, true)
        for _ in 0..<3 { XCTAssertTrue(h.app.bus.undo(doc)) }
        XCTAssertEqual(try h.snapshot(), before)
        XCTAssertThrowsError(try h.app.workspace.item(doc, page: page1, id: id))
    }

    func testSelectiveRevertStillSkipsRecordsChangedLater() async throws {
        let h = Harness()
        let first = try await probeContext(h)
        try first.mutate { tx in
            var it = try tx.item(self.doc, page: self.page1, id: Fixtures.textID)
            it.locked = true
            try tx.put(it, doc: self.doc, page: self.page1)
        }
        let later = try await probeContext(h)
        try later.mutate { tx in
            var it = try tx.item(self.doc, page: self.page1, id: Fixtures.textID)
            it.layer = 3
            try tx.put(it, doc: self.doc, page: self.page1)
        }
        let r = h.app.bus.revert(group: first.group, doc: doc)
        XCTAssertEqual(r?.skipped, 1)
        XCTAssertEqual(try h.app.workspace.item(doc, page: page1, id: Fixtures.textID).layer, 3)
    }

    func testLinkedUndoAcrossDocuments() async throws {
        let h = Harness()
        let beforeA = try h.snapshot(Fixtures.docID)
        let beforeB = try h.snapshot(Fixtures.whiteboardID)
        let ctx = try await probeContext(h)
        ctx.linkUndoAcrossDocuments()
        try ctx.mutate { tx in
            try tx.delete(item: Fixtures.stickyID, doc: Fixtures.docID, page: Fixtures.page1)
            var board = try tx.item(Fixtures.whiteboardID, page: Fixtures.boardID, id: Fixtures.boardShapeID)
            board.locked = true
            try tx.put(board, doc: Fixtures.whiteboardID, page: Fixtures.boardID)
        }
        XCTAssertTrue(h.app.bus.history.isLinked(ctx.group))
        XCTAssertTrue(h.app.bus.undo(Fixtures.whiteboardID))
        XCTAssertEqual(try h.snapshot(Fixtures.docID), beforeA, "undo in one document undoes the linked step in the other")
        XCTAssertEqual(try h.snapshot(Fixtures.whiteboardID), beforeB)
        XCTAssertEqual(h.undoDepth(Fixtures.docID), 0)
        XCTAssertTrue(h.app.bus.redo(Fixtures.docID))
        XCTAssertThrowsError(try h.app.workspace.item(Fixtures.docID, page: Fixtures.page1, id: Fixtures.stickyID))
        XCTAssertTrue(try h.app.workspace.item(Fixtures.whiteboardID, page: Fixtures.boardID, id: Fixtures.boardShapeID).locked)

        // Unlinked groups keep per-document undo.
        let plain = try await probeContext(h)
        try plain.mutate { tx in
            try tx.delete(item: Fixtures.textID, doc: Fixtures.docID, page: Fixtures.page1)
            try tx.delete(item: Fixtures.boardShapeID, doc: Fixtures.whiteboardID, page: Fixtures.boardID)
        }
        XCTAssertTrue(h.app.bus.undo(Fixtures.docID))
        XCTAssertThrowsError(try h.app.workspace.item(Fixtures.whiteboardID, page: Fixtures.boardID, id: Fixtures.boardShapeID))
    }

    // MARK: Provenance, moves and batch writes

    func testMoveKeepsProvenanceForNonUserPrincipals() async throws {
        let h = Harness(features: [V2ProbeFeature.self])
        let r = try await h.run("v2probe.create")
        guard case let .item(_, _, id)? = NodeRef(r["ref"]?.stringValue ?? "") else { return XCTFail("no ref") }
        XCTAssertEqual(try h.app.workspace.item(doc, page: page1, id: id).createdBy, "user")

        try await h.run("v2probe.move", ["id": .string(id.raw)], as: .ai("chat7"))
        let moved = try h.app.workspace.item(doc, page: Fixtures.page2, id: id)
        XCTAssertEqual(moved.createdBy, "user", "the AI moving the user's item keeps it the user's")
        XCTAssertEqual(moved.frame?.x, 30)
        XCTAssertThrowsError(try h.app.workspace.item(doc, page: page1, id: id))

        // A plain put by the AI of a NEW item still stamps the AI.
        let made = try await h.run("v2probe.create", as: .ai("chat7"))
        guard case let .item(_, _, aiID)? = NodeRef(made["ref"]?.stringValue ?? "") else { return XCTFail("no ref") }
        XCTAssertEqual(try h.app.workspace.item(doc, page: page1, id: aiID).createdBy, "ai:chat7")

        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.app.workspace.item(doc, page: page1, id: id).createdBy, "user", "undo puts it back")
    }

    func testBatchPutAndDelete() async throws {
        let h = Harness()
        let before = try h.snapshot()
        let items = (0..<500).map { i in
            Item.makeStroke(Stroke(style: .defaultPen, points: [StrokePoint(x: Float(i), y: 10), StrokePoint(x: Float(i), y: 20)]))
        }
        let ctx = try await probeContext(h)
        let written = try ctx.mutate { tx in try tx.put(items, doc: self.doc, page: Fixtures.page2) }
        XCTAssertEqual(written.count, 500)
        let onPage = try h.app.workspace.items(doc, page: Fixtures.page2)
        XCTAssertEqual(onPage.map { $0.id }, written.map { $0.id }, "appended in order, on top")
        XCTAssertEqual(Set(onPage.map { $0.z }).count, 500)
        XCTAssertLessThan(onPage.map { $0.z.count }.max() ?? 0, 10, "batch z keys are balanced, not one character longer every few items")
        XCTAssertTrue(onPage.allSatisfy { $0.createdBy == "user" })

        let del = try await probeContext(h)
        XCTAssertThrowsError(try del.mutate { tx in
            try tx.delete(items: [written[0].id, "NOTANITEM001"], doc: self.doc, page: Fixtures.page2)
        })
        XCTAssertEqual(try h.app.workspace.items(doc, page: Fixtures.page2).count, 500, "nothing written on failure")
        try del.mutate { tx in try tx.delete(items: written.prefix(200).map { $0.id }, doc: self.doc, page: Fixtures.page2) }
        XCTAssertEqual(try h.app.workspace.items(doc, page: Fixtures.page2).count, 300)
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertTrue(h.app.bus.undo(doc))
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testBatchCardsAppendInOrder() async throws {
        let h = Harness()
        let cards = (0..<50).map { StudyCard(front: CardFace(text: RichText(plain: "Q\($0)")), back: CardFace()) }
        let ctx = try await probeContext(h)
        let written = try ctx.mutate { tx in try tx.put(cards, doc: Fixtures.studySetID) }
        let live = try h.app.workspace.content(Fixtures.studySetID).liveCards
        XCTAssertEqual(live.suffix(50).map { $0.id }, written.map { $0.id })
        XCTAssertTrue(h.app.bus.undo(Fixtures.studySetID))
        XCTAssertEqual(try h.app.workspace.content(Fixtures.studySetID).liveCards.count, 2)
    }

    func testLargeCardImportUndoesRedoesAndRollsBackInOnePass() async throws {
        let h = Harness()
        let set = Fixtures.studySetID
        let before = try h.snapshot(set)
        let cards = (0..<10_000).map { StudyCard(front: CardFace(text: RichText(plain: "Q\($0)")), back: CardFace()) }

        // A failed import leaves nothing behind (batched rollback).
        let failing = try await probeContext(h)
        XCTAssertThrowsError(try failing.mutate { tx -> Void in
            _ = try tx.put(cards, doc: set)
            throw NibError.invalid("importer stopped")
        })
        XCTAssertEqual(try h.snapshot(set), before)

        // Import, then edit one imported card again in the same group: one undo removes everything.
        let ctx = try await probeContext(h)
        let written = try ctx.mutate { tx -> [StudyCard] in
            let w = try tx.put(cards, doc: set)
            var edited = w[42]
            edited.front = CardFace(text: RichText(plain: "edited"))
            try tx.put(edited, doc: set)
            return w
        }
        XCTAssertEqual(try h.app.workspace.content(set).liveCards.count, 10_002)
        XCTAssertLessThan(written.map { $0.order.count }.max() ?? 0, 10, "balanced order keys")
        XCTAssertEqual(written.map { $0.order }, written.map { $0.order }.sorted(), "appended in array order")
        XCTAssertTrue(h.app.bus.undo(set))
        XCTAssertEqual(try h.app.workspace.content(set).liveCards.count, 2)
        XCTAssertTrue(h.app.bus.redo(set))
        let live = try h.app.workspace.content(set).liveCards
        XCTAssertEqual(live.count, 10_002)
        XCTAssertEqual(live.first { $0.id == written[42].id }?.front.text?.plainText, "edited")
        XCTAssertTrue(h.app.bus.undo(set))
        XCTAssertEqual(try h.app.workspace.content(set).liveCards.count, 2)
    }

    func testBatchPagesOutlineAndAudio() async throws {
        let h = Harness()
        let before = try h.snapshot()
        let ctx = try await probeContext(h)
        let invalid: [PageRecord] = [PageRecord(), PageRecord(rotation: 45)]
        XCTAssertThrowsError(try ctx.mutate { tx in try tx.put(invalid, doc: self.doc) },
                             "every page is validated before anything is written")
        XCTAssertEqual(try h.snapshot(), before)

        let newPages: [PageRecord] = (0..<20).map { _ in PageRecord() }
        let pages = try ctx.mutate { tx in try tx.put(newPages, doc: self.doc) }
        let live = try h.app.workspace.content(doc).livePages
        XCTAssertEqual(live.suffix(20).map { $0.id }, pages.map { $0.id }, "appended in array order")
        let entries: [OutlineEntry] = (0..<3).map { OutlineEntry(title: "Part \($0)", page: pages[$0].id) }
        let outline = try ctx.mutate { tx in try tx.put(entries, doc: self.doc) }
        XCTAssertEqual(try h.app.workspace.content(doc).liveOutline.suffix(3).map { $0.title }, ["Part 0", "Part 1", "Part 2"])
        XCTAssertEqual(outline.count, 3)
        let newClips = [AudioClip(name: "a", file: "a.m4a", start: 0), AudioClip(name: "b", file: "b.m4a", start: 5)]
        let clips = try ctx.mutate { tx in try tx.put(newClips, doc: self.doc) }
        XCTAssertTrue(clips.allSatisfy { $0.rev != .zero })
        XCTAssertTrue(h.app.bus.undo(doc), "one context = one undo group for pages, outline and audio")
        XCTAssertEqual(try h.snapshot(), before)
    }

    func testHarnessInsertIsOneUndoStep() async throws {
        let h = Harness()
        let written = try await h.insert([Item.makeSticky(StickyItem(frame: Frame(x: 1, y: 1, w: 50, h: 50))),
                                          Item.makeSticky(StickyItem(frame: Frame(x: 60, y: 1, w: 50, h: 50)))],
                                         page: Fixtures.page2)
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(h.undoDepth(doc), 1)
        XCTAssertNil(h.app.commands.descriptor("nibtesting.insert"), "the helper command is removed again")
    }

    // MARK: CommandContext

    func testCommandContextReachesTheAppAndSessionDefaults() async throws {
        let h = Harness()
        let ctx = try await probeContext(h)
        XCTAssertTrue(ctx.app === h.app)
        XCTAssertTrue(ctx.content === h.app.content)
        XCTAssertTrue(ctx.ui === h.app.ui)
        XCTAssertNil(ctx.navigator)
        XCTAssertEqual(try ctx.documentOrSession(nil), doc)
        XCTAssertEqual(try ctx.documentOrSession("doc:FIXTUREDOC02"), Fixtures.textDocID)
        let page = try ctx.pageOrSession(nil)
        XCTAssertEqual(page.doc, doc)
        XCTAssertEqual(page.page, page1)
        XCTAssertThrowsError(try ctx.pageOrSession("doc:FIXTUREDOC01"))
        XCTAssertEqual(ctx.refsOrSelection(nil), [])
        h.session.selection = Selection(doc: doc, page: page1, items: [Fixtures.shapeID])
        XCTAssertEqual(ctx.refsOrSelection([]), ["item:FIXTUREDOC01/FIXTUREPG001/FIXTURESHP01"])

        XCTAssertFalse(ctx.isReadOnly(doc))
        h.app.services.set(NSMutableSet(array: [doc.raw]), for: ServiceKeys.storeReadOnly)
        XCTAssertTrue(ctx.isReadOnly(doc))
        XCTAssertTrue(h.app.isReadOnly(doc))
        XCTAssertFalse(ctx.isReadOnly(Fixtures.textDocID))
        XCTAssertEqual(h.app.deviceHex, "00000007")
    }

    func testUndoFallsBackToTheSessionDocumentForTheUser() async throws {
        let h = Harness()
        let ctx = try await probeContext(h)
        try ctx.mutate { tx in try tx.delete(item: Fixtures.stickyID, doc: self.doc, page: self.page1) }
        let r = try await h.run(CommandIDs.undo)
        XCTAssertEqual(r["done"], true)
        XCTAssertNoThrow(try h.app.workspace.item(doc, page: page1, id: Fixtures.stickyID))
        do {
            try await h.run(CommandIDs.undo, [:], as: .ai("t"))
            XCTFail("non-user callers must name the document")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .invalidParams)
        }
    }

    func testInputFileSecurity() async throws {
        let h = Harness(features: [V2ProbeFeature.self])
        let host = FakePluginHost(hosts: ["example.org"])
        h.app.services.set(host, for: ServiceKeys.pluginHost)
        h.app.gateway.grants = { p in
            if case .plugin = p { return [.documentRead, .network] }
            return Gateway.defaultGrants(p)
        }
        func denied(_ url: String, as principal: Principal, _ code: NibError.Code,
                    file: StaticString = #filePath, line: UInt = #line) async {
            do {
                try await h.run("v2probe.fetch", ["url": .string(url)], as: principal)
                XCTFail("\(url) must be refused for \(principal)", file: file, line: line)
            } catch let e as NibError {
                XCTAssertEqual(e.code, code, "\(url) as \(principal): \(e)", file: file, line: line)
            } catch {
                XCTFail("unexpected \(error)", file: file, line: line)
            }
        }
        // The old `case "https", "http" where principal.isUser` let every non-user principal download over https.
        await denied("http://example.org/a.pdf", as: .plugin("dev.test.plugin"), .permissionDenied)
        await denied("https://evil.example.com/a.pdf", as: .plugin("dev.test.plugin"), .permissionDenied)
        await denied("http://example.org/a.pdf", as: .ai("chat"), .permissionDenied)
        h.app.gateway.grants = { p in
            if case .ai = p { return [.documentRead] }
            return Gateway.defaultGrants(p)
        }
        await denied("https://example.org/a.pdf", as: .ai("chat"), .permissionDenied)
        await denied("tmp:../../secret", as: .user, .invalidParams)
        await denied("tmp:.hidden", as: .user, .invalidParams)

        let tmp = try h.assets.putTemporary(Data([1, 2, 3]), ext: "bin")
        let ok = try await h.run("v2probe.fetch", ["url": .string("tmp:" + tmp.name)])
        XCTAssertEqual(ok["size"], 3)
        XCTAssertEqual(NibLimits.maxDownloadBytes, 200 * 1_048_576)
    }

    func testClosureHookTransformsAndVetoes() async throws {
        let h = Harness(features: [V2ProbeFeature.self])
        h.app.bus.hooks.register(CommandHookDescriptor(id: "v2.hook", owner: "test", commands: ["v2probe.*"]) { command, params in
            if command == "v2probe.echo", params["veto"] == true { throw NibError(.userDenied, "vetoed") }
            return command == "v2probe.echo" ? params.merging(["hooked": true]) : nil
        })
        let r = try await h.run("v2probe.echo", ["x": 1])
        XCTAssertEqual(r["hooked"], true)
        XCTAssertEqual(r["x"], 1)
        do {
            try await h.run("v2probe.echo", ["veto": true])
            XCTFail("the hook vetoes")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .userDenied)
        }
    }

    func testGuardHookSeesTheCallAndVetoesForEveryPrincipal() async throws {
        let h = Harness(features: [V2ProbeFeature.self])
        var seen: [(principal: String, page: PageID?, session: Bool)] = []
        var mutateError: NibError?
        let limit = 1
        h.app.bus.hooks.register(CommandHookDescriptor.guarding(id: "v2.limit", owner: "test", commands: ["v2probe.create"]) { _, params, ctx in
            let page = try ctx.pageOrSession(params["page"]?.stringValue)
            seen.append((ctx.principal.kind, page.page, ctx.activeSession != nil))
            do { try ctx.mutate { _ in } } catch let e as NibError { mutateError = e }
            let count = try ctx.app?.workspace.items(page.doc, page: page.page).filter { $0.kind == .sticky }.count ?? 0
            if count >= limit + 1 { throw NibError(.invalidParams, "board limit reached") }
            return nil
        })
        XCTAssertEqual(h.session.page, Fixtures.page1)
        let before = try h.app.workspace.items(doc, page: page1).filter { $0.kind == .sticky }.count
        XCTAssertEqual(before, 1, "fixture page 1 has one sticky")
        _ = try await h.run("v2probe.create")
        XCTAssertEqual(mutateError?.code, .permissionDenied, "a guard runs read-only")
        for principal in [Principal.ai("c"), .plugin("dev.test.plugin"), .user] {
            do {
                _ = try await h.run("v2probe.create", as: principal)
                XCTFail("the guard vetoes \(principal.kind)")
            } catch let e as NibError {
                XCTAssertEqual(e.code, .invalidParams)
            }
        }
        XCTAssertEqual(seen.map { $0.principal }, ["user", "ai", "plugin", "user"])
        XCTAssertTrue(seen.allSatisfy { $0.page == Fixtures.page1 && $0.session }, "session defaults resolve inside the guard")
        XCTAssertEqual(try h.app.workspace.items(doc, page: page1).filter { $0.kind == .sticky }.count, 2)

        XCTAssertEqual(TemplateIDs.blank, PageRecord().background.template?.id)
        XCTAssertEqual(TemplateIDs.whiteboardDots, "builtin.whiteboardDots")
        let t = TemplateDefinition(id: TemplateIDs.ruled, title: "Ruled", category: "Writing", owner: "test",
                                   defaults: [TemplateParamNames.spacing: 24, TemplateParamNames.margin: 10]) { _, _, _ in
            TemplateRender(paper: .white)
        }
        XCTAssertEqual(t.metrics(for: [:], size: nil).spacing, 24)
        XCTAssertEqual(t.metrics(for: [:], size: nil).margins?.left, 10)
    }

    func testGatewayPerKindPresenterAndPolicy() async throws {
        let h = Harness(features: [V2ProbeFeature.self])
        let bridgeConfirmer = AutoConfirm()
        bridgeConfirmer.decision = .deny
        h.app.gateway.setPresenter(bridgeConfirmer, forPrincipalKind: "bridge")
        h.app.gateway.setPolicy(forPrincipalKind: "bridge") { _ in .always }
        XCTAssertEqual(h.app.gateway.policy(.bridge("c")), .always)
        XCTAssertEqual(h.app.gateway.policy(.ai("c")), .destructive)
        do {
            try await h.run("v2probe.create", as: .bridge("c"))
            XCTFail("the bridge presenter denies")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .userDenied)
        }
        XCTAssertEqual(bridgeConfirmer.requests.count, 1)
        XCTAssertTrue(h.confirmer.requests.isEmpty, "the app-wide presenter was not asked")
        _ = try await h.run("v2probe.create", as: .ai("c"))
        XCTAssertTrue(h.app.gateway.confirmationPresenter(for: .ai("c")) === h.confirmer)
    }

    // MARK: Session, events and registries

    func testSessionEventsTemporaryToolsAndInking() async throws {
        let h = Harness()
        var types: [String] = []
        let sub = h.app.events.subscribe { types.append($0.type) }
        defer { sub.cancel() }
        let other = EditorSession()
        h.app.services.sessions.add(other)
        h.app.services.sessions.activate(h.session)
        XCTAssertEqual(types.filter { $0 == NibEventType.sessionActivated }.count, 2)
        h.session.hiddenLayers = [1]
        h.session.activeLayer = 2
        XCTAssertEqual(types.filter { $0 == NibEventType.layersChanged }.count, 2)

        h.session.tool = "pen"
        try await h.run(CommandIDs.toolSelect, ["tool": "lasso", "temporary": true])
        XCTAssertEqual(h.session.tool, "lasso")
        XCTAssertEqual(h.session.temporaryReturnTool, "pen")
        let canvas = FakeCanvasHost(h)
        canvas.finishToolUse(StickyTestTool())
        XCTAssertEqual(h.session.tool, "pen", "a temporary tool returns after one use")
        XCTAssertNil(h.session.temporaryReturnTool)
        XCTAssertTrue(types.contains(NibEventType.toolFinished))
        try await h.run(CommandIDs.toolSelect, ["tool": "image"])
        canvas.finishToolUse(OneShotTestTool())
        XCTAssertEqual(h.session.tool, "pen", "a non-sticky tool hands back to the previous tool")

        var seen: [Bool] = []
        let watch = h.session.inking.observe { seen.append($0.isInking) }
        h.session.inking.begin(strokeBounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        h.session.inking.update(strokeBounds: CGRect(x: 0, y: 0, width: 20, height: 10))
        h.session.inking.end()
        watch.cancel()
        XCTAssertEqual(seen, [true, true, false])
        XCTAssertNil(h.session.inking.strokeBounds)
    }

    func testTypedEventPayloads() {
        let bus = EventBus()
        var got: SyncStatusPayload?
        let sub = bus.subscribe { got = $0.decode(SyncStatusPayload.self) ?? got }
        defer { sub.cancel() }
        let sent = SyncStatusPayload(state: "warning", source: "store", reason: "newerFormat", message: "read-only")
        let e = bus.emit(sent, doc: Fixtures.docID)
        XCTAssertEqual(e.type, NibEventType.syncStatus)
        XCTAssertEqual(got, sent)
        XCTAssertNil(e.decode(IndexProgressPayload.self))
        let laser = bus.emit(LaserMovedPayload(page: "page:D/P", point: nil, mode: "dot", color: .black))
        XCTAssertNil(laser.payload?["point"], "a lifted laser has no point")
        XCTAssertEqual(laser.decode(LaserMovedPayload.self)?.mode, "dot")
        XCTAssertEqual(IndexProgressPayload(running: true, done: 3, total: 10).pending, 7)
        for type in [AudioPlaybackPayload.eventType, AudioRecordingPayload.eventType, ShapeSnappedPayload.eventType,
                     PencilHapticPayload.eventType] {
            XCTAssertFalse(type.isEmpty)
        }
    }

    func testRegistryChangeNotificationsNameTheIDs() {
        let registry = Registry<TapePatternDescriptor>()
        let box = NoteBox()
        let token = NotificationCenter.default.addObserver(forName: .nibRegistryDidChange, object: registry, queue: nil) {
            box.notes.append($0)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        registry.register(TapePatternDescriptor(id: "tape.a", title: "A", owner: "p") { Data() })
        registry.register(TapePatternDescriptor(id: "tape.a", title: "A2", owner: "p") { Data() })
        registry.register(TapePatternDescriptor(id: "tape.b", title: "B", owner: "p") { Data() })
        registry.unregister(owner: "p")
        let notes = box.notes
        XCTAssertEqual(notes.map { RegistryChange.ids($0) }, [["tape.a"], ["tape.a"], ["tape.b"], ["tape.a", "tape.b"]])
        XCTAssertEqual(notes.map { $0.userInfo?[RegistryChange.kindKey] as? String },
                       [RegistryChange.registered, RegistryChange.replaced, RegistryChange.registered, RegistryChange.unregistered])
        XCTAssertEqual(registry.generation, 4)
    }

    func testFloatingHostToolMenuPopoverAndSnapshots() throws {
        let h = Harness()
        let host = FakeFloatingHost()
        XCTAssertNil(h.session.floatingHost)
        h.session.floatingHost = host
        let navigator = RecordingNavigator(session: h.session)
        XCTAssertTrue(navigator.floatingHost === host, "the navigator forwards the window's host by default")
        XCTAssertTrue(ChromeContext(app: h.app, session: h.session).floatingHost === host)
        host.present("comment.thread") { Text("Thread") }
        XCTAssertTrue(host.isPresenting("comment.thread"))
        XCTAssertTrue(host.setAnchor("pin", rect: CGRect(x: 1, y: 2, width: 3, height: 4), in: UIView()))
        host.postToast("Deleted")
        XCTAssertEqual(host.toasts, ["Deleted"])
        host.dismiss("comment.thread")
        XCTAssertFalse(host.isPresenting("comment.thread"))

        var open = true
        var menu = ToolMenuDescriptor(tool: "pen", owner: "presets") { _ in AnyView(Text("bar")) }
        XCTAssertNil(menu.makePopover)
        menu.makePopover = { _ in
            ToolMenuPopover(source: "pen.width", isPresented: Binding(get: { open }, set: { open = $0 }), title: "Thickness") {
                Text("slider")
            }
        }
        h.app.ui.toolMenus.register(menu)
        let popover = try XCTUnwrap(h.app.ui.toolMenus.get("pen")?.makePopover?(h.session))
        XCTAssertEqual(popover.source, "pen.width")
        popover.isPresented.wrappedValue = false
        XCTAssertFalse(open)

        let red = try XCTUnwrap(NibSnapshot.image(Color(red: 1, green: 0, blue: 0), size: CGSize(width: 20, height: 20), scale: 1))
        let p = try XCTUnwrap(NibSnapshot.pixel(red, at: CGPoint(x: 10, y: 10)))
        XCTAssertGreaterThan(p.r, 200)
        XCTAssertLessThan(p.g, 60)
        XCTAssertNil(NibSnapshot.pixel(red, at: CGPoint(x: 30, y: 10)))
        let variants = NibSnapshot.images(Color.primary, size: CGSize(width: 10, height: 10), scale: 1)
        XCTAssertEqual(Set(variants.keys), Set(NibSnapshot.Variant.allCases))
        let light = variants[.light].flatMap { NibSnapshot.pixel($0, at: CGPoint(x: 5, y: 5)) }
        let dark = variants[.dark].flatMap { NibSnapshot.pixel($0, at: CGPoint(x: 5, y: 5)) }
        XCTAssertNotEqual(light, dark, "Color.primary follows the variant's colour scheme")
        let text = Text("The quick brown fox jumps over the lazy dog")
        XCTAssertGreaterThan(NibSnapshot.fittingSize(text, width: 200, variant: .largeText).height,
                             NibSnapshot.fittingSize(text, width: 200).height)
    }

    func testChromeOverlayRegistry() {
        let h = Harness()
        var recording = false
        h.app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: "audio.hud", owner: "audio", placement: .top, surface: .hud, order: 20,
            isVisible: { _ in recording }, makeView: { _ in AnyView(Text("REC")) }))
        h.app.ui.chromeOverlays.register(ChromeOverlayDescriptor(
            id: "zoom.pane", owner: "zoom", placement: .bottom, surface: .panel, order: 10, recedesWhileWriting: false,
            docKinds: [.notebook], makeView: { _ in AnyView(Text("Zoom")) }))
        let notebook = ChromeContext(app: h.app, session: h.session, kind: .notebook)
        XCTAssertEqual(h.app.ui.visibleChromeOverlays(notebook).map { $0.id }, ["zoom.pane"])
        recording = true
        XCTAssertEqual(h.app.ui.visibleChromeOverlays(notebook).map { $0.id }, ["zoom.pane", "audio.hud"], "z-order by order")
        let board = ChromeContext(app: h.app, session: h.session, kind: .whiteboard)
        XCTAssertEqual(h.app.ui.visibleChromeOverlays(board).map { $0.id }, ["audio.hud"])
        XCTAssertFalse(h.app.ui.chromeOverlays.get("zoom.pane")?.recedesWhileWriting ?? true)

        let box = NoteBox()
        let token = NotificationCenter.default.addObserver(forName: .nibChromeNeedsUpdate, object: h.app.ui, queue: nil) {
            box.notes.append($0)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        h.app.ui.setNeedsChromeUpdate(h.session)
        XCTAssertEqual(box.notes.first?.userInfo?["session"] as? String, h.session.id.raw)
    }

    func testLiveDescriptorState() {
        let h = Harness()
        var item = ToolbarItemDescriptor(id: "undo", title: "Undo", icon: "arrow.uturn.backward", group: .navTrailing,
                                         order: 0, owner: "t", command: CommandIDs.undo, params: ["x": 1])
        item.sessionParams = { s in ["doc": .string(s.document.map { NodeRef.document($0).description } ?? "")] }
        item.isEnabled = { _ in false }
        item.sessionTitle = { _ in "Undo Add Page" }
        XCTAssertEqual(item.resolvedParams(for: h.session), ["x": 1, "doc": "doc:FIXTUREDOC01"])
        XCTAssertEqual(item.resolvedTitle(for: h.session), "Undo Add Page")
        XCTAssertEqual(item.resolvedIcon(for: h.session), "arrow.uturn.backward")
        XCTAssertEqual(item.isEnabled?(h.session), false)

        var key = KeyCommandDescriptor(id: "k", title: "K", shortcut: KeyShortcut("k", .command), command: "x.y", owner: "t")
        key.sessionParams = { s in ["page": .string(s.page?.raw ?? "")] }
        XCTAssertEqual(key.resolvedParams(for: h.session), ["page": "FIXTUREPG001"])
        XCTAssertEqual(key.resolvedParams(for: nil), [:])

        var menu = MenuItemDescriptor(id: "m", title: "Scroll", location: .documentMore, order: 0, owner: "t", command: "x.y")
        menu.isChecked = { _ in true }
        menu.contextTitle = { ctx in ctx.textRange.map { "Range \($0)" } ?? "none" }
        let ctx = MenuContext(app: h.app, folder: Fixtures.folderID, textRange: [2, 3])
        XCTAssertEqual(menu.resolvedTitle(for: ctx), "Range [2, 3]")
        XCTAssertEqual(menu.isChecked?(ctx), true)
    }

    // MARK: Model and geometry

    func testTemplateMetricsAndRegionRendering() {
        var t = TemplateDefinition(id: "t.grid", title: "Grid", category: "Essentials", owner: "t",
                                   defaults: ["spacing": 24, "margin": true]) { _, size, _ in
            TemplateRender(paper: .white, display: DisplayList(ops: [DisplayOp(op: .rect, rect: Rect(x: 0, y: 0, width: size.width, height: size.height))]))
        }
        let m = t.metrics(for: [:], size: .a4)
        XCTAssertEqual(m.spacing, 24)
        XCTAssertEqual(m.repeatPeriod, PageSize(24, 24))
        XCTAssertEqual(m.margins?.left ?? 0, 25 * 72 / 25.4, accuracy: 1e-9)
        XCTAssertEqual(t.metrics(for: ["spacing": 30], size: nil).spacing, 30)
        XCTAssertEqual(t.renderOps([:], size: .a4, scale: 2, region: Rect(x: 0, y: 0, width: 10, height: 10)).display.ops.count, 1)
        t.renderRegion = { _, _, _, region in
            TemplateRender(paper: .white, display: DisplayList(ops: [DisplayOp(op: .dots, rect: region, spacing: 24),
                                                                     DisplayOp(op: .dots, rect: region, spacing: 12)]))
        }
        t.metricsProvider = { _, _ in TemplateMetrics(spacing: 12) }
        XCTAssertEqual(t.renderOps([:], size: .a4, scale: 2, region: Rect(x: 0, y: 0, width: 10, height: 10)).display.ops.count, 2)
        XCTAssertEqual(t.renderOps([:], size: .a4, scale: 2, region: nil).display.ops.count, 1)
        XCTAssertEqual(t.metrics(for: [:], size: .a4).spacing, 12)
    }

    func testDisplayOpTextAlignmentAndWeight() throws {
        let op = DisplayOp(op: .text, rect: Rect(x: 0, y: 0, width: 200, height: 30), fill: .black, text: "Monday",
                           fontSize: 18, align: .center, weight: .semibold)
        let back = try JSONValue.from(op).decode(DisplayOp.self)
        XCTAssertEqual(back, op)
        XCTAssertNil(try JSONValue.parse(#"{"op":"text","text":"x"}"#).decode(DisplayOp.self).align)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 30), format: format).image { ctx in
            DisplayList(ops: [op]).draw(in: ctx.cgContext)
        }
        XCTAssertEqual(image.size.width, 200)
    }

    func testFrameArrayFormAndRotatedNonUniformScale() {
        XCTAssertEqual(Frame(array: [1, 2, 3, 4]), Frame(x: 1, y: 2, w: 3, h: 4))
        XCTAssertEqual(Frame(array: [1, 2, 3, 4, 0.5])?.rotation, 0.5)
        XCTAssertNil(Frame(array: [1, 2, 3]))
        XCTAssertEqual(Frame(x: 1, y: 2, w: 3, h: 4, rotation: 0.25).array, [1, 2, 3, 4, 0.25])

        let plain = Frame(x: 0, y: 0, w: 100, h: 50)
        XCTAssertEqual(plain.applying(.scale(2, 1)), Frame(x: 0, y: 0, w: 200, h: 50), "unrotated frames as before")
        // A frame rotated 90°: its own width runs along the page's y axis, so a page-x stretch changes its HEIGHT.
        let turned = Frame(x: 0, y: 0, w: 100, h: 50, rotation: .pi / 2)
        let stretched = turned.applying(.scale(2, 1, about: turned.center))
        XCTAssertEqual(stretched.w, 100, accuracy: 1e-9)
        XCTAssertEqual(stretched.h, 100, accuracy: 1e-9)
        XCTAssertEqual(stretched.rotation, .pi / 2, accuracy: 1e-9)
        let rotated = turned.applying(.rotation(.pi / 2))
        XCTAssertEqual(rotated.rotation, .pi, accuracy: 1e-12, "similarity transforms keep the old arithmetic")
        XCTAssertEqual(rotated.w, 100, accuracy: 1e-9)

        let t = Affine.rotation(0.3).concatenating(.translation(5, -2)).concatenating(.scale(2, 3))
        let p = Point(7, 11)
        let back = t.inverted.map { $0.apply(t.apply(p)) }
        XCTAssertEqual(back?.x ?? 0, 7, accuracy: 1e-9)
        XCTAssertEqual(back?.y ?? 0, 11, accuracy: 1e-9)
        XCTAssertNil(Affine.scale(0, 1).inverted)
    }

    func testPageBackgroundTransform() {
        let a4 = PageSize.a4
        XCTAssertEqual(PageRecord.backgroundTransform(sourceSize: a4, rotation: 0, pageSize: a4), .identity)
        // A landscape source turned 90° fits a portrait page exactly.
        let src = PageSize(841.89, 595.28)
        let t = PageRecord.backgroundTransform(sourceSize: src, rotation: 90, pageSize: a4)
        let topLeft = t.apply(.zero), topRight = t.apply(Point(src.width, 0))
        XCTAssertEqual(topLeft.x, a4.width, accuracy: 1e-6, "the source's top-left lands top-right")
        XCTAssertEqual(topLeft.y, 0, accuracy: 1e-6)
        XCTAssertEqual(topRight.x, a4.width, accuracy: 1e-6)
        XCTAssertEqual(topRight.y, a4.height, accuracy: 1e-6)
        // Letterboxed: a square source in A4 is centred vertically.
        var page = PageRecord(size: a4)
        page.rotation = 0
        let square = page.backgroundTransform(sourceSize: PageSize(100, 100))
        XCTAssertEqual(square.apply(.zero).y, (a4.height - a4.width) / 2, accuracy: 1e-6)
        XCTAssertEqual(PageRecord.scanTextExtKey, "nib.scanText")
    }

    func testBalancedFractionalKeys() {
        let keys = FractionalIndex.balanced(count: 10_000)
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertEqual(Set(keys).count, 10_000)
        XCTAssertLessThanOrEqual(keys.map { $0.count }.max() ?? 0, 4)
        let inside = FractionalIndex.balanced(count: 20, after: "V", before: "W")
        XCTAssertTrue(inside.allSatisfy { $0 > "V" && $0 < "W" })
        XCTAssertEqual(inside, inside.sorted())
    }

    func testFragmentRoundTripAndInstantiate() throws {
        let parent = Item(id: "PARENT000001", kind: .shape, z: "V",
                          shape: ShapeItem(shape: .rectangle, frame: Frame(x: 0, y: 0, w: 100, h: 100)))
        let child = Item(id: "CHILD0000001", kind: .image, z: "k", attachedTo: "PARENT000001",
                         image: ImageItem(frame: Frame(x: 10, y: 10, w: 20, h: 20), asset: Fixtures.pngAsset))
        let fragment = NibFragment.make(items: NibFragment.expand(["PARENT000001"], in: [parent, child])) { ref in
            ref == Fixtures.pngAsset ? Fixtures.pngData : nil
        }
        XCTAssertEqual(fragment.items.count, 2)
        XCTAssertEqual(fragment.assets[Fixtures.pngAsset.name], Fixtures.pngData)
        let data = try XCTUnwrap(fragment.encoded())
        let back = try NibFragment.decode(data)
        XCTAssertEqual(back, fragment)
        XCTAssertEqual(try JSONValue.parse(String(decoding: data, as: UTF8.self))["format"], "nib-fragment/1")
        let placed = back.instantiated(translate: Point(5, 5), ids: ["NEWPARENT001"], zAfter: "z", layer: 1,
                                       assets: [Fixtures.pngAsset.name: AssetRef("copied.png")])
        XCTAssertEqual(placed[0].id, "NEWPARENT001")
        XCTAssertEqual(placed[1].attachedTo, "NEWPARENT001")
        XCTAssertEqual(placed[1].image?.asset, AssetRef("copied.png"))
        XCTAssertEqual(placed[1].image?.frame.x, 15)
        XCTAssertTrue(placed.allSatisfy { $0.layer == 1 && $0.z > "z" })
        XCTAssertThrowsError(try NibFragment.decode(Data(#"{"format":"nib-fragment/9"}"#.utf8)))
    }

    func testModelAdditionsDecodeLeniently() throws {
        let style = try JSONValue.parse(#"{"padding":6,"align":"center","lineSpacing":4}"#).decode(TextBoxStyle.self)
        XCTAssertEqual(style.align, .center)
        XCTAssertEqual(style.lineSpacing, 4)
        XCTAssertNil(try JSONValue.parse(#"{"align":"sideways"}"#).decode(TextBoxStyle.self).align)
        let old = try JSONValue.from(TextBoxStyle())
        XCTAssertNil(old["align"], "unset paragraph defaults are not encoded")

        let image = try JSONValue.parse(#"{"frame":{"x":0,"y":0,"w":1,"h":1},"asset":"a.png","flipX":true}"#).decode(ImageItem.self)
        XCTAssertEqual(image.flipX, true)
        XCTAssertNil(image.flipY)
        XCTAssertNil(try JSONValue.from(ImageItem(frame: Frame(x: 0, y: 0, w: 1, h: 1), asset: AssetRef("a.png")))["flipX"])

        let rec = try JSONValue.parse(#"{"text":"hi","words":[{"text":"hi","bbox":[1,2,3,4]}]}"#).decode(TextRecognition.self)
        XCTAssertEqual(rec.words?.first?.text, "hi")
        XCTAssertEqual(rec.bbox, .zero)

        XCTAssertEqual(ShapeItem.quadraticControl(through: Point(0, 0), Point(50, 50), Point(100, 0)),
                       [Point(0, 0), Point(50, 100), Point(100, 0)])
        XCTAssertEqual(NibLimits.drawerMargin, 12)
        XCTAssertEqual(RGBA.highlighterAlpha, RGBA.highlighterYellow.a)
    }

    func testStrokeFastPathsMatchTheGenericDecoder() throws {
        let points = (0..<50).map { i in
            StrokePoint(x: Float(i), y: Float(i) * 2, t: Float(i) * 0.01, force: 0.3, azimuth: 0.2, altitude: 1.1,
                        roll: 0.4, width: 2, height: 3, opacity: 0.9)
        }
        let flat = points.flatMap { [$0.x, $0.y, $0.t, $0.force, $0.azimuth, $0.altitude, $0.roll, $0.width, $0.height, $0.opacity] }
        XCTAssertEqual(Stroke.unpackFull(flat), points)
        let data = flat.withUnsafeBufferPointer { Data(buffer: $0) }
        XCTAssertEqual(Stroke.unpackCompact(data), points)
        let encoder = JSONEncoder()
        encoder.userInfo[.nibCompactPoints] = true
        let stroke = Stroke(style: .defaultPen, points: points, t0: 5)
        XCTAssertEqual(try JSONDecoder().decode(Stroke.self, from: try encoder.encode(stroke)).points, points)
    }

    func testPresetsTapeRefsSelectionOutlineAndToolbarLayout() async throws {
        let partial = try JSONValue.parse(##"{"swatches":[{"color":"#112233"}],"widths":[1,2,3]}"##).decode(ToolPresets.self)
        XCTAssertEqual(partial.patterns, [.solid, .solid, .solid])
        XCTAssertEqual(partial.selectedWidth, 1)
        XCTAssertThrowsError(try JSONValue.parse(#"{"widths":[1]}"#).decode(ToolPresets.self))
        XCTAssertEqual(PresetSwatch.tapePatternRef(id: "tape.dots"), AssetRef("tape.dots.png"))
        XCTAssertEqual(PresetSwatch.tapePatternID(AssetRef("tape.dots.png")), "tape.dots")
        XCTAssertEqual(PresetSwatch.tapePatternID(AssetRef("builtin.dots")), "builtin.dots")

        let h = Harness()
        h.session.selection = Selection(doc: doc, page: page1, items: [Fixtures.shapeID],
                                        outline: [Point(0, 0), Point(10, 0), Point(5, 8)])
        XCTAssertEqual(h.session.selection.outline?.count, 3)
        h.session.editingTextRef = "item:FIXTUREDOC01/FIXTUREPG001/FIXTURETXT01"
        h.session.editingTextRange = [0, 5]
        XCTAssertEqual(h.session.editingTextRange, [0, 5])
        try await h.run(CommandIDs.settingsSet, ["name": "toolbar.layout", "value": ["order": ["pen"], "hidden": ["ruler"]]])
        XCTAssertEqual(h.app.settings.get(NibSettings.toolbarLayout), ToolbarLayoutSetting(order: ["pen"], hidden: ["ruler"]))
        XCTAssertTrue(h.app.settings.get(NibSettings.penReactsToRoll))
    }

    func testRichTextBridgeKeepsAModelFontThatIsNotInstalled() {
        var run = TextAttributes()
        run.font = "NoSuchFamilyV2"
        let text = RichText(paragraphs: [Paragraph(runs: [TextRun("Hello", run)])])
        let back = RichTextBridge.richText(RichTextBridge.attributed(text))
        XCTAssertEqual(back.paragraphs.first?.runs.first?.attrs.font, "NoSuchFamilyV2")
        let plain = RichTextBridge.richText(RichTextBridge.attributed(RichText(plain: "Hello")))
        XCTAssertNil(plain.paragraphs.first?.runs.first?.attrs.font)
    }

    func testTextLayoutAndHitBounds() {
        let content = ContentRegistries()
        let box = Item.makeText(TextBoxItem(frame: Frame(x: 10, y: 20, w: 100, h: 40), text: RichText(plain: "x"),
                                            style: TextBoxStyle(padding: 5)))
        XCTAssertEqual(content.textLayout(for: box)?.container, Frame(x: 15, y: 25, w: 90, h: 30))
        let note = Item.makeSticky(StickyItem(frame: Frame(x: 0, y: 0, w: 100, h: 100)))
        XCTAssertNil(content.textLayout(for: note))
        content.textLayouts.register(TextLayoutDescriptor(key: "sticky", owner: "sticky") { item in
            item.sticky.map { TextLayoutInfo(container: Frame(x: $0.frame.x + 12, y: $0.frame.y + 12, w: 76, h: 60)) }
        })
        XCTAssertEqual(content.textLayout(for: note)?.container.x, 12)
        XCTAssertEqual(TextLayoutInfo.lineFragmentPadding, 0)
        XCTAssertEqual(content.hitBounds(for: note), note.bounds)
        XCTAssertEqual(content.paintBounds(for: note), note.bounds.insetBy(-NibLimits.drawerMargin))
        content.drawers.register(ItemDrawerEntry(key: "sticky", owner: "sticky", drawer: IconOnlyDrawer()))
        XCTAssertEqual(content.hitBounds(for: note), Rect(x: 0, y: 0, width: 28, height: 28))
        XCTAssertEqual(content.paintBounds(for: note), note.bounds.insetBy(-NibLimits.drawerMargin))
    }

    func testWorkspaceCacheAccessors() throws {
        let h = Harness()
        let w = h.app.workspace
        var opened = 0
        let sub = h.app.events.subscribe { if $0.type == NibEventType.docOpened { opened += 1 } }
        defer { sub.cancel() }
        XCTAssertEqual(try w.peekContent(Fixtures.textDocID).meta.kind, .textDocument)
        XCTAssertFalse(w.isLoaded(Fixtures.textDocID), "peeking does not open the document")
        XCTAssertEqual(opened, 0)
        XCTAssertFalse(w.isPageCached(doc, page: Fixtures.page2))
        XCTAssertNil(w.contentRevision(doc, page: Fixtures.page2), "unknown without loading (in-memory persistence)")
        _ = try w.items(doc, page: page1)
        XCTAssertTrue(w.isPageCached(doc, page: page1))
        XCTAssertTrue(w.cachedPages(doc).contains(page1))
        XCTAssertEqual(w.contentRevision(doc, page: page1), Rev(wallMs: 1, counter: 0, device: 0))
        XCTAssertFalse(w.isReadOnly(doc))
    }

    func testWindowShowLibraryUsesTheNavigator() async throws {
        let h = Harness()
        do {
            try await h.run(CommandIDs.windowShowLibrary)
            XCTFail("no window")
        } catch let e as NibError {
            XCTAssertEqual(e.code, .unavailable)
        }
        let nav = RecordingNavigator(session: h.session)
        h.app.ui.activeNavigator = nav
        try await h.run(CommandIDs.windowShowLibrary, ["folder": "folder:FIXTUREFLD01"])
        XCTAssertEqual(nav.shownFolders, [Fixtures.folderID])
        nav.addTab(Fixtures.textDocID)
        XCTAssertEqual(nav.opened.map { $0.1 }, [.newTab], "default addTab opens a tab")

        var done: Result<ElementID?, NibError>?
        FakeCanvasHost(h).commitStroke(Stroke(style: .defaultPen, points: []), page: page1) { done = $0 }
        if case .success(let id)? = done { XCTAssertNil(id) } else { XCTFail("the default completion reports success") }
    }

    func testNewSettingsAreDeclared() async throws {
        let h = Harness()
        for name in ["appearance.liquid", "text.defaultStyle", "shapes.drawAndHold"] {
            XCTAssertNotNil(h.app.settings.descriptor(name), name)
        }
        try await h.run(CommandIDs.settingsSet, ["name": "appearance.liquid", "value": "calm"], as: .ai("t"))
        XCTAssertEqual(h.app.settings.get(NibSettings.liquidMode), "calm")
        XCTAssertEqual(NibSettings.defaultAIDirectTools.count, 8)
        XCTAssertEqual(BridgeNames.portSetting, "security.bridge.port")
        XCTAssertEqual(PanelIDs.trash, "organize.trash")
    }

    // MARK: Helpers

    private func probeContext(_ h: Harness, group: String? = nil) async throws -> CommandContext {
        var captured: CommandContext?
        let d = CommandDescriptor(id: "test.v2probe", title: "Probe", summary: "test", effect: .edit, exposure: .ui)
        h.app.commands.register(d) { _, ctx in
            captured = ctx
            return .null
        }
        try await h.app.bus.execute(Invocation(command: "test.v2probe", session: h.session, group: group))
        return try XCTUnwrap(captured)
    }

    /// The stand-ins F031's test registers for item.transform (F012) and item.update (F003).
    private func registerMoveStandIns(_ app: NibApp) {
        app.commands.register(CommandDescriptor(id: CommandIDs.itemTransform, title: "Move", summary: "Test stand-in.",
                                                params: .anything(), effect: .edit)) { json, ctx in
            guard case let .item(doc, page, id)? = NodeRef(json["refs"]?[0]?.stringValue ?? ""),
                  let dx = json["translate"]?[0]?.doubleValue, let dy = json["translate"]?[1]?.doubleValue else {
                throw NibError.invalid("refs / translate")
            }
            try ctx.mutate { tx in
                let item = try tx.item(doc, page: page, id: id)
                try tx.put(item.transformed(by: .translation(dx, dy)), doc: doc, page: page)
            }
            return [:]
        }
        app.commands.register(CommandDescriptor(id: CommandIDs.itemUpdate, title: "Update", summary: "Test stand-in.",
                                                params: .anything(), effect: .edit)) { json, ctx in
            guard case let .item(doc, page, id)? = NodeRef(json["ref"]?.stringValue ?? "") else { throw NibError.invalid("ref") }
            try ctx.mutate { tx in
                let item = try tx.item(doc, page: page, id: id)
                let merged = try JSONValue.from(item).merging(json["patch"] ?? [:]).decode(Item.self)
                try tx.put(merged, doc: doc, page: page)
            }
            return [:]
        }
    }
}

private extension Item {
    func with(id: ElementID) -> Item {
        var it = self
        it.id = id
        return it
    }
}

/// Commands the v2 tests call as other principals.
enum V2ProbeFeature: NibFeature {
    static let id = "v2probe"

    static func register(_ app: NibApp) {
        app.commands.register(CommandDescriptor(id: "v2probe.create", title: "Create", summary: "Adds a sticky note (test).",
                                                examples: [[:]], effect: .edit)) { _, ctx in
            let item = try ctx.mutate { tx in
                try tx.put(Item.makeSticky(StickyItem(frame: Frame(x: 10, y: 10, w: 50, h: 50))), doc: Fixtures.docID,
                           page: Fixtures.page1)
            }
            return ["ref": .string(NodeRef.item(Fixtures.docID, Fixtures.page1, item.id).description)]
        }
        app.commands.register(CommandDescriptor(id: "v2probe.move", title: "Move", summary: "Moves an item to page 2 (test).",
                                                params: .obj(["id": .str()], required: ["id"]),
                                                examples: [["id": "FIXTURESTY01"]], effect: .edit)) { json, ctx in
            let id = NibID(json["id"]?.stringValue ?? "")
            try ctx.mutate { tx in
                try tx.move(item: id, doc: Fixtures.docID, from: Fixtures.page1, to: Fixtures.page2,
                            transform: .translation(20, 0))
            }
            return [:]
        }
        app.commands.register(CommandDescriptor(id: "v2probe.fetch", title: "Fetch", summary: "Resolves a url param (test).",
                                                params: .obj(["url": .str()], required: ["url"]),
                                                examples: [["url": "tmp:x"]], effect: .read)) { json, ctx in
            let url = try await ctx.inputFile(json["url"]?.stringValue ?? "")
            let size = (try? Data(contentsOf: url).count) ?? -1
            return ["size": .number(Double(size))]
        }
        app.commands.register(CommandDescriptor(id: "v2probe.echo", title: "Echo", summary: "Returns its params (test).",
                                                examples: [[:]], effect: .read)) { json, _ in json }
    }
}

/// Collects notifications from `@Sendable` observer blocks.
private final class NoteBox {
    var notes: [Notification] = []
}

/// Minimal plugin host exposing one plugin whose manifest allows `hosts`.
@MainActor
private final class FakePluginHost: PluginHosting {
    let plugin: FakePluginHandle

    init(hosts: [String]) {
        var manifest = try! PluginManifest.fixture(id: "dev.test.plugin", permissions: ["document:read", "network"])
        manifest.network = PluginNetwork(hosts: hosts)
        plugin = FakePluginHandle(manifest: manifest)
    }

    var installed: [PluginInfo] { [] }
    func handle(_ id: String) -> PluginRuntimeHandle? { id == plugin.manifest.id ? plugin : nil }
    func folder(_ id: String) -> URL? { nil }
    func load(_ id: String) async throws {}
    func unload(_ id: String) {}
    func setEnabled(_ id: String, _ enabled: Bool) async throws {}
    var aiInstructions: [String] { [] }
}

@MainActor
private final class FakePluginHandle: PluginRuntimeHandle {
    let manifest: PluginManifest
    init(manifest: PluginManifest) { self.manifest = manifest }
    var logs: [String] { [] }
    func invoke(command: String, params: JSONValue, context: CommandContext) async throws -> JSONValue { .null }
    func deliver(_ event: NibEvent) {}
    func postMessage(from panel: String, message: JSONValue) {}
    func evaluate(_ javascript: String) async -> String { "" }
    func stop() {}
}

@MainActor
private final class StickyTestTool: CanvasTool {
    let id = "lasso"
    let inputMode = CanvasInputMode.samples
}

@MainActor
private final class OneShotTestTool: CanvasTool {
    let id = "image"
    let inputMode = CanvasInputMode.taps
    var isSticky: Bool { false }
}

/// A drawer whose hit area is only a 28 pt icon (collapsed sticky note).
private final class IconOnlyDrawer: ItemDrawer {
    func draw(_ item: Item, in context: DrawContext) {}
    func hitBounds(_ item: Item) -> Rect? {
        guard let f = item.frame else { return nil }
        return Rect(x: f.x, y: f.y, width: 28, height: 28)
    }
}

/// Records what features put into the window's droplet container.
@MainActor
private final class FakeFloatingHost: FloatingHosting {
    private(set) var presented: [String: AnyView] = [:]
    private(set) var anchors: [String: CGRect] = [:]
    private(set) var toasts: [String] = []

    func present(_ id: String, content: AnyView) { presented[id] = content }
    func dismiss(_ id: String) { presented[id] = nil }
    func isPresenting(_ id: String) -> Bool { presented[id] != nil }
    func setAnchor(_ id: String, rect: CGRect, in view: UIView) -> Bool {
        anchors[id] = rect
        return true
    }
    func removeAnchor(_ id: String) { anchors[id] = nil }
    func containerRect(_ rect: CGRect, from view: UIView) -> CGRect? { rect }
    func postToast(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?) { toasts.append(message) }
}

@MainActor
private final class RecordingNavigator: SceneNavigator {
    let session: EditorSession
    private(set) var shownFolders: [FolderID?] = []
    private(set) var opened: [(DocumentID, OpenMode)] = []
    init(session: EditorSession) { self.session = session }
    var openDocuments: [DocumentID] { opened.map { $0.0 } }
    var activeDocument: DocumentID? { opened.last?.0 }
    var rootViewController: UIViewController? { nil }
    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode) { opened.append((doc, mode)) }
    func closeDocument(_ doc: DocumentID) {}
    func showLibrary(folder: FolderID?) { shownFolders.append(folder) }
    func showSettings(page: String?) {}
    func presentModal(_ viewController: UIViewController) {}
}
```

### `NibKit/Tests/NibContractsTests/CommandCatalogueTests.swift`

```swift
import XCTest
import NibContracts

/// contracts-v2.1: every command id in the ARCHITECTURE.md §6.5 catalogue has a `CommandIDs` constant, and `PanelIDs`
/// matches the well-known panel ids that ARCHITECTURE.md §13 lists. The tables below name every constant, so a missing
/// one fails to compile; the doc checks read docs/ARCHITECTURE.md from the repository checkout this file lives in.
final class CommandCatalogueTests: XCTestCase {
    /// Every `CommandIDs` constant with the id it holds, in §6.5 catalogue order.
    static let commandIDs: [(String, String)] = [
        ("edit.undo", CommandIDs.undo),
        ("edit.redo", CommandIDs.redo),
        ("history.list", CommandIDs.historyList),
        ("history.revertGroup", CommandIDs.revertGroup),
        ("commands.list", CommandIDs.commandsList),
        ("commands.describe", CommandIDs.commandsDescribe),
        ("commands.batch", CommandIDs.batch),
        ("tool.select", CommandIDs.toolSelect),
        ("settings.get", CommandIDs.settingsGet),
        ("settings.set", CommandIDs.settingsSet),
        ("settings.list", CommandIDs.settingsList),
        ("settings.describe", CommandIDs.settingsDescribe),
        ("window.showLibrary", CommandIDs.windowShowLibrary),

        ("a11y.describePage", CommandIDs.a11yDescribePage),

        ("ai.ask", CommandIDs.aiAsk),
        ("ai.chat.list", CommandIDs.aiChatList),
        ("ai.chat.rename", CommandIDs.aiChatRename),
        ("ai.chat.delete", CommandIDs.aiChatDelete),
        ("ai.chat.feedback", CommandIDs.aiChatFeedback),
        ("ai.provider.list", CommandIDs.aiProviderList),
        ("ai.provider.save", CommandIDs.aiProviderSave),
        ("ai.provider.activate", CommandIDs.aiProviderActivate),
        ("ai.provider.delete", CommandIDs.aiProviderDelete),
        ("ai.provider.test", CommandIDs.aiProviderTest),
        ("ai.quiz", CommandIDs.aiQuiz),

        ("answerZone.create", CommandIDs.answerZoneCreate),
        ("answerZone.score", CommandIDs.answerZoneScore),
        ("answerZone.setHints", CommandIDs.answerZoneSetHints),
        ("answerZone.revealHint", CommandIDs.answerZoneRevealHint),

        ("app.openURL", CommandIDs.appOpenURL),
        ("app.quickAction", CommandIDs.appQuickAction),
        ("app.deleteAllData", CommandIDs.appDeleteAllData),

        ("asset.put", CommandIDs.assetPut),
        ("asset.get", CommandIDs.assetGet),
        ("asset.upload", CommandIDs.assetUpload),

        ("audio.record", CommandIDs.audioRecord),
        ("audio.play", CommandIDs.audioPlay),
        ("audio.pause", CommandIDs.audioPause),
        ("audio.seek", CommandIDs.audioSeek),
        ("audio.setPlayback", CommandIDs.audioSetPlayback),
        ("audio.rename", CommandIDs.audioRename),
        ("audio.delete", CommandIDs.audioDelete),
        ("audio.export", CommandIDs.audioExport),
        ("audio.quickRecord", CommandIDs.audioQuickRecord),

        ("backup.now", CommandIDs.backupNow),
        ("backup.manual", CommandIDs.backupManual),
        ("backup.configure", CommandIDs.backupConfigure),
        ("backup.chooseFolder", CommandIDs.backupChooseFolder),
        ("backup.status", CommandIDs.backupStatus),
        ("backup.clearQueue", CommandIDs.backupClearQueue),

        ("block.insert", CommandIDs.blockInsert),
        ("block.update", CommandIDs.blockUpdate),
        ("block.delete", CommandIDs.blockDelete),
        ("block.move", CommandIDs.blockMove),
        ("block.comment", CommandIDs.blockComment),
        ("block.editComment", CommandIDs.blockEditComment),
        ("block.deleteComment", CommandIDs.blockDeleteComment),
        ("block.resolveComment", CommandIDs.blockResolveComment),

        ("board.add", CommandIDs.boardAdd),
        ("board.rename", CommandIDs.boardRename),
        ("board.insertTemplate", CommandIDs.boardInsertTemplate),

        ("bridge.setEnabled", CommandIDs.bridgeSetEnabled),
        ("bridge.status", CommandIDs.bridgeStatus),

        ("calendar.events", CommandIDs.calendarEvents),
        ("calendar.createNote", CommandIDs.calendarCreateNote),
        ("calendar.openNote", CommandIDs.calendarOpenNote),

        ("canvas.decorate", CommandIDs.canvasDecorate),
        ("canvas.clearDecorations", CommandIDs.canvasClearDecorations),

        ("card.add", CommandIDs.cardAdd),
        ("card.update", CommandIDs.cardUpdate),
        ("card.delete", CommandIDs.cardDelete),
        ("card.move", CommandIDs.cardMove),
        ("card.moveTo", CommandIDs.cardMoveTo),

        ("clipboard.copy", CommandIDs.clipboardCopy),
        ("clipboard.cut", CommandIDs.clipboardCut),
        ("clipboard.paste", CommandIDs.clipboardPaste),
        ("clipboard.copyText", CommandIDs.clipboardCopyText),

        ("collab.host", CommandIDs.collabHost),
        ("collab.join", CommandIDs.collabJoin),
        ("collab.leave", CommandIDs.collabLeave),
        ("collab.participants", CommandIDs.collabParticipants),
        ("collab.approve", CommandIDs.collabApprove),
        ("collab.setRole", CommandIDs.collabSetRole),
        ("collab.revoke", CommandIDs.collabRevoke),
        ("collab.follow", CommandIDs.collabFollow),
        ("collab.followMe", CommandIDs.collabFollowMe),
        ("collab.markSeen", CommandIDs.collabMarkSeen),

        ("comment.add", CommandIDs.commentAdd),
        ("comment.reply", CommandIDs.commentReply),
        ("comment.edit", CommandIDs.commentEdit),
        ("comment.deleteMessage", CommandIDs.commentDeleteMessage),
        ("comment.resolve", CommandIDs.commentResolve),
        ("comment.tapAt", CommandIDs.commentTapAt),

        ("connector.create", CommandIDs.connectorCreate),
        ("connector.setPath", CommandIDs.connectorSetPath),

        ("diagnostics.export", CommandIDs.diagnosticsExport),
        ("diagnostics.setFeatureEnabled", CommandIDs.diagnosticsSetFeatureEnabled),

        ("diagram.addConnected", CommandIDs.diagramAddConnected),
        ("diagram.create", CommandIDs.diagramCreate),

        ("dictionary.add", CommandIDs.dictionaryAdd),
        ("dictionary.remove", CommandIDs.dictionaryRemove),
        ("dictionary.list", CommandIDs.dictionaryList),

        ("doc.create", CommandIDs.docCreate),
        ("doc.setFavorite", CommandIDs.docSetFavorite),
        ("doc.merge", CommandIDs.docMerge),
        ("doc.setScrollDirection", CommandIDs.docSetScrollDirection),
        ("doc.open", CommandIDs.docOpen),
        ("doc.quickNote", CommandIDs.docQuickNote),
        ("doc.convertToWhiteboard", CommandIDs.docConvertToWhiteboard),
        ("doc.setLanguage", CommandIDs.docSetLanguage),
        ("doc.setWritingAids", CommandIDs.docSetWritingAids),
        ("doc.setLocked", CommandIDs.docSetLocked),
        ("doc.unlock", CommandIDs.docUnlock),
        ("doc.suggestTitle", CommandIDs.docSuggestTitle),

        ("element.create", CommandIDs.elementCreate),
        ("element.insert", CommandIDs.elementInsert),
        ("element.collection.create", CommandIDs.elementCollectionCreate),
        ("element.collection.update", CommandIDs.elementCollectionUpdate),
        ("element.collection.delete", CommandIDs.elementCollectionDelete),
        ("element.collection.list", CommandIDs.elementCollectionList),
        ("element.list", CommandIDs.elementList),
        ("element.rename", CommandIDs.elementRename),
        ("element.delete", CommandIDs.elementDelete),
        ("element.import", CommandIDs.elementImport),
        ("element.export", CommandIDs.elementExport),

        ("export.run", CommandIDs.exportRun),
        ("export.present", CommandIDs.exportPresent),
        ("export.saveToSource", CommandIDs.exportSaveToSource),

        ("folder.create", CommandIDs.folderCreate),
        ("folder.setStyle", CommandIDs.folderSetStyle),

        ("gallery.list", CommandIDs.galleryList),

        ("gif.search", CommandIDs.gifSearch),

        ("handwriting.toText", CommandIDs.handwritingToText),
        ("handwriting.toTextPages", CommandIDs.handwritingToTextPages),
        ("handwriting.words", CommandIDs.handwritingWords),
        ("handwriting.reflow", CommandIDs.handwritingReflow),
        ("handwriting.straighten", CommandIDs.handwritingStraighten),
        ("handwriting.align", CommandIDs.handwritingAlign),
        ("handwriting.insertSpace", CommandIDs.handwritingInsertSpace),
        ("handwriting.replaceWord", CommandIDs.handwritingReplaceWord),
        ("handwriting.restyle", CommandIDs.handwritingRestyle),

        ("image.insert", CommandIDs.imageInsert),
        ("image.crop", CommandIDs.imageCrop),
        ("image.flip", CommandIDs.imageFlip),
        ("image.replace", CommandIDs.imageReplace),
        ("image.saveToPhotos", CommandIDs.imageSaveToPhotos),
        ("image.pick", CommandIDs.imagePick),

        ("import.files", CommandIDs.importFiles),
        ("import.pick", CommandIDs.importPick),

        ("index.rebuild", CommandIDs.indexRebuild),

        ("ink.addStrokes", CommandIDs.inkAddStrokes),
        ("ink.setStyle", CommandIDs.inkSetStyle),
        ("ink.setPoints", CommandIDs.inkSetPoints),
        ("ink.erase", CommandIDs.inkErase),
        ("ink.scribbleErase", CommandIDs.inkScribbleErase),
        ("ink.writeText", CommandIDs.inkWriteText),

        ("item.create", CommandIDs.itemCreate),
        ("item.update", CommandIDs.itemUpdate),
        ("item.transform", CommandIDs.itemTransform),
        ("item.moveToPage", CommandIDs.itemMoveToPage),
        ("item.delete", CommandIDs.itemDelete),
        ("item.arrange", CommandIDs.itemArrange),
        ("item.recolor", CommandIDs.itemRecolor),
        ("item.setLocked", CommandIDs.itemSetLocked),
        ("item.duplicate", CommandIDs.itemDuplicate),

        ("laser.setMode", CommandIDs.laserSetMode),
        ("laser.point", CommandIDs.laserPoint),

        ("layer.setActive", CommandIDs.layerSetActive),
        ("layer.setVisible", CommandIDs.layerSetVisible),
        ("layer.rename", CommandIDs.layerRename),
        ("layer.moveItems", CommandIDs.layerMoveItems),
        ("layer.exportOptions", CommandIDs.layerExportOptions),

        ("lesson.create", CommandIDs.lessonCreate),
        ("lesson.setState", CommandIDs.lessonSetState),
        ("lesson.importRoster", CommandIDs.lessonImportRoster),
        ("lesson.collect", CommandIDs.lessonCollect),
        ("lesson.cluster", CommandIDs.lessonCluster),
        ("lesson.setClusters", CommandIDs.lessonSetClusters),

        ("library.list", CommandIDs.libraryList),
        ("library.rename", CommandIDs.libraryRename),
        ("library.move", CommandIDs.libraryMove),
        ("library.duplicate", CommandIDs.libraryDuplicate),
        ("library.trash", CommandIDs.libraryTrash),
        ("library.setView", CommandIDs.librarySetView),
        ("library.reorder", CommandIDs.libraryReorder),
        ("library.chooseFolder", CommandIDs.libraryChooseFolder),
        ("library.relocate", CommandIDs.libraryRelocate),
        ("library.locations", CommandIDs.libraryLocations),
        ("library.switch", CommandIDs.librarySwitch),
        ("library.repair", CommandIDs.libraryRepair),

        ("link.set", CommandIDs.linkSet),
        ("link.remove", CommandIDs.linkRemove),
        ("link.follow", CommandIDs.linkFollow),
        ("link.back", CommandIDs.linkBack),
        ("link.autodetect", CommandIDs.linkAutodetect),
        ("link.tapAt", CommandIDs.linkTapAt),

        ("lock.setup", CommandIDs.lockSetup),

        ("math.recognize", CommandIDs.mathRecognize),
        ("math.convert", CommandIDs.mathConvert),
        ("math.setLatex", CommandIDs.mathSetLatex),
        ("math.copy", CommandIDs.mathCopy),
        ("math.evaluate", CommandIDs.mathEvaluate),
        ("math.assist", CommandIDs.mathAssist),
        ("math.graph.create", CommandIDs.mathGraphCreate),
        ("math.graph.setViewport", CommandIDs.mathGraphSetViewport),
        ("math.solve", CommandIDs.mathSolve),

        ("mathassist.tapAt", CommandIDs.mathassistTapAt),

        ("meeting.summarize", CommandIDs.meetingSummarize),
        ("meeting.generateNotes", CommandIDs.meetingGenerateNotes),

        ("menu.showAt", CommandIDs.menuShowAt),

        ("node.insert", CommandIDs.nodeInsert),
        ("node.set", CommandIDs.nodeSet),
        ("node.remove", CommandIDs.nodeRemove),
        ("node.move", CommandIDs.nodeMove),

        ("outline.add", CommandIDs.outlineAdd),
        ("outline.rename", CommandIDs.outlineRename),
        ("outline.move", CommandIDs.outlineMove),
        ("outline.delete", CommandIDs.outlineDelete),
        ("outline.sortByPage", CommandIDs.outlineSortByPage),
        ("outline.list", CommandIDs.outlineList),
        ("outline.generate", CommandIDs.outlineGenerate),

        ("page.setTemplate", CommandIDs.pageSetTemplate),
        ("page.setBackground", CommandIDs.pageSetBackground),
        ("page.clear", CommandIDs.pageClear),
        ("page.deleteItems", CommandIDs.pageDeleteItems),
        ("page.add", CommandIDs.pageAdd),
        ("page.duplicate", CommandIDs.pageDuplicate),
        ("page.copy", CommandIDs.pageCopy),
        ("page.paste", CommandIDs.pagePaste),
        ("page.moveTo", CommandIDs.pageMoveTo),
        ("page.reorder", CommandIDs.pageReorder),
        ("page.rotate", CommandIDs.pageRotate),
        ("page.trash", CommandIDs.pageTrash),
        ("page.restore", CommandIDs.pageRestore),
        ("page.purge", CommandIDs.pagePurge),
        ("page.setBookmarked", CommandIDs.pageSetBookmarked),

        ("panel.open", CommandIDs.panelOpen),
        ("panel.close", CommandIDs.panelClose),

        ("pdf.text", CommandIDs.pdfText),
        ("pdf.links", CommandIDs.pdfLinks),
        ("pdf.markSelection", CommandIDs.pdfMarkSelection),
        ("pdf.copyText", CommandIDs.pdfCopyText),
        ("pdf.tapAt", CommandIDs.pdfTapAt),

        ("pencil.gesture", CommandIDs.pencilGesture),
        ("pencil.palette", CommandIDs.pencilPalette),
        ("pencil.actions", CommandIDs.pencilActions),

        ("plugin.list", CommandIDs.pluginList),
        ("plugin.enable", CommandIDs.pluginEnable),
        ("plugin.reload", CommandIDs.pluginReload),
        ("plugin.logs", CommandIDs.pluginLogs),
        ("plugin.sdkTypes", CommandIDs.pluginSdkTypes),
        ("plugin.docs", CommandIDs.pluginDocs),
        ("plugin.install", CommandIDs.pluginInstall),
        ("plugin.uninstall", CommandIDs.pluginUninstall),
        ("plugin.review", CommandIDs.pluginReview),

        ("present.setMode", CommandIDs.presentSetMode),

        ("preset.select", CommandIDs.presetSelect),
        ("preset.setSwatch", CommandIDs.presetSetSwatch),
        ("preset.addSwatch", CommandIDs.presetAddSwatch),
        ("preset.removeSwatch", CommandIDs.presetRemoveSwatch),
        ("preset.moveSwatch", CommandIDs.presetMoveSwatch),
        ("preset.setWidth", CommandIDs.presetSetWidth),
        ("preset.reset", CommandIDs.presetReset),

        ("print.present", CommandIDs.printPresent),

        ("query.context", CommandIDs.queryContext),
        ("query.tree", CommandIDs.queryTree),
        ("query.get", CommandIDs.queryGet),
        ("query.find", CommandIDs.queryFind),

        ("recognize.pageText", CommandIDs.recognizePageText),
        ("recognize.items", CommandIDs.recognizeItems),

        ("relay.configure", CommandIDs.relayConfigure),

        ("render.page", CommandIDs.renderPage),

        ("replay.setMode", CommandIDs.replaySetMode),
        ("replay.seekToItem", CommandIDs.replaySeekToItem),
        ("replay.tapAt", CommandIDs.replayTapAt),

        ("ruler.set", CommandIDs.rulerSet),

        ("scan.documents", CommandIDs.scanDocuments),
        ("scan.qr", CommandIDs.scanQr),

        ("search.text", CommandIDs.searchText),
        ("search.open", CommandIDs.searchOpen),
        ("search.step", CommandIDs.searchStep),

        ("selection.set", CommandIDs.selectionSet),
        ("selection.clear", CommandIDs.selectionClear),
        ("selection.fromPolygon", CommandIDs.selectionFromPolygon),
        ("selection.fromRect", CommandIDs.selectionFromRect),
        ("selection.fromLoop", CommandIDs.selectionFromLoop),
        ("selection.selectAll", CommandIDs.selectionSelectAll),
        ("selection.tapAt", CommandIDs.selectionTapAt),
        ("selection.screenshot", CommandIDs.selectionScreenshot),

        ("settings.open", CommandIDs.settingsOpen),

        ("shape.recognize", CommandIDs.shapeRecognize),
        ("shape.create", CommandIDs.shapeCreate),
        ("shape.setStyle", CommandIDs.shapeSetStyle),
        ("shape.setKind", CommandIDs.shapeSetKind),
        ("shape.setPoints", CommandIDs.shapeSetPoints),
        ("shape.tapAt", CommandIDs.shapeTapAt),

        ("sidebar.toggle", CommandIDs.sidebarToggle),

        ("spellcheck.tapAt", CommandIDs.spellcheckTapAt),

        ("sticky.create", CommandIDs.stickyCreate),
        ("sticky.setCollapsed", CommandIDs.stickySetCollapsed),
        ("sticky.resolve", CommandIDs.stickyResolve),
        ("sticky.setColor", CommandIDs.stickySetColor),
        ("sticky.tapAt", CommandIDs.stickyTapAt),

        ("stopwatch.start", CommandIDs.stopwatchStart),
        ("stopwatch.lap", CommandIDs.stopwatchLap),

        ("study.grade", CommandIDs.studyGrade),
        ("study.resetProgress", CommandIDs.studyResetProgress),
        ("study.setReminders", CommandIDs.studySetReminders),
        ("study.setTheme", CommandIDs.studySetTheme),
        ("study.importText", CommandIDs.studyImportText),
        ("study.exportCSV", CommandIDs.studyExportCSV),

        ("sync.now", CommandIDs.syncNow),

        ("tab.close", CommandIDs.tabClose),
        ("tab.closeOthers", CommandIDs.tabCloseOthers),
        ("tab.select", CommandIDs.tabSelect),

        ("table.edit", CommandIDs.tableEdit),
        ("table.exportCSV", CommandIDs.tableExportCSV),

        ("tape.tapAt", CommandIDs.tapeTapAt),
        ("tape.setRevealed", CommandIDs.tapeSetRevealed),
        ("tape.removeAll", CommandIDs.tapeRemoveAll),
        ("tape.importPattern", CommandIDs.tapeImportPattern),
        ("tape.patterns", CommandIDs.tapePatterns),
        ("tape.deletePattern", CommandIDs.tapeDeletePattern),
        ("tape.clearHistory", CommandIDs.tapeClearHistory),

        ("template.list", CommandIDs.templateList),
        ("template.choose", CommandIDs.templateChoose),
        ("template.import", CommandIDs.templateImport),
        ("template.listCustom", CommandIDs.templateListCustom),
        ("template.group.create", CommandIDs.templateGroupCreate),
        ("template.group.rename", CommandIDs.templateGroupRename),
        ("template.group.delete", CommandIDs.templateGroupDelete),
        ("template.delete", CommandIDs.templateDelete),
        ("template.setHidden", CommandIDs.templateSetHidden),
        ("template.fromPage", CommandIDs.templateFromPage),

        ("text.createBox", CommandIDs.textCreateBox),
        ("text.setText", CommandIDs.textSetText),
        ("text.format", CommandIDs.textFormat),
        ("text.setParagraph", CommandIDs.textSetParagraph),
        ("text.setBoxStyle", CommandIDs.textSetBoxStyle),
        ("text.saveDefaultStyle", CommandIDs.textSaveDefaultStyle),
        ("text.tapAt", CommandIDs.textTapAt),
        ("text.startPageText", CommandIDs.textStartPageText),

        ("timer.start", CommandIDs.timerStart),
        ("timer.control", CommandIDs.timerControl),
        ("timer.history", CommandIDs.timerHistory),
        ("timer.saveMode", CommandIDs.timerSaveMode),
        ("timer.deleteMode", CommandIDs.timerDeleteMode),

        ("toolbar.setLayout", CommandIDs.toolbarSetLayout),
        ("toolbar.reset", CommandIDs.toolbarReset),
        ("toolbar.setVisible", CommandIDs.toolbarSetVisible),
        ("toolbar.layouts", CommandIDs.toolbarLayouts),
        ("toolbar.saveLayout", CommandIDs.toolbarSaveLayout),
        ("toolbar.applyLayout", CommandIDs.toolbarApplyLayout),
        ("toolbar.deleteLayout", CommandIDs.toolbarDeleteLayout),
        ("toolbar.dock", CommandIDs.toolbarDock),

        ("transcript.get", CommandIDs.transcriptGet),
        ("transcript.regenerate", CommandIDs.transcriptRegenerate),
        ("transcript.editSegment", CommandIDs.transcriptEditSegment),
        ("transcript.insert", CommandIDs.transcriptInsert),

        ("trash.list", CommandIDs.trashList),
        ("trash.recover", CommandIDs.trashRecover),
        ("trash.deletePermanently", CommandIDs.trashDeletePermanently),
        ("trash.empty", CommandIDs.trashEmpty),

        ("view.goToPage", CommandIDs.viewGoToPage),
        ("view.zoom", CommandIDs.viewZoom),
        ("view.scrollBy", CommandIDs.viewScrollBy),
        ("view.reveal", CommandIDs.viewReveal),
        ("view.setReadOnly", CommandIDs.viewSetReadOnly),

        ("webdav.syncNow", CommandIDs.webdavSyncNow),
        ("webdav.configure", CommandIDs.webdavConfigure),
        ("webdav.put", CommandIDs.webdavPut),
        ("webdav.status", CommandIDs.webdavStatus),

        ("window.open", CommandIDs.windowOpen),

        ("zoom.toggle", CommandIDs.zoomToggle),
        ("zoom.setBox", CommandIDs.zoomSetBox),
        ("zoom.newLine", CommandIDs.zoomNewLine),
        ("zoom.setReturnHeight", CommandIDs.zoomSetReturnHeight),
    ]

    /// Every `PanelIDs` constant with the id it holds (`studyLearn` is the superseded alias of `studySmartLearn`).
    static let panelIDs: [(String, String)] = [
        ("aichat.panel", PanelIDs.assistant),
        ("organize.trash", PanelIDs.trash),
        ("organize.favourites", PanelIDs.favourites),
        ("templateui.manage", PanelIDs.templates),
        ("syncui.panel", PanelIDs.cloudBackup),
        ("about.panel", PanelIDs.about),
        ("pluginmanager.gallery", PanelIDs.gallery),
        ("studysession.practice", PanelIDs.studyPractice),
        ("studysession.smartLearn", PanelIDs.studySmartLearn),
        ("studysession.smartLearn", PanelIDs.studyLearn),
        ("pages.movePages", PanelIDs.movePages),
    ]

    func testEveryCommandConstantHoldsItsID() {
        for (id, constant) in Self.commandIDs {
            XCTAssertEqual(constant, id)
        }
        XCTAssertEqual(Set(Self.commandIDs.map { $0.0 }).count, Self.commandIDs.count, "an id is listed twice")
    }

    func testEveryCatalogueIDHasACommandConstant() throws {
        let catalogue = try Self.catalogueIDs()
        XCTAssertGreaterThan(catalogue.count, 300, "the §6.5 parser found too few rows")
        let constants = Set(Self.commandIDs.map { $0.0 })
        let missing = catalogue.filter { !constants.contains($0) }
        XCTAssertEqual(missing, [], "§6.5 ids without a CommandIDs constant (add each to CommandIDs.swift and here)")
        let listed = Set(catalogue)
        let stale = Self.commandIDs.map { $0.0 }.filter { !listed.contains($0) }
        XCTAssertEqual(stale, [], "CommandIDs constants whose id is not in the §6.5 catalogue")
    }

    func testPanelIDsMatchTheArchitecturePanelList() throws {
        for (id, constant) in Self.panelIDs {
            XCTAssertEqual(constant, id)
        }
        let listed = try Self.architecturePanelIDs()
        XCTAssertEqual(listed, Set(Self.panelIDs.map { $0.0 }), "PanelIDs differs from the ARCHITECTURE.md §13 list")
    }

    // MARK: docs/ARCHITECTURE.md

    private static func architecture() throws -> [Substring] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NibContractsTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // NibKit
            .deletingLastPathComponent() // repository root
        let text = try String(contentsOf: root.appendingPathComponent("docs/ARCHITECTURE.md"), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// The first-column id of every table row in §6.5, in document order.
    private static func catalogueIDs() throws -> [String] {
        let lines = try architecture()
        guard let start = lines.firstIndex(where: { $0.hasPrefix("### 6.5 ") }) else {
            XCTFail("ARCHITECTURE.md has no §6.5 heading")
            return []
        }
        let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
        return lines[start..<end].compactMap { line -> String? in
            guard line.hasPrefix("| `") else { return nil }
            let cell = line.dropFirst(3)
            guard let close = cell.firstIndex(of: "`") else { return nil }
            return String(cell[..<close])
        }
    }

    /// The backticked dotted ids after "Well-known panel ids are in `PanelIDs`" in §13.
    private static func architecturePanelIDs() throws -> Set<String> {
        let marker = "Well-known panel ids are in `PanelIDs`"
        guard let line = try architecture().first(where: { $0.contains(marker) }),
              let range = line.range(of: marker) else {
            XCTFail("ARCHITECTURE.md no longer says: \(marker)")
            return []
        }
        let spans = line[range.upperBound...].split(separator: "`", omittingEmptySubsequences: false)
        var ids = Set<String>()
        for (index, span) in spans.enumerated() where index % 2 == 1 {
            let parts = span.split(separator: ".", omittingEmptySubsequences: false)
            let isID = parts.count == 2 && parts.allSatisfy { part in
                !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            }
            if isID, let first = span.first, first.isLowercase { ids.insert(String(span)) }
        }
        return ids
    }
}
```

## Part B — Package manifest and generated lists

These files are generated from `forge-spec.json` by the architect's generator (module order = registration order). The scaffold writes them verbatim. To add or remove a module, update the spec and regenerate; never hand-edit these files.

### `NibKit/Package.swift`

```swift
// swift-tools-version:5.10
// GENERATED from docs/forge-spec.json (module list). Edit the spec, not this file, when adding a module.
import PackageDescription

let zip: Target.Dependency = .product(name: "ZIPFoundation", package: "ZIPFoundation")
let swiftMath: Target.Dependency = .product(name: "SwiftMath", package: "SwiftMath")
// Reserved design system (tokens, droplet/"liquid" components, Metal shaders), filled by a later design stage.
// Every ui/fullstack feature module depends on it; core modules do not (ARCHITECTURE.md §3).
let design: Target.Dependency = "NibDesign"

struct Module {
    let name: String
    var deps: [Target.Dependency] = []
    var resources: [Resource] = []
    var testResources: [Resource] = []
}

let modules: [Module] = [
    Module(name: "NibStore"),
    Module(name: "NibLibrary"),
    Module(name: "FeatQuery"),
    Module(name: "NibRender"),
    Module(name: "NibTemplates"),
    Module(name: "FeatCanvas", deps: [design]),
    Module(name: "FeatPen", deps: [design]),
    Module(name: "FeatPresets", deps: [design]),
    Module(name: "FeatHighlighter", deps: [design]),
    Module(name: "FeatEraser", deps: [design]),
    Module(name: "FeatLasso", deps: [design]),
    Module(name: "FeatTransform", deps: [design]),
    Module(name: "FeatObjectMenu", deps: [design]),
    Module(name: "FeatClipboard", deps: [design]),
    Module(name: "FeatUndoUI", deps: [design]),
    Module(name: "FeatToolbar", deps: [design]),
    Module(name: "FeatDocChrome", deps: [design]),
    Module(name: "FeatWindows", deps: [design]),
    Module(name: "FeatLibraryUI", deps: [design]),
    Module(name: "FeatLibraryOrganize", deps: [design]),
    Module(name: "FeatCreate", deps: [design]),
    Module(name: "FeatPages", deps: [design]),
    Module(name: "FeatSidebar", deps: [design]),
    Module(name: "NibPDF"),
    Module(name: "NibSync"),
    Module(name: "FeatTextBox", deps: [design]),
    Module(name: "FeatSettings", deps: [design]),
    Module(name: "FeatPageText", deps: [design]),
    Module(name: "FeatLinks", deps: [design]),
    Module(name: "FeatShapeRecognition", deps: [design]),
    Module(name: "FeatShapes", deps: [design]),
    Module(name: "FeatDiagrams", deps: [design]),
    Module(name: "FeatTape", deps: [design]),
    Module(name: "FeatImages", deps: [design]),
    Module(name: "FeatElements", deps: [design, zip]),
    Module(name: "FeatSticky", deps: [design]),
    Module(name: "FeatComments", deps: [design]),
    Module(name: "FeatZoomWindow", deps: [design]),
    Module(name: "FeatRuler", deps: [design]),
    Module(name: "FeatLaser", deps: [design]),
    Module(name: "FeatLayers", deps: [design]),
    Module(name: "FeatReadOnly", deps: [design]),
    Module(name: "FeatPencilHardware", deps: [design]),
    Module(name: "FeatWhiteboard", deps: [design]),
    Module(name: "FeatTemplateUI", deps: [design]),
    Module(name: "FeatOutline", deps: [design]),
    Module(name: "FeatTextDoc", deps: [design]),
    Module(name: "FeatTextDocTables", deps: [design]),
    Module(name: "FeatStudyEditor", deps: [design]),
    Module(name: "FeatStudySession", deps: [design]),
    Module(name: "FeatStudyIO"),
    Module(name: "FeatAudio", deps: [design]),
    Module(name: "FeatReplay", deps: [design]),
    Module(name: "FeatTranscription", deps: [design]),
    Module(name: "NibIndex"),
    Module(name: "FeatSearchUI", deps: [design]),
    Module(name: "FeatConvertText", deps: [design]),
    Module(name: "FeatSmartInk", deps: [design]),
    Module(name: "FeatInkSynth", deps: [design]),
    Module(name: "FeatMath", deps: [design, swiftMath]),
    Module(name: "FeatMathAssist", deps: [design]),
    Module(name: "FeatTimeKeeper", deps: [design]),
    Module(name: "FeatPresentation", deps: [design]),
    Module(name: "FeatImport", deps: [design, zip]),
    Module(name: "FeatScan", deps: [design]),
    Module(name: "NibExport", deps: [zip]),
    Module(name: "FeatExportUI", deps: [design]),
    Module(name: "FeatBackup", deps: [design, zip]),
    Module(name: "FeatWebDAV"),
    Module(name: "FeatSyncUI", deps: [design]),
    Module(name: "FeatLock", deps: [design]),
    Module(name: "FeatCollab", deps: [design, zip]),
    Module(name: "FeatKeyboard", deps: [design]),
    Module(name: "FeatSystemIntegration", deps: [design]),
    Module(name: "FeatCalendar", deps: [design]),
    Module(name: "FeatDiagnostics", deps: [design]),
    Module(name: "NibPluginRuntime", resources: [.copy("Resources/prelude.js")]),
    Module(name: "NibPluginHost"),
    Module(name: "FeatPluginInstall", deps: [design, zip]),
    Module(name: "FeatPluginManager", deps: [design]),
    Module(name: "FeatPluginPanels", deps: [design]),
    Module(name: "NibAIProviders", testResources: [.copy("Fixtures")]),
    Module(name: "NibAIAgent"),
    Module(name: "FeatAIChat", deps: [design]),
    Module(name: "FeatAISettings", deps: [design]),
    Module(name: "FeatAIActions"),
    Module(name: "FeatAIMath", deps: [design]),
    Module(name: "FeatMeetingAI", deps: [design]),
    Module(name: "NibBridge"),
    Module(name: "FeatBridgeUI", deps: [design]),
    Module(name: "FeatRelay"),
    Module(name: "FeatOnboarding", deps: [design]),
    Module(name: "FeatAppearance", deps: [design]),
    Module(name: "FeatA11y", deps: [design]),
    Module(name: "FeatManagedConfig"),
    Module(name: "FeatAbout", deps: [design]),
    Module(name: "FeatTeacher", deps: [design]),
    Module(name: "FeatPerformance"),
]

var targets: [Target] = [
    .target(name: "NibContracts"),
    // The design system (docs/DESIGN_SYSTEM.md): Shaders/NibLiquid.metal compiles into default.metallib in its bundle
    // (ShaderLibrary.bundle(.module)); Localizable.xcstrings holds its strings (String(localized:bundle: .module)).
    .target(name: "NibDesign", dependencies: ["NibContracts"],
            resources: [.process("Shaders"), .process("Localizable.xcstrings")]),
    .target(name: "NibTesting", dependencies: ["NibContracts"]),
    .testTarget(name: "NibContractsTests", dependencies: ["NibContracts", "NibTesting"]),
    .testTarget(name: "NibDesignTests", dependencies: ["NibDesign"]),
    .testTarget(name: "ConformanceTests",
                dependencies: ["NibContracts", "NibTesting"] + modules.map { Target.Dependency.target(name: $0.name) }),
    // Example plugins call doc.create, card.add, ink.writeText, panels and nib.ai, so they run against every module
    // (with NibTesting's FakeAIService); cross-feature acceptance scenarios live in IntegrationTests (F111).
    .testTarget(name: "ExamplePluginsTests",
                dependencies: ["NibContracts", "NibTesting"] + modules.map { Target.Dependency.target(name: $0.name) }),
    .testTarget(name: "IntegrationTests",
                dependencies: ["NibContracts", "NibTesting"] + modules.map { Target.Dependency.target(name: $0.name) }),
]

for m in modules {
    targets.append(.target(name: m.name, dependencies: ["NibContracts"] + m.deps,
                           resources: m.resources.isEmpty ? nil : m.resources))
    targets.append(.testTarget(name: m.name + "Tests",
                               dependencies: [.target(name: m.name), "NibContracts", "NibTesting"],
                               resources: m.testResources.isEmpty ? nil : m.testResources))
}

let package = Package(
    name: "NibKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17)],
    // Two products, so Xcode always generates the aggregate "NibKit-Package" scheme CI tests with.
    products: [.library(name: "NibKit", targets: ["NibContracts", "NibDesign"] + modules.map { $0.name }),
               .library(name: "NibTesting", targets: ["NibTesting"])],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.0.0"),
    ],
    targets: targets
)
```

### `Nib/App/FeatureList.swift`

```swift
// GENERATED from docs/forge-spec.json. Registration order = this order (services first; the second half of a
// split feature right after its first half).
import NibContracts
import NibStore
import NibLibrary
import FeatQuery
import NibRender
import NibTemplates
import FeatCanvas
import FeatPen
import FeatPresets
import FeatHighlighter
import FeatEraser
import FeatLasso
import FeatTransform
import FeatObjectMenu
import FeatClipboard
import FeatUndoUI
import FeatToolbar
import FeatDocChrome
import FeatWindows
import FeatLibraryUI
import FeatLibraryOrganize
import FeatCreate
import FeatPages
import FeatSidebar
import NibPDF
import NibSync
import FeatTextBox
import FeatSettings
import FeatPageText
import FeatLinks
import FeatShapeRecognition
import FeatShapes
import FeatDiagrams
import FeatTape
import FeatImages
import FeatElements
import FeatSticky
import FeatComments
import FeatZoomWindow
import FeatRuler
import FeatLaser
import FeatLayers
import FeatReadOnly
import FeatPencilHardware
import FeatWhiteboard
import FeatTemplateUI
import FeatOutline
import FeatTextDoc
import FeatTextDocTables
import FeatStudyEditor
import FeatStudySession
import FeatStudyIO
import FeatAudio
import FeatReplay
import FeatTranscription
import NibIndex
import FeatSearchUI
import FeatConvertText
import FeatSmartInk
import FeatInkSynth
import FeatMath
import FeatMathAssist
import FeatTimeKeeper
import FeatPresentation
import FeatImport
import FeatScan
import NibExport
import FeatExportUI
import FeatBackup
import FeatWebDAV
import FeatSyncUI
import FeatLock
import FeatCollab
import FeatKeyboard
import FeatSystemIntegration
import FeatCalendar
import FeatDiagnostics
import NibPluginRuntime
import NibPluginHost
import FeatPluginInstall
import FeatPluginManager
import FeatPluginPanels
import NibAIProviders
import NibAIAgent
import FeatAIChat
import FeatAISettings
import FeatAIActions
import FeatAIMath
import FeatMeetingAI
import NibBridge
import FeatBridgeUI
import FeatRelay
import FeatOnboarding
import FeatAppearance
import FeatA11y
import FeatManagedConfig
import FeatAbout
import FeatTeacher
import FeatPerformance

enum FeatureList {
    static let all: [NibFeature.Type] = [
        NibStoreFeature.self,
        NibLibraryFeature.self,
        FeatQueryFeature.self,
        NibRenderFeature.self,
        NibTemplatesFeature.self,
        FeatCanvasFeature.self,
        FeatCanvasInputFeature.self,
        FeatPenFeature.self,
        FeatPresetsFeature.self,
        FeatHighlighterFeature.self,
        FeatEraserFeature.self,
        FeatLassoFeature.self,
        FeatTransformFeature.self,
        FeatObjectMenuFeature.self,
        FeatClipboardFeature.self,
        FeatUndoUIFeature.self,
        FeatToolbarFeature.self,
        FeatDocChromeFeature.self,
        FeatWindowsFeature.self,
        FeatLibraryUIFeature.self,
        FeatLibraryOrganizeFeature.self,
        FeatCreateFeature.self,
        FeatPagesFeature.self,
        FeatSidebarFeature.self,
        NibPDFFeature.self,
        NibSyncFeature.self,
        FeatTextBoxFeature.self,
        FeatSettingsFeature.self,
        FeatPageTextFeature.self,
        FeatLinksFeature.self,
        FeatShapeRecognitionFeature.self,
        FeatShapesFeature.self,
        FeatDiagramsFeature.self,
        FeatTapeFeature.self,
        FeatImagesFeature.self,
        FeatElementsFeature.self,
        FeatStickyFeature.self,
        FeatCommentsFeature.self,
        FeatZoomWindowFeature.self,
        FeatRulerFeature.self,
        FeatLaserFeature.self,
        FeatLayersFeature.self,
        FeatReadOnlyFeature.self,
        FeatPencilHardwareFeature.self,
        FeatWhiteboardFeature.self,
        FeatTemplateUIFeature.self,
        FeatOutlineFeature.self,
        FeatTextDocFeature.self,
        FeatTextDocEditingFeature.self,
        FeatTextDocExtrasFeature.self,
        FeatTextDocTablesFeature.self,
        FeatStudyEditorFeature.self,
        FeatStudySessionFeature.self,
        FeatStudyIOFeature.self,
        FeatAudioFeature.self,
        FeatReplayFeature.self,
        FeatTranscriptionFeature.self,
        NibIndexFeature.self,
        FeatSearchUIFeature.self,
        FeatConvertTextFeature.self,
        FeatSmartInkFeature.self,
        FeatInkSynthFeature.self,
        FeatSpellcheckFeature.self,
        FeatRestyleFeature.self,
        FeatMathFeature.self,
        FeatMathAssistFeature.self,
        FeatMathAssistOverlayFeature.self,
        FeatMathGraphFeature.self,
        FeatTimeKeeperFeature.self,
        FeatPresentationFeature.self,
        FeatImportFeature.self,
        FeatScanFeature.self,
        NibExportFeature.self,
        FeatExportUIFeature.self,
        FeatBackupFeature.self,
        FeatWebDAVFeature.self,
        FeatSyncUIFeature.self,
        FeatLockFeature.self,
        FeatCollabFeature.self,
        FeatCollabPresenceFeature.self,
        FeatKeyboardFeature.self,
        FeatSystemIntegrationFeature.self,
        FeatCalendarFeature.self,
        FeatDiagnosticsFeature.self,
        NibPluginRuntimeFeature.self,
        NibPluginHostFeature.self,
        FeatPluginInstallFeature.self,
        FeatPluginManagerFeature.self,
        FeatPluginPanelsFeature.self,
        NibAIProvidersFeature.self,
        NibAIAgentFeature.self,
        FeatAIChatFeature.self,
        FeatAISettingsFeature.self,
        FeatAIActionsFeature.self,
        FeatAIMathFeature.self,
        FeatMeetingAIFeature.self,
        NibBridgeFeature.self,
        FeatBridgeUIFeature.self,
        FeatRelayFeature.self,
        FeatOnboardingFeature.self,
        FeatAppearanceFeature.self,
        FeatA11yFeature.self,
        FeatManagedConfigFeature.self,
        FeatAboutFeature.self,
        FeatTeacherFeature.self,
        FeatTeacherLessonsFeature.self,
        FeatTeacherInsightsFeature.self,
        FeatPerformanceFeature.self
    ]
}
```

### `NibKit/Tests/ConformanceTests/AllFeatures.swift`

```swift
// GENERATED from docs/forge-spec.json.
import NibContracts
import NibStore
import NibLibrary
import FeatQuery
import NibRender
import NibTemplates
import FeatCanvas
import FeatPen
import FeatPresets
import FeatHighlighter
import FeatEraser
import FeatLasso
import FeatTransform
import FeatObjectMenu
import FeatClipboard
import FeatUndoUI
import FeatToolbar
import FeatDocChrome
import FeatWindows
import FeatLibraryUI
import FeatLibraryOrganize
import FeatCreate
import FeatPages
import FeatSidebar
import NibPDF
import NibSync
import FeatTextBox
import FeatSettings
import FeatPageText
import FeatLinks
import FeatShapeRecognition
import FeatShapes
import FeatDiagrams
import FeatTape
import FeatImages
import FeatElements
import FeatSticky
import FeatComments
import FeatZoomWindow
import FeatRuler
import FeatLaser
import FeatLayers
import FeatReadOnly
import FeatPencilHardware
import FeatWhiteboard
import FeatTemplateUI
import FeatOutline
import FeatTextDoc
import FeatTextDocTables
import FeatStudyEditor
import FeatStudySession
import FeatStudyIO
import FeatAudio
import FeatReplay
import FeatTranscription
import NibIndex
import FeatSearchUI
import FeatConvertText
import FeatSmartInk
import FeatInkSynth
import FeatMath
import FeatMathAssist
import FeatTimeKeeper
import FeatPresentation
import FeatImport
import FeatScan
import NibExport
import FeatExportUI
import FeatBackup
import FeatWebDAV
import FeatSyncUI
import FeatLock
import FeatCollab
import FeatKeyboard
import FeatSystemIntegration
import FeatCalendar
import FeatDiagnostics
import NibPluginRuntime
import NibPluginHost
import FeatPluginInstall
import FeatPluginManager
import FeatPluginPanels
import NibAIProviders
import NibAIAgent
import FeatAIChat
import FeatAISettings
import FeatAIActions
import FeatAIMath
import FeatMeetingAI
import NibBridge
import FeatBridgeUI
import FeatRelay
import FeatOnboarding
import FeatAppearance
import FeatA11y
import FeatManagedConfig
import FeatAbout
import FeatTeacher
import FeatPerformance

enum AllFeatures {
    static let list: [NibFeature.Type] = [
        NibStoreFeature.self,
        NibLibraryFeature.self,
        FeatQueryFeature.self,
        NibRenderFeature.self,
        NibTemplatesFeature.self,
        FeatCanvasFeature.self,
        FeatCanvasInputFeature.self,
        FeatPenFeature.self,
        FeatPresetsFeature.self,
        FeatHighlighterFeature.self,
        FeatEraserFeature.self,
        FeatLassoFeature.self,
        FeatTransformFeature.self,
        FeatObjectMenuFeature.self,
        FeatClipboardFeature.self,
        FeatUndoUIFeature.self,
        FeatToolbarFeature.self,
        FeatDocChromeFeature.self,
        FeatWindowsFeature.self,
        FeatLibraryUIFeature.self,
        FeatLibraryOrganizeFeature.self,
        FeatCreateFeature.self,
        FeatPagesFeature.self,
        FeatSidebarFeature.self,
        NibPDFFeature.self,
        NibSyncFeature.self,
        FeatTextBoxFeature.self,
        FeatSettingsFeature.self,
        FeatPageTextFeature.self,
        FeatLinksFeature.self,
        FeatShapeRecognitionFeature.self,
        FeatShapesFeature.self,
        FeatDiagramsFeature.self,
        FeatTapeFeature.self,
        FeatImagesFeature.self,
        FeatElementsFeature.self,
        FeatStickyFeature.self,
        FeatCommentsFeature.self,
        FeatZoomWindowFeature.self,
        FeatRulerFeature.self,
        FeatLaserFeature.self,
        FeatLayersFeature.self,
        FeatReadOnlyFeature.self,
        FeatPencilHardwareFeature.self,
        FeatWhiteboardFeature.self,
        FeatTemplateUIFeature.self,
        FeatOutlineFeature.self,
        FeatTextDocFeature.self,
        FeatTextDocEditingFeature.self,
        FeatTextDocExtrasFeature.self,
        FeatTextDocTablesFeature.self,
        FeatStudyEditorFeature.self,
        FeatStudySessionFeature.self,
        FeatStudyIOFeature.self,
        FeatAudioFeature.self,
        FeatReplayFeature.self,
        FeatTranscriptionFeature.self,
        NibIndexFeature.self,
        FeatSearchUIFeature.self,
        FeatConvertTextFeature.self,
        FeatSmartInkFeature.self,
        FeatInkSynthFeature.self,
        FeatSpellcheckFeature.self,
        FeatRestyleFeature.self,
        FeatMathFeature.self,
        FeatMathAssistFeature.self,
        FeatMathAssistOverlayFeature.self,
        FeatMathGraphFeature.self,
        FeatTimeKeeperFeature.self,
        FeatPresentationFeature.self,
        FeatImportFeature.self,
        FeatScanFeature.self,
        NibExportFeature.self,
        FeatExportUIFeature.self,
        FeatBackupFeature.self,
        FeatWebDAVFeature.self,
        FeatSyncUIFeature.self,
        FeatLockFeature.self,
        FeatCollabFeature.self,
        FeatCollabPresenceFeature.self,
        FeatKeyboardFeature.self,
        FeatSystemIntegrationFeature.self,
        FeatCalendarFeature.self,
        FeatDiagnosticsFeature.self,
        NibPluginRuntimeFeature.self,
        NibPluginHostFeature.self,
        FeatPluginInstallFeature.self,
        FeatPluginManagerFeature.self,
        FeatPluginPanelsFeature.self,
        NibAIProvidersFeature.self,
        NibAIAgentFeature.self,
        FeatAIChatFeature.self,
        FeatAISettingsFeature.self,
        FeatAIActionsFeature.self,
        FeatAIMathFeature.self,
        FeatMeetingAIFeature.self,
        NibBridgeFeature.self,
        FeatBridgeUIFeature.self,
        FeatRelayFeature.self,
        FeatOnboardingFeature.self,
        FeatAppearanceFeature.self,
        FeatA11yFeature.self,
        FeatManagedConfigFeature.self,
        FeatAboutFeature.self,
        FeatTeacherFeature.self,
        FeatTeacherLessonsFeature.self,
        FeatTeacherInsightsFeature.self,
        FeatPerformanceFeature.self
    ]
}
```

### `NibKit/Tests/ConformanceTests/ConformanceTests.swift`

```swift
import XCTest
import NibContracts
import NibTesting

/// Runs against EVERY feature module (AllFeatures.swift is generated from docs/forge-spec.json).
@MainActor
final class ConformanceTests: XCTestCase {
    func testEveryCommandConforms() async {
        let problems = await CommandConformance.check(features: AllFeatures.list)
        XCTAssertTrue(problems.isEmpty, "\n" + problems.joined(separator: "\n"))
    }

    func testFeatureIDsAreUnique() {
        let h = Harness(features: AllFeatures.list)
        XCTAssertEqual(Set(h.app.featureIDs).count, h.app.featureIDs.count)
    }
}
```
## Part C — App shell (app target)

The shell is intentionally thin. It creates `NibApp`, registers the features, hosts one `ShellViewController` per window scene, turns `KeyCommandDescriptor`s into `UIKeyCommand`s, routes URLs and quick actions to commands, awaits `ui.openGate`, and shows fallback screens when a provider feature is missing.

### `Nib/App/AppDelegate.swift`

```swift
import UIKit
import BackgroundTasks
import NibContracts
import NibDesign

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// Minimal confirmation UI, so plugins and the bridge work without the AI chat feature (F085 wraps it).
    static let confirmer = ShellConfirmationPresenter()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        SafeMode.beginLaunch()
        let app = NibApp()
        app.gateway.presenter = AppDelegate.confirmer
        let disabled = SafeMode.disabledFeatures
        let features = FeatureList.all.filter { !disabled.contains($0.id) }
        app.register(features)
        DesignGallery.registerSettingsPage(in: app)   // Settings › Advanced › Developer (NibDesign is not a feature)
        registerBackgroundTasks(app)   // must run before this method returns
        Task { @MainActor in
            await app.start(features)
            SafeMode.endLaunch()
        }
        return true
    }

    /// Registers every identifier in Info.plist `BGTaskSchedulerPermittedIdentifiers` exactly once, synchronously
    /// (registering after launch throws NSInternalInconsistencyException), and routes each launch to the
    /// `BackgroundTaskDescriptor` with that id; a task without a descriptor (feature disabled) completes at once.
    private func registerBackgroundTasks(_ app: NibApp) {
        let ids = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        for id in ids {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { [weak app] task in
                Task { @MainActor in
                    guard let app = app, let descriptor = app.content.backgroundTasks.get(id) else {
                        task.setTaskCompleted(success: true)
                        return
                    }
                    let work = Task { @MainActor in await descriptor.handler(task) }
                    task.expirationHandler = { work.cancel() }
                    task.setTaskCompleted(success: await work.value)
                }
            }
        }
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let role = connectingSceneSession.role
        let config = UISceneConfiguration(name: nil, sessionRole: role)
        if role == .windowExternalDisplayNonInteractive {
            if NibApp.shared?.ui.externalDisplay != nil { config.delegateClass = ExternalDisplaySceneDelegate.self }
        } else {
            config.delegateClass = SceneDelegate.self
        }
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var shell: ShellViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene, let app = NibApp.shared else { return }
        let shell = ShellViewController(app: app)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = shell
        window.makeKeyAndVisible()
        self.window = window
        self.shell = shell
        app.ui.sceneHooks?.sceneDidConnect(windowScene, options: connectionOptions, navigator: shell)
        for context in connectionOptions.urlContexts { shell.handle(url: context.url) }
        if let item = connectionOptions.shortcutItem {
            app.perform(CommandIDs.appQuickAction, ["type": .string(item.type)], session: shell.session)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        NibApp.shared?.perform(CommandIDs.appQuickAction, ["type": .string(shortcutItem.type)], session: shell?.session)
        completionHandler(true)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts { shell?.handle(url: context.url) }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let shell = shell, let app = NibApp.shared else { return }
        app.ui.activeNavigator = shell
        app.services.sessions.activate(shell.session)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard let shell = shell else { return }
        NibApp.shared?.services.sessions.remove(shell.session)
    }

    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        guard let shell = shell else { return nil }
        return NibApp.shared?.ui.sceneHooks?.restorationActivity(shell)
    }
}

/// Alert-based confirmation for non-user principals (plugins, bridge, AI): who asks, which command, the params.
@MainActor
final class ShellConfirmationPresenter: ConfirmationPresenter {
    func confirm(_ request: ConfirmationRequest) async -> ConfirmationDecision {
        guard let root = NibApp.shared?.ui.activeNavigator?.rootViewController else { return .deny }
        let details = String(request.params.jsonString(pretty: true).prefix(600))
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: request.command.title,
                                          message: "\(request.principal) wants to run \(request.command.id).\n\n\(details)",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "Deny"), style: .cancel) { _ in
                continuation.resume(returning: .deny)
            })
            alert.addAction(UIAlertAction(title: String(localized: "Allow Rest of This Turn"), style: .default) { _ in
                continuation.resume(returning: .allowRestOfGroup)
            })
            alert.addAction(UIAlertAction(title: String(localized: "Allow"), style: .default) { _ in
                continuation.resume(returning: .allow)
            })
            var top = root
            while let presented = top.presentedViewController { top = presented }
            top.present(alert, animated: true)
        }
    }
}

/// External display (AirPlay / HDMI) scene; content comes from the Presentation feature.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene,
              let root = NibApp.shared?.ui.externalDisplay?(windowScene) else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = root
        window.isHidden = false
        self.window = window
    }
}
```

### `Nib/App/ShellViewController.swift`

```swift
import UIKit
import SwiftUI
import NibContracts

/// Root of every window. Owns the tab model and implements `SceneNavigator`; everything visible is provided by
/// features through `app.ui.screens` (library, document chrome, settings, onboarding) with minimal fallbacks.
@MainActor
final class ShellViewController: UIViewController, SceneNavigator {
    let app: NibApp
    let session: EditorSession
    private(set) var openDocuments: [DocumentID] = []
    private(set) var activeDocument: DocumentID?
    private var content: UIViewController?
    private var tabBar: UIView?
    private var failureObserver: NSObjectProtocol?

    init(app: NibApp) {
        self.app = app
        self.session = EditorSession()
        super.init(nibName: nil, bundle: nil)
        app.services.sessions.add(session)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var rootViewController: UIViewController? { self }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        failureObserver = NotificationCenter.default.addObserver(forName: .nibCommandFailed, object: nil, queue: .main) { [weak self] note in
            let message = (note.userInfo?["error"] as? NibError)?.message ?? "Something went wrong"
            Task { @MainActor in self?.toast(message) }
        }
        if let onboarding = app.ui.screens.onboarding?(app, self) {
            display(onboarding)
        } else {
            showLibrary(folder: nil)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top
        if let bar = tabBar {
            bar.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: 36)
            content?.view.frame = CGRect(x: 0, y: top + 36, width: view.bounds.width, height: max(0, view.bounds.height - top - 36))
        } else {
            content?.view.frame = view.bounds
        }
    }

    // MARK: SceneNavigator

    func showLibrary(folder: FolderID?) {
        session.document = nil
        display(app.ui.screens.libraryRoot?(app, self) ?? FallbackLibraryViewController(app: app, navigator: self))
    }

    func openDocument(_ doc: DocumentID, page: PageID?, mode: OpenMode) {
        if let gate = app.ui.openGate, mode != .newWindow {
            Task { @MainActor in
                if await gate(doc) { self.performOpen(doc, page: page, mode: mode) }
            }
        } else {
            performOpen(doc, page: page, mode: mode)
        }
    }

    private func performOpen(_ doc: DocumentID, page: PageID?, mode: OpenMode) {
        if mode == .newWindow {
            let activity = NSUserActivity(activityType: "app.nib.openDocument")
            activity.userInfo = ["doc": doc.raw, "page": page?.raw ?? ""]
            let request = UISceneSessionActivationRequest(role: .windowApplication, userActivity: activity, options: nil)
            UIApplication.shared.activateSceneSession(for: request, errorHandler: nil)
            return
        }
        guard let docContent = try? app.workspace.content(doc) else {
            toast("Could not open the document")
            return
        }
        let asTab = mode == .newTab || app.settings.get(NibSettings.openAsTabs)
        if !openDocuments.contains(doc) {
            if !asTab, let current = activeDocument, let i = openDocuments.firstIndex(of: current) {
                openDocuments[i] = doc
            } else {
                openDocuments.append(doc)
            }
        }
        activeDocument = doc
        session.document = doc
        session.selection = Selection()
        session.page = page ?? docContent.livePages.first?.id
        let kind = docContent.meta.kind
        let editor = app.ui.editors.get(kind.rawValue)?.make(doc, session, app)
            ?? FallbackEditorViewController(message: "No editor is installed for \(kind.rawValue) documents.")
        display(app.ui.screens.documentContainer?(editor, doc, app, self) ?? editor)
        if let p = page { session.editor?.reveal(page: p, rect: nil, animated: false) }
    }

    func closeDocument(_ doc: DocumentID) {
        openDocuments.removeAll { $0 == doc }
        guard activeDocument == doc else {
            refreshTabBar()
            return
        }
        activeDocument = nil
        if let next = openDocuments.last {
            openDocument(next, page: nil, mode: .replace)
        } else {
            showLibrary(folder: nil)
        }
    }

    func showSettings(page: String?) {
        let root = app.ui.screens.settingsRoot?(app, self) ?? FallbackSettingsViewController(app: app)
        presentModal(UINavigationController(rootViewController: root))
    }

    func presentModal(_ viewController: UIViewController) {
        var top: UIViewController = self
        while let presented = top.presentedViewController { top = presented }
        top.present(viewController, animated: true)
    }

    // MARK: Keyboard (every shortcut is a registered KeyCommandDescriptor that runs a command)

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let inDocument = activeDocument != nil
        return app.content.keyCommands.all.compactMap { d -> UIKeyCommand? in
            switch d.scope {
            case .global: break
            case .library: if inDocument { return nil }
            case .document: if !inDocument { return nil }
            case .canvas: if !inDocument || session.isEditingText { return nil }
            }
            let command = UIKeyCommand(title: d.title, action: #selector(runKeyCommand(_:)),
                                       input: ShellViewController.keyInput(d.shortcut.key),
                                       modifierFlags: ShellViewController.modifierFlags(d.shortcut.modifiers),
                                       propertyList: d.id)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func runKeyCommand(_ sender: UIKeyCommand) {
        guard let id = sender.propertyList as? String, let d = app.content.keyCommands.get(id) else { return }
        app.perform(d.command, d.params, session: session)
    }

    private static func keyInput(_ key: String) -> String {
        switch key {
        case "up": return UIKeyCommand.inputUpArrow
        case "down": return UIKeyCommand.inputDownArrow
        case "left": return UIKeyCommand.inputLeftArrow
        case "right": return UIKeyCommand.inputRightArrow
        case "escape": return UIKeyCommand.inputEscape
        case "delete": return UIKeyCommand.inputDelete
        case "tab": return "\t"
        case "return": return "\r"
        case "space": return " "
        default: return key
        }
    }

    private static func modifierFlags(_ m: KeyModifiers) -> UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if m.contains(.command) { flags.insert(.command) }
        if m.contains(.shift) { flags.insert(.shift) }
        if m.contains(.option) { flags.insert(.alternate) }
        if m.contains(.control) { flags.insert(.control) }
        return flags
    }

    // MARK: URLs

    /// File URLs (Open In / share sheet) go to `import.files`; nib:// URLs to `app.openURL`.
    func handle(url: URL) {
        if url.isFileURL {
            app.perform(CommandIDs.importFiles, ["urls": [.string(url.absoluteString)]], session: session)
        } else {
            app.perform(CommandIDs.appOpenURL, ["url": .string(url.absoluteString)], session: session)
        }
    }

    // MARK: Private

    private func display(_ vc: UIViewController) {
        if let old = content {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        addChild(vc)
        view.addSubview(vc.view)
        vc.didMove(toParent: self)
        content = vc
        refreshTabBar()
    }

    private func refreshTabBar() {
        tabBar?.removeFromSuperview()
        tabBar = nil
        if activeDocument != nil, let bar = app.ui.sceneHooks?.makeTabBar(self) {
            view.addSubview(bar)
            tabBar = bar
        }
        view.setNeedsLayout()
    }

    private func toast(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        let width = min(view.bounds.width - 32, 480)
        let size = label.sizeThatFits(CGSize(width: width - 24, height: .greatestFiniteMagnitude))
        label.frame = CGRect(x: (view.bounds.width - size.width - 24) / 2,
                             y: view.bounds.height - view.safeAreaInsets.bottom - size.height - 48,
                             width: size.width + 24, height: size.height + 16)
        view.addSubview(label)
        UIView.animate(withDuration: 0.3, delay: 2.5, options: []) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }
}

// MARK: - Fallback screens (used only when the providing feature is missing or disabled)

final class FallbackLibraryViewController: UITableViewController {
    private let app: NibApp
    private weak var navigator: SceneNavigator?
    private var nodes: [LibraryNode] = []

    init(app: NibApp, navigator: SceneNavigator) {
        self.app = app
        self.navigator = navigator
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        nodes = app.services.library?.allNodes().filter { $0.kind == .document } ?? []
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(nodes.count, 1) }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var config = cell.defaultContentConfiguration()
        config.text = nodes.isEmpty ? "No documents (library feature not installed)" : nodes[indexPath.row].title
        cell.contentConfiguration = config
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard indexPath.row < nodes.count else { return }
        navigator?.openDocument(nodes[indexPath.row].id, page: nil, mode: .replace)
    }
}

final class FallbackEditorViewController: UIViewController {
    private let message: String

    init(message: String) {
        self.message = message
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.frame = view.bounds.insetBy(dx: 32, dy: 32)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
    }
}

final class FallbackSettingsViewController: UITableViewController {
    private let app: NibApp
    private var pages: [SettingsPageDescriptor] { app.ui.settingsPages.all }

    init(app: NibApp) {
        self.app = app
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { pages.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var config = cell.defaultContentConfiguration()
        config.text = pages[indexPath.row].title
        config.image = UIImage(systemName: pages[indexPath.row].icon)
        cell.contentConfiguration = config
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let page = pages[indexPath.row]
        navigationController?.pushViewController(UIHostingController(rootView: page.makeView(app)), animated: true)
    }
}
```
## Part D — Project and CI

`project.yml` (XcodeGen), the GitHub Actions workflow (macos-26 with Xcode 26.6 pinned: a fast `feature` job on `feat/**` branches, the `test` ∥ `ipa` jobs everywhere else) and the three Python helpers. Unsigned build (ad-hoc signed in CI only to carry the optional App Group entitlement); see ARCHITECTURE.md §19 for sideloading.

### `project.yml`

```yaml
name: Nib
options:
  bundleIdPrefix: app.nib
  deploymentTarget:
    iOS: "17.0"
  createIntermediateGroups: true
  developmentLanguage: en
settings:
  base:
    SWIFT_VERSION: "5.0"
    SWIFT_STRICT_CONCURRENCY: minimal
    IPHONEOS_DEPLOYMENT_TARGET: "17.0"
    TARGETED_DEVICE_FAMILY: "1,2"
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
    CODE_SIGNING_ALLOWED: "NO"
    CODE_SIGNING_REQUIRED: "NO"
    CODE_SIGN_IDENTITY: ""
    DEVELOPMENT_TEAM: ""
    ENABLE_USER_SCRIPT_SANDBOXING: "NO"
packages:
  NibKit:
    path: NibKit
targets:
  Nib:
    type: application
    platform: iOS
    sources:
      - path: Nib
    dependencies:
      - package: NibKit
        product: NibKit
      - target: NibWidgets
      - target: NibShare
    entitlements:
      path: Nib/Nib.entitlements
      properties:
        com.apple.security.application-groups: [group.app.nib.Nib]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.nib.Nib
        PRODUCT_NAME: Nib
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
    info:
      path: Nib/Info.plist
      properties:
        CFBundleDisplayName: Nib
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        LSRequiresIPhoneOS: true
        UILaunchScreen: {}
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: true
        UIRequiresFullScreen: false
        # The droplet display link asks for 80-120 Hz (NibDesign DisplayLinkDriver); ProMotion iPhones need this.
        CADisableMinimumFrameDurationOnPhone: true
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        UISupportedInterfaceOrientations~ipad:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationPortraitUpsideDown
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        UIFileSharingEnabled: true
        LSSupportsOpeningDocumentsInPlace: true
        UIBackgroundModes: [audio, fetch, processing]
        # Registered by AppDelegate before launch returns; each id maps to a BackgroundTaskDescriptor
        # (backup F068 processing, index F055 processing, webdav F069 refresh, sync F025 refresh).
        BGTaskSchedulerPermittedIdentifiers: [app.nib.backup, app.nib.index, app.nib.webdav, app.nib.sync]
        # App Group ids the build asks for (progressive enhancement; AltStore/SideStore add ALTAppGroups).
        NibAppGroups: [group.app.nib.Nib]
        NSCameraUsageDescription: Nib uses the camera to insert photos and scan documents.
        NSMicrophoneUsageDescription: Nib records audio alongside your notes.
        NSPhotoLibraryUsageDescription: Nib inserts images from your photo library.
        NSPhotoLibraryAddUsageDescription: Nib saves images and exports to your photo library.
        NSSpeechRecognitionUsageDescription: Nib transcribes your recordings on this device.
        NSFaceIDUsageDescription: Nib uses Face ID to unlock password-protected notebooks.
        NSLocalNetworkUsageDescription: Nib uses the local network for live collaboration and the AI bridge.
        NSCalendarsFullAccessUsageDescription: Nib shows your calendar events and creates notes for meetings.
        NSCalendarsUsageDescription: Nib shows your calendar events and creates notes for meetings.
        NSBonjourServices: [_nib._tcp, _nib-collab._tcp, _nib-collab._udp]
        NSAppTransportSecurity:
          NSAllowsArbitraryLoads: true
        NSUserActivityTypes: [app.nib.openDocument]
        CFBundleURLTypes:
          - CFBundleURLName: app.nib
            CFBundleURLSchemes: [nib]
        UIApplicationShortcutItems:
          - UIApplicationShortcutItemType: app.nib.quicknote
            UIApplicationShortcutItemTitle: QuickNote
            UIApplicationShortcutItemIconSymbolName: square.and.pencil
        CFBundleDocumentTypes:
          - CFBundleTypeName: Nib Document
            CFBundleTypeRole: Editor
            LSHandlerRank: Owner
            LSTypeIsPackage: true
            LSItemContentTypes: [app.nib.document]
          - CFBundleTypeName: Nib Plugin
            CFBundleTypeRole: Viewer
            LSHandlerRank: Owner
            LSItemContentTypes: [app.nib.plugin]
          - CFBundleTypeName: Nib Element Collection
            CFBundleTypeRole: Viewer
            LSHandlerRank: Owner
            LSItemContentTypes: [app.nib.collection]
          - CFBundleTypeName: PDF
            CFBundleTypeRole: Viewer
            LSHandlerRank: Alternate
            LSItemContentTypes: [com.adobe.pdf]
          - CFBundleTypeName: Image
            CFBundleTypeRole: Viewer
            LSHandlerRank: Alternate
            LSItemContentTypes: [public.image]
          - CFBundleTypeName: Importable files
            CFBundleTypeRole: Viewer
            LSHandlerRank: Alternate
            LSItemContentTypes:
              - org.openxmlformats.wordprocessingml.document
              - com.microsoft.word.doc
              - org.openxmlformats.presentationml.presentation
              - com.microsoft.powerpoint.ppt
              - public.comma-separated-values-text
              - public.tab-separated-values-text
              - public.plain-text
              - public.zip-archive
        UTExportedTypeDeclarations:
          - UTTypeIdentifier: app.nib.document
            UTTypeDescription: Nib Document
            UTTypeConformsTo: [com.apple.package, public.composite-content]
            UTTypeTagSpecification:
              public.filename-extension: [nibnote]
          - UTTypeIdentifier: app.nib.plugin
            UTTypeDescription: Nib Plugin
            UTTypeConformsTo: [public.zip-archive]
            UTTypeTagSpecification:
              public.filename-extension: [nibplugin]
          - UTTypeIdentifier: app.nib.collection
            UTTypeDescription: Nib Element Collection
            UTTypeConformsTo: [public.zip-archive]
            UTTypeTagSpecification:
              public.filename-extension: [nibcollection]
          - UTTypeIdentifier: app.nib.fragment
            UTTypeDescription: Nib Fragment
            UTTypeConformsTo: [public.json]
          - UTTypeIdentifier: app.nib.pages
            UTTypeDescription: Nib Pages
            UTTypeConformsTo: [public.json]
  NibWidgets:
    type: app-extension
    platform: iOS
    sources:
      - path: NibWidgets
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.nib.Nib.widgets
        PRODUCT_NAME: NibWidgets
        SKIP_INSTALL: "YES"
    info:
      path: NibWidgets/Info.plist
      properties:
        CFBundleDisplayName: Nib
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        NSExtension:
          NSExtensionPointIdentifier: com.apple.widgetkit-extension
        NibAppGroups: [group.app.nib.Nib]
    entitlements:
      path: NibWidgets/NibWidgets.entitlements
      properties:
        com.apple.security.application-groups: [group.app.nib.Nib]
  NibShare:
    # Optional share extension (F064): writes into the App Group inbox when one exists, else hands small payloads
    # to the app through the pasteboard (nib://import?from=pasteboard). Removed in Nib-unsigned-noextensions.ipa.
    type: app-extension
    platform: iOS
    sources:
      - path: NibShare
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.nib.Nib.share
        PRODUCT_NAME: NibShare
        SKIP_INSTALL: "YES"
    info:
      path: NibShare/Info.plist
      properties:
        CFBundleDisplayName: Nib
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        NibAppGroups: [group.app.nib.Nib]
        NSExtension:
          NSExtensionPointIdentifier: com.apple.share-services
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).ShareViewController
          NSExtensionAttributes:
            NSExtensionActivationRule:
              NSExtensionActivationSupportsImageWithMaxCount: 20
              NSExtensionActivationSupportsText: true
              NSExtensionActivationSupportsWebURLWithMaxCount: 1
              NSExtensionActivationSupportsFileWithMaxCount: 20
    entitlements:
      path: NibShare/NibShare.entitlements
      properties:
        com.apple.security.application-groups: [group.app.nib.Nib]
schemes:
  Nib:
    build:
      targets:
        Nib: all
    run:
      config: Debug
    archive:
      config: Release
```

### `.github/workflows/ios.yml`

```yaml
name: iOS

on:
  push:
    branches: [main, 'feat/**']
  pull_request:
  workflow_dispatch:

concurrency:
  group: ios-${{ github.ref }}
  cancel-in-progress: true

env:
  # Xcode 26.6 = iOS 26 SDK, because the locked UI uses Liquid Glass. The deployment target stays iOS 17.0 and Swift 5
  # language mode; every iOS 26+ API sits behind #available. Bump the dd-x26.6-* cache keys together with this path.
  XCODE: /Applications/Xcode_26.6.app
  HOMEBREW_NO_AUTO_UPDATE: 1

jobs:
  # feat/<FeatureID> branches (one per feature agent): lint that feature, build and run ONLY its test target(s), and
  # build the app only when the feature owns files in Nib/, NibWidgets/ or NibShare/. No full suite, no IPA.
  feature:
    if: startsWith(github.ref, 'refs/heads/feat/')
    runs-on: macos-26
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0 # Scripts/restore_mtimes.py reads the history

      - name: Resolve feature from branch
        id: feat
        run: |
          python3 - "$GITHUB_REF_NAME" >> "$GITHUB_OUTPUT" <<'EOF'
          import json, os, re, sys
          m = re.match(r"feat/(F\d{3})\b", sys.argv[1])
          if not m:
              sys.exit("branch %s is not feat/<FeatureID> (e.g. feat/F012)" % sys.argv[1])
          spec = json.load(open("docs/forge-spec.json", encoding="utf-8"))
          f = next((x for x in spec["features"] if x["id"] == m.group(1)), None)
          if f is None:
              sys.exit("%s is not a feature in docs/forge-spec.json" % m.group(1))
          tests = sorted({p.split("/")[2] for p in f.get("tests", []) if p.startswith("NibKit/Tests/")})
          app = any(p.split("/")[0] in ("Nib", "NibWidgets", "NibShare") for p in f["files"] + f.get("tests", []))
          # A package scheme that builds only these test targets and their dependencies (not all ~200 targets).
          ref = ('<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{0}" BuildableName = "{0}" '
                 'BlueprintName = "{0}" ReferencedContainer = "container:"></BuildableReference>')
          entries = "".join('<BuildActionEntry buildForTesting = "YES" buildForRunning = "NO" buildForProfiling = "NO" '
                            'buildForArchiving = "NO" buildForAnalyzing = "NO">' + ref.format(t) + "</BuildActionEntry>"
                            for t in tests)
          testables = "".join('<TestableReference skipped = "NO">' + ref.format(t) + "</TestableReference>" for t in tests)
          scheme_dir = "NibKit/.swiftpm/xcode/xcshareddata/xcschemes"
          os.makedirs(scheme_dir, exist_ok=True)
          with open(scheme_dir + "/NibFeature.xcscheme", "w") as out:
              out.write('<?xml version="1.0" encoding="UTF-8"?>\n<Scheme LastUpgradeVersion = "2600" version = "1.7">'
                        '<BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES"><BuildActionEntries>'
                        + entries + '</BuildActionEntries></BuildAction><TestAction buildConfiguration = "Debug" '
                        'selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" '
                        'selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" '
                        'shouldUseLaunchSchemeArgsEnv = "YES"><Testables>' + testables + "</Testables></TestAction></Scheme>\n")
          print("id=" + f["id"])
          print("tests=" + " ".join(tests))
          print("app=" + ("true" if app else "false"))
          print("%s (%s): test targets [%s], app build %s" % (f["id"], f["module"], " ".join(tests), app), file=sys.stderr)
          EOF

      - name: Lint (this feature's module + spec + docs)
        run: python3 Scripts/lint.py --feature ${{ steps.feat.outputs.id }}

      - name: Select Xcode 26.6
        run: |
          if [ ! -d "$XCODE" ]; then
            echo "::error::$XCODE is not on this runner image any more; pick another Xcode 26.x in ios.yml (env.XCODE)"
            ls -d /Applications/Xcode*.app
            exit 1
          fi
          sudo xcode-select -s "$XCODE/Contents/Developer"
          xcodebuild -version

      - name: Metal toolchain (NibDesign compiles Shaders/NibLiquid.metal; Xcode 26 ships it as a component)
        run: xcrun metal --version >/dev/null 2>&1 || xcodebuild -downloadComponent MetalToolchain

      - name: Restore file times (keeps the restored DerivedData incremental)
        run: |
          python3 Scripts/restore_mtimes.py
          defaults write com.apple.dt.XCBuild IgnoreFileSystemDeviceInodeChanges -bool YES

      - name: Cache Swift packages
        uses: actions/cache@v4
        with:
          path: build/SourcePackages
          key: spm-${{ hashFiles('NibKit/Package.swift') }}

      - name: Restore DerivedData from main
        # Read-only: feature branches never save (111 branches x GBs would evict main's cache). Main's cache already
        # holds NibContracts, NibTesting and the SDK modules, so only this feature's module and tests compile.
        uses: actions/cache/restore@v4
        with:
          path: build/DerivedData
          key: dd-x26.6-main-${{ hashFiles('NibKit/Package.swift', 'NibKit/Sources/**', 'NibKit/Tests/**') }}
          restore-keys: dd-x26.6-main-

      - name: Pick simulator
        id: sim
        if: steps.feat.outputs.tests != ''
        run: echo "udid=$(python3 Scripts/pick_sim.py)" >> "$GITHUB_OUTPUT"

      - name: Build and test ${{ steps.feat.outputs.tests }}
        if: steps.feat.outputs.tests != ''
        working-directory: NibKit
        run: |
          set -o pipefail
          mkdir -p ../build
          SCHEME=NibFeature
          if ! xcodebuild -list -json 2>/dev/null | grep -q '"NibFeature"'; then
            echo "::warning::generated NibFeature scheme not picked up; falling back to NibKit-Package (builds every target)"
            SCHEME=NibKit-Package
          fi
          ONLY=""
          for t in ${{ steps.feat.outputs.tests }}; do ONLY="$ONLY -only-testing:$t"; done
          COMMON="-scheme $SCHEME -destination id=${{ steps.sim.outputs.udid }} -derivedDataPath ../build/DerivedData"
          COMMON="$COMMON -clonedSourcePackagesDirPath ../build/SourcePackages -skipPackagePluginValidation $ONLY"
          xcodebuild build-for-testing $COMMON 2>&1 | tee ../build/feature-build.log
          xcodebuild test-without-building $COMMON -parallel-testing-enabled NO \
            -resultBundlePath ../build/Feature.xcresult 2>&1 | tee ../build/feature-tests.log

      - name: Build the app (feature owns app-target files)
        if: steps.feat.outputs.app == 'true'
        run: |
          set -o pipefail
          mkdir -p build
          brew install xcodegen
          swift Scripts/make_icons.swift
          xcodegen generate
          xcodebuild build -project Nib.xcodeproj -scheme Nib -configuration Debug -destination 'generic/platform=iOS' \
            -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages \
            -skipPackagePluginValidation \
            CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" 2>&1 | tee build/app-build.log

      - name: Upload logs
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: feature-logs
          path: |
            build/*.log
            build/*.xcresult

  test:
    if: ${{ !startsWith(github.ref, 'refs/heads/feat/') }}
    runs-on: macos-26
    timeout-minutes: 120
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0 # Scripts/restore_mtimes.py reads the history

      - name: Select Xcode 26.6
        run: |
          if [ ! -d "$XCODE" ]; then
            echo "::error::$XCODE is not on this runner image any more; pick another Xcode 26.x in ios.yml (env.XCODE)"
            ls -d /Applications/Xcode*.app
            exit 1
          fi
          sudo xcode-select -s "$XCODE/Contents/Developer"
          xcodebuild -version

      - name: Metal toolchain (NibDesign compiles Shaders/NibLiquid.metal; Xcode 26 ships it as a component)
        run: xcrun metal --version >/dev/null 2>&1 || xcodebuild -downloadComponent MetalToolchain

      - name: Restore file times (keeps the restored DerivedData incremental)
        run: |
          python3 Scripts/restore_mtimes.py
          defaults write com.apple.dt.XCBuild IgnoreFileSystemDeviceInodeChanges -bool YES

      - name: Cache Swift packages
        uses: actions/cache@v4
        with:
          path: build/SourcePackages
          key: spm-${{ hashFiles('NibKit/Package.swift') }}

      - name: Restore DerivedData
        id: dd
        uses: actions/cache/restore@v4
        with:
          path: build/DerivedData
          key: dd-x26.6-main-${{ hashFiles('NibKit/Package.swift', 'NibKit/Sources/**', 'NibKit/Tests/**') }}
          restore-keys: dd-x26.6-main-

      - name: Install XcodeGen
        run: brew install xcodegen

      - name: Generate icons
        run: swift Scripts/make_icons.swift

      - name: Lint (code + docs)
        run: python3 Scripts/lint.py

      - name: Generate project
        run: xcodegen generate

      - name: Relay self-test
        run: |
          if [ -f tools/relay/relay.mjs ]; then node tools/relay/relay.mjs --selftest; else echo "relay not built yet"; fi

      - name: Pick simulator
        id: sim
        run: echo "udid=$(python3 Scripts/pick_sim.py)" >> "$GITHUB_OUTPUT"

      - name: Package tests (contracts, canary, conformance, integration, every module)
        working-directory: NibKit
        run: |
          set -o pipefail
          mkdir -p ../build
          xcodebuild test -scheme NibKit-Package \
            -destination "id=${{ steps.sim.outputs.udid }}" \
            -parallel-testing-enabled NO \
            -derivedDataPath ../build/DerivedData \
            -clonedSourcePackagesDirPath ../build/SourcePackages \
            -skipPackagePluginValidation \
            -resultBundlePath ../build/NibKitTests.xcresult 2>&1 | tee ../build/package-tests.log

      - name: Save DerivedData (main only; feature branches restore it)
        if: (success() || failure()) && github.ref == 'refs/heads/main' && steps.dd.outputs.cache-hit != 'true'
        uses: actions/cache/save@v4
        with:
          path: build/DerivedData
          key: ${{ steps.dd.outputs.cache-primary-key }}

      - name: Upload test logs
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: test-logs
          path: |
            build/*.log
            build/*.xcresult

  ipa:
    # Independent of `test`, so an IPA is produced even when tests fail. The archive compiles the app.
    if: ${{ !startsWith(github.ref, 'refs/heads/feat/') }}
    runs-on: macos-26
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode 26.6
        run: |
          if [ ! -d "$XCODE" ]; then echo "::error::$XCODE missing; update env.XCODE"; exit 1; fi
          sudo xcode-select -s "$XCODE/Contents/Developer"

      - name: Metal toolchain (NibDesign compiles Shaders/NibLiquid.metal; Xcode 26 ships it as a component)
        run: xcrun metal --version >/dev/null 2>&1 || xcodebuild -downloadComponent MetalToolchain

      - name: Cache Swift packages
        uses: actions/cache@v4
        with:
          path: build/SourcePackages
          key: spm-${{ hashFiles('NibKit/Package.swift') }}

      - name: Install XcodeGen
        run: brew install xcodegen

      - name: Generate icons and project
        run: |
          swift Scripts/make_icons.swift
          xcodegen generate

      - name: Archive
        run: |
          set -o pipefail
          mkdir -p build
          xcodebuild archive -project Nib.xcodeproj -scheme Nib -configuration Release \
            -destination 'generic/platform=iOS' -archivePath build/Nib.xcarchive \
            -clonedSourcePackagesDirPath build/SourcePackages \
            -skipPackagePluginValidation \
            CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" 2>&1 | tee build/archive.log

      - name: Package IPAs
        run: |
          set -e
          rm -rf build/Payload && mkdir -p build/Payload
          cp -R build/Nib.xcarchive/Products/Applications/Nib.app build/Payload/
          APP=build/Payload/Nib.app
          test -d "$APP/PlugIns/NibWidgets.appex" || { echo "::error::NibWidgets.appex missing from the IPA"; exit 1; }
          # Ad-hoc sign with the entitlements (App Group) so sideloading tools that honour them can register the group.
          for ext in "$APP"/PlugIns/*.appex; do
            name=$(basename "$ext" .appex)
            codesign --force --sign - --entitlements "$name/$name.entitlements" "$ext" || true
          done
          codesign --force --sign - --entitlements Nib/Nib.entitlements "$APP" || true
          (cd build && zip -qry Nib-unsigned.ipa Payload)
          rm -rf "$APP/PlugIns"
          codesign --force --sign - --entitlements Nib/Nib.entitlements "$APP" || true
          (cd build && zip -qry Nib-unsigned-noextensions.ipa Payload)

      - name: Upload IPAs
        uses: actions/upload-artifact@v4
        with:
          name: Nib-unsigned-ipa
          path: |
            build/Nib-unsigned.ipa
            build/Nib-unsigned-noextensions.ipa

      - name: Upload archive log
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: archive-log
          path: build/archive.log
```

### `Scripts/pick_sim.py`

```python
#!/usr/bin/env python3
"""Print the UDID of an available iPhone simulator on the newest iOS runtime that the selected SDK supports."""
import json
import subprocess
import sys

sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], text=True).strip()
sdk_major = int(sdk.split(".")[0])
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
best = None
for runtime, devices in data["devices"].items():
    if ".iOS-" not in runtime:
        continue
    version = tuple(int(x) for x in runtime.split(".iOS-")[-1].split("-") if x.isdigit())
    if not version or version[0] > sdk_major:
        continue  # a runtime newer than the SDK cannot run what we build
    for d in devices:
        if not d.get("isAvailable", True):
            continue
        score = (version, "iPhone" in d["name"], "Pro" in d["name"])
        if best is None or score > best[0]:
            best = (score, d["udid"], d["name"], runtime)
if best is None:
    sys.exit("no available iOS simulator for SDK %s" % sdk)
print(best[1])
print("picked %s (%s) for SDK %s" % (best[2], best[3], sdk), file=sys.stderr)
```

### `Scripts/restore_mtimes.py`

```python
#!/usr/bin/env python3
"""Set every tracked file's mtime to the time of the last commit that touched it (CI; needs checkout fetch-depth 0).

A fresh checkout stamps every file "now", so a restored DerivedData would recompile everything. With commit times,
files a commit did not touch look unchanged and only what changed recompiles (ios.yml also sets XCBuild's
IgnoreFileSystemDeviceInodeChanges). Files missing from the history keep "now", which only costs a rebuild.
"""
import os
import subprocess

os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
log =subprocess.run(["git", "-c", "core.quotePath=false", "log", "--format=@%ct", "--name-only", "--no-renames"],
                     capture_output=True, text=True, check=True).stdout
seen, when = set(), 0
for line in log.splitlines():
    if line.startswith("@"):
        when = int(line[1:])
    elif line and line not in seen:
        seen.add(line)  # newest commit first, so the first time a path appears is its last change
        if os.path.isfile(line):
            os.utime(line, (when, when))
print("restore_mtimes: %d paths" % len(seen))
```

### `Scripts/lint.py`

```python
#!/usr/bin/env python3
"""Nib repository lint (runs in CI before building).

Errors (exit 1):
  * a feature module imports another NibKit module (only NibContracts, NibDesign, its own module, ZIPFoundation,
    SwiftMath and Apple frameworks are allowed; Package.swift gives NibDesign to ui/fullstack modules only);
  * `applyRemote(` outside NibSync / FeatCollab;
  * `UserDefaults.standard` outside NibContracts / NibTesting / FeatManagedConfig;
  * `BGTaskScheduler` used by a feature (register BackgroundTaskDescriptors instead; the shell registers them);
  * a forge-spec feature file listed for a module that lives in another module's folder;
  * a file path owned by two features (files + tests);
  * docs lint: a Markdown table row in docs/*.md whose cell count differs from its header (unescaped `|`);
  * design rules (docs/DESIGN_SYSTEM.md §4) in UI feature code (modules with a ui/fullstack feature and their files
    under Nib/; never NibDesign, NibContracts, NibTesting or the app shell): raw colours, fonts, kerning/tracking,
    radii, shadows, animations and springs, materials and glass, haptics, SF Symbol strings, shaders, emoji, banned
    words and US spellings in UI copy, toast droplets and droplets inside a ScrollView/List.
Warnings: print( / fatalError( in package sources, spec files missing on disk, module files not listed in the spec,
  settings/Keychain/.nib-library writes outside a command file, and a feature registering command ids other than
  exactly its "Commands owned" list.
Usage: python3 Scripts/lint.py [--feature F012]   (--feature: code rules only for that feature's module; CI's
  feat/<FeatureID> run uses it, so another module's problems never fail your branch)
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "NibKit", "Sources")
SPEC = os.path.join(ROOT, "docs", "forge-spec.json")
REMOTE_OK = {"NibSync", "FeatCollab"}
DEFAULTS_OK = {"NibContracts", "FeatManagedConfig", "NibTesting"}
SHARED = ("NibContracts", "NibTesting", "NibDesign")  # architect-owned, importable modules (not features)

errors, warnings = [], []
modules = sorted(d for d in os.listdir(SRC) if os.path.isdir(os.path.join(SRC, d))) if os.path.isdir(SRC) else []
module_set = set(modules)
feature_filter = None
if len(sys.argv) > 2 and sys.argv[1] == "--feature":
    feature_filter = sys.argv[2]

spec = json.load(open(SPEC, encoding="utf-8")) if os.path.exists(SPEC) else {"features": []}
owned = {}
for f in spec["features"]:
    for p in f["files"] + f.get("tests", []):
        if p in owned:
            errors.append("%s is listed by both %s and %s" % (p, owned[p], f["id"]))
        owned[p] = f["id"]


def rel(p):
    return os.path.relpath(p, ROOT).replace(os.sep, "/")


def owned_commands(desc):
    """Command ids from a feature's 'Commands owned: …' list."""
    i = desc.find("Commands owned: ")
    if i < 0:
        return set()
    text = desc[i + len("Commands owned: "):]
    cut = text.find(". Module ")
    text = text[:cut] if cut >= 0 else text
    return set(re.findall(r'(?<![\w.`"])([a-z][a-zA-Z0-9]*(?:\.[a-zA-Z0-9]+)+) \{', text))


scan = modules
if feature_filter:
    scan = sorted({f["module"] for f in spec["features"] if f["id"] == feature_filter} & module_set)
    if not any(f["id"] == feature_filter for f in spec["features"]):
        errors.append("unknown feature %s (not in docs/forge-spec.json)" % feature_filter)

for m in scan:
    if m in SHARED:
        continue
    for dirpath, _, files in os.walk(os.path.join(SRC, m)):
        for fn in files:
            if not fn.endswith(".swift"):
                continue
            path = os.path.join(dirpath, fn)
            text = open(path, encoding="utf-8", errors="replace").read()
            r = rel(path)
            for imp in re.findall(r"^\s*(?:@testable\s+)?import\s+(?:class\s+|struct\s+|enum\s+|func\s+)?([A-Za-z_][A-Za-z0-9_]*)", text, re.M):
                if imp in module_set and imp not in ("NibContracts", "NibDesign", m):
                    errors.append("%s imports feature module %s (use commands/services instead)" % (r, imp))
            if "applyRemote(" in text and m not in REMOTE_OK:
                errors.append("%s calls applyRemote (only NibSync/FeatCollab may)" % r)
            if "UserDefaults.standard" in text and m not in DEFAULTS_OK:
                errors.append("%s uses UserDefaults.standard (use SettingsStore / SettingKey)" % r)
            if "BGTaskScheduler" in text:
                errors.append("%s uses BGTaskScheduler (register a BackgroundTaskDescriptor; app.scheduleBackgroundTask)" % r)
            if re.search(r"(?<![A-Za-z_.])print\(", text):
                warnings.append("%s uses print( (use os.Logger)" % r)
            if "fatalError(" in text and "init(coder" not in text:
                warnings.append("%s uses fatalError(" % r)
            is_command_file = "NibCommand" in text or "CommandDescriptor(" in text
            if not is_command_file and re.search(r"settings\.set(JSON)?\(|Keychain\.set(String)?\(|\.nib-library/", text):
                warnings.append("%s writes settings/Keychain/.nib-library outside a command file (make it a command)" % r)
            if r not in owned and not re.search(r"Feature\.swift$", fn):
                warnings.append("%s is not listed in forge-spec.json" % r)

for f in spec["features"]:
    if feature_filter and f["id"] != feature_filter:
        continue
    for p in f["files"]:
        if p.startswith("NibKit/Sources/"):
            mod = p.split("/")[2]
            if mod != f["module"]:
                errors.append("%s lists %s outside its module %s" % (f["id"], p, f["module"]))
        if feature_filter and not os.path.exists(os.path.join(ROOT, p)):
            warnings.append("%s: %s does not exist yet" % (f["id"], p))
    present = [os.path.join(ROOT, p) for p in f["files"] if p.endswith(".swift") and os.path.exists(os.path.join(ROOT, p))]
    if present:
        registered = set()
        for p in present:
            registered |= set(re.findall(r'CommandDescriptor\(\s*id:\s*"([^"]+)"', open(p, encoding="utf-8", errors="replace").read()))
        expected = owned_commands(f["description"])
        for extra in sorted(registered - expected):
            warnings.append("%s registers %s, which ARCHITECTURE §6.5 does not list for it" % (f["id"], extra))
        if feature_filter:
            for missing in sorted(expected - registered):
                warnings.append("%s does not register %s yet" % (f["id"], missing))

# Design rules (DESIGN_SYSTEM.md §4): UI features compose NibDesign tokens and components only. NibDesign itself (and
# the architect's app shell) is exempt. ponytail: line regexes, not a Swift parser; a rule that misfires gets narrowed.
DESIGN_RULES = [
    ("raw colour (use NibColor / NibUIColor / NibInk / NibPaper)",
     r"(?<![\w.])(Color|UIColor)\(\s*(red|hue):|Color\(\s*hex|#colorLiteral|Color\(\s*\.sRGB|"
     r"Color\.(black|white)\.opacity\("),
    ("raw font (use NibFont / NibUIFont / NibFont.glyph)",
     r"(\.font\(\s*|Font)\.system\(\s*size:|Font\.custom\(|UIFont\.systemFont\(\s*ofSize:|UIFont\(\s*name:|"
     r"\.boldSystemFont\(|\.monospacedSystemFont\("),
    ("hand-set kerning or tracking (text styles carry Apple's tracking)", r"\.(kerning|tracking)\("),
    ("raw radius (use NibRadius / NibDropletShape)",
     r"\.cornerRadius\(\s*[\d.]|RoundedRectangle\(\s*cornerRadius:\s*[\d.]|\.cornerRadius\s*=\s*[\d.]|"
     r"UnevenRoundedRectangle\([^)]*Radius:\s*[\d.]"),
    ("raw shadow (use .nibElevation / CALayer.nibElevation)", r"\.shadow\(|\.shadow(Opacity|Radius)\b"),
    ("raw motion (use NibMotion.x.animation / NibMotion.animate / NibMotion.animateUIKit)",
     r"\.animation\(\s*\.(easeIn|easeOut|easeInOut|linear|default|bouncy|snappy|smooth)\b|"
     r"UIView\.animate\(\s*withDuration:|CABasicAnimation\("),
    ("materials and glass (use .droplet / nibGlass / opaque surfaces)",
     r"\.(ultraThin|thin|regular|thick|ultraThick)Material\b|(?<![\w.])Material\.|UIBlurEffect|UIVisualEffectView|"
     r"UIGlassEffect|UIGlassContainerEffect|\.glassEffect\(|GlassEffectContainer|\.buttonStyle\(\s*\.glass"),
    ("raw haptics (use NibHaptics.play / .nibHaptic)",
     r"UIImpactFeedbackGenerator|UISelectionFeedbackGenerator|UINotificationFeedbackGenerator|CHHapticEngine|"
     r"\.sensoryFeedback\("),
    ("SF Symbol string (use Image(nib:) / UIImage(nib:) / NibSymbol)",
     r"(?<![\w.])(Image|UIImage)\(\s*systemName:|Label\([^)]*systemImage:"),
    ("banned AI glyph (the drop is the mark)", r"\"(sparkles|sparkle|wand\.and\.stars|wand\.and\.rays)[\w.]*\""),
    ("toast droplet (use .nibToast($item))", r"\.droplet\([^)]*style:\s*\.toast\b"),
    ("shader in a feature (NibDesign components only)", r"\.(layerEffect|distortionEffect|colorEffect)\(|ShaderLibrary"),
]
# A six-digit hex literal next to a colour (ZIP and PDF magic numbers pass); withAnimation / .spring( without a token.
DESIGN_HEX = re.compile(r"\b0x[0-9A-Fa-f]{6}\b")
DESIGN_SPRING = re.compile(r"withAnimation\s*[({]|\.spring\(")
CANVAS_FEEDBACK_OK = {"FeatPencilHardware", "FeatTransform"}
EMOJI = re.compile("[\U0001F000-\U0001FAFF☀-➿]")
BANNED_WORDS = re.compile(r"\b(seamless|elevate|unleash|supercharge|magic)", re.I)
US_SPELLINGS = re.compile(r"\b(colors?|favorites?|customiz\w*|organiz\w*|summariz\w*|recogniz\w*|centers?|centered|"
                          r"gray|canceled|behaviors?)\b", re.I)
STRING_LITERAL = re.compile(r'"(?:[^"\\\n]|\\.)*"')


def strip_comment(line):
    """The line without a trailing // comment (a // inside a string literal is kept)."""
    out, in_str, i = [], False, 0
    while i < len(line):
        c = line[i]
        if c == "\\" and in_str:
            out.append(line[i:i + 2])
            i += 2
            continue
        if c == '"':
            in_str = not in_str
        elif not in_str and line.startswith("//", i):
            break
        out.append(c)
        i += 1
    return "".join(out)


def localized_literals(line):
    """String literals passed to String(localized:) on this line, with interpolations removed."""
    return [re.sub(r"\\\([^)]*\)", " ", m.group(1))
            for m in re.finditer(r'String\(\s*localized:\s*("(?:[^"\\\n]|\\.)*")', line)]


def scroll_bodies(text):
    """(start, end) character spans of every ScrollView { … } / List { … } body."""
    spans = []
    for m in re.finditer(r"\b(ScrollView|List)\b[^{}\n]*\{", text):
        depth, i = 1, m.end()
        while i < len(text) and depth:
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        spans.append((m.end(), i))
    return spans


def design_lint(path, module):
    r = rel(path)
    text = open(path, encoding="utf-8", errors="replace").read()
    for n, raw in enumerate(text.split("\n"), 1):
        line = strip_comment(raw)
        if not line.strip() or line.lstrip().startswith(("*", "/*")):
            continue
        for what, pattern in DESIGN_RULES:
            if re.search(pattern, line):
                errors.append("%s:%d: %s" % (r, n, what))
        if DESIGN_HEX.search(line) and re.search(r"Color|nib", line):
            errors.append("%s:%d: raw hex colour (use NibColor / NibInk / NibPaper)" % (r, n))
        if DESIGN_SPRING.search(line) and "NibMotion" not in line:
            errors.append("%s:%d: animation or spring without a NibMotion token" % (r, n))
        if "UICanvasFeedbackGenerator" in line and module not in CANVAS_FEEDBACK_OK:
            errors.append("%s:%d: UICanvasFeedbackGenerator outside FeatPencilHardware / FeatTransform" % (r, n))
        if any(EMOJI.search(lit) for lit in STRING_LITERAL.findall(line)):
            errors.append("%s:%d: emoji in a string literal" % (r, n))
        for lit in localized_literals(line):
            if BANNED_WORDS.search(lit):
                errors.append("%s:%d: banned word in UI copy %s" % (r, n, lit))
            m = US_SPELLINGS.search(lit)
            if m:
                errors.append("%s:%d: US spelling '%s' in UI copy (British English: colour, favourite, centre...)"
                              % (r, n, m.group(0)))
    for start, end in scroll_bodies(text):
        if ".droplet(" in text[start:end]:
            errors.append("%s:%d: .droplet inside a ScrollView/List (chrome belongs to the container above the "
                          "content)" % (r, text.count("\n", 0, start) + 1))


# Scope: modules with a ui/fullstack feature (Package.swift gives them NibDesign) and feature-owned Swift files under
# Nib/ (the app target links NibKit). Not NibWidgets (no NibDesign there) and not the architect's shell (Nib/App).
design_files = []
for m in sorted({f["module"] for f in spec["features"] if f.get("layer") in ("ui", "fullstack")} & set(scan)):
    if m in SHARED:
        continue
    for dirpath, _, files in os.walk(os.path.join(SRC, m)):
        design_files += [(os.path.join(dirpath, fn), m) for fn in sorted(files) if fn.endswith(".swift")]
for f in spec["features"]:
    if f.get("layer") in ("ui", "fullstack") and (not feature_filter or f["id"] == feature_filter):
        design_files += [(os.path.join(ROOT, p), f["module"]) for p in f["files"]
                         if p.startswith("Nib/") and p.endswith(".swift") and os.path.exists(os.path.join(ROOT, p))]
for path, m in design_files:
    design_lint(path, m)

# Docs lint: every Markdown table row has as many cells as its header.
for md in sorted(glob.glob(os.path.join(ROOT, "docs", "*.md"))):
    header, in_code = None, False
    for n, line in enumerate(open(md, encoding="utf-8").read().split("\n"), 1):
        if line.strip().startswith("```"):
            in_code = not in_code
        if in_code or not line.startswith("|"):
            header = None
            continue
        parts = [c.strip() for c in re.split(r"(?<!\\)\|", line.strip().strip("|"))]
        cells = len(parts)
        if header is None:
            header = cells
        elif cells != header:
            errors.append("%s:%d: table row has %d cells, header has %d (escape | as \\|)" % (rel(md), n, cells, header))
        elif md.endswith("ARCHITECTURE.md") and cells == 5 and re.match(r"`[a-z][a-zA-Z0-9]*(\.[a-zA-Z0-9]+)+`$", parts[0]):
            # §6.5 catalogue row: | `id` | effect | params | Fxxx | summary |
            if not re.match(r"F\d{3}$", parts[3]) or not re.match(r"(read|session|edit|library|irreversible)\b", parts[1]):
                errors.append("%s:%d: catalogue row %s is malformed (effect '%s', owner '%s')" % (rel(md), n, parts[0], parts[1], parts[3]))

for w in warnings:
    print("warning: " + w)
for e in errors:
    print("error: " + e)
print("lint: %d error(s), %d warning(s)" % (len(errors), len(warnings)))
sys.exit(1 if errors else 0)
```

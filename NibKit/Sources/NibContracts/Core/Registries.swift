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

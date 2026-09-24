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
public final class Registry<D: Registrable> {
    private var items: [D] = []
    private let lock = NSLock()

    public init() {}

    /// Sorted by (order, id).
    public var all: [D] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    public func register(_ d: D) {
        lock.lock()
        items.removeAll { $0.id == d.id }
        items.append(d)
        items.sort { ($0.order, $0.id) < ($1.order, $1.id) }
        lock.unlock()
        NotificationCenter.default.post(name: .nibRegistryDidChange, object: self)
    }

    public func unregister(id: String) {
        lock.lock()
        items.removeAll { $0.id == id }
        lock.unlock()
        NotificationCenter.default.post(name: .nibRegistryDidChange, object: self)
    }

    public func unregister(owner: String) {
        lock.lock()
        items.removeAll { $0.owner == owner }
        lock.unlock()
        NotificationCenter.default.post(name: .nibRegistryDidChange, object: self)
    }

    public func get(_ id: String) -> D? {
        lock.lock()
        defer { lock.unlock() }
        return items.first { $0.id == id }
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
    public var render: (_ params: [String: JSONValue], _ size: PageSize, _ scale: Double) -> TemplateRender

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
}

// MARK: - Item drawing

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

    public init(cg: CGContext, scale: Double, doc: DocumentID, page: PageID, darkPaper: Bool = false,
                assets: AssetStore? = nil, replay: ReplayState? = nil) {
        self.cg = cg
        self.scale = scale
        self.doc = doc
        self.page = page
        self.darkPaper = darkPaper
        self.assets = assets
        self.replay = replay
    }
}

/// Draws one kind of item into a tile, a thumbnail or an export. Must be thread-safe (render threads).
public protocol ItemDrawer: AnyObject {
    func draw(_ item: Item, in context: DrawContext)
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

    public init(folder: FolderID? = nil, document: DocumentID? = nil, position: PagePosition = .end, anchorPage: PageID? = nil) {
        self.folder = folder
        self.document = document
        self.position = position
        self.anchorPage = anchorPage
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

public struct ExporterDescriptor: Registrable {
    public var id: String
    public var title: String
    public var fileExtension: String
    public var utType: String
    public var order: Int
    public var owner: String
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

/// An action users can bind to Apple Pencil double-tap or squeeze (offered by F043's settings).
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

    public init() {}

    public func drawer(for item: Item) -> ItemDrawer? {
        drawers.get(item.drawKey)?.drawer ?? drawers.get(item.kind.rawValue)?.drawer
    }

    public func template(_ ref: TemplateRef) -> TemplateDefinition? { templates.get(ref.id) }

    public func importer(forExtension ext: String) -> ImporterDescriptor? {
        let e = ext.lowercased()
        return importers.all.first { $0.fileExtensions.contains(e) }
    }
}

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

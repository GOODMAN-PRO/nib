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
        let pts = (0..<20).map { i in StrokePoint(x: Float(72 + i * 4), y: Float(120 + (i % 5)), t: Float(i) * 0.01) }
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
    public init(features: [NibFeature.Type] = [], fixtures: Bool = true, deviceID: UInt32 = 7) {
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
        // Features may install real services in `register`; tests keep the in-memory ones.
        app.workspace.persistence = persistence
        app.services.library = library
        app.services.assets = assets
        app.settings.syncedBackend = nil
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
